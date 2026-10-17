import AVFoundation
import Foundation
import WheelieCore

/// AVAudioPlayer wrapper for the editors: one playhead, several sources (the original and preview
/// renders). Switching sources keeps the position and play state, so a preview can replace the original
/// mid-playback. Files AVFoundation can't open are decoded to a temp WAV with ffmpeg first.
@MainActor
final class AudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    /// Set by editors while a preview renders; the transport shows a spinner.
    @Published var isPreparing = false
    /// The URL the editor asked for (the original or a render), not the decoded stand-in.
    @Published private(set) var source: URL?
    private(set) var duration: Double = 0

    var onPlayheadMoved: ((Double) -> Void)?

    private var player: AVAudioPlayer?
    private var players: [URL: AVAudioPlayer] = [:]
    private var standIns: [URL: URL] = [:]
    private var timer: Timer?
    private var stopAt: Double?
    private var fadeOutAt: Double?
    private var fadeOutDuration: Double = 0

    var canPlay: Bool { player != nil }

    /// Loads the original file. Returns false when nothing could be made playable.
    func load(_ url: URL, info: AudioInfo, temp: TempWorkspace) async -> Bool {
        if makePlayer(url) != nil {
            return use(url)
        }
        isPreparing = true
        defer { isPreparing = false }
        guard let copy = try? await AudioPreview.playableCopy(of: url, info: info, in: temp.directory),
              makePlayer(copy) != nil else { return false }
        standIns[url] = copy
        return use(url)
    }

    /// Switches to `url`, keeping the playhead and whether it is playing.
    @discardableResult
    func use(_ url: URL) -> Bool {
        let file = standIns[url] ?? url
        guard let next = players[file] ?? makePlayer(file) else { return false }
        source = url
        guard next !== player else { return true }
        let wasPlaying = isPlaying
        let time = currentTime
        player?.pause()
        player = next
        duration = next.duration
        next.volume = 1
        next.currentTime = min(time, max(0, next.duration - 0.01))
        if wasPlaying { next.play() }
        return true
    }

    /// Drops a cached player for a render that is about to be deleted or replaced.
    func forget(_ url: URL) {
        if let p = players[url], p === player { return }
        players[url] = nil
    }

    private func makePlayer(_ url: URL) -> AVAudioPlayer? {
        if let existing = players[url] { return existing }
        guard let p = try? AVAudioPlayer(contentsOf: url), p.duration > 0 else { return nil }
        p.prepareToPlay()
        players[url] = p
        return p
    }

    // MARK: Transport

    /// Plays from `start` (or the playhead), optionally stopping at `end` with volume fades.
    func play(from start: Double? = nil, until end: Double? = nil, fadeIn: Double = 0, fadeOut: Double = 0) {
        guard let player else { return }
        if let start {
            player.currentTime = min(max(0, start), duration)
        } else if currentTime >= duration - 0.05 {
            player.currentTime = 0
        }
        stopAt = end
        if let end, fadeOut > 0.01 {
            fadeOutAt = max(player.currentTime, end - fadeOut)
            fadeOutDuration = min(fadeOut, end - player.currentTime)
        } else {
            fadeOutAt = nil
        }
        if fadeIn > 0.01 {
            player.volume = 0
            player.play()
            player.setVolume(1, fadeDuration: fadeIn)
        } else {
            player.volume = 1
            player.play()
        }
        isPlaying = true
        startTimer()
        tick()
    }

    func pause() {
        player?.pause()
        player?.volume = 1
        isPlaying = false
        stopAt = nil
        fadeOutAt = nil
        stopTimer()
        if let player { setTime(player.currentTime) }
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        stopAt = nil
        fadeOutAt = nil
        player?.volume = 1
        player?.currentTime = t
        setTime(t)
    }

    func stop() {
        pause()
        players.removeAll()
        player = nil
        source = nil
    }

    // MARK: Clock

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        var t = player.currentTime
        if isPlaying && !player.isPlaying {
            // Reached the end of the file.
            isPlaying = false
            t = duration
            stopAt = nil
            stopTimer()
            player.volume = 1
        }
        if let end = stopAt, t >= end {
            player.pause()
            player.volume = 1
            isPlaying = false
            t = end
            stopAt = nil
            fadeOutAt = nil
            stopTimer()
        }
        if let fadeAt = fadeOutAt, t >= fadeAt {
            player.setVolume(0, fadeDuration: fadeOutDuration)
            fadeOutAt = nil
        }
        setTime(t)
    }

    private func setTime(_ t: Double) {
        guard abs(t - currentTime) > 0.0005 else { return }
        currentTime = t
        onPlayheadMoved?(t)
    }
}
