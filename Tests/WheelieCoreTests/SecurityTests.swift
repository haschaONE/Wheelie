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

    /// The allowlist itself (not the sniffer) must stop a playlist that ffmpeg reaches indirectly.
    func testNestedPlaylistBlockedByDemuxerAllowlist() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Without the allowlist this exact setup copies secret.ts into the output.
        let secret = dir.appendingPathComponent("secret.ts")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=d=1",
                                       "-c:a", "aac", "-f", "mpegts", secret.path])
        let playlist = dir.appendingPathComponent("innocent.m3u8")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(secret.path)\n#EXT-X-ENDLIST\n".utf8).write(to: playlist)
        let list = dir.appendingPathComponent("list.txt")
        try Data("ffconcat version 1.0\nfile '\(playlist.path)'\n".utf8).write(to: list)
        let out = dir.appendingPathComponent("out.wav")
        do {
            try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "concat", "-safe", "0",
                                           "-i", list.path, "-y", out.path])
            XCTFail("nested hls playlist was opened")
        } catch {
            XCTAssertTrue("\(error)".contains("whitelist"), "\(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    func testProbeArgumentsAreHardened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-sec-\(UUID().uuidString).mp4")
        try Data([0, 0, 0, 0x18]).write(to: file)
        let args = try Tools.hardenFFmpegInputs(["-v", "error", file.path], probe: true)
        XCTAssertEqual(Array(args.prefix(4)), ["-protocol_whitelist", "file,pipe", "-format_whitelist", Tools.mediaDemuxers.joined(separator: ",")])
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

final class VideoRunnerSecurityTests: XCTestCase {
    func testVideoRunnerRefusesPlaylistInput() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("clip.mp4")
        try Data("#EXTM3U\n#EXTINF:1,\nfile:///etc/hosts\n".utf8).write(to: fake)
        do {
            try await VideoToolRunner.ffmpeg(["-i", fake.path, "-y", dir.appendingPathComponent("o.mp4").path])
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(error is UnsafeMediaInputError, "\(error)")
        }
    }
}
