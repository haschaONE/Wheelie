import AVFoundation
import AppKit
import Combine
import WheelieCore

/// Playback, scrubbing and thumbnails for one video, shared by every video editor.
/// Uses AVFoundation when it can play the file; otherwise ffprobe/ffmpeg provide the
/// duration, the filmstrip and still frames for the preview.
@MainActor
final class VideoToolsPlayer: ObservableObject {
    enum LoadState: Equatable {
        case loading, ready, failed(String)
    }

    let url: URL
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var info: VideoToolInfo?
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    /// AVFoundation can play this file (false for most MKV/WebM/AVI).
    @Published private(set) var canPlay = false
    @Published private(set) var thumbnails: [CGImage?] = []
    /// Preview image when AVFoundation can't play the file.
    @Published private(set) var stillFrame: CGImage?
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }
    @Published var keepPitch = true {
        didSet { player?.currentItem?.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed }
    }

    /// Playback loops inside this range (Trim).
    var loopRange: ClosedRange<Double>?
    /// Playback jumps over these ranges (removed Split clips).
    var skipRanges: [ClosedRange<Double>] = []

    private(set) var player: AVPlayer?
    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?
    private var seekInFlight = false
    private var pendingSeek: Double?
    private var isScrubbing = false
    private var stillTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var didLoad = false
    let thumbnailCount = 14

    init(url: URL) { self.url = url }

    // MARK: Derived

    /// Displayed frame size in pixels (rotation applied).
    var pixelSize: CGSize {
        guard let info, info.displayWidth > 0 else { return CGSize(width: 1920, height: 1080) }
        return CGSize(width: info.displayWidth, height: info.displayHeight)
    }

    var displayAspect: Double { info?.displayAspect ?? 16.0 / 9 }
    var frameDuration: Double { info?.frameDuration ?? 1.0 / 30 }
    var hasAudio: Bool { info?.hasAudio ?? false }

    // MARK: Loading

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        async let probed = try? VideoToolProbe.probe(url)
        let avInfo = await loadAVFoundation()
        var info = await probed
        if info == nil, let avInfo { info = avInfo }
        guard let info, info.hasVideo, info.duration > 0 else {
            state = .failed(info == nil ? "Couldn't read this video. Is ffmpeg installed? (brew install ffmpeg)"
                                        : VideoToolError.noVideoTrack.message)
            return
        }
        self.info = info
        duration = info.duration
        state = .ready
        if !canPlay { requestStill(at: 0) }
        startThumbnails()
    }

    /// Sets up the AVPlayer when AVFoundation can play the video track. Returns basic facts as a fallback.
    private func loadAVFoundation() async -> VideoToolInfo? {
        let asset = AVURLAsset(url: url)
        guard let (playable, length) = try? await asset.load(.isPlayable, .duration), playable,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.isPlayable)) == true,
              let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        canPlay = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reachedEnd() } }
        let shown = size.applying(transform)
        let quarter = abs(transform.b) > 0.5
        return VideoToolInfo(duration: length.seconds.isFinite ? length.seconds : 0,
                              width: Int(abs(quarter ? shown.height : shown.width)),
                              height: Int(abs(quarter ? shown.width : shown.height)),
                              rotation: quarter ? 90 : 0, fps: Double(fps), hasAudio: !audio.isEmpty)
    }

    /// Stops playback and releases the player; called when the editor window closes.
    func tearDown() {
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        endObserver = nil
        stillTask?.cancel()
        thumbnailTask?.cancel()
        player?.replaceCurrentItem(with: nil)
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player, state == .ready else { return }
        var start = currentTime
        if let loop = loopRange, start < loop.lowerBound || start >= loop.upperBound - 0.02 {
            start = loop.lowerBound
        } else if start >= duration - 0.02 {
            start = 0
        }
        if let skip = skipRanges.first(where: { $0.contains(start) }) { start = skip.upperBound }
        if start >= duration - 0.02 { return }
        if abs(start - currentTime) > 0.001 { seek(to: start) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !isScrubbing, !seekInFlight else { return }
        currentTime = min(max(0, seconds), duration)
        guard isPlaying else { return }
        if let loop = loopRange, currentTime >= loop.upperBound - 0.01 {
            seek(to: loop.lowerBound)
            return
        }
        if let skip = skipRanges.first(where: { currentTime >= $0.lowerBound && currentTime < $0.upperBound - 0.02 }) {
            if skip.upperBound >= duration - 0.02 { pause() } else { seek(to: skip.upperBound) }
        }
    }

    private func reachedEnd() {
        if isPlaying, let loop = loopRange {
            seek(to: loop.lowerBound)
            player?.rate = rate
        } else {
            isPlaying = false
            currentTime = duration
        }
    }

    // MARK: Seeking

    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        currentTime = t
        if player != nil { performSeek(t) } else { requestStill(at: t) }
    }

    /// Timeline drags: pause, then follow the pointer.
    func scrub(to time: Double) {
        if !isScrubbing {
            isScrubbing = true
            pause()
        }
        seek(to: time)
    }

    func endScrub() { isScrubbing = false }

    /// Moves by whole frames (or seconds with `seconds: true`).
    func step(_ count: Int, seconds: Bool = false) {
        pause()
        if seconds {
            seek(to: currentTime + Double(count))
        } else {
            let fd = frameDuration
            let frame = (currentTime / fd).rounded() + Double(count)
            seek(to: frame * fd)
        }
    }

    /// Coalesces seeks so dragging stays responsive: one in flight, the newest one queued.
    private func performSeek(_ t: Double) {
        guard let player else { return }
        if seekInFlight { pendingSeek = t; return }
        seekInFlight = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.performSeek(next)
                }
            }
        }
    }

    // MARK: Frames

    private func requestStill(at time: Double) {
        guard !canPlay else { return }
        stillTask?.cancel()
        let url = url, duration = duration
        stillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let image = try? await VideoToolFrames.frame(url, at: time, maxHeight: 720, duration: duration)
            guard !Task.isCancelled, let image else { return }
            self?.stillFrame = image
        }
    }

    /// A small frame at `time` (snapshot list, join list).
    func frameImage(at time: Double, maxHeight: Int = 160) async -> CGImage? {
        if let asset, canPlay {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxHeight * 3, height: maxHeight)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 6000)).image {
                return image
            }
        }
        return try? await VideoToolFrames.frame(url, at: time, maxHeight: maxHeight, duration: duration)
    }

    private func startThumbnails() {
        let count = thumbnailCount
        thumbnails = Array(repeating: nil, count: count)
        let url = url, duration = duration
        let times = (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
        let asset = canPlay ? asset : nil
        thumbnailTask = Task { [weak self] in
            if let asset {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 120)
                let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                for (index, t) in times.enumerated() {
                    guard !Task.isCancelled else { return }
                    let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                    self?.thumbnails[index] = image
                }
            } else {
                for (index, t) in times.enumerated() {
                    guard !Task.isCancelled else { return }
                    let image = try? await VideoToolFrames.frame(url, at: t, maxHeight: 120, duration: duration)
                    self?.thumbnails[index] = image
                }
            }
        }
    }
}
