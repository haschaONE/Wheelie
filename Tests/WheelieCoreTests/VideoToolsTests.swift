import CoreGraphics
import ImageIO
import XCTest
@testable import WheelieCore

// MARK: - Pure logic

final class VideoToolsLogicTests: XCTestCase {
    func testTimecodeFormatting() {
        XCTAssertEqual(VideoToolTimecode.format(0), "0:00.00")
        XCTAssertEqual(VideoToolTimecode.format(65.256), "1:05.26")
        XCTAssertEqual(VideoToolTimecode.format(59.999), "1:00.00")
        XCTAssertEqual(VideoToolTimecode.format(3725), "1:02:05.00")
        XCTAssertEqual(VideoToolTimecode.format(5.5, fractionDigits: 0), "0:06")
        XCTAssertEqual(VideoToolTimecode.fileStamp(12.7), "00m12s")
        XCTAssertEqual(VideoToolTimecode.fileStamp(3732), "1h02m12s")
        XCTAssertEqual(VideoToolTimecode.compact(2), "2")
        XCTAssertEqual(VideoToolTimecode.compact(0.25), "0.25")
    }

    func testTimecodeParsing() {
        XCTAssertEqual(VideoToolTimecode.parse("12"), 12)
        XCTAssertEqual(VideoToolTimecode.parse("12.5s"), 12.5)
        XCTAssertEqual(VideoToolTimecode.parse("1:05.25"), 65.25)
        XCTAssertEqual(VideoToolTimecode.parse("1:02:05"), 3725)
        XCTAssertEqual(VideoToolTimecode.parse("00:00:05.000000000"), 5)
        XCTAssertEqual(VideoToolTimecode.parse("0,5"), 0.5)
        XCTAssertNil(VideoToolTimecode.parse(""))
        XCTAssertNil(VideoToolTimecode.parse("abc"))
        XCTAssertNil(VideoToolTimecode.parse("1:75"))
        XCTAssertNil(VideoToolTimecode.parse("-3"))
    }

    func testAtempoChaining() {
        XCTAssertEqual(VideoToolArgs.atempoChain(0.25), [0.5, 0.5])
        XCTAssertEqual(VideoToolArgs.atempoChain(4), [2, 2])
        XCTAssertEqual(VideoToolArgs.atempoChain(2), [2])
        XCTAssertEqual(VideoToolArgs.atempoChain(1), [1])
        XCTAssertEqual(VideoToolArgs.atempoChain(3), [2, 1.5])
        let slow = VideoToolArgs.atempoChain(0.3)
        XCTAssertEqual(slow.count, 2)
        XCTAssertEqual(slow[0], 0.5)
        XCTAssertEqual(slow[1], 0.6, accuracy: 1e-9)
        for factor in stride(from: 0.25, through: 4.0, by: 0.05) {
            let chain = VideoToolArgs.atempoChain(factor)
            XCTAssertTrue(chain.allSatisfy { (0.5...2.0).contains($0) }, "\(factor): \(chain)")
            XCTAssertEqual(chain.reduce(1, *), factor, accuracy: 1e-9)
        }
        XCTAssertEqual(VideoToolArgs.audioSpeedFilter(factor: 0.25, keepPitch: true, sampleRate: 48000),
                       "asetpts=PTS-STARTPTS,atempo=0.5,atempo=0.5")
        XCTAssertEqual(VideoToolArgs.audioSpeedFilter(factor: 2, keepPitch: false, sampleRate: 44100),
                       "asetpts=PTS-STARTPTS,asetrate=88200,aresample=44100")
    }

