import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

// MARK: - Metadata

final class MetadataTests: XCTestCase {
    func testReaderFindsGPSCameraAndDates() throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("photo.jpg")
        try writeImage(noiseImage(400, 300), to: jpg, type: .jpeg, properties: privateMetadata())

        let groups = MetadataReader.readImage(jpg)
        let location = try XCTUnwrap(groups.first { $0.category == .location })
        XCTAssertEqual(location.entries.first { $0.label == "Latitude" }?.value, "37.330000° N")
        XCTAssertEqual(location.entries.first { $0.label == "Longitude" }?.value, "122.031000° W")
        XCTAssertNotNil(location.entries.first { $0.label == "Altitude" })
        let camera = try XCTUnwrap(groups.first { $0.category == .camera })
        XCTAssertEqual(camera.entries.first { $0.label == "Make" }?.value, "ACME")
        XCTAssertEqual(camera.entries.first { $0.label == "Lens" }?.value, "Test Lens 50mm")
        let dates = try XCTUnwrap(groups.first { $0.category == .dates })
        XCTAssertEqual(dates.entries.first { $0.label == "Taken" }?.value, "2024-05-06 07:08:09")
        XCTAssertNotNil(groups.first { $0.category == .people })
        XCTAssertNotNil(groups.first { $0.category == .software })
    }

    func testStripJPEGRemovesEXIFAndGPSLosslessly() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("photo.jpg")
        try writeImage(noiseImage(400, 300), to: jpg, type: .jpeg, properties: privateMetadata())
        // Add what cameras and editors leave behind: a second EXIF block with an embedded thumbnail
        // (which can show the uncropped original), a comment, and a trailer after end-of-image.
        let thumbnail = dir.appendingPathComponent("thumb.jpg")
        try writeImage(noiseImage(32, 24), to: thumbnail, type: .jpeg, properties: [:])
        var bytes = try Data(contentsOf: jpg)
        let exif = Data("Exif\0\0".utf8) + Data([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0]) + (try Data(contentsOf: thumbnail))
        let comment = Data("secret comment".utf8)
        var inserted = Data([0xFF, 0xE1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 0xFF)]) + exif
        inserted += Data([0xFF, 0xFE, 0, UInt8(comment.count + 2)]) + comment
        bytes.insert(contentsOf: inserted, at: 2)
        bytes += Data("TRAILER secret".utf8)
        try bytes.write(to: jpg)
        XCTAssertEqual(jpegStarts(bytes), 2, "fixture carries a thumbnail")
        let originalBytes = try Data(contentsOf: jpg)

        let out = try await MetadataStripper.strip(jpg)
        let cleaned = try Data(contentsOf: out)
        XCTAssertEqual(jpegStarts(cleaned), 1, "embedded thumbnail removed")
        XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains("secret"))
        XCTAssertEqual(out.lastPathComponent, "photo clean.jpg")
        XCTAssertEqual(try Data(contentsOf: jpg), originalBytes, "original must stay unchanged")

        let props = try properties(out)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary])
        XCTAssertNil((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 400)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 300)
        XCTAssertTrue(MetadataReader.readImage(out).isEmpty)
        XCTAssertEqual(rgba(try decode(out)), rgba(try decode(jpg)), "JPEG data must be copied, not re-encoded")
        XCTAssertLessThan(ByteSize.of(out), ByteSize.of(jpg))
    }

    func testStripPNGLosslesslyKeepsOrientation() async throws {
        let dir = try compressTempDir()
        let png = dir.appendingPathComponent("shot.png")
        var meta = privateMetadata()
        meta[kCGImagePropertyOrientation] = 6
        meta[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGAuthor: "Jane", kCGImagePropertyPNGComment: "secret"]
        try writeImage(noiseImage(400, 300), to: png, type: .png, properties: meta)
        XCTAssertNotNil(MetadataReader.readImage(png).first { $0.category == .location })

        let out = try await MetadataStripper.strip(png)
        XCTAssertEqual(out.lastPathComponent, "shot clean.png")
        let props = try properties(out)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 6, "orientation is kept as the only tag")
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 400)
        XCTAssertTrue(MetadataReader.readImage(out).isEmpty, "\(MetadataReader.readImage(out))")
        XCTAssertEqual(rgba(try decode(out)), rgba(try decode(png)))
        XCTAssertFalse(String(decoding: try Data(contentsOf: out), as: UTF8.self).contains("Jane"))
    }

    func testStripReencodedFormatsBakeOrientation() async throws {
        let dir = try compressTempDir()
        for (ext, type) in [("heic", UTType.heic), ("tiff", .tiff)] {
            let file = dir.appendingPathComponent("rotated.\(ext)")
            var meta = privateMetadata()
            meta[kCGImagePropertyOrientation] = 6
            try writeImage(noiseImage(400, 300), to: file, type: type, properties: meta)
            XCTAssertFalse(MetadataReader.readImage(file).isEmpty, ext)

            let out = try await MetadataStripper.strip(file)
            XCTAssertEqual(out.pathExtension, ext)
            let props = try properties(out)
            XCTAssertNil(props[kCGImagePropertyGPSDictionary], ext)
            XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1, ext)
            // Upright pixels: 400×300 rotated by orientation 6 becomes 300×400.
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300, ext)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400, ext)
            XCTAssertTrue(MetadataReader.readImage(out).isEmpty, "\(ext): \(MetadataReader.readImage(out))")
        }
    }

    func testStripPDFRemovesInfoAndXMP() async throws {
        let dir = try compressTempDir()
        let pdf = dir.appendingPathComponent("doc.pdf")
        try xmpPDF().write(to: pdf)
        let before = MetadataReader.readPDF(pdf)
        XCTAssertEqual(before.first { $0.category == .document }?.entries.first { $0.label == "Author" }?.value, "Jane Secret")
        XCTAssertNotNil(before.first { $0.category == .other }?.entries.first { $0.label == "XMP metadata" })

        let out = try await MetadataStripper.strip(pdf)
        XCTAssertEqual(out.lastPathComponent, "doc clean.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertNil(doc.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertNil(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertFalse(MetadataReader.hasXMP(doc))
        XCTAssertFalse(String(decoding: try Data(contentsOf: out), as: UTF8.self).contains("Jane Secret"))
    }

    func testStripVideoRemovesTagsAndLocation() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let base = dir.appendingPathComponent("base.mp4")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15",
                                       "-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:v", "libx264",
                                       "-c:a", "aac", base.path])
        let movie = dir.appendingPathComponent("movie.mov")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-display_rotation:v:0", "90", "-i", base.path,
                                       "-c", "copy", "-metadata", "title=Secret Title", "-metadata", "artist=Jane",
                                       "-metadata", "location=+37.3349-122.0090/",
                                       "-metadata", "creation_time=2024-05-06T07:08:09Z", movie.path])
        let before = await MetadataReader.read(movie)
        let location = try XCTUnwrap(before.first { $0.category == .location })
        XCTAssertEqual(location.entries.first { $0.label == "Latitude" }?.value, "37.334900° N")
        XCTAssertNotNil(before.first { $0.category == .people })

        let out = try await MetadataStripper.strip(movie)
        XCTAssertEqual(out.lastPathComponent, "movie clean.mov")
        let probe = try await MediaProbe.probe(out)
        XCTAssertTrue(probe.formatTags.keys.allSatisfy { ["major_brand", "minor_version", "compatible_brands"].contains($0) },
                      "\(probe.formatTags)")
        XCTAssertEqual(probe.videoStreams.count, 1)
        XCTAssertEqual(probe.audioStreams.count, 1)
        XCTAssertEqual(abs(probe.videoStreams[0].rotation), 90, "display rotation is not metadata and must survive")
        let after = await MetadataReader.read(out)
        XCTAssertTrue(after.filter { [.location, .people, .media, .dates].contains($0.category) }.isEmpty, "\(after)")
    }

    func testStripAnimatedGIFKeepsFrames() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let gif = dir.appendingPathComponent("anim.gif")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                                       "testsrc2=size=160x120:rate=5:duration=1", "-loop", "0", gif.path])
        let out = try await MetadataStripper.strip(gif)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 5)
        let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        XCTAssertEqual((container?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int, 0)
    }

    func testStripWebPWithoutReencoding() async throws {
        try XCTSkipIf(Tools.locate("cwebp") == nil || Tools.locate("webpmux") == nil, "libwebp tools not installed")
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("source.jpg")
        try writeImage(noiseImage(320, 240), to: jpg, type: .jpeg, properties: privateMetadata())
        let webp = dir.appendingPathComponent("photo.webp")
        try await Tools.run("cwebp", ["-quiet", "-metadata", "all", jpg.path, "-o", webp.path])
        XCTAssertNotNil(MetadataReader.readImage(webp).first { $0.category == .location })

        let out = try await MetadataStripper.strip(webp)
        XCTAssertEqual(out.lastPathComponent, "photo clean.webp")
        XCTAssertTrue(MetadataReader.readImage(out).isEmpty, "\(MetadataReader.readImage(out))")
        XCTAssertLessThan(ByteSize.of(out), ByteSize.of(webp))
    }

    func testStripAudioTags() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let mp3 = dir.appendingPathComponent("song.mp3")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                       "-metadata", "title=Private Song", "-metadata", "artist=Jane",
                                       "-metadata", "comment=recorded at home", mp3.path])
        let before = await MetadataReader.read(mp3)
        XCTAssertEqual(before.first { $0.category == .people }?.entries.first?.value, "Jane")

        let out = try await MetadataStripper.strip(mp3)
        let after = await MetadataReader.read(out)
        XCTAssertTrue(after.isEmpty, "\(after)")
        let probe = try await MediaProbe.probe(out)
        XCTAssertEqual(probe.audioStreams.count, 1)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.2)
    }

    func testISO6709() {
        let point = MetadataReader.parseISO6709("+37.3349-122.0090+012.300/")
        XCTAssertEqual(point?.latitude ?? 0, 37.3349, accuracy: 1e-6)
        XCTAssertEqual(point?.longitude ?? 0, -122.009, accuracy: 1e-6)
        XCTAssertEqual(point?.altitude ?? 0, 12.3, accuracy: 1e-6)
        XCTAssertNil(MetadataReader.parseISO6709("Berlin"))
        XCTAssertNil(MetadataReader.parseISO6709("+37.3349-122.0090/")?.altitude)
    }
}

