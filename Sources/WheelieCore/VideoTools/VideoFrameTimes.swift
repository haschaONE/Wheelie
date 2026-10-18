import Foundation

/// When video frames start, in seconds from the start of the file: the clock that ffmpeg's `-ss`,
/// filter `t` and AVPlayer all use.
///
/// The editors show the frame *shown* at the playhead: the last frame that starts at or before it,
/// as AVPlayer and AVAssetImageGenerator (zero tolerance) display it. ffmpeg works the other way
/// round: an accurate `-ss t`, `trim=start=t` and `enable='between(t,…)'` all begin with the first
/// frame that starts at or after `t`. A playhead is almost always inside a frame, so passing it
/// straight to ffmpeg skips the frame on screen. `cut(at:)` gives a time between the shown frame
/// and the one before it, which ffmpeg turns into exactly the shown frame (even after `number()`
/// rounds it to six decimals).
public struct VideoFrameTimes: Sendable, Equatable {
    /// Sorted frame start times. Empty when unknown: the frame grid of `frameDuration` is used.
    public var starts: [Double]
    /// Sorted start times of keyframes.
    public var keyframes: [Double]
    public var frameDuration: Double

    /// A playhead this close before a frame counts as being on it (float noise, CMTime rounding).
    public static let tolerance = 1e-6

    public init(starts: [Double] = [], keyframes: [Double] = [], frameDuration: Double) {
        self.starts = starts.sorted()
        self.keyframes = keyframes.sorted()
        self.frameDuration = frameDuration > 0 && frameDuration.isFinite ? frameDuration : 1.0 / 30
    }

    private func shownIndex(_ time: Double) -> Int? {
        starts.lastIndex { $0 <= time + Self.tolerance }
    }

    /// Start of the frame shown at `time`.
    public func shownFrame(at time: Double) -> Double {
        if let i = shownIndex(time) { return starts[i] }
        if let first = starts.first { return first }
        let fd = frameDuration
        return max(0, ((max(0, time) + Self.tolerance) / fd).rounded(.down) * fd)
    }

    /// A time just before the frame shown at `time` (halfway from the previous frame), never negative.
    public func cut(at time: Double) -> Double {
        guard !starts.isEmpty else { return max(0, shownFrame(at: time) - frameDuration / 2) }
        guard let i = shownIndex(time) else { return 0 }
        let previous = i > 0 ? starts[i - 1] : starts[i] - frameDuration
        return max(0, (previous + starts[i]) / 2)
    }

    /// True when the frame shown at `time` is a keyframe.
    public func showsKeyframe(at time: Double) -> Bool {
        guard !starts.isEmpty else { return false }
        let shown = shownFrame(at: time)
        return keyframes.contains { abs($0 - shown) <= Self.tolerance }
    }
}
