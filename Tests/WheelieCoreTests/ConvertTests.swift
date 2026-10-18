import AppKit
import Compression
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

/// Regression tests for inner-ring conversions: WebP orientation/CMYK, multi-page TIFF → PDF (and its
/// limits), the ffmpeg AVIF fallback, video without audio → audio, and .ts/.mts classification.
final class ConvertRegressionTests: XCTestCase {
    // MARK: Video → audio

    func testVideoWithoutAudioToAudioFormatSaysSo() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil, "ffmpeg not installed")
        let dir = try makeTempDir()
        let clip = dir.appendingPathComponent("silent.mp4")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
                                       "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", clip.path])
        for format in [OutputFormat.mp3, .m4a, .wav] {
            do {
                _ = try await Converter.convert(clip, to: format)
                XCTFail("expected failure for \(format)")
            } catch {
                XCTAssertEqual(error.localizedDescription, "silent.mp4 has no audio track.")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("silent.\(format.fileExtension)").path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["silent.mp4"])
    }

    func testVideoWithAudioStillConvertsToAudio() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil, "ffmpeg not installed")
        let dir = try makeTempDir()
        let clip = dir.appendingPathComponent("talk.mov")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
                                       "-f", "lavfi", "-i", "sine=frequency=440", "-t", "1", "-c:v", "mjpeg",
                                       "-c:a", "pcm_s16le", clip.path])
        let hasAudio = await Converter.hasAudioStream(clip)
        XCTAssertEqual(hasAudio, true)
        let wav = try await Converter.convert(clip, to: .wav)[0]
        XCTAssertGreaterThan(try Data(contentsOf: wav).count, 1000)
    }

    // MARK: WebP

    func testWebPAppliesEXIFOrientation() async throws {
        try XCTSkipIf(Tools.locate("cwebp") == nil, "cwebp not installed")
        let dir = try makeTempDir()
        for ext in ["jpg", "tiff"] {
            let source = dir.appendingPathComponent("rot6.\(ext)")
            try writeImage(solidImage(width: 40, height: 20), to: source, type: ext == "jpg" ? .jpeg : .tiff,
                           properties: [kCGImagePropertyOrientation: 6])
            XCTAssertFalse(Converter.cwebpReadsDirectly(source))
            let out = try await Converter.convert(source, to: .webp)[0]
            let size = try pixelSize(out)
            XCTAssertEqual(size.width, 20, ext)
            XCTAssertEqual(size.height, 40, ext)
        }
        // Upright RGB sources still go straight to cwebp.
        let upright = dir.appendingPathComponent("upright.png")
        try Converter.writeImage(solidImage(width: 40, height: 20), to: upright, type: .png)
        XCTAssertTrue(Converter.cwebpReadsDirectly(upright))
        XCTAssertFalse(Converter.cwebpReadsDirectly(dir.appendingPathComponent("nothing.bmp")))
    }

    func testWebPConvertsCMYKJPEG() async throws {
        try XCTSkipIf(Tools.locate("cwebp") == nil, "cwebp not installed")
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("cmyk.jpg")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.genericCMYK)!,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(CGColor(genericCMYKCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        try Converter.writeImage(ctx.makeImage()!, to: source, type: .jpeg)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyColorModel] as? String, kCGImagePropertyColorModelCMYK as String)
        XCTAssertFalse(Converter.cwebpReadsDirectly(source))
        let out = try await Converter.convert(source, to: .webp)[0]
        XCTAssertEqual(try pixelSize(out).width, 40)
    }

    // MARK: Multi-page TIFF → PDF

    func testMultiPageTIFFToPDFKeepsEveryPage() async throws {
        let dir = try makeTempDir()
        let tiff = dir.appendingPathComponent("scan.tiff")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 4, nil))
        for width in [60, 80, 100] {
            let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
            CGImageDestinationAddImage(dest, solidImage(width: width, height: 50), props as CFDictionary)
        }
        // A page stored sideways (orientation 6) comes out upright.
        let rotated: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
                                        kCGImagePropertyOrientation: 6]
        CGImageDestinationAddImage(dest, solidImage(width: 100, height: 50), rotated as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let pdf = try await Converter.convert(tiff, to: .pdf)[0]
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(doc.pageCount, 4)
        // 144 dpi: 100 px wide is 50 pt.
        XCTAssertEqual(doc.page(at: 2)!.bounds(for: .mediaBox).width, 50, accuracy: 0.5)
        XCTAssertEqual(doc.page(at: 2)!.bounds(for: .mediaBox).height, 25, accuracy: 0.5)
        XCTAssertEqual(doc.page(at: 3)!.bounds(for: .mediaBox).width, 25, accuracy: 0.5)
        XCTAssertEqual(doc.page(at: 3)!.bounds(for: .mediaBox).height, 50, accuracy: 0.5)
    }

    func testTIFFWithTooManyPagesIsRefusedBeforeDecoding() async throws {
        let dir = try makeTempDir()
        let tiff = dir.appendingPathComponent("fax.tiff")
        try craftedTIFF(pages: Array(repeating: (1, 1), count: Converter.maxTIFFPages + 1)).write(to: tiff)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), Converter.maxTIFFPages + 1)

        let start = Date()
        await assertTooLarge(try await Converter.convert(tiff, to: .pdf), contains: "2001 pages")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["fax.tiff"])

        // The same kind of file within the limits converts (so the refusals above aren't just bad TIFFs).
        try craftedTIFF(pages: [(1, 1), (10, 10), (20, 5)]).write(to: tiff)
        let pdf = try await Converter.convert(tiff, to: .pdf)[0]
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 3)
    }

    func testTIFFWithHugeDeclaredPageIsRefusedWithoutAllocating() async throws {
        let dir = try makeTempDir()
        let tiff = dir.appendingPathComponent("bomb.tiff")
        // About 140 KB on disk, holding a 12000 × 12000 (144 MP) second page.
        try craftedTIFF(pages: [(10, 10), (12_000, 12_000)]).write(to: tiff)
        XCTAssertLessThan(try Data(contentsOf: tiff).count, 200_000)

        let start = Date()
        await assertTooLarge(try await Converter.convert(tiff, to: .pdf), contains: "page 2 is 12000 × 12000 pixels")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["bomb.tiff"])
    }

    func testTIFFWhosePagesAddUpTooMuchIsRefused() async throws {
        let dir = try makeTempDir()
        let tiff = dir.appendingPathComponent("stack.tiff")
        // Each page is exactly the per-page limit (100 MP); eleven of them pass 1 GP.
        try craftedTIFF(pages: Array(repeating: (10_000, 10_000), count: 11)).write(to: tiff)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        XCTAssertThrowsError(try Converter.tiffPageProperties(src, name: "stack.tiff")) { error in
            guard case DocumentError.tooLarge(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("add up to more than 1000 megapixels"), message)
        }
        await assertTooLarge(try await Converter.convert(tiff, to: .pdf), contains: "add up to")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["stack.tiff"])
    }

    // MARK: AVIF (ffmpeg fallback)

    func testAVIFFFmpegArgumentsMatchTheEncoder() async throws {
        let png = URL(fileURLWithPath: "/tmp/in.png"), avif = URL(fileURLWithPath: "/tmp/out.avif")
        XCTAssertFalse(Converter.ffmpegAVIFArguments(input: png, output: avif, encoder: "libsvtav1").contains("-still-picture"))
        XCTAssertFalse(Converter.ffmpegAVIFArguments(input: png, output: avif, encoder: "librav1e").contains("-still-picture"))
        XCTAssertTrue(Converter.ffmpegAVIFArguments(input: png, output: avif, encoder: "libaom-av1").contains("-still-picture"))
        XCTAssertEqual(Converter.ffmpegAVIFArguments(input: png, output: avif, encoder: "libsvtav1").last, avif.path)

        // The fallback itself, with whatever AV1 encoder this ffmpeg has.
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let encoder = try await Converter.ffmpegAV1Encoder()
        try XCTSkipIf(encoder == nil, "ffmpeg has no AV1 encoder")
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("in.png"), output = dir.appendingPathComponent("out.avif")
        try Converter.writeImage(solidImage(width: 33, height: 21), to: source, type: .png)
        try await Converter.writeAVIFWithFFmpeg(source, to: output)
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
    }

    // MARK: Classification

    func testTypeScriptSourcesAreNotVideo() throws {
        let dir = try makeTempDir()
        for name in ["app.ts", "mod.mts", "types.m2ts"] {
            let url = dir.appendingPathComponent(name)
            try Data("export function greet(name: string): string {\n  return `Hello ${name}`\n}\n".utf8).write(to: url)
            XCTAssertEqual(FileKind(url: url), .unknown, name)
            XCTAssertEqual(OutputFormat.targets(for: [url]), [], name)
        }
        var ts = Data(count: 400)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        let stream = dir.appendingPathComponent("broadcast.ts")
        try ts.write(to: stream)
        XCTAssertEqual(FileKind(url: stream), .video)
        var m2ts = Data(count: 400)
        m2ts[4] = 0x47; m2ts[196] = 0x47
        let avchd = dir.appendingPathComponent("00001.mts")
        try m2ts.write(to: avchd)
        XCTAssertEqual(FileKind(url: avchd), .video)
        // Not readable (yet): decided by the extension, as before.
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/nonexistent/clip.mts")), .video)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/nonexistent/clip.m2ts")), .video)
    }

    func testRealTransportStreamIsVideo() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try makeTempDir()
        let clip = dir.appendingPathComponent("recording.ts")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
                                       "-t", "1", "-c:v", "mpeg2video", "-f", "mpegts", clip.path])
        XCTAssertEqual(FileKind(url: clip), .video)
    }
}

