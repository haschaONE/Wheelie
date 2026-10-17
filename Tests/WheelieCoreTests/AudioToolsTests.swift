import Foundation
import XCTest
@testable import WheelieCore

// MARK: - Parsers and builders (no ffmpeg needed)

final class AudioParsingTests: XCTestCase {
    func testTimecode() {
        XCTAssertEqual(Timecode.string(75.5), "1:15.50")
        XCTAssertEqual(Timecode.string(3725), "1:02:05.00")
        XCTAssertEqual(Timecode.string(59.999), "1:00.00")
        XCTAssertEqual(Timecode.string(9.4, decimals: 0), "0:09")
        XCTAssertEqual(Timecode.parse("75.5"), 75.5)
        XCTAssertEqual(Timecode.parse("1:15.5"), 75.5)
        XCTAssertEqual(Timecode.parse("1:02:05"), 3725)
        XCTAssertEqual(Timecode.parse(" 0:03,25 "), 3.25)
        XCTAssertNil(Timecode.parse("abc"))
        XCTAssertNil(Timecode.parse("1.5:00"))
        XCTAssertNil(Timecode.parse(""))
    }

    func testProbeParsing() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"h264","codec_type":"video","width":1280,"height":720,"disposition":{"attached_pic":0}},
          {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"channel_layout":"stereo","bit_rate":"128000","disposition":{"attached_pic":0}},
          {"index":2,"codec_name":"mjpeg","codec_type":"video","width":300,"height":300,"disposition":{"attached_pic":1}}
        ],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.500000","bit_rate":"900000"}}
        """
        let info = try AudioProbe.parse(json: Data(json.utf8))
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.codec, "aac")
        XCTAssertEqual(info.bitRate, 128000)
        XCTAssertEqual(info.audioStreamIndex, 1)
        XCTAssertTrue(info.hasVideo)
        XCTAssertEqual(info.coverArtStreamIndex, 2)
        XCTAssertEqual(info.videoWidth, 1280)

        let mp3 = """
        {"streams":[{"index":0,"codec_name":"mp3","codec_type":"audio","sample_rate":"44100","channels":1,"channel_layout":"mono"},
                    {"index":1,"codec_name":"png","codec_type":"video","disposition":{"attached_pic":1}}],
         "format":{"format_name":"mp3","duration":"3.0","bit_rate":"192000"}}
        """
        let audio = try AudioProbe.parse(json: Data(mp3.utf8))
        XCTAssertFalse(audio.hasVideo)
        XCTAssertEqual(audio.coverArtStreamIndex, 1)
        XCTAssertEqual(audio.bitRate, 192000, "falls back to the format bit rate for audio-only files")
        XCTAssertTrue(audio.summary.contains("Mono"))

        let silentVideo = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"h264"}],"format":{"duration":"2"}}"#
        XCTAssertThrowsError(try AudioProbe.parse(json: Data(silentVideo.utf8), name: "clip.mp4")) { error in
            XCTAssertEqual(error.localizedDescription, "clip.mp4 has no audio track.")
        }
    }

    func testSilenceParsing() {
        let stderr = """
        Input #0, wav, from 'padded.wav':
        [Parsed_silencedetect_0 @ 0xb0ec04e40] silence_start: -0.00204
        [Parsed_silencedetect_0 @ 0xb0ec04e40] silence_end: 1.000023 | silence_duration: 1.002063
        [Parsed_silencedetect_0 @ 0xb0ec04e40] silence_start: 2.2
        [Parsed_silencedetect_0 @ 0xb0ec04e40] silence_end: 2.6 | silence_duration: 0.4
        [Parsed_silencedetect_0 @ 0xb0ec04e40] silence_start: 3.00102
        [out#0/null @ 0x816c046c0] video:0KiB audio:1688KiB
        """
        let silences = AudioTrim.parseSilences(stderr)
        XCTAssertEqual(silences.count, 3)
        XCTAssertEqual(silences[0], SilenceInterval(start: 0, end: 1.000023))
        XCTAssertEqual(silences[1], SilenceInterval(start: 2.2, end: 2.6))
        XCTAssertEqual(silences[2].start, 3.00102)
        XCTAssertNil(silences[2].end)

        // Leading and trailing silence go; the pause in the middle stays.
        let range = AudioTrim.audibleRange(silences: silences, duration: 4.5)
        XCTAssertEqual(range?.lowerBound ?? 0, 1.000023, accuracy: 1e-6)
        XCTAssertEqual(range?.upperBound ?? 0, 3.00102, accuracy: 1e-6)

        // A trailing silence that ffmpeg closes at EOF counts as trailing too.
        let closed = [SilenceInterval(start: 0, end: 0.5), SilenceInterval(start: 3, end: 4.49)]
        XCTAssertEqual(AudioTrim.audibleRange(silences: closed, duration: 4.5), 0.5...3)
        // No silence: untouched.
        XCTAssertEqual(AudioTrim.audibleRange(silences: [], duration: 4.5), 0...4.5)
        // All silent.
        XCTAssertNil(AudioTrim.audibleRange(silences: [SilenceInterval(start: 0, end: nil)], duration: 4.5))
        XCTAssertNil(AudioTrim.audibleRange(silences: [SilenceInterval(start: 0, end: 4.5)], duration: 4.5))
        // An end with no start means silence from the top.
        XCTAssertEqual(AudioTrim.parseSilences("silence_end: 0.8 | silence_duration: 0.8"), [SilenceInterval(start: 0, end: 0.8)])
    }

    func testTrimValidationAndFades() throws {
        let s = try AudioTrim.validated(TrimSettings(start: -1, end: 99, fadeIn: 3, fadeOut: 3), duration: 4)
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.end, 4)
        XCTAssertEqual(s.fadeIn + s.fadeOut, 4, accuracy: 1e-9, "fades are scaled to fit the clip")
        XCTAssertThrowsError(try AudioTrim.validated(TrimSettings(start: 2, end: 2.01), duration: 4))
        XCTAssertNil(AudioTrim.fadeFilter(TrimSettings(start: 1, end: 3)))
        XCTAssertEqual(AudioTrim.fadeFilter(TrimSettings(start: 1, end: 3, fadeIn: 0.5, fadeOut: 0.25)),
                       "afade=t=in:st=0:d=0.5,afade=t=out:st=1.75:d=0.25")
        XCTAssertThrowsError(try AudioTrim.validateThreshold(-90))
        XCTAssertNoThrow(try AudioTrim.validateThreshold(-50))

        let info = AudioInfo(duration: 4, channels: 2, sampleRate: 44100, codec: "mp3", bitRate: 128000, coverArtStreamIndex: 1)
        let enc = AudioEncoding.matching(info, source: URL(fileURLWithPath: "/a/song.mp3"))
        let args = AudioTrim.arguments(input: URL(fileURLWithPath: "/a/song.mp3"), output: URL(fileURLWithPath: "/a/out.mp3"),
                                       info: info, settings: TrimSettings(start: 1, end: 3), encoding: enc)
        XCTAssertEqual(Array(args[args.firstIndex(of: "-ss")!...].prefix(4)), ["-ss", "1", "-t", "2"])
        XCTAssertTrue(args.contains("attached_pic"), "cover art is kept")
        XCTAssertEqual(args.last, "/a/out.mp3")
    }

    func testLoudnormParsing() throws {
        let stderr = """
        [Parsed_loudnorm_0 @ 0x816c04e40]\u{20}
        {
        \t"input_i" : "-27.61",
        \t"input_tp" : "-4.47",
        \t"input_lra" : "18.06",
        \t"input_thresh" : "-39.20",
        \t"output_i" : "-16.58",
        \t"output_tp" : "-1.50",
        \t"output_lra" : "14.78",
        \t"output_thresh" : "-27.71",
        \t"normalization_type" : "dynamic",
        \t"target_offset" : "0.58"
        }
        [out#0/null @ 0x816c046c0] video:0KiB audio:1688KiB subtitle:0KiB
        """
        let m = try AudioNormalize.parseMeasurement(stderr)
        XCTAssertEqual(m, LoudnessMeasurement(integrated: -27.61, truePeak: -4.47, range: 18.06, threshold: -39.20, targetOffset: 0.58))
        XCTAssertFalse(m.isSilent)

        let target = LoudnessTarget(integrated: -16, range: 11, truePeak: -1)
        XCTAssertEqual(AudioNormalize.gain(target: target, measurement: m), 11.61, accuracy: 1e-9)
        XCTAssertFalse(AudioNormalize.isLinear(target: target, measurement: m), "range 18 LU > 11 LU target")
        let calm = LoudnessMeasurement(integrated: -30, truePeak: -20, range: 5, threshold: -40)
        XCTAssertTrue(AudioNormalize.isLinear(target: target, measurement: calm))
        let filter = AudioNormalize.applyFilter(target: target, measurement: m)
        XCTAssertTrue(filter.hasPrefix("loudnorm=I=-16:LRA=11:TP=-1:measured_I=-27.61:measured_LRA=18.06:measured_TP=-4.47"))
        XCTAssertTrue(filter.contains("linear=true"))

        let silent = stderr.replacingOccurrences(of: "\"-27.61\"", with: "\"-inf\"")
        XCTAssertTrue(try AudioNormalize.parseMeasurement(silent).isSilent)
        XCTAssertThrowsError(try AudioNormalize.parseMeasurement("no json here"))
    }

    func testLoudnessTargets() {
        XCTAssertEqual(LoudnessPreset.streaming.target?.integrated, -14)
        XCTAssertEqual(LoudnessPreset.podcast.target?.integrated, -16)
        XCTAssertEqual(LoudnessPreset.broadcast.target?.integrated, -23)
        XCTAssertNil(LoudnessPreset.custom.target)
        XCTAssertEqual(LoudnessPreset.matching(LoudnessPreset.broadcast.target!), .broadcast)
        XCTAssertEqual(LoudnessPreset.matching(LoudnessTarget(integrated: -18, range: 11, truePeak: -1)), .custom)
        XCTAssertNoThrow(try AudioNormalize.validate(LoudnessTarget(integrated: -70, range: 50, truePeak: -9)))
        XCTAssertNoThrow(try AudioNormalize.validate(LoudnessTarget(integrated: -5, range: 1, truePeak: 0)))
        XCTAssertThrowsError(try AudioNormalize.validate(LoudnessTarget(integrated: -4, range: 11, truePeak: -1)))
        XCTAssertThrowsError(try AudioNormalize.validate(LoudnessTarget(integrated: -16, range: 0.5, truePeak: -1)))
        XCTAssertThrowsError(try AudioNormalize.validate(LoudnessTarget(integrated: -16, range: 11, truePeak: 1)))
    }

    func testPeakBuckets() {
        // Two channels: left full-scale square burst in the first half, right half-scale everywhere.
        var samples: [Float] = []
        for i in 0..<1000 {
            samples.append(i < 500 ? (i % 2 == 0 ? 1 : -1) : 0)
            samples.append(0.5)
        }
        let peaks = WaveformExtractor.peaks(interleaved: samples, channels: 2, buckets: 10)
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks[0].count, 10)
        XCTAssertEqual(peaks[0][0], 1, accuracy: 0.001)
        XCTAssertEqual(peaks[0][4], 1, accuracy: 0.001)
        XCTAssertEqual(peaks[0][5], 0, accuracy: 0.001)
        XCTAssertEqual(peaks[1][9], 0.5, accuracy: 0.001)
        let wave = Waveform(channels: peaks, duration: 1)
        XCTAssertEqual(wave.combined[9], 0.5, accuracy: 0.001)
        XCTAssertEqual(wave.maximum, 1, accuracy: 0.001)
        // More buckets than samples still yields the requested count.
        XCTAssertEqual(WaveformExtractor.peaks(interleaved: [0.2, 0.4], channels: 1, buckets: 8)[0].count, 8)
        XCTAssertEqual(WaveformExtractor.bucketCount(forDuration: 1), 1000)
        XCTAssertEqual(WaveformExtractor.bucketCount(forDuration: 99_999), 30_000)
    }

    func testChannelFilters() {
        let stereo = AudioInfo(duration: 3, channels: 2, channelLayout: "stereo", sampleRate: 44100, codec: "aac")
        XCTAssertEqual(AudioChannels.filter(info: stereo, settings: ChannelSettings()), "pan=stereo|c0=1*c0|c1=1*c1")
        XCTAssertEqual(AudioChannels.filter(info: stereo, settings: ChannelSettings(swapped: true)), "pan=stereo|c0=1*c1|c1=1*c0")
        XCTAssertEqual(AudioChannels.filter(info: stereo, settings: ChannelSettings(output: .mono)), "pan=mono|c0=0.5*c0+0.5*c1")
        XCTAssertEqual(AudioChannels.filter(info: stereo, settings: ChannelSettings(output: .mono, balance: -1)), "pan=mono|c0=1*c0")
        XCTAssertEqual(AudioChannels.filter(info: stereo, settings: ChannelSettings(leftVolume: 1.5, balance: 0.5)),
                       "pan=stereo|c0=0.75*c0|c1=1*c1")
        let mono = AudioInfo(duration: 3, channels: 1, channelLayout: "mono", sampleRate: 44100, codec: "mp3")
        XCTAssertEqual(AudioChannels.filter(info: mono, settings: ChannelSettings()), "pan=stereo|c0=1*c0|c1=1*c0")
        XCTAssertEqual(AudioChannels.filter(info: mono, settings: ChannelSettings(output: .mono, leftVolume: 0)), "pan=mono|c0=0*c0")
        let surround = AudioInfo(duration: 3, channels: 6, channelLayout: "5.1", sampleRate: 48000, codec: "ac3")
        XCTAssertTrue(AudioChannels.filter(info: surround, settings: ChannelSettings()).hasPrefix("aformat=channel_layouts=stereo,pan="))
        XCTAssertEqual(AudioChannels.soloFilter(info: stereo, channel: 1, gain: 2), "pan=mono|c0=2*c1")
        XCTAssertThrowsError(try AudioChannels.validate(ChannelSettings(leftVolume: 3)))
    }

    func testBleepGraph() throws {
        let ranges = [BleepRange(start: 3, end: 4), BleepRange(start: 1, end: 2), BleepRange(start: 1.5, end: 2.5),
                      BleepRange(start: 9, end: 12), BleepRange(start: 5, end: 5.001)]
        let merged = AudioBleep.merged(ranges, duration: 10)
        XCTAssertEqual(merged, [1...2.5, 3...4, 9...10])
        XCTAssertEqual(AudioBleep.enableExpression(merged), "between(t,1,2.5)+between(t,3,4)+between(t,9,10)")

        let info = AudioInfo(duration: 10, channels: 2, channelLayout: "stereo", sampleRate: 48000, codec: "aac")
        let beep = try AudioBleep.filterGraph(settings: BleepSettings(ranges: ranges, style: .beep, volume: 0.25), info: info)
        XCTAssertTrue(beep.contains("volume=0:enable='between(t,1,2.5)+between(t,3,4)+between(t,9,10)'"))
        XCTAssertTrue(beep.contains("sine=frequency=1000:sample_rate=48000"))
        XCTAssertTrue(beep.contains("volume=2,"), "0.25 of full scale = 2 × sine's 1/8 amplitude")
        XCTAssertTrue(beep.contains("pan=stereo|c0=c0|c1=c0"))
        XCTAssertTrue(beep.hasSuffix("amix=inputs=2:duration=first:dropout_transition=0:normalize=0[bleeped]"))
        let silence = try AudioBleep.filterGraph(settings: BleepSettings(ranges: ranges, style: .silence), info: info)
        XCTAssertFalse(silence.contains("sine"))
        XCTAssertTrue(silence.hasSuffix("[bleeped]"))
        XCTAssertThrowsError(try AudioBleep.filterGraph(settings: BleepSettings(), info: info))
    }

    func testEncodingMatchesSource() {
        let url = { (ext: String) in URL(fileURLWithPath: "/a/file.\(ext)") }
        let mp3 = AudioEncoding.matching(AudioInfo(duration: 1, channels: 2, sampleRate: 44100, codec: "mp3", bitRate: 200_000), source: url("mp3"))
        XCTAssertEqual(mp3.codecArguments, ["-c:a", "libmp3lame", "-b:a", "224k"])
        XCTAssertTrue(mp3.carriesCoverArt)
        let wav = AudioEncoding.matching(AudioInfo(duration: 1, channels: 2, sampleRate: 96000, codec: "pcm_s24le"), source: url("wav"))
        XCTAssertEqual(wav.codecArguments, ["-c:a", "pcm_s24le"])
        let opus = AudioEncoding.matching(AudioInfo(duration: 1, channels: 2, sampleRate: 48000, codec: "opus"), source: url("ogg"))
        XCTAssertEqual(opus.requiredSampleRate, 48000)
        XCTAssertEqual(opus.fileExtension, "ogg")
        let movie = AudioEncoding.matching(AudioInfo(duration: 1, channels: 2, sampleRate: 48000, codec: "aac", hasVideo: true), source: url("mp4"))
        XCTAssertEqual(movie.codecArguments.prefix(2), ["-c:a", "aac"])
        XCTAssertFalse(movie.carriesCoverArt)
        XCTAssertEqual(AudioEncoding.preview(forDuration: 60), .previewWAV)
        XCTAssertEqual(AudioEncoding.preview(forDuration: 3600), .previewAAC)
    }

    func testVisualizerGraphs() {
        let settings = VisualizerSettings(style: .waveform, canvas: .landscape,
                                          foreground: VisualizerColor(red: 1, green: 0, blue: 0.5), background: VisualizerColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(settings.foreground.ffmpeg, "0xFF0080")
        let expected: [VisualizerStyle: String] = [.waveform: "showwaves=", .bars: "showfreqs=", .spectrum: "showspectrum=", .circle: "avectorscope="]
        for style in VisualizerStyle.allCases {
            var s = settings
            s.style = style
            let graph = AudioVisualizer.filterGraph(settings: s, duration: 10, audioStream: 0, hasImage: false)
            XCTAssertTrue(graph.contains(expected[style]!), "\(style)")
            XCTAssertTrue(graph.contains("color=c=0xFF0080:s=1920x1080:r=30"), "\(style)")
            XCTAssertTrue(graph.contains("color=c=0x000000:s=1920x1080"), "\(style)")
            XCTAssertTrue(graph.hasSuffix("[video]"))
        }
        let withImage = AudioVisualizer.filterGraph(settings: settings, duration: 10, audioStream: 0, hasImage: true)
        XCTAssertTrue(withImage.contains("[1:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080"))
        XCTAssertTrue(withImage.contains("colorchannelmixer"), "dimmed")
        XCTAssertEqual(VisualizerCanvas.portrait.scaled(0.4), VisualizerCanvas(width: 432, height: 768))

        // Level boost only lifts quiet audio, and only where the style needs it.
        XCTAssertEqual(AudioVisualizer.levelBoost(forPeak: 0.45), 2, accuracy: 1e-9)
        XCTAssertEqual(AudioVisualizer.levelBoost(forPeak: 1), 1)
        XCTAssertEqual(AudioVisualizer.levelBoost(forPeak: 0.001), 8)
        XCTAssertTrue(AudioVisualizer.maskGraph(style: .circle, canvas: .square, fps: 30, input: "0:0", levelBoost: 2).contains("volume=2"))
        XCTAssertFalse(AudioVisualizer.maskGraph(style: .waveform, canvas: .square, fps: 30, input: "0:0", levelBoost: 2).contains("volume="))
        // Bars are whole pixels wide and fit inside the canvas.
        for width in [432, 1080, 1920] {
            let bars = AudioVisualizer.barLayout(width: width)
            XCTAssertLessThanOrEqual(bars.count * bars.width, width)
            XCTAssertGreaterThan(bars.count, 40)
        }
    }

    func testTimelineViewport() {
        var v = TimelineViewport(duration: 100)
        XCTAssertFalse(v.isZoomed)
        v.zoom(by: 4, around: 50)
        XCTAssertEqual(v.length, 25)
        XCTAssertEqual(v.start, 37.5, "the anchor keeps its place on screen")
        XCTAssertTrue(v.isZoomed)
        v.pan(by: 100)
        XCTAssertEqual(v.start, 75, "pans stop at the end")
        v.pan(by: -1000)
        XCTAssertEqual(v.start, 0)
        v.zoom(by: 1e9)
        XCTAssertEqual(v.length, v.minimumLength)
        v.reveal(80)
        XCTAssertTrue((v.start...v.end).contains(80), "follows the playhead")
        v.show(10...20)
        XCTAssertLessThanOrEqual(v.start, 10)
        XCTAssertGreaterThanOrEqual(v.end, 20)
        v.reset()
        XCTAssertEqual(v.length, 100)
        XCTAssertEqual(v.time(atFraction: 1.5), 100, "clamped to the file")
        XCTAssertEqual(v.fraction(of: 25), 0.25)
        v.zoom(by: 0.1)
        XCTAssertEqual(v.length, 100, "can't zoom out past the whole file")
    }
}

// MARK: - End to end with ffmpeg

final class AudioToolsIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil, "ffmpeg not installed")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // Fixtures

    func ffmpeg(_ args: [String]) async throws {
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y"] + args)
    }

    /// 1 s silence + 2 s 440 Hz + 1.5 s silence.
    func makePadded(_ name: String = "padded.wav") async throws -> URL {
        let url = dir.appendingPathComponent(name)
        try await ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=1", "-f", "lavfi", "-i", "sine=f=440:r=44100:d=2",
                          "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=1.5",
                          "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", url.path])
        return url
    }

    /// Stereo: loud 440 Hz on the left (amplitude ~0.5), quiet 880 Hz on the right (~0.125).
    func makeStereo(_ name: String = "stereo.wav", seconds: Double = 2) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        try await ffmpeg(["-f", "lavfi", "-i", "sine=f=440:r=44100:d=\(seconds)", "-f", "lavfi", "-i", "sine=f=880:r=44100:d=\(seconds)",
                          "-filter_complex", "[0]volume=4[l];[l][1]join=inputs=2:channel_layout=stereo", url.path])
        return url
    }

    func streams(_ url: URL) async throws -> [[String: Any]] {
        let out = try await Tools.capture("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path])
        let json = try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any]
        return json?["streams"] as? [[String: Any]] ?? []
    }

    func measuredIntegrated(_ url: URL) async throws -> Double {
        try await AudioNormalize.measure(url).integrated
    }

    // Tests

    func testProbeAndWaveformPeaks() async throws {
        let padded = try await makePadded()
        let info = try await AudioProbe.probe(padded)
        XCTAssertEqual(info.duration, 4.5, accuracy: 0.02)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 44100)

        let wave = try await WaveformExtractor.extract(padded, buckets: 90, info: info)
        XCTAssertEqual(wave.channels.count, 1)
        XCTAssertEqual(wave.bucketCount, 90)
        // Buckets are 50 ms: silence for the first 20, tone (amplitude 1/8) for the next 40, then silence.
        XCTAssertLessThan(wave.channels[0][0..<19].max()!, 0.01)
        XCTAssertEqual(wave.channels[0][25], 0.125, accuracy: 0.02)
        XCTAssertEqual(wave.channels[0][55], 0.125, accuracy: 0.02)
        XCTAssertLessThan(wave.channels[0][62..<90].max()!, 0.01)

        let stereo = try await makeStereo()
        let lr = try await WaveformExtractor.extract(stereo, channels: 2, buckets: 50)
        XCTAssertEqual(lr.channels.count, 2)
        XCTAssertEqual(lr.channels[0][25], 0.5, accuracy: 0.05)
        XCTAssertEqual(lr.channels[1][25], 0.125, accuracy: 0.02)
    }

    func testAutoTrimRemovesSilentEnds() async throws {
        let padded = try await makePadded()
        let range = try await AudioTrim.detectAudibleRange(padded, thresholdDB: -50)
        XCTAssertEqual(range.lowerBound, 1, accuracy: 0.05)
        XCTAssertEqual(range.upperBound, 3, accuracy: 0.05)
        let out = try await AudioTrim.trim(padded, settings: TrimSettings(start: range.lowerBound, end: range.upperBound))
        XCTAssertEqual(out.lastPathComponent, "padded trimmed.wav")
        let info = try await AudioProbe.probe(out)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)

        let silent = dir.appendingPathComponent("silent.wav")
        try await ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=1", silent.path])
        do {
            _ = try await AudioTrim.detectAudibleRange(silent, thresholdDB: -50)
            XCTFail("expected a silence error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("silent"))
        }
    }

    func testTrimDurationFadesAndCoverArt() async throws {
        let wav = try await makeStereo(seconds: 3)
        let art = dir.appendingPathComponent("art.png")
        try await ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", art.path])
        let mp3 = dir.appendingPathComponent("song.mp3")
        try await ffmpeg(["-i", wav.path, "-i", art.path, "-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-b:a", "128k",
                          "-c:v", "mjpeg", "-disposition:v", "attached_pic", mp3.path])

        let out = try await AudioTrim.trim(mp3, settings: TrimSettings(start: 0.5, end: 2, fadeIn: 0.3, fadeOut: 0.3))
        XCTAssertEqual(out.lastPathComponent, "song trimmed.mp3")
        let info = try await AudioProbe.probe(out)
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.06)
        XCTAssertNotNil(info.coverArtStreamIndex, "cover art survives")
        XCTAssertEqual(info.codec, "mp3")

        // The fade-in makes the start quiet: first 50 ms peak well under the steady level.
        let wave = try await WaveformExtractor.extract(out, buckets: 30, info: info)
        XCTAssertLessThan(wave.channels[0][0], wave.channels[0][15] * 0.6)

        // A second trim never overwrites the first.
        let again = try await AudioTrim.trim(mp3, settings: TrimSettings(start: 0, end: 1))
        XCTAssertEqual(again.lastPathComponent, "song trimmed 2.mp3")
    }

    func testMonoOutputAndStereoSwap() async throws {
        let stereo = try await makeStereo()
        let mono = try await AudioChannels.convert(stereo, settings: ChannelSettings(output: .mono))
        XCTAssertEqual(mono.lastPathComponent, "stereo mono.wav")
        let monoInfo = try await AudioProbe.probe(mono)
        XCTAssertEqual(monoInfo.channels, 1)

        let swapped = try await AudioChannels.convert(stereo, settings: ChannelSettings(output: .stereo, swapped: true))
        let swappedInfo = try await AudioProbe.probe(swapped)
        XCTAssertEqual(swappedInfo.channels, 2)
        let lr = try await WaveformExtractor.extract(swapped, channels: 2, buckets: 20, info: swappedInfo)
        XCTAssertEqual(lr.channels[0][10], 0.125, accuracy: 0.02, "quiet right channel is now on the left")
        XCTAssertEqual(lr.channels[1][10], 0.5, accuracy: 0.05)

        // Volume and balance: right muted by full-left balance.
        let left = try await AudioChannels.convert(stereo, settings: ChannelSettings(balance: -1))
        let leftWave = try await WaveformExtractor.extract(left, channels: 2, buckets: 20)
        XCTAssertLessThan(leftWave.channels[1].max()!, 0.001)

        // Mono source -> stereo duplicates the channel.
        let padded = try await makePadded()
        let doubled = try await AudioChannels.convert(padded, settings: ChannelSettings(output: .stereo))
        let doubledInfo = try await AudioProbe.probe(doubled)
        XCTAssertEqual(doubledInfo.channels, 2)
    }

    func testChannelsOnVideoKeepsVideo() async throws {
        let movie = dir.appendingPathComponent("movie.mp4")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-f", "lavfi", "-i", "sine=f=440:d=1",
                          "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", movie.path])
        let out = try await AudioChannels.convert(movie, settings: ChannelSettings(output: .mono))
        XCTAssertEqual(out.pathExtension, "mp4")
        let s = try await streams(out)
        XCTAssertEqual(s.first { $0["codec_type"] as? String == "video" }?["codec_name"] as? String, "h264")
        XCTAssertEqual(s.first { $0["codec_type"] as? String == "audio" }?["channels"] as? Int, 1)

        let normalized = try await AudioNormalize.normalize(movie, target: LoudnessPreset.streaming.target!)
        let n = try await streams(normalized)
        XCTAssertEqual(n.first { $0["codec_type"] as? String == "video" }?["width"] as? Int, 160)
        XCTAssertEqual(n.first { $0["codec_type"] as? String == "audio" }?["sample_rate"] as? String, "44100")
    }

    func testNormalizeHitsTarget() async throws {
        // Quiet speech-like signal: a tone whose level wanders, plus a little noise.
        let quiet = dir.appendingPathComponent("quiet.m4a")
        try await ffmpeg(["-f", "lavfi", "-i", "aevalsrc='0.04*sin(2*PI*300*t)*(0.6+0.4*sin(2*PI*0.7*t))':s=44100:d=8",
                          "-f", "lavfi", "-i", "anoisesrc=d=8:c=pink:a=0.003:r=44100",
                          "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-c:a", "aac", "-b:a", "128k", quiet.path])
        let before = try await AudioNormalize.measure(quiet)
        XCTAssertLessThan(before.integrated, -25)

        for target in [LoudnessPreset.podcast.target!, LoudnessPreset.broadcast.target!] {
            let out = try await AudioNormalize.normalize(quiet, target: target)
            XCTAssertTrue(out.lastPathComponent.hasPrefix("quiet normalized"))
            XCTAssertEqual(out.pathExtension, "m4a")
            let after = try await measuredIntegrated(out)
            XCTAssertEqual(after, target.integrated, accuracy: 1, "\(target)")
            let info = try await AudioProbe.probe(out)
            XCTAssertEqual(info.sampleRate, 44100, "back to the source rate after loudnorm's 192 kHz")
        }

        // A steady sine has no loudness range, so loudnorm uses its dynamic mode; it still lands on target.
        let sine = dir.appendingPathComponent("sine.wav")
        try await ffmpeg(["-f", "lavfi", "-i", "sine=f=500:r=48000:d=6", "-af", "volume=0.2", sine.path])
        let target = LoudnessTarget(integrated: -20, range: 7, truePeak: -2)
        let out = try await AudioNormalize.normalize(sine, target: target)
        let after = try await measuredIntegrated(out)
        XCTAssertEqual(after, -20, accuracy: 1)
    }

    func testBleepKeepsDurationAndMutesRanges() async throws {
        let src = dir.appendingPathComponent("talk.wav")
        try await ffmpeg(["-f", "lavfi", "-i", "sine=f=300:r=44100:d=3", "-af", "volume=2,pan=stereo|c0=c0|c1=c0", src.path])
        let info = try await AudioProbe.probe(src)

        let muted = try await AudioBleep.bleep(src, settings: BleepSettings(ranges: [BleepRange(start: 0.5, end: 1.0)], style: .silence))
        XCTAssertEqual(muted.lastPathComponent, "talk bleeped.wav")
        let mutedInfo = try await AudioProbe.probe(muted)
        XCTAssertEqual(mutedInfo.duration, info.duration, accuracy: 0.05)
        XCTAssertEqual(mutedInfo.channels, 2)
        let mutedWave = try await WaveformExtractor.extract(muted, buckets: 30, info: mutedInfo)
        XCTAssertLessThan(mutedWave.channels[0][6..<9].max()!, 0.001, "0.6–0.9 s is silent")
        XCTAssertGreaterThan(mutedWave.channels[0][20], 0.2, "outside the range is untouched")

        let beeped = try await AudioBleep.bleep(src, settings: BleepSettings(ranges: [BleepRange(start: 0.5, end: 1.0),
                                                                                     BleepRange(start: 2, end: 2.5)],
                                                                            style: .beep, volume: 0.5))
        let beepInfo = try await AudioProbe.probe(beeped)
        XCTAssertEqual(beepInfo.duration, info.duration, accuracy: 0.05)
        let beepWave = try await WaveformExtractor.extract(beeped, buckets: 30, info: beepInfo)
        XCTAssertEqual(beepWave.channels[0][7], 0.5, accuracy: 0.06, "the tone replaces the audio")
        XCTAssertEqual(beepWave.channels[0][22], 0.5, accuracy: 0.06)
        XCTAssertEqual(beepWave.channels[0][15], 0.25, accuracy: 0.04, "original level between bleeps")

        // A range past the end is clamped, not an error; the result keeps its length.
        let mp3 = dir.appendingPathComponent("talk.mp3")
        try await ffmpeg(["-i", src.path, "-c:a", "libmp3lame", mp3.path])
        let whole = try await AudioBleep.bleep(mp3, settings: BleepSettings(ranges: [BleepRange(start: 0, end: 99)]))
        let wholeInfo = try await AudioProbe.probe(whole)
        let mp3Info = try await AudioProbe.probe(mp3)
        XCTAssertEqual(wholeInfo.duration, mp3Info.duration, accuracy: 0.06)
    }

    func testVisualizerStylesProduceVideo() async throws {
        let stereo = try await makeStereo(seconds: 1.5)
        let info = try await AudioProbe.probe(stereo)
        let cases: [(VisualizerStyle, VisualizerCanvas)] = [(.waveform, .square), (.bars, .landscape),
                                                             (.spectrum, .portrait), (.circle, VisualizerCanvas(width: 640, height: 360))]
        for (style, canvas) in cases {
            let out = dir.appendingPathComponent("viz-\(style.rawValue).mp4")
            try await AudioVisualizer.render(stereo, settings: VisualizerSettings(style: style, canvas: canvas), info: info, output: out)
            let s = try await streams(out)
            let video = s.first { $0["codec_type"] as? String == "video" }
            let audio = s.first { $0["codec_type"] as? String == "audio" }
            XCTAssertEqual(video?["codec_name"] as? String, "h264", "\(style)")
            XCTAssertEqual(video?["width"] as? Int, canvas.width, "\(style)")
            XCTAssertEqual(video?["height"] as? Int, canvas.height, "\(style)")
            XCTAssertEqual(video?["r_frame_rate"] as? String, "30/1", "\(style)")
            XCTAssertEqual(audio?["codec_name"] as? String, "aac", "\(style)")
            let duration = Double(video?["duration"] as? String ?? "") ?? 0
            XCTAssertEqual(duration, 1.5, accuracy: 0.1, "\(style)")
        }

        // Default naming, a background image and a still preview.
        let image = dir.appendingPathComponent("bg.png")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=300x200", "-frames:v", "1", image.path])
        let prepared = try AudioVisualizer.preparedImage(image, into: dir)
        let settings = VisualizerSettings(style: .bars, canvas: .landscape, backgroundImage: prepared)
        let named = try await AudioVisualizer.render(stereo, settings: settings, info: info)
        XCTAssertEqual(named.lastPathComponent, "stereo visualizer.mp4")
        let frame = dir.appendingPathComponent("frame.png")
        try await AudioVisualizer.previewFrame(stereo, settings: settings, info: info, at: 1, scale: 0.25, output: frame)
        let frameStreams = try await streams(frame)
        XCTAssertEqual(frameStreams.first?["width"] as? Int, 480)
        XCTAssertEqual(frameStreams.first?["height"] as? Int, 270)
    }

    func testCoverArtExtractionAndPlayableCopy() async throws {
        let wav = try await makeStereo(seconds: 1)
        let art = dir.appendingPathComponent("art.png")
        try await ffmpeg(["-f", "lavfi", "-i", "color=c=blue:s=80x80", "-frames:v", "1", art.path])
        let m4a = dir.appendingPathComponent("tagged.m4a")
        try await ffmpeg(["-i", wav.path, "-i", art.path, "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "png",
                          "-disposition:v", "attached_pic", m4a.path])
        let info = try await AudioProbe.probe(m4a)
        XCTAssertFalse(info.hasVideo)
        let cover = try await AudioVisualizer.extractCoverArt(m4a, info: info, into: dir)
        XCTAssertNotNil(cover)
        let coverStreams = try await streams(cover!)
        XCTAssertEqual(coverStreams.first?["width"] as? Int, 80)
        let noArt = try await AudioVisualizer.extractCoverArt(wav, info: try await AudioProbe.probe(wav), into: dir)
        XCTAssertNil(noArt)

        let opus = dir.appendingPathComponent("voice.opus")
        try await ffmpeg(["-i", wav.path, "-c:a", "libopus", opus.path])
        let opusInfo = try await AudioProbe.probe(opus)
        let playable = try await AudioPreview.playableCopy(of: opus, info: opusInfo, in: dir)
        XCTAssertEqual(playable.pathExtension, "wav")
        let playableInfo = try await AudioProbe.probe(playable)
        XCTAssertEqual(playableInfo.duration, opusInfo.duration, accuracy: 0.05)

        // Normalizing Opus keeps a rate the encoder accepts.
        let normalized = try await AudioNormalize.normalize(opus, target: LoudnessPreset.podcast.target!, info: opusInfo)
        XCTAssertEqual(normalized.pathExtension, "opus")
        let normalizedInfo = try await AudioProbe.probe(normalized)
        XCTAssertEqual(normalizedInfo.sampleRate, 48000)
    }
}