// MARK: - Compression

final class CompressTests: XCTestCase {
    func testJPEGPresetShrinksAndKeepsDates() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("photo.jpg")
        try writeImage(noiseImage(1200, 900), to: jpg, type: .jpeg, properties: privateMetadata(), quality: 0.98)

        let result = try await Compressor.compress(jpg, options: CompressionOptions(goal: .preset, imageStrength: .balanced))
        XCTAssertEqual(result.output.lastPathComponent, "photo compressed.jpg")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
        XCTAssertEqual(result.compressedBytes, ByteSize.of(result.output))
        XCTAssertGreaterThan(result.reduction, 0.2)
        let props = try properties(result.output)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1200)
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "compression keeps photo metadata")
    }

    func testHEICStaysHEICAndStrongCapsSize() async throws {
        let dir = try compressTempDir()
        let heic = dir.appendingPathComponent("photo.heic")
        try writeImage(noiseImage(3600, 2400), to: heic, type: .heic, properties: [:], quality: 0.95)
        let result = try await Compressor.compress(heic, options: CompressionOptions(goal: .preset, imageStrength: .strong))
        XCTAssertEqual(result.output.lastPathComponent, "photo compressed.heic")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
        let props = try properties(result.output)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, ImageCompressor.strongPresetMaxEdge)

        let sized = try await Compressor.compress(heic, options: CompressionOptions(goal: .preset, imageStrength: .balanced,
                                                                                    imageSize: .small))
        XCTAssertEqual(try properties(sized.output)[kCGImagePropertyPixelWidth] as? Int, 1024)
    }

    func testJPEGRespectsTargetSize() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("photo.jpg")
        try writeImage(noiseImage(1200, 900), to: jpg, type: .jpeg, properties: [:], quality: 0.98)
        let original = ByteSize.of(jpg)

        let target = original / 5
        let result = try await Compressor.compress(jpg, options: CompressionOptions(goal: .maxBytes(target)))
        XCTAssertLessThanOrEqual(result.compressedBytes, target)
        XCTAssertGreaterThan(result.compressedBytes, target / 3, "should use most of the budget")

        let reduced = try await Compressor.compress(jpg, options: CompressionOptions(goal: .reduction(70)))
        XCTAssertLessThanOrEqual(reduced.compressedBytes, original * 30 / 100)
        XCTAssertEqual(reduced.output.lastPathComponent, "photo compressed 2.jpg")
    }

    func testTinyTargetDownscales() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("big.jpg")
        try writeImage(noiseImage(1600, 1200), to: jpg, type: .jpeg, properties: [:], quality: 0.95)
        let result = try await Compressor.compress(jpg, options: CompressionOptions(goal: .maxBytes(30_000)))
        XCTAssertLessThanOrEqual(result.compressedBytes, 30_000)
        let props = try properties(result.output)
        XCTAssertLessThan(props[kCGImagePropertyPixelWidth] as? Int ?? 0, 1600)
    }

    func testWouldExceedDeletesOutput() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("small.jpg")
        try writeImage(noiseImage(320, 240), to: jpg, type: .jpeg, properties: [:], quality: 0.05)
        do {
            _ = try await Compressor.compress(jpg, options: CompressionOptions(goal: .preset, imageStrength: .light))
            XCTFail("re-encoding a q=0.05 JPEG at q=0.8 must not be delivered")
        } catch let error as CompressionError {
            XCTAssertEqual(error, .wouldExceed)
            XCTAssertEqual(error.localizedDescription, "Compressed output would exceed the original or target file size.")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("compressed") }
        XCTAssertEqual(leftovers, [])
    }

    func testUnreachableTarget() async throws {
        let dir = try compressTempDir()
        let jpg = dir.appendingPathComponent("photo.jpg")
        try writeImage(noiseImage(600, 400), to: jpg, type: .jpeg, properties: [:], quality: 0.9)
        do {
            _ = try await Compressor.compress(jpg, options: CompressionOptions(goal: .maxBytes(300)))
            XCTFail("expected targetUnreachable")
        } catch let error as CompressionError {
            guard case .targetUnreachable(let smallest) = error else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(smallest, 300)
        }
    }

    func testPNGPaletteCompression() async throws {
        let dir = try compressTempDir()
        let png = dir.appendingPathComponent("art.png")
        try writeImage(noiseImage(320, 240, alpha: true), to: png, type: .png, properties: [:])

        let result = try await Compressor.compress(png, options: CompressionOptions(goal: .preset, imageStrength: .balanced))
        XCTAssertEqual(result.output.pathExtension, "png")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        XCTAssertNotEqual(image.alphaInfo, .none, "transparency survives quantization")
        let props = try properties(result.output)
        XCTAssertEqual(props[kCGImagePropertyHasAlpha] as? Bool, true)
    }

    func testFlatPNGStaysExact() throws {
        // 3 colors + transparent: the exact palette path must reproduce every pixel.
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 32, y: 0, width: 16, height: 32))
        let data = try XCTUnwrap(PalettePNG.encode(ctx.makeImage()!, maxColors: 16, dither: true, dpi: 144))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double ?? 0, 144, accuracy: 0.5)
        let pixels = rgba(decoded)
        func pixel(_ x: Int) -> [UInt8] { Array(pixels[(x * 4)..<(x * 4 + 4)]) }
        XCTAssertEqual(pixel(2), [255, 0, 0, 255])
        XCTAssertEqual(pixel(20), [0, 255, 0, 255])
        XCTAssertEqual(pixel(40), [0, 0, 255, 255])
        XCTAssertEqual(pixel(60)[3], 0)
    }

    func testWebPCompression() async throws {
        try XCTSkipIf(Tools.locate("cwebp") == nil, "cwebp not installed")
        let dir = try compressTempDir()
        let png = dir.appendingPathComponent("source.png")
        try writeImage(noiseImage(640, 480), to: png, type: .png, properties: [:])
        let webp = dir.appendingPathComponent("photo.webp")
        try await Tools.run("cwebp", ["-quiet", "-q", "100", png.path, "-o", webp.path])
        let result = try await Compressor.compress(webp, options: CompressionOptions(goal: .preset, imageStrength: .balanced))
        XCTAssertEqual(result.output.lastPathComponent, "photo compressed.webp")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
    }

    func testAnimatedGIFCompression() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let gif = dir.appendingPathComponent("anim.gif")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=240x180:rate=10:duration=1",
                                       "-t", "1", "-vf", "noise=alls=20:allf=t,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                       gif.path])
        let frames = CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil)))
        let result = try await Compressor.compress(gif, options: CompressionOptions(goal: .preset, imageStrength: .strong))
        XCTAssertEqual(result.output.pathExtension, "gif")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
        let out = try XCTUnwrap(CGImageSourceCreateWithURL(result.output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(out), frames)
    }

    func testVideoPresetAndTargetSize() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let clip = dir.appendingPathComponent("clip.mov")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
                                       "-vf", "noise=alls=25:allf=t", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "14",
                                       "-c:a", "aac", "-b:a", "192k", clip.path])
        let original = ByteSize.of(clip)

        let preset = try await Compressor.compress(clip, options: CompressionOptions(goal: .preset, mediaStrength: .balanced))
        XCTAssertEqual(preset.output.lastPathComponent, "clip compressed.mp4")
        XCTAssertLessThan(preset.compressedBytes, original)
        let probe = try await MediaProbe.probe(preset.output)
        XCTAssertEqual(probe.duration, 3, accuracy: 0.2)
        XCTAssertEqual(probe.videoStreams.count, 1)
        XCTAssertEqual(probe.audioStreams.count, 1)

        let target = original * 35 / 100
        let sized = try await Compressor.compress(clip, options: CompressionOptions(goal: .maxBytes(target)))
        XCTAssertLessThanOrEqual(sized.compressedBytes, target)
        XCTAssertGreaterThanOrEqual(Double(sized.compressedBytes), Double(target) * 0.85, "two-pass should land within ~10%")
    }

    func testAudioCompression() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try compressTempDir()
        let wav = dir.appendingPathComponent("tone.wav")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                                       "-ac", "2", wav.path])
        let preset = try await Compressor.compress(wav, options: CompressionOptions(goal: .preset, mediaStrength: .balanced))
        XCTAssertEqual(preset.output.pathExtension, "m4a")
        XCTAssertLessThan(preset.compressedBytes, preset.originalBytes / 4)

        let target: Int64 = 40_000
        let sized = try await Compressor.compress(wav, options: CompressionOptions(goal: .maxBytes(target)))
        XCTAssertLessThanOrEqual(sized.compressedBytes, target)
    }

    func testPDFWithLargeImageShrinks() async throws {
        let dir = try compressTempDir()
        let pdf = dir.appendingPathComponent("scan.pdf")
        let image = NSImage(cgImage: noiseImage(1800, 1350), size: NSSize(width: 600, height: 450))
        let doc = PDFDocument()
        doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(doc.write(to: pdf))

        let result = try await Compressor.compress(pdf, options: CompressionOptions(goal: .preset, imageStrength: .balanced))
        XCTAssertEqual(result.output.lastPathComponent, "scan compressed.pdf")
        XCTAssertLessThan(result.compressedBytes, result.originalBytes / 2)
        XCTAssertEqual(PDFDocument(url: result.output)?.pageCount, 1)

        let target = result.originalBytes / 6
        let sized = try await Compressor.compress(pdf, options: CompressionOptions(goal: .maxBytes(target)))
        XCTAssertLessThanOrEqual(sized.compressedBytes, target)
    }

    func testBudgetPlans() throws {
        // 10 MB over 60 s ≈ 1290 kbit/s total.
        let plan = try MediaCompressor.budgetPlan(targetBytes: 10_000_000, duration: 60, audioStreams: 1, sourceAudioKbps: 256)
        XCTAssertEqual(plan.audioKbps, 96)
        XCTAssertEqual(plan.rate, .bitrate(kbps: 1293 - 96))
        XCTAssertEqual(plan.maxShortEdge, 720)
        XCTAssertThrowsError(try MediaCompressor.budgetPlan(targetBytes: 50_000, duration: 600, audioStreams: 1, sourceAudioKbps: nil)) {
            XCTAssertEqual($0 as? CompressionError, .targetTooSmallForDuration)
        }
        XCTAssertEqual(MediaCompressor.presetAudioKbps(.mp3, strength: .balanced, sourceKbps: 320), 128)
        XCTAssertEqual(MediaCompressor.presetAudioKbps(.mp3, strength: .light, sourceKbps: 128), 96)
        XCTAssertEqual(CompressionOptions(goal: .reduction(40)).targetBytes(forOriginal: 1000), 600)
        XCTAssertNil(CompressionOptions(goal: .preset).targetBytes(forOriginal: 1000))
    }
}

