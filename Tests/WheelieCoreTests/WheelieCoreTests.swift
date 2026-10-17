import AppKit
import PDFKit
import XCTest
@testable import WheelieCore

final class FormatTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.PNG")), .image)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.webp")), .image)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.mov")), .video)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.mkv")), .video)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.mp3")), .audio)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/a/b.zip")), .unknown)
    }

    func testTargetsHideSourceFormat() {
        let t = OutputFormat.targets(for: [URL(fileURLWithPath: "/x.jpeg")])
        XCTAssertFalse(t.contains(.jpeg))
        XCTAssertTrue(t.contains(.png))
    }

    func testMixedSelectionUsesIntersection() {
        let t = OutputFormat.targets(for: [URL(fileURLWithPath: "/x.png"), URL(fileURLWithPath: "/y.pdf")])
        XCTAssertEqual(t, [.png, .jpeg])
        XCTAssertEqual(OutputFormat.targets(for: [URL(fileURLWithPath: "/x.png"), URL(fileURLWithPath: "/y.mp3")]), [])
    }

    func testUniqueNaming() throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("photo.png")
        XCTAssertEqual(OutputNaming.uniqueURL(for: src, ext: "jpg").lastPathComponent, "photo.jpg")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("photo.jpg").path, contents: Data())
        XCTAssertEqual(OutputNaming.uniqueURL(for: src, ext: "jpg").lastPathComponent, "photo 2.jpg")
    }
}

final class ConversionTests: XCTestCase {
    func testImageConversions() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("square.png")
        try makePNG(at: png)
        for format in [OutputFormat.jpeg, .heic, .tiff, .webp, .pdf] {
            let out = try await Converter.convert(png, to: format)
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out[0].pathExtension, format.fileExtension)
            XCTAssertGreaterThan(try size(out[0]), 0, "\(format)")
        }
        // Round-trip from a non-cwebp-readable input exercises the temp PNG path.
        let fromHeic = try await Converter.convert(dir.appendingPathComponent("square.heic"), to: .webp)
        XCTAssertEqual(fromHeic[0].lastPathComponent, "square 2.webp")
    }

    func testPDFConversions() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("page.png")
        try makePNG(at: png)
        let pdf = try await Converter.convert(png, to: .pdf)[0]
        let doc = PDFDocument(url: pdf)!
        doc.insert(PDFPage(image: NSImage(contentsOf: png)!)!, at: 1)
        XCTAssertTrue(doc.write(to: pdf))
        let pages = try await Converter.convert(pdf, to: .jpeg)
        XCTAssertEqual(pages.map(\.lastPathComponent), ["page-p1.jpg", "page-p2.jpg"])
        let txt = try await Converter.convert(pdf, to: .txt)
        XCTAssertEqual(txt[0].pathExtension, "txt")
    }

    func testMediaConversions() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try tempDir()
        let clip = dir.appendingPathComponent("clip.mkv")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
                                       "-f", "lavfi", "-i", "sine=frequency=440", "-t", "1", "-c:v", "libx264",
                                       "-c:a", "aac", clip.path])
        for format in OutputFormat.targets(for: .video) {
            let out = try await Converter.convert(clip, to: format)
            XCTAssertGreaterThan(try size(out[0]), 0, "\(format)")
        }
        let mp3 = dir.appendingPathComponent("clip.mp3")
        for format in OutputFormat.targets(for: [mp3]) {
            let out = try await Converter.convert(mp3, to: format)
            XCTAssertGreaterThan(try size(out[0]), 0, "\(format)")
        }
    }

    func testFFmpegFailureCleansUp() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try tempDir()
        let bogus = dir.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: bogus)
        do {
            _ = try await Converter.convert(bogus, to: .mp3)
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.mp3").path))
        }
    }
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func size(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
}

/// 64x64 PNG, half transparent, so JPEG flattening is exercised.
private func makePNG(at url: URL) throws {
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
    try Converter.writeImage(ctx.makeImage()!, to: url, type: .png)
}
