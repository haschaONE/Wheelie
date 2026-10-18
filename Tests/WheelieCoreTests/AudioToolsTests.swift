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

        // A movie with two audio tracks: the first is processed, the second is listed to be kept.
        let multi = """
        {"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":640,"height":360},
                    {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2},
                    {"index":2,"codec_name":"mov_text","codec_type":"subtitle"},
                    {"index":3,"codec_name":"ac3","codec_type":"audio","sample_rate":"48000","channels":6}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"5"}}
        """
        let multiInfo = try AudioProbe.parse(json: Data(multi.utf8))
        XCTAssertEqual(multiInfo.audioStreamIndex, 1)
        XCTAssertEqual(multiInfo.otherAudioStreamIndices, [3])
        XCTAssertEqual(info.otherAudioStreamIndices, [])

        // Raw VBR AAC: ffprobe guesses 509 s from the bit rate; the measured length replaces it, and the
        // average bit rate follows from the file size.
        let adts = """
        {"streams":[{"index":0,"codec_name":"aac","codec_type":"audio","sample_rate":"44100","channels":2}],
         "format":{"format_name":"aac","duration":"509.08","size":"640000","bit_rate":"10057"}}
        """
        let estimated = try AudioProbe.parse(json: Data(adts.utf8))
        XCTAssertEqual(estimated.duration, 509.08, accuracy: 0.001)
        let measured = try AudioProbe.parse(json: Data(adts.utf8), measuredDuration: 40)
        XCTAssertEqual(measured.duration, 40)
        XCTAssertEqual(measured.bitRate, 128_000)
        XCTAssertEqual(AudioProbe.parseProgressDuration("out_time_us=N/A\nprogress=continue\nout_time_us=1500000\nout_time_us=40031202\nprogress=end\n")!,
                       40.031202, accuracy: 0.000001)
        XCTAssertNil(AudioProbe.parseProgressDuration("progress=end\n"))

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
        // Buckets laid out over a longer span than the decoded samples: the peaks stay where they are in
        // time and the buckets past the end of the audio are empty.
        let spanned = [Float](repeating: 0.5, count: 100).withUnsafeBufferPointer { floats -> [[Float]] in
            let ints = floats.map { Int16($0 * 32767) }
            return ints.withUnsafeBufferPointer { WaveformExtractor.peaks(int16: $0, channels: 1, buckets: 10, spanFrames: 200) }
        }
        XCTAssertEqual(spanned[0][4], 0.5, accuracy: 0.001)
        XCTAssertEqual(spanned[0][5], 0)
        XCTAssertEqual(spanned[0][9], 0)
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
        // A balanced if-tree, checked per sample; the last range reaches the end, so it stays on to the real end.
        XCTAssertEqual(AudioBleep.insideExpression(merged, duration: 10),
                       "if(lt(t,3),if(lt(t,1),0,if(lte(t,2.5),1,0)),if(lte(t,4),1,if(lt(t,9),0,1)))")
        XCTAssertEqual(AudioBleep.insideExpression([1.03...1.1], duration: 0), "if(lt(t,1.03),0,if(lte(t,1.1),1,0))")
        XCTAssertEqual(AudioBleep.insideExpression([], duration: 5), "0")

        // "Entire audio" for several files: an infinite end covers each file to its own end.
        let whole = [BleepRange(start: 0, end: .infinity)]
        XCTAssertEqual(AudioBleep.merged(whole, duration: 220), [0...220])
        XCTAssertEqual(AudioBleep.merged(whole, duration: 180), [0...180])
        XCTAssertEqual(AudioBleep.insideExpression(AudioBleep.merged(whole, duration: 0), duration: 0), "if(lt(t,0),0,1)")

        let info = AudioInfo(duration: 10, channels: 2, channelLayout: "stereo", sampleRate: 48000, codec: "aac")
        let beep = try AudioBleep.filterGraph(settings: BleepSettings(ranges: ranges, style: .beep, volume: 0.25), info: info)
        XCTAssertEqual(beep, "[0:0]asetpts=PTS-STARTPTS,aeval=exprs='if("
                       + AudioBleep.insideExpression(merged, duration: 10)
                       + ",0.25*sin(2*PI*1000*t),val(ch))':c=same[bleeped]")
        XCTAssertFalse(beep.contains("enable="), "timeline enable is only checked once per frame")
        let silence = try AudioBleep.filterGraph(settings: BleepSettings(ranges: ranges, style: .silence), info: info)
        XCTAssertFalse(silence.contains("sin("))
        XCTAssertTrue(silence.contains(",0,val(ch))'"))
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

        // The container must be able to hold the codec.
        func enc(_ codec: String, _ ext: String, video: Bool = false, bitRate: Int? = nil) -> AudioEncoding {
            AudioEncoding.matching(AudioInfo(duration: 1, channels: 2, sampleRate: 44100, codec: codec, bitRate: bitRate,
                                             hasVideo: video), source: url(ext))
        }
        XCTAssertEqual(enc("pcm_mulaw", "au").codecArguments, ["-c:a", "pcm_mulaw"])
        XCTAssertEqual(enc("pcm_mulaw", "au").fileExtension, "au")
        XCTAssertEqual(enc("mp2", "mp2").codecArguments, ["-c:a", "mp2", "-b:a", "192k"])
        XCTAssertEqual(enc("mp2", "mpg", video: true, bitRate: 384_000).codecArguments, ["-c:a", "mp2", "-b:a", "384k"])
        XCTAssertEqual(enc("aac", "m4r").codecArguments, ["-c:a", "aac", "-b:a", "192k", "-f", "ipod"])
        XCTAssertEqual(enc("aac", "m4r").fileExtension, "m4r")
        XCTAssertEqual(enc("wavpack", "wv").codecArguments, ["-c:a", "wavpack"])
        XCTAssertEqual(enc("aac", "caf").codecArguments, ["-c:a", "alac"], "ffmpeg can't write AAC into CAF")
        let amr = enc("amr_nb", "amr")
        XCTAssertEqual(amr.fileExtension, "m4a", "no AMR encoder: M4A instead")
        XCTAssertEqual(amr.codecArguments.prefix(2), ["-c:a", "aac"])
        XCTAssertTrue(amr.carriesCoverArt)
        XCTAssertEqual(enc("dts", "dts").fileExtension, "m4a")
        XCTAssertEqual(enc("ape", "ape").fileExtension, "flac", "lossless stays lossless")
        XCTAssertEqual(enc("ape", "ape").codecArguments, ["-c:a", "flac"])
        XCTAssertEqual(enc("alac", "").fileExtension, "m4a")
        XCTAssertEqual(enc("alac", "").codecArguments, ["-c:a", "alac"])
        XCTAssertEqual(enc("dts", "mkv", video: true).codecArguments.prefix(2), ["-c:a", "aac"])
        XCTAssertEqual(enc("dts", "mkv", video: true).fileExtension, "mkv")
        XCTAssertEqual(enc("aac", "xyz", video: true).fileExtension, "mkv")
        XCTAssertEqual(enc("pcm_s16le", "aiff").codecArguments, ["-c:a", "pcm_s16le"])
        XCTAssertEqual(enc("pcm_s24le", "flac").codecArguments, ["-c:a", "flac"])
        XCTAssertEqual(enc("pcm_s16be", "wav").codecArguments, ["-c:a", "pcm_s16le"], "WAV has no big-endian PCM")
        XCTAssertEqual(enc("wmav2", "wma").codecArguments.prefix(2), ["-c:a", "aac"])
        // Every audio extension FileKind accepts, with its usual codec, gets a codec its container holds.
        let usual = ["mp3": "mp3", "m4a": "aac", "m4b": "aac", "m4r": "aac", "aac": "aac", "wav": "pcm_s16le",
                     "aif": "pcm_s16be", "aiff": "pcm_s16be", "aifc": "pcm_s16be", "caf": "aac", "flac": "flac",
                     "ogg": "vorbis", "oga": "vorbis", "opus": "opus", "wma": "wmav2", "amr": "amr_nb", "au": "pcm_mulaw",
                     "snd": "pcm_mulaw", "mp2": "mp2", "ac3": "ac3", "3gp": "aac", "mka": "aac", "ape": "ape", "wv": "wavpack"]
        for (ext, codec) in usual {
            let e = enc(codec, ext)
            let produced = e.codecArguments[1] == "libmp3lame" ? "mp3" : e.codecArguments[1] == "libopus" ? "opus" : e.codecArguments[1]
            XCTAssertTrue(AudioEncoding.holds(e.fileExtension, produced), "\(ext) \(codec) -> \(e)")
        }
        XCTAssertEqual(AudioEncoding.preview(forDuration: 3600), .previewAAC)
    }

    func testStreamArgumentsKeepEveryOtherStreamOfMovies() {
        let movie = AudioInfo(duration: 5, channels: 2, sampleRate: 48000, codec: "aac", audioStreamIndex: 1,
                              otherAudioStreamIndices: [3], hasVideo: true)
        let enc = AudioEncoding(codecArguments: ["-c:a", "aac", "-b:a", "192k"], fileExtension: "mp4")
        XCTAssertEqual(AudioFFmpeg.audioArguments(movie, encoding: enc, keepVideo: true, filter: "pan=mono|c0=c0", sampleRate: 48000),
                       ["-map", "0:v?", "-map", "0:1", "-map", "0:3", "-map", "0:s?", "-map", "0:t?", "-c", "copy",
                        "-filter:a:0", "pan=mono|c0=c0", "-c:a:0", "aac", "-b:a:0", "192k", "-ar:a:0", "48000"])
        // Without the video (previews) only the processed track is written.
        XCTAssertEqual(AudioFFmpeg.audioArguments(movie, encoding: enc, keepVideo: false, filter: "volume=1", sampleRate: nil),
                       ["-vn", "-map", "0:1", "-af", "volume=1", "-c:a", "aac", "-b:a", "192k"])
    }

    func testBackgroundImageSize() {
        XCTAssertEqual(AudioVisualizer.backgroundShortSide, 1920)
        XCTAssertEqual(AudioVisualizer.backgroundMaxPixelSize(width: 8064, height: 6048), 2560, "48 MP -> short side 1920")
        XCTAssertEqual(AudioVisualizer.backgroundMaxPixelSize(width: 3000, height: 4000), 2560)
        XCTAssertEqual(AudioVisualizer.backgroundMaxPixelSize(width: 1000, height: 800), 1000, "small images keep their size")
        XCTAssertEqual(AudioVisualizer.backgroundMaxPixelSize(width: 7680, height: 1920), 7680, "a panorama keeps enough height")
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

    /// Mono float samples of a file at 44.1 kHz.
    func samples(_ url: URL) async throws -> [Float] {
        let raw = dir.appendingPathComponent("samples-\(UUID().uuidString).raw")
        try await ffmpeg(["-i", url.path, "-ac", "1", "-ar", "44100", "-f", "f32le", "-c:a", "pcm_f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func peak(_ s: [Float], from: Double, to: Double, rate: Double = 44100) -> Float {
        s[Int((from * rate).rounded())...Int((to * rate).rounded())].map(abs).max() ?? 0
    }

    func testBleepIsSampleAccurate() async throws {
        // WAV decodes in 4096-sample packets (93 ms): neither range starts on a packet boundary, and
        // 1.03–1.10 s lies inside a single packet.
        let src = dir.appendingPathComponent("word.wav")
        try await ffmpeg(["-f", "lavfi", "-i", "sine=f=440:r=44100:d=2", "-af", "volume=4", src.path])
        let original = try await samples(src)

        let output = dir.appendingPathComponent("muted.wav")
        try await AudioBleep.bleep(src, settings: BleepSettings(ranges: [BleepRange(start: 1.03, end: 1.10)], style: .silence),
                                   output: output)
        let muted = try await samples(output)
        XCTAssertLessThan(peak(muted, from: 1.0302, to: 1.0998), 0.0001, "silent from the first sample of the range")
        XCTAssertGreaterThan(peak(muted, from: 1.0, to: 1.0298), 0.45, "untouched just before")
        XCTAssertGreaterThan(peak(muted, from: 1.1002, to: 1.13), 0.45, "untouched just after")

        let beepURL = dir.appendingPathComponent("beeped.wav")
        try await AudioBleep.bleep(src, settings: BleepSettings(ranges: [BleepRange(start: 0.94, end: 1.2)], style: .beep,
                                                                volume: 0.3, frequency: 1000), output: beepURL)
        let beeped = try await samples(beepURL)
        XCTAssertEqual(beeped.count, original.count)
        var toneError: Float = 0
        for i in Int(0.9402 * 44100)...Int(1.1998 * 44100) {
            toneError = max(toneError, abs(beeped[i] - Float(0.3 * sin(2 * Double.pi * 1000 * Double(i) / 44100))))
        }
        XCTAssertLessThan(toneError, 0.002, "only the tone inside the range, none of the word")
        var sourceError: Float = 0
        for i in Int(1.2002 * 44100)...Int(1.3 * 44100) { sourceError = max(sourceError, abs(beeped[i] - original[i])) }
        for i in Int(0.85 * 44100)...Int(0.9398 * 44100) { sourceError = max(sourceError, abs(beeped[i] - original[i])) }
        XCTAssertLessThan(sourceError, 0.001, "the audio around the range is unchanged, with no tone")
    }

    func testEstimatedDurationIsMeasuredAndEmptyResultsFail() async throws {
        // Raw ADTS AAC with a quiet start: ffprobe estimates its length from the bit rate, far too long.
        let aac = dir.appendingPathComponent("vbr.aac")
        try await ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=3", "-f", "lavfi", "-i", "anoisesrc=d=3:a=0.3:r=44100",
                          "-filter_complex", "[1]pan=stereo|c0=c0|c1=c0[n];[0][n]concat=n=2:v=0:a=1", "-c:a", "aac", "-q:a", "2", aac.path])
        let info = try await AudioProbe.probe(aac)
        XCTAssertEqual(info.duration, 6, accuracy: 0.1)
        XCTAssertNotNil(info.bitRate)

        let wave = try await WaveformExtractor.extract(aac, buckets: 60, info: info)
        XCTAssertLessThan(wave.channels[0][0..<28].max()!, 0.01, "the quiet half is drawn in the first half")
        XCTAssertGreaterThan(wave.channels[0][32..<60].min()!, 0.1, "the loud half fills the second half")

        // A range past the real end: ffmpeg exits cleanly but writes nothing. That's an error, not an export.
        var stale = info
        stale.duration = 100
        let output = dir.appendingPathComponent("vbr trimmed.aac")
        do {
            try await AudioTrim.trim(aac, settings: TrimSettings(start: 50, end: 60), info: stale, output: output)
            XCTFail("an empty result must not count as a success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("empty"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExportsWriteCodecsTheirContainersHold() async throws {
        let wav = try await makeStereo(seconds: 1)
        let fixtures: [(String, [String])] = [
            ("t.au", ["-c:a", "pcm_mulaw"]), ("t.mp2", ["-c:a", "mp2"]), ("t.m4r", ["-c:a", "aac", "-f", "ipod"]),
            ("t.wv", ["-c:a", "wavpack"]), ("t.caf", ["-c:a", "alac"]), ("t.aiff", ["-c:a", "pcm_s16be"]),
            ("t.wma", ["-c:a", "wmav2"]), ("t.oga", ["-c:a", "flac"]),
        ]
        for (name, codec) in fixtures {
            let src = dir.appendingPathComponent(name)
            try await ffmpeg(["-i", wav.path] + codec + [src.path])
            let info = try await AudioProbe.probe(src)
            let ext = src.pathExtension
            let trimmed = try await AudioTrim.trim(src, settings: TrimSettings(start: 0.2, end: 0.8), info: info)
            XCTAssertEqual(trimmed.pathExtension, ext, name)
            let trimmedInfo = try await AudioProbe.probe(trimmed)
            XCTAssertEqual(trimmedInfo.duration, 0.6, accuracy: 0.1, name)
            let mono = try await AudioChannels.convert(src, settings: ChannelSettings(output: .mono), info: info)
            let monoInfo = try await AudioProbe.probe(mono)
            XCTAssertEqual(monoInfo.channels, 1, name)
            try await AudioBleep.bleep(src, settings: BleepSettings(ranges: [BleepRange(start: 0.1, end: 0.3)]), info: info)
        }

        // MPEG-PS video with MP2 audio (.mpg / .vob).
        let mpg = dir.appendingPathComponent("v.mpg")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=25", "-f", "lavfi", "-i", "sine=f=440:d=1",
                          "-t", "1", "-c:v", "mpeg2video", "-c:a", "mp2", "-ac", "2", mpg.path])
        let mono = try await AudioChannels.convert(mpg, settings: ChannelSettings(output: .mono))
        XCTAssertEqual(mono.pathExtension, "mpg")
        let s = try await streams(mono)
        XCTAssertEqual(s.first { $0["codec_type"] as? String == "video" }?["codec_name"] as? String, "mpeg2video")
        XCTAssertEqual(s.first { $0["codec_type"] as? String == "audio" }?["channels"] as? Int, 1)
        let normalized = try await AudioNormalize.normalize(mpg, target: LoudnessPreset.streaming.target!)
        XCTAssertEqual(normalized.pathExtension, "mpg")
    }

    func testMoviesKeepOtherAudioTracksAndSubtitles() async throws {
        let srt = dir.appendingPathComponent("subs.srt")
        try "1\n00:00:00,000 --> 00:00:01,500\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        let movie = dir.appendingPathComponent("multi.mp4")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-f", "lavfi", "-i", "sine=f=440:d=2",
                          "-f", "lavfi", "-i", "sine=f=660:d=2", "-i", srt.path,
                          "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-t", "2",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-c:s", "mov_text",
                          "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=ger", movie.path])
        let info = try await AudioProbe.probe(movie)
        XCTAssertEqual(info.otherAudioStreamIndices.count, 1)

        func check(_ url: URL, firstChannels: Int) async throws {
            let s = try await streams(url)
            let types = s.compactMap { $0["codec_type"] as? String }
            XCTAssertEqual(types, ["video", "audio", "audio", "subtitle"], url.lastPathComponent)
            let audio = s.filter { $0["codec_type"] as? String == "audio" }
            XCTAssertEqual(audio.first?["channels"] as? Int, firstChannels)
            XCTAssertEqual(audio.last?["channels"] as? Int, 2, "the second track is copied as it is")
            XCTAssertEqual((audio.last?["tags"] as? [String: Any])?["language"] as? String, "ger")
            XCTAssertEqual(s.last?["codec_name"] as? String, "mov_text")
        }
        let mono = try await AudioChannels.convert(movie, settings: ChannelSettings(output: .mono), info: info)
        try await check(mono, firstChannels: 1)
        let normalized = try await AudioNormalize.normalize(movie, target: LoudnessPreset.podcast.target!, info: info)
        try await check(normalized, firstChannels: 2)
    }

    func testCancellingARenderStopsFFmpeg() async throws {
        let output = dir.appendingPathComponent("long.wav")
        // -re: realtime, so this would take a minute if it weren't stopped.
        let args = AudioFFmpeg.baseArguments + ["-re", "-f", "lavfi", "-i", "sine=f=440:d=60", "-c:a", "pcm_s16le", output.path]
        let started = Date()
        let task = Task { try await AudioFFmpeg.run(args, output: output) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the partial render is deleted")
    }

    func testLargeBackgroundImageIsDownscaled() async throws {
        let big = dir.appendingPathComponent("big.png")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=size=4000x3000", "-frames:v", "1", big.path])
        let prepared = try AudioVisualizer.preparedImage(big, into: dir)
        let s = try await streams(prepared)
        XCTAssertEqual(s.first?["width"] as? Int, 2560)
        XCTAssertEqual(s.first?["height"] as? Int, 1920)
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