// MARK: - Fixtures

private func compressTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-compress-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Photo-like content: smooth gradients plus deterministic noise, so lossy codecs have work to do.
private func noiseImage(_ width: Int, _ height: Int, alpha: Bool = false) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 12345
    for y in 0..<height {
        for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 27)  // 0...31
            let o = (y * width + x) * 4
            let a = alpha ? UInt8(min(255, x * 255 / max(width - 1, 1))) : 255
            pixels[o] = UInt8(min(255, x * 255 / width + noise))
            pixels[o + 1] = UInt8(min(255, y * 255 / height + noise))
            pixels[o + 2] = UInt8(min(255, (x + y) * 128 / (width + height) + 64 + noise))
            pixels[o + 3] = a
            if alpha {  // premultiply
                for c in 0..<3 { pixels[o + c] = UInt8(Int(pixels[o + c]) * Int(a) / 255) }
            }
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func privateMetadata() -> [CFString: Any] {
    [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.031, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 12.5,
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
            kCGImagePropertyExifLensModel: "Test Lens 50mm",
            kCGImagePropertyExifUserComment: "secret",
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "ACME", kCGImagePropertyTIFFModel: "Cam 1",
            kCGImagePropertyTIFFSoftware: "TestSoft", kCGImagePropertyTIFFArtist: "Jane",
        ],
        kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCKeywords: ["a", "b"], kCGImagePropertyIPTCCopyrightNotice: "(c) Jane",
        ],
    ]
}