    func testSpeedArguments() {
        let info = VideoToolInfo(duration: 4, width: 320, height: 240, fps: 30, hasAudio: true, audioSampleRate: 48000)
        let args = VideoToolArgs.speed(input: URL(fileURLWithPath: "/in.mp4"), output: URL(fileURLWithPath: "/out.mp4"),
                                       factor: 4, keepPitch: true, info: info, encoding: .mp4)
        XCTAssertTrue(args.contains("setpts=(PTS-STARTPTS)/4,fps=30"))
        XCTAssertTrue(args.contains("asetpts=PTS-STARTPTS,atempo=2,atempo=2"))
        XCTAssertEqual(VideoSpeed.fileSuffix(0.25), " 0.25x")
        XCTAssertEqual(VideoSpeed.label(2), "2×")
        var silent = info
        silent.hasAudio = false
        let noAudio = VideoToolArgs.speed(input: URL(fileURLWithPath: "/in.mp4"), output: URL(fileURLWithPath: "/out.mp4"),
                                          factor: 0.5, keepPitch: true, info: silent, encoding: .mp4)
        XCTAssertTrue(noAudio.contains("-an"))
        XCTAssertFalse(noAudio.contains("-filter:a"))
    }

    func testSplitPointValidation() {
        XCTAssertNil(VideoSplitPlan.validationError(points: [1, 2], duration: 4))
        XCTAssertNil(VideoSplitPlan.validationError(points: [1, 1.05], duration: 4))
        XCTAssertEqual(VideoSplitPlan.validationError(points: [1, 1.04], duration: 4), VideoSplitPlan.apartMessage)
        XCTAssertEqual(VideoSplitPlan.validationError(points: [2, 1.01, 1], duration: 4), VideoSplitPlan.apartMessage)
        XCTAssertEqual(VideoSplitPlan.validationError(points: [0.01], duration: 4), VideoSplitPlan.insideMessage)
        XCTAssertEqual(VideoSplitPlan.validationError(points: [3.97], duration: 4), VideoSplitPlan.insideMessage)
        XCTAssertEqual(VideoSplitPlan.validationError(points: [5], duration: 4), VideoSplitPlan.insideMessage)
        XCTAssertEqual(VideoSplitPlan.insertionError(2.02, into: [2], duration: 4), VideoSplitPlan.apartMessage)
        XCTAssertNil(VideoSplitPlan.insertionError(3, into: [2], duration: 4))

        let clips = VideoSplitPlan.clips(points: [3, 1], duration: 4)
        XCTAssertEqual(clips, [VideoClipRange(start: 0, end: 1), VideoClipRange(start: 1, end: 3), VideoClipRange(start: 3, end: 4)])

        XCTAssertEqual(VideoSplitPlan.exportError(points: [], removed: [], mode: .separate, duration: 4), VideoSplitPlan.emptyMessage)
        XCTAssertNil(VideoSplitPlan.exportError(points: [1], removed: [], mode: .separate, duration: 4))
        XCTAssertEqual(VideoSplitPlan.exportError(points: [1], removed: [0, 1], mode: .separate, duration: 4),
                       VideoSplitPlan.keepOneMessage)
        XCTAssertEqual(VideoSplitPlan.exportError(points: [1], removed: [], mode: .joinRest, duration: 4),
                       VideoSplitPlan.removeToJoinMessage)
        XCTAssertEqual(VideoSplitPlan.exportError(points: [1], removed: [0, 1], mode: .joinRest, duration: 4),
                       VideoSplitPlan.keepOneMessage)
        XCTAssertNil(VideoSplitPlan.exportError(points: [1, 2], removed: [1], mode: .joinRest, duration: 4))
    }

