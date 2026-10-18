import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

/// Batch conversion (partial failures, same-name scheduling), reserved output names under
/// concurrency, and the headless `--convert` CLI.
final class CoreFixTests: XCTestCase {
    // MARK: OutputNaming.reserveURL

    func testReserveURLTreatsDanglingSymlinkAsTaken() throws {
        let dir = try makeTempDir()
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("photo.jpg").path,
                                                   withDestinationPath: dir.appendingPathComponent("elsewhere").path)
        let url = try OutputNaming.reserveURL(for: dir.appendingPathComponent("photo.png"), ext: "jpg")
        XCTAssertEqual(url.lastPathComponent, "photo 2.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("elsewhere").path))
    }

    // MARK: Converter under concurrency

    /// Two cover.jpg from different folders, "Save to" one folder, converted at once.
    func testConcurrentConversionsIntoSharedSaveFolder() async throws {
        let dir = try makeTempDir()
        let out = dir.appendingPathComponent("Downloads")
        let a = dir.appendingPathComponent("A/cover.jpg"), b = dir.appendingPathComponent("B/cover.jpg")
        for url in [out, a.deletingLastPathComponent(), b.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try writeTestImage(a, type: .jpeg, width: 64)
        try writeTestImage(b, type: .jpeg, width: 80)
        let saved = OutputNaming.configuredDirectory
        OutputNaming.preferredDirectory = out
        defer { OutputNaming.preferredDirectory = saved }
        async let first = Converter.convert(a, to: .png)
        async let second = Converter.convert(b, to: .png)
        let outputs = try await first + second
        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), ["cover.png", "cover 2.png"])
        XCTAssertEqual(Set(try outputs.map(pixelWidth)), [64, 80], "each source kept its own output")
    }

    /// A failing conversion only removes its own output, never a parallel job's.
    func testFailingConversionDoesNotDeleteParallelOutput() async throws {
        for _ in 0..<5 {
            let dir = try makeTempDir()
            let broken = dir.appendingPathComponent("x.png"), good = dir.appendingPathComponent("x.bmp")
            try Data("not an image".utf8).write(to: broken)
            try writeTestImage(good, type: .bmp, width: 64)
            async let failing: [URL]? = try? Converter.convert(broken, to: .jpeg)
            async let working = Converter.convert(good, to: .jpeg)
            let (failed, outputs) = try await (failing, working)
            XCTAssertNil(failed)
            XCTAssertEqual(outputs.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputs[0].path))
            XCTAssertEqual(try pixelWidth(outputs[0]), 64)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
            XCTAssertEqual(left, [outputs[0].lastPathComponent], "the failed job's reservation is cleaned up")
        }
    }

    /// Every writer must replace the empty placeholder `reserveURL` leaves.
    func testWritersReplaceReservedPlaceholder() async throws {
        let dir = try makeTempDir()
        let png = dir.appendingPathComponent("icon.png")
        try writeTestImage(png, type: .png, width: 64)
        var formats: [OutputFormat] = [.gif, .bmp, .ico, .icns, .tiff, .heic]
        if Converter.canEncodeAVIF { formats.append(.avif) }
        for format in formats {
            do {
                let out = try await Converter.convert(png, to: format)
                XCTAssertEqual(out.count, 1)
                XCTAssertGreaterThan(try fileSize(out[0]), 0, "\(format)")
            } catch ConversionError.unsupported {
                continue   // e.g. no AV1 encoder in this ffmpeg
            }
        }
    }

    // MARK: ConvertBatch

    func testBatchReportsPartialFailureWithOutputs() async throws {
        let dir = try makeTempDir()
        let broken = dir.appendingPathComponent("x.png"), good = dir.appendingPathComponent("x.bmp")
        let other = dir.appendingPathComponent("y.bmp")
        try Data("not an image".utf8).write(to: broken)
        try writeTestImage(good, type: .bmp, width: 64)
        try writeTestImage(other, type: .bmp, width: 32)
        do {
            _ = try await ConvertBatch.run([broken, good, other]) { try await Converter.convert($0, to: .jpeg) }
            XCTFail("expected a partial failure")
        } catch let error as BatchConversionError {
            XCTAssertEqual(error.outputs.map(\.lastPathComponent), ["x.jpg", "y.jpg"])
            for url in error.outputs { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
            XCTAssertEqual(error.failures.map(\.file), [broken])
            XCTAssertEqual(error.total, 3)
            XCTAssertTrue(error.localizedDescription.hasPrefix("1 of 3 failed: "), error.localizedDescription)
            XCTAssertEqual((error as PartialOutputsError).outputs.count, 2)
        }
    }

    func testBatchSingleFailureMessageIsTheError() async {
        let file = URL(fileURLWithPath: "/nowhere/a.png")
        do {
            _ = try await ConvertBatch.run([file]) { _ in throw ConversionError.unreadable(file) }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Couldn't read a.png.")
            XCTAssertEqual((error as? PartialOutputsError)?.outputs, [])
        }
    }

    func testBatchNeverRunsSameNamedFilesTogether() async throws {
        let files = ["IMG_1.HEIC", "IMG_1.MOV", "img_1.jpg", "other.png", "third.png"].map { URL(fileURLWithPath: "/in/" + $0) }
        let tracker = BatchOverlapTracker()
        let outputs = try await ConvertBatch.run(files, maxConcurrent: 2) { file in
            await tracker.begin(ConvertBatch.nameKey(file))
            try await Task.sleep(nanoseconds: 20_000_000)
            await tracker.end(ConvertBatch.nameKey(file))
            return [file.appendingPathExtension("out")]
        }
        XCTAssertEqual(outputs, files.map { $0.appendingPathExtension("out") }, "outputs in input order")
        let (overlap, peak) = await (tracker.sameNameOverlap, tracker.peak)
        XCTAssertFalse(overlap)
        XCTAssertEqual(peak, 2, "different names still run two at a time")
    }

    // MARK: Headless CLI

    func testConvertCommandParsing() {
        XCTAssertEqual(ConvertCommand.parse(["Wheelie"]), .app)
        XCTAssertEqual(ConvertCommand.parse(["Wheelie", "--show-wheel", "a.png"]), .app)
        guard case .usageError = ConvertCommand.parse(["Wheelie", "--convert"]) else { return XCTFail("no format") }
        guard case .usageError = ConvertCommand.parse(["Wheelie", "--convert", "png"]) else { return XCTFail("no files") }
        guard case .usageError = ConvertCommand.parse(["Wheelie", "--convert", "nope", "a.png"]) else { return XCTFail("bad format") }
        XCTAssertEqual(ConvertCommand.parse(["Wheelie", "--convert", "JPG", "/a/b.png"]),
                       .convert(.jpeg, [URL(fileURLWithPath: "/a/b.png")]))
    }
}

private actor BatchOverlapTracker {
    private var running: [String] = []
    private(set) var sameNameOverlap = false
    private(set) var peak = 0

    func begin(_ key: String) {
        if running.contains(key) { sameNameOverlap = true }
        running.append(key)
        peak = max(peak, running.count)
    }

    func end(_ key: String) {
        if let i = running.firstIndex(of: key) { running.remove(at: i) }
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-corefix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fileSize(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
}

private func pixelWidth(_ url: URL) throws -> Int {
    try Converter.loadImage(url).width
}

private func writeTestImage(_ url: URL, type: UTType, width: Int) throws {
    let ctx = CGContext(data: nil, width: width, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: 48))
    try Converter.writeImage(ctx.makeImage()!, to: url, type: type)
}
