import XCTest
@testable import WheelieCore

final class SecurityTests: XCTestCase {
    func testPlaylistDisguisedAsVideoIsRefused() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("clip.mp4")
        try Data("#EXTM3U\n#EXTINF:1,\nfile:///etc/hosts\n".utf8).write(to: fake)
        do {
            _ = try await Converter.convert(fake, to: .mp3)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(error is UnsafeMediaInputError, "\(error)")
        }
    }

    func testExplicitFormatInputsAreLeftAlone() throws {
        let args = try Tools.hardenFFmpegInputs(["-f", "lavfi", "-i", "sine", "-y", "/tmp/x.wav"])
        XCTAssertEqual(args, ["-f", "lavfi", "-i", "sine", "-y", "/tmp/x.wav"])
    }

    func testDanglingSymlinkCountsAsTaken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("a.jpg").path,
                                                   withDestinationPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let out = OutputNaming.uniqueURL(for: dir.appendingPathComponent("a.png"), ext: "jpg")
        XCTAssertEqual(out.lastPathComponent, "a 2.jpg")
    }
}