    func testCropMath() {
        let wide = VideoCropMath.largest(ratio: 16.0 / 9, width: 320, height: 240)
        XCTAssertEqual(wide, VideoCropRect(x: 0, y: 30, width: 320, height: 180))
        let square = VideoCropMath.largest(ratio: 1, width: 321, height: 241)
        XCTAssertEqual(square.width, square.height)
        XCTAssertTrue([square.x, square.y, square.width, square.height].allSatisfy { $0 % 2 == 0 })
        XCTAssertEqual(VideoCropMath.largest(ratio: nil, width: 321, height: 241), VideoCropRect(x: 0, y: 0, width: 320, height: 240))

        let even = VideoCropMath.even(CGRect(x: 3, y: 5, width: 101, height: 51), width: 320, height: 240)
        XCTAssertEqual(even, VideoCropRect(x: 2, y: 4, width: 100, height: 50))
        // Out-of-frame rectangles are pulled back inside.
        XCTAssertEqual(VideoCropMath.even(CGRect(x: 300, y: 230, width: 100, height: 50), width: 320, height: 240),
                       VideoCropRect(x: 220, y: 190, width: 100, height: 50))

        // Corner drag with a ratio keeps the ratio and the opposite corner.
        let start = CGRect(x: 40, y: 30, width: 160, height: 90)
        let dragged = VideoCropMath.resized(start, handle: .bottomRight, to: CGPoint(x: 300, y: 120), ratio: 16.0 / 9,
                                            width: 320, height: 240)
        XCTAssertEqual(dragged.minX, 40, accuracy: 0.001)
        XCTAssertEqual(dragged.minY, 30, accuracy: 0.001)
        XCTAssertEqual(dragged.width / dragged.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertLessThanOrEqual(dragged.maxX, 320.001)
        // Free drag past the frame edge is clamped.
        let free = VideoCropMath.resized(start, handle: .left, to: CGPoint(x: -50, y: 0), ratio: nil, width: 320, height: 240)
        XCTAssertEqual(free.minX, 0)
        XCTAssertEqual(free.maxX, 200)

        XCTAssertEqual(VideoCropMath.validationError(VideoCropRect(x: 0, y: 0, width: 1, height: 10), width: 320, height: 240),
                       VideoCropMath.tooSmallMessage)
        XCTAssertEqual(VideoCropMath.validationError(VideoCropRect(x: 300, y: 0, width: 40, height: 10), width: 320, height: 240),
                       VideoCropMath.insideMessage)
        XCTAssertNil(VideoCropMath.validationError(VideoCropRect(x: 0, y: 0, width: 320, height: 240), width: 320, height: 240))
    }

    func testRedactFilterGraph() {
        let partial = VideoRedactBox(rect: VideoCropRect(x: 10, y: 20, width: 100, height: 60), start: 1, end: 2.5)
        let whole = VideoRedactBox(rect: VideoCropRect(x: 0, y: 0, width: 40, height: 40), start: 0, end: 4)
        let black = VideoToolArgs.redactFilterGraph(boxes: [partial, whole], style: .black, duration: 4)
        XCTAssertEqual(black, "[0:v:0]drawbox=x=10:y=20:w=100:h=60:color=black:t=fill:enable='between(t,1,2.5)',"
                       + "drawbox=x=0:y=0:w=40:h=40:color=black:t=fill,format=yuv420p[vout]")
        let blur = VideoToolArgs.redactFilterGraph(boxes: [partial, whole], style: .blur, duration: 4)
        XCTAssertTrue(blur.hasPrefix("[0:v:0]split=3[base][src0][src1];"))
        XCTAssertTrue(blur.contains("[src0]crop=100:60:10:20,gblur="))
        XCTAssertTrue(blur.contains("[base][fx0]overlay=x=10:y=20:enable='between(t,1,2.5)'[ov0]"))
        XCTAssertTrue(blur.contains("[ov0][fx1]overlay=x=0:y=0[ov1]"))
        XCTAssertTrue(blur.hasSuffix("[ov1]format=yuv420p[vout]"))
        let pixel = VideoToolArgs.redactFilterGraph(boxes: [partial], style: .pixelate, duration: 4)
        XCTAssertTrue(pixel.contains("flags=area,scale=100:60:flags=neighbor"))

        XCTAssertEqual(VideoRedactPlan.validationError([], width: 320, height: 240, duration: 4), VideoRedactPlan.emptyMessage)
        var outside = partial
        outside.rect.x = 300
        XCTAssertEqual(VideoRedactPlan.validationError([outside], width: 320, height: 240, duration: 4), VideoRedactPlan.insideMessage)
        var backwards = partial
        backwards.end = 0.5
        XCTAssertEqual(VideoRedactPlan.validationError([backwards], width: 320, height: 240, duration: 4),
                       VideoToolError.invalidRange.message)
        XCTAssertNil(VideoRedactPlan.validationError([partial, whole], width: 320, height: 240, duration: 4))
    }

    func testOtherArgumentBuilders() {
        let input = URL(fileURLWithPath: "/v/in.mp4"), output = URL(fileURLWithPath: "/v/out.mp4")
        let copy = VideoToolArgs.trim(input: input, output: output, start: 1.5, duration: 2, encoding: nil)
        XCTAssertEqual(Array(copy.prefix(6)), ["-ss", "1.5", "-i", "/v/in.mp4", "-t", "2"])
        XCTAssertTrue(copy.contains("copy"))
        let encoded = VideoToolArgs.trim(input: input, output: output, start: 0, duration: 2, encoding: .mp4)
        XCTAssertFalse(encoded.contains("-ss"))
        XCTAssertTrue(encoded.contains("libx264"))

        let mute = VideoToolArgs.mute(input: input, output: output)
        XCTAssertTrue(mute.contains("-an"))
        XCTAssertEqual(mute[mute.firstIndex(of: "-c")! + 1], "copy")

        let join = VideoToolArgs.join(inputs: [.init(url: input, duration: 2, hasAudio: true),
                                               .init(url: URL(fileURLWithPath: "/v/b.mov"), duration: 1.5, hasAudio: false)],
                                      output: output, width: 640, height: 360, fps: 30)
        let graph = join[join.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.contains("[1:v:0]scale=640:360:force_original_aspect_ratio=decrease"))
        XCTAssertTrue(graph.contains("pad=640:360:(ow-iw)/2:(oh-ih)/2"))
        XCTAssertTrue(graph.contains("anullsrc=r=48000:cl=stereo,atrim=duration=1.5"))
        XCTAssertTrue(graph.hasSuffix("[v0][a0][v1][a1]concat=n=2:v=1:a=1[vout][aout]"))
        let silentJoin = VideoToolArgs.join(inputs: [.init(url: input, duration: 2, hasAudio: false),
                                                     .init(url: input, duration: 2, hasAudio: false)],
                                            output: output, width: 640, height: 360, fps: 30)
        XCTAssertFalse(silentJoin.joined(separator: " ").contains("anullsrc"))
        XCTAssertFalse(silentJoin.contains("[aout]"))

        let keep = VideoToolArgs.keepRanges(input: input, output: output,
                                            ranges: [VideoClipRange(start: 0, end: 1), VideoClipRange(start: 2, end: 4)],
                                            hasAudio: true, encoding: .mp4)
        let keepGraph = keep[keep.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(keepGraph.contains("[sv1]trim=start=2:end=4,setpts=PTS-STARTPTS[v1]"))
        XCTAssertTrue(keepGraph.contains("concat=n=2:v=1:a=1[vout][aout]"))

        let crop = VideoToolArgs.crop(input: input, output: output, rect: VideoCropRect(x: 10, y: 20, width: 100, height: 50),
                                      encoding: .mp4)
        XCTAssertTrue(crop.contains("crop=100:50:10:20"))
        let snap = VideoToolArgs.snapshot(input: input, output: URL(fileURLWithPath: "/v/a.jpg"), time: 2, format: .jpg)
        XCTAssertEqual(Array(snap.prefix(2)), ["-ss", "2"])
        XCTAssertTrue(snap.contains("-frames:v"))

        XCTAssertEqual(VideoToolEncoding.matching(URL(fileURLWithPath: "/a.webm")).fileExtension, "webm")
        XCTAssertEqual(VideoToolEncoding.matching(URL(fileURLWithPath: "/a.wmv")).fileExtension, "mp4")
        XCTAssertEqual(VideoToolEncoding.matching(URL(fileURLWithPath: "/a.MOV")).fileExtension, "mov")
    }

    func testKeyframesAndStreamCopy() {
        let keys = VideoToolProbe.parseKeyframes("0.000000,K__\n0.133333,___\n2.000000,K_\n1.000000,K__\nbad\n")
        XCTAssertEqual(keys, [0, 1, 2])
        XCTAssertTrue(VideoToolOps.canStreamCopy(start: 0, keyframes: [], frameDuration: 1.0 / 30))
        XCTAssertTrue(VideoToolOps.canStreamCopy(start: 1.01, keyframes: keys, frameDuration: 1.0 / 30))
        XCTAssertFalse(VideoToolOps.canStreamCopy(start: 1.25, keyframes: keys, frameDuration: 1.0 / 30))
    }

    func testProgressParser() {
        var parser = VideoToolProgressParser(expectedDuration: 4)
        XCTAssertNil(parser.feed("frame=10\nout_time_us=1000"))
        XCTAssertEqual(parser.feed("000\n"), 0.25)
        XCTAssertEqual(parser.feed("out_time_ms=3000000\nspeed=2x\n"), 0.75)
        XCTAssertNil(parser.feed("out_time_us=N/A\n"))
        XCTAssertEqual(parser.feed("out_time_us=9000000\n"), 1)
        XCTAssertEqual(parser.feed("progress=end\n"), 1)
    }

    func testProbeParsing() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","codec_name":"mjpeg","width":600,"height":600,"disposition":{"attached_pic":1}},
          {"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001",
           "r_frame_rate":"30000/1001","sample_aspect_ratio":"1:1","tags":{"rotate":"90","DURATION":"00:00:07.500000000"}},
          {"codec_type":"audio","codec_name":"aac","sample_rate":"44100"}
        ],"format":{}}
        """
        let info = try VideoToolProbe.parse(Data(json.utf8))
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.fps, 29.97, accuracy: 0.01)
        XCTAssertEqual(info.rotation, 90)
        XCTAssertEqual(info.displayWidth, 1080)
        XCTAssertEqual(info.displayHeight, 1920)
        XCTAssertEqual(info.duration, 7.5, accuracy: 0.001)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.audioSampleRate, 44100)

        let coverOnly = try VideoToolProbe.parse(Data("""
        {"streams":[{"codec_type":"audio","codec_name":"mp3"},
                    {"codec_type":"video","width":500,"height":500,"disposition":{"attached_pic":1}}],
         "format":{"duration":"3.0"}}
        """.utf8))
        XCTAssertFalse(coverOnly.hasVideo)
        XCTAssertEqual(coverOnly.duration, 3)
    }
}

// MARK: - ffmpeg integration

final class VideoToolsExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil, "ffmpeg not installed")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// testsrc + sine, keyframe every second.
    private func fixture(_ name: String, size: String = "320x240", seconds: Double = 4, audio: Bool = true,
                         rate: Int = 30) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=\(size):rate=\(rate)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"] }
        args += ["-t", VideoToolArgs.number(seconds)]
        if url.pathExtension == "webm" {
            args += ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-g", "\(rate)"]
            if audio { args += ["-c:a", "libopus"] }
        } else {
            args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "\(rate)"]
            if audio { args += ["-c:a", "aac"] }
        }
        try await Tools.run("ffmpeg", args + [url.path])
        return url
    }

    private func imageSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    func testProbe() async throws {
        let clip = try await fixture("clip.mp4")
        let info = try await VideoToolProbe.probe(clip)
        XCTAssertEqual(info.duration, 4, accuracy: 0.1)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 240)
        XCTAssertEqual(info.fps, 30, accuracy: 0.01)
        XCTAssertTrue(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.rotation, 0)
        XCTAssertEqual(info.audioSampleRate, 48000)

        let silent = try await fixture("silent.mkv", seconds: 2, audio: false, rate: 25)
        let silentInfo = try await VideoToolProbe.probe(silent)
        XCTAssertFalse(silentInfo.hasAudio)
        XCTAssertEqual(silentInfo.fps, 25, accuracy: 0.01)
        XCTAssertEqual(silentInfo.duration, 2, accuracy: 0.1)

        let rotated = dir.appendingPathComponent("rotated.mp4")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-display_rotation", "90", "-i", clip.path,
                                       "-c", "copy", rotated.path])
        let rotatedInfo = try await VideoToolProbe.probe(rotated)
        XCTAssertEqual(rotatedInfo.rotation % 180, 90)
        XCTAssertEqual(rotatedInfo.displayWidth, 240)
        XCTAssertEqual(rotatedInfo.displayHeight, 320)

        let keyframes = try await VideoToolProbe.keyframeTimes(clip)
        XCTAssertEqual(keyframes, [0, 1, 2, 3])
        let near = try await VideoToolProbe.keyframeTimes(clip, near: 2.2)
        XCTAssertTrue(near.contains(2))
    }

    func testTrim() async throws {
        let clip = try await fixture("clip.mp4")
        let progress = VideoToolsProgressRecorder()
        let accurate = try await VideoToolOps.trim(clip, start: 1.25, end: 3.25, accurate: true, directory: dir,
                                                   progress: { progress.add($0) })
        XCTAssertEqual(accurate.lastPathComponent, "clip trimmed.mp4")
        let info = try await VideoToolProbe.probe(accurate)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(progress.values.last, 1)

        // Starts on a keyframe: copied, still exact.
        let keyed = try await VideoToolOps.trim(clip, start: 1, end: 2.5, directory: dir)
        XCTAssertEqual(keyed.lastPathComponent, "clip trimmed 2.mp4")
        let keyedDuration = try await VideoToolProbe.probe(keyed).duration
        XCTAssertEqual(keyedDuration, 1.5, accuracy: 0.1)

        // Fast mode copies from the keyframe before the start.
        let fast = try await VideoToolOps.trim(clip, start: 1.25, end: 3.25, accurate: false, directory: dir)
        let fastDuration = try await VideoToolProbe.probe(fast).duration
        XCTAssertGreaterThan(fastDuration, 1.9)
        XCTAssertLessThan(fastDuration, 2.5)

        do {
            _ = try await VideoToolOps.trim(clip, start: 3, end: 3.01, directory: dir)
            XCTFail("expected range error")
        } catch {
            XCTAssertEqual(error as? VideoToolError, .invalidRange)
        }
    }

    func testTrimWebM() async throws {
        let clip = try await fixture("web.webm", seconds: 2)
        let out = try await VideoToolOps.trim(clip, start: 0.5, end: 1.5, directory: dir)
        XCTAssertEqual(out.pathExtension, "webm")
        let duration = try await VideoToolProbe.probe(out).duration
        XCTAssertEqual(duration, 1, accuracy: 0.1)
    }

    func testSplit() async throws {
        let clip = try await fixture("clip.mp4")
        let clips = try await VideoToolOps.split(clip, points: [3, 1.5], mode: .separate, directory: dir)
        XCTAssertEqual(clips.map(\.lastPathComponent), ["clip-1.mp4", "clip-2.mp4", "clip-3.mp4"])
        let expected = [1.5, 1.5, 1.0]
        for (url, duration) in zip(clips, expected) {
            let actual = try await VideoToolProbe.probe(url).duration
            XCTAssertEqual(actual, duration, accuracy: 0.1, url.lastPathComponent)
        }

        let some = try await VideoToolOps.split(clip, points: [1.5, 3], removed: [0], mode: .separate, directory: dir)
        XCTAssertEqual(some.map(\.lastPathComponent), ["clip-2 2.mp4", "clip-3 2.mp4"])

        let joined = try await VideoToolOps.split(clip, points: [1, 2.5], removed: [1], mode: .joinRest, directory: dir)
        XCTAssertEqual(joined.count, 1)
        let joinedInfo = try await VideoToolProbe.probe(joined[0])
        XCTAssertEqual(joinedInfo.duration, 2.5, accuracy: 0.1)
        XCTAssertTrue(joinedInfo.hasAudio)

        do {
            _ = try await VideoToolOps.split(clip, points: [1, 1.02], mode: .separate, directory: dir)
            XCTFail("expected validation error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoSplitPlan.apartMessage)
        }
    }

    func testJoinDifferentSizesAndMissingAudio() async throws {
        let a = try await fixture("a.mp4", size: "320x240", seconds: 2)
        let b = try await fixture("b.mov", size: "640x360", seconds: 1.5, audio: false, rate: 25)
        let out = try await VideoToolOps.join([a, b], directory: dir)
        XCTAssertEqual(out.lastPathComponent, "a joined.mp4")
        let info = try await VideoToolProbe.probe(out)
        XCTAssertEqual(info.duration, 3.5, accuracy: 0.15)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 240)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.fps, 30, accuracy: 0.01)

        let largest = try await VideoToolOps.join([a, b], resolution: .largest, directory: dir)
        let largestInfo = try await VideoToolProbe.probe(largest)
        XCTAssertEqual(largestInfo.width, 640)
        XCTAssertEqual(largestInfo.height, 360)

        do {
            _ = try await VideoToolOps.join([a], directory: dir)
            XCTFail("expected count error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoToolOps.joinCountMessage)
        }
    }

    func testSpeed() async throws {
        let clip = try await fixture("clip.mp4")
        let fast = try await VideoToolOps.changeSpeed(clip, factor: 2, directory: dir)
        XCTAssertEqual(fast.lastPathComponent, "clip 2x.mp4")
        let info = try await VideoToolProbe.probe(fast)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.fps, 30, accuracy: 0.01)

        let slow = try await VideoToolOps.changeSpeed(clip, factor: 0.5, keepPitch: false, directory: dir)
        let slowDuration = try await VideoToolProbe.probe(slow).duration
        XCTAssertEqual(slowDuration, 8, accuracy: 0.15)

        do {
            _ = try await VideoToolOps.changeSpeed(clip, factor: 5, directory: dir)
            XCTFail("expected range error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoSpeed.rangeMessage)
        }
    }

    func testMute() async throws {
        let clip = try await fixture("clip.mp4", seconds: 2)
        let out = try await VideoToolOps.mute(clip, directory: dir)
        XCTAssertEqual(out.lastPathComponent, "clip muted.mp4")
        let info = try await VideoToolProbe.probe(out)
        XCTAssertFalse(info.hasAudio)
        XCTAssertTrue(info.hasVideo)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)

        do {
            _ = try await VideoToolOps.mute(out, directory: dir)
            XCTFail("expected no-audio error")
        } catch {
            XCTAssertEqual(error as? VideoToolError, .noAudioTrack)
        }

        // Batch: silent files are skipped, and only an all-silent batch fails.
        let other = try await fixture("other.mov", seconds: 1)
        let batch = try await VideoToolOps.mute([out, other], directory: dir)
        XCTAssertEqual(batch.map(\.lastPathComponent), ["other muted.mov"])
        do {
            _ = try await VideoToolOps.mute([out, batch[0]], directory: dir)
            XCTFail("expected all-silent error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoToolOps.muteNoneMessage)
        }
    }

    func testCancellationStopsFFmpegAndCleansUp() async throws {
        let output = dir.appendingPathComponent("long.mp4")
        let args = ["-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30", "-t", "120",
                    "-c:v", "libx264", "-preset", "veryslow", output.path]
        let progress = VideoToolsProgressRecorder()
        let job = Task {
            try await VideoToolRunner.ffmpeg(args, expectedDuration: 120, cleanup: [output], progress: { progress.add($0) })
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        job.cancel()
        do {
            try await job.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(progress.values.last ?? 0, 1)
    }

    func testCrop() async throws {
        let clip = try await fixture("clip.mp4", seconds: 2)
        let out = try await VideoToolOps.crop(clip, rect: VideoCropRect(x: 10, y: 20, width: 161, height: 121), directory: dir)
        XCTAssertEqual(out.lastPathComponent, "clip cropped.mp4")
        let info = try await VideoToolProbe.probe(out)
        XCTAssertEqual(info.width, 160)
        XCTAssertEqual(info.height, 120)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)

        do {
            _ = try await VideoToolOps.crop(clip, rect: VideoCropRect(x: 300, y: 0, width: 100, height: 100), directory: dir)
            XCTFail("expected bounds error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoCropMath.insideMessage)
        }
    }

    func testSnapshots() async throws {
        let clip = try await fixture("clip.mp4")
        let shots = try await VideoToolOps.snapshots(clip, times: [2, 0.5, 4], format: .png, directory: dir)
        XCTAssertEqual(shots.map(\.lastPathComponent), ["clip 00m00s.png", "clip 00m02s.png", "clip 00m03s.png"])
        for shot in shots {
            XCTAssertEqual(imageSize(shot)?.0, 320)
            XCTAssertEqual(imageSize(shot)?.1, 240)
        }

        let rotated = dir.appendingPathComponent("rotated.mp4")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-display_rotation", "90", "-i", clip.path,
                                       "-c", "copy", rotated.path])
        let jpg = try await VideoToolOps.snapshots(rotated, times: [1], format: .jpg, directory: dir)
        XCTAssertEqual(jpg.first?.pathExtension, "jpg")
        XCTAssertEqual(imageSize(jpg[0])?.0, 240)
        XCTAssertEqual(imageSize(jpg[0])?.1, 320)

        do {
            _ = try await VideoToolOps.snapshots(clip, times: [], directory: dir)
            XCTFail("expected empty error")
        } catch {
            XCTAssertEqual(error.localizedDescription, VideoToolOps.snapshotEmptyMessage)
        }
    }

    func testRedact() async throws {
        let clip = try await fixture("clip.mp4", seconds: 2)
        let boxes = [VideoRedactBox(rect: VideoCropRect(x: 20, y: 20, width: 100, height: 80), start: 0.5, end: 1.5),
                     VideoRedactBox(rect: VideoCropRect(x: 200, y: 100, width: 60, height: 60), start: 0, end: 2)]
        for style in VideoRedactStyle.allCases {
            let out = try await VideoToolOps.redact(clip, boxes: boxes, style: style, directory: dir)
            let info = try await VideoToolProbe.probe(out)
            XCTAssertEqual(info.width, 320, style.rawValue)
            XCTAssertEqual(info.height, 240, style.rawValue)
            XCTAssertTrue(info.hasAudio)
            XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        }
        // A black box really covers that area of the frame.
        let out = try await VideoToolOps.redact(clip, boxes: [boxes[1]], style: .black, directory: dir)
        let frame = try await VideoToolFrames.frame(out, at: 1, maxHeight: 240)
        XCTAssertEqual(frame.width, 320)
        XCTAssertLessThan(brightness(frame, x: 230, y: 130), 0.1)
    }

    func testFrameExtraction() async throws {
        let clip = try await fixture("clip.mkv", seconds: 2)
        let frame = try await VideoToolFrames.frame(clip, at: 1.99, maxHeight: 120)
        XCTAssertEqual(frame.height, 120)
        XCTAssertEqual(frame.width, 160)
    }

    private func brightness(_ image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}

private final class VideoToolsProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