// MARK: Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-convert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func solidImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func writeImage(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

private func pixelSize(_ url: URL) throws -> (width: Int, height: Int) {
    let props = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    let width = try XCTUnwrap(props?[kCGImagePropertyPixelWidth] as? Int)
    let height = try XCTUnwrap(props?[kCGImagePropertyPixelHeight] as? Int)
    return (width, height)
}

/// Expects `DocumentError.tooLarge` whose message contains `text`.
private func assertTooLarge(_ body: @autoclosure () async throws -> [URL], contains text: String,
                            file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("expected a too-large error", file: file, line: line)
    } catch {
        guard case DocumentError.tooLarge(let message) = error else {
            return XCTFail("unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertTrue(message.contains(text), message, file: file, line: line)
    }
}

/// A valid little-endian 8-bit grayscale TIFF with pages of the given sizes, each one black and stored
/// as a single Deflate strip, so a 100+ megapixel page is a few hundred KB on disk. Pages of the same
/// size share one strip.
private func craftedTIFF(pages: [(width: Int, height: Int)]) -> Data {
    var data = Data()
    func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func u32(_ v: Int) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> shift) & 0xFF)) } }

    data.append(contentsOf: [0x49, 0x49]); u16(42); u32(0)   // first IFD offset patched below
    var strips: [String: (offset: Int, length: Int)] = [:]
    for page in pages where strips["\(page.width)x\(page.height)"] == nil {
        let strip = zlibZeros(page.width * page.height)
        strips["\(page.width)x\(page.height)"] = (data.count, strip.count)
        data.append(strip)
        if data.count % 2 == 1 { data.append(0) }
    }

    let firstIFD = data.count
    data.replaceSubrange(4..<8, with: [UInt8(firstIFD & 0xFF), UInt8((firstIFD >> 8) & 0xFF),
                                       UInt8((firstIFD >> 16) & 0xFF), UInt8((firstIFD >> 24) & 0xFF)])
    let ifdSize = 2 + 9 * 12 + 4
    for (index, page) in pages.enumerated() {
        let strip = strips["\(page.width)x\(page.height)"]!
        // Width, height, 8 bits, Deflate, BlackIsZero, strip offset, 1 sample, rows per strip, strip bytes.
        let entries: [(tag: Int, type: Int, value: Int)] = [
            (256, 4, page.width), (257, 4, page.height), (258, 3, 8), (259, 3, 8), (262, 3, 1),
            (273, 4, strip.offset), (277, 3, 1), (278, 4, page.height), (279, 4, strip.length),
        ]
        u16(entries.count)
        for entry in entries {
            u16(entry.tag); u16(entry.type); u32(1)
            if entry.type == 3 { u16(entry.value); u16(0) } else { u32(entry.value) }
        }
        u32(index + 1 < pages.count ? firstIFD + (index + 1) * ifdSize : 0)
    }
    return data
}

/// A zlib stream (RFC 1950) of `count` zero bytes, compressed 1 MB at a time.
private func zlibZeros(_ count: Int) -> Data {
    let chunk = 1 << 20, dstSize = 1 << 16
    let src = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
    src.initialize(repeating: 0, count: chunk)
    defer { src.deallocate(); dst.deallocate() }
    var stream = compression_stream(dst_ptr: dst, dst_size: dstSize, src_ptr: src, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
        return Data()
    }
    defer { compression_stream_destroy(&stream) }
    var out = Data([0x78, 0x01])   // zlib header; COMPRESSION_ZLIB writes raw Deflate
    var remaining = count
    while true {
        if stream.src_size == 0 && remaining > 0 {
            stream.src_ptr = UnsafePointer(src)
            stream.src_size = min(chunk, remaining)
            remaining -= stream.src_size
        }
        stream.dst_ptr = dst
        stream.dst_size = dstSize
        let status = compression_stream_process(&stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
        out.append(dst, count: dstSize - stream.dst_size)
        if status != COMPRESSION_STATUS_OK { break }
    }
    let adler = UInt32(count % 65521) << 16 | 1   // Adler-32 of all zeros
    out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
    return out
}