private func writeImage(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any], quality: Double = 0.9) throws {
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    var props = properties
    props[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

/// Number of embedded JPEG streams (SOI markers followed by another marker).
private func jpegStarts(_ data: Data) -> Int {
    let b = [UInt8](data)
    return (0..<(b.count - 2)).filter { b[$0] == 0xFF && b[$0 + 1] == 0xD8 && b[$0 + 2] == 0xFF }.count
}

private func decode(_ url: URL) throws -> CGImage {
    let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
}

private func properties(_ url: URL) throws -> [CFString: Any] {
    let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
}

/// Straight (unpremultiplied) sRGB RGBA bytes of an image.
private func rgba(_ image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let buffer = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
    // Row 0 of the bitmap is the top row of the image.
    return Array(buffer)
}

/// Minimal hand-written PDF with an Info dictionary and an XMP packet in the catalog.
private func xmpPDF() -> Data {
    let xmp = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" \
    xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator><rdf:Seq><rdf:li>Jane Secret</rdf:li></rdf:Seq>\
    </dc:creator></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
    """
    let content = "BT /F1 24 Tf 72 700 Td (Hello) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream",
        "<< /Title (Secret Title) /Author (Jane Secret) /Creator (SecretApp 1.0) /CreationDate (D:20240506070809Z) >>",
    ]
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (i, object) in objects.enumerated() {
        offsets.append(out.utf8.count)
        out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 7 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(out.utf8)
}
