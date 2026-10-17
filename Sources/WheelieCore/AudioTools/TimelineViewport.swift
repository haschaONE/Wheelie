import Foundation

/// The visible window of a zoomable audio timeline, in seconds.
public struct TimelineViewport: Sendable, Equatable {
    public private(set) var duration: Double
    public private(set) var start: Double
    public private(set) var length: Double

    public init(duration: Double) {
        let d = max(0.001, duration)
        self.duration = d
        self.start = 0
        self.length = d
    }

    public var end: Double { start + length }
    public var isZoomed: Bool { length < duration * 0.999 }
    /// Zoom stops when the window is this short.
    public var minimumLength: Double { min(duration, max(0.2, duration / 4000)) }
    /// 1 = everything visible.
    public var zoomFactor: Double { duration / length }

    public mutating func setDuration(_ duration: Double) {
        self = TimelineViewport(duration: duration)
    }

    /// `factor` > 1 zooms in. `anchor` (seconds) stays at the same place on screen.
    public mutating func zoom(by factor: Double, around anchor: Double? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = min(max(anchor ?? (start + length / 2), start), end)
        let ratio = (anchor - start) / length
        let newLength = min(duration, max(minimumLength, length / factor))
        start = anchor - ratio * newLength
        length = newLength
        clamp()
    }

    public mutating func pan(by seconds: Double) {
        guard seconds.isFinite else { return }
        start += seconds
        clamp()
    }

    public mutating func reset() {
        start = 0
        length = duration
    }

    /// Pages forward/back so `time` is visible (used to follow the playhead).
    public mutating func reveal(_ time: Double) {
        guard isZoomed else { return }
        if time > end || time < start {
            start = time - length * 0.1
            clamp()
        }
    }

    /// Shows `range` with a little margin, zooming in or out as needed.
    public mutating func show(_ range: ClosedRange<Double>) {
        let margin = (range.upperBound - range.lowerBound) * 0.1
        length = min(duration, max(minimumLength, range.upperBound - range.lowerBound + 2 * margin))
        start = range.lowerBound - margin
        clamp()
    }

    /// Seconds -> fraction of the visible width (may be outside 0...1).
    public func fraction(of time: Double) -> Double { (time - start) / length }

    /// Fraction of the visible width -> seconds, clamped to the file.
    public func time(atFraction fraction: Double) -> Double {
        min(duration, max(0, start + fraction * length))
    }

    private mutating func clamp() {
        length = min(duration, max(minimumLength, length))
        start = min(max(0, start), duration - length)
    }
}
