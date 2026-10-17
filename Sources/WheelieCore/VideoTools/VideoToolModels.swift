import CoreGraphics
import Foundation

// MARK: - Split

/// One clip between two split points.
public struct VideoClipRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { max(0, end - start) }
}

public enum VideoSplitExportMode: String, CaseIterable, Sendable {
    /// Every kept clip becomes its own file: "name-1", "name-2", ...
    case separate
    /// Kept clips are joined into one file.
    case joinRest

    public var label: String {
        switch self {
        case .separate: return "Separate clips"
        case .joinRest: return "Join the rest into one video"
        }
    }
}

public enum VideoSplitPlan {
    public static let minimumGap = 0.05
    static let epsilon = 1e-6

    public static let emptyMessage = "Add split points at least 0.05 seconds apart, inside the video."
    public static let insideMessage = "Add split points inside the video, at least 0.05 seconds from either end."
    public static let apartMessage = "Split points must be at least 0.05 seconds apart."
    public static let removeToJoinMessage = "Remove a clip to join the rest into one video."
    public static let keepOneMessage = "Keep at least one clip."

    /// nil when every point is inside the video and the points are far enough apart.
    public static func validationError(points: [Double], duration: Double) -> String? {
        let sorted = points.sorted()
        if sorted.contains(where: { $0 < minimumGap - epsilon || $0 > duration - minimumGap + epsilon }) {
            return insideMessage
        }
        if zip(sorted, sorted.dropFirst()).contains(where: { $1 - $0 < minimumGap - epsilon }) {
            return apartMessage
        }
        return nil
    }

    /// Why `point` can't be added, or nil if it can.
    public static func insertionError(_ point: Double, into points: [Double], duration: Double) -> String? {
        validationError(points: points + [point], duration: duration)
    }

    /// Clips between 0, the sorted points and the end.
    public static func clips(points: [Double], duration: Double) -> [VideoClipRange] {
        let bounds = [0] + points.sorted() + [duration]
        return zip(bounds, bounds.dropFirst()).map { VideoClipRange(start: $0, end: $1) }
    }

    /// Why this split can't be exported, or nil.
    public static func exportError(points: [Double], removed: Set<Int>, mode: VideoSplitExportMode,
                                   duration: Double) -> String? {
        if let error = validationError(points: points, duration: duration) { return error }
        let count = points.count + 1
        let kept = (0..<count).filter { !removed.contains($0) }
        switch mode {
        case .separate:
            if points.isEmpty { return emptyMessage }
            if kept.isEmpty { return keepOneMessage }
        case .joinRest:
            if kept.isEmpty { return keepOneMessage }
            if kept.count == count { return points.isEmpty ? emptyMessage : removeToJoinMessage }
        }
        return nil
    }
}

// MARK: - Crop

/// Integer pixel rectangle in the displayed (rotation-applied) frame; origin top-left.
public struct VideoCropRect: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: Int(rect.minX.rounded()), y: Int(rect.minY.rounded()),
                  width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
}

public enum VideoCropAspect: String, CaseIterable, Sendable, Identifiable {
    case free, wide, tall, square, classic, portrait

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .free: return "Free"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .square: return "1:1"
        case .classic: return "4:3"
        case .portrait: return "4:5"
        }
    }

    /// Width / height, nil for free-form.
    public var ratio: Double? {
        switch self {
        case .free: return nil
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        case .square: return 1
        case .classic: return 4.0 / 3
        case .portrait: return 4.0 / 5
        }
    }
}

public enum VideoCropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 = moves the min edge, +1 = moves the max edge, 0 = that axis is untouched.
    public var xDirection: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .topRight, .right, .bottomRight: return 1
        case .top, .bottom: return 0
        }
    }

    public var yDirection: Int {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .left, .right: return 0
        }
    }
}

public enum VideoCropMath {
    public static let minimumSize = 2
    public static let insideMessage = "Keep the crop inside the video frame."
    public static let tooSmallMessage = "The crop must be at least 2 × 2 pixels."

    /// The biggest centred rectangle of `ratio` (nil = whole frame), with even sides.
    public static func largest(ratio: Double?, width: Int, height: Int) -> VideoCropRect {
        var w = Double(width), h = Double(height)
        if let ratio, ratio > 0 {
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        let rect = CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
        return even(rect, width: width, height: height)
    }

    /// Snaps to even pixels (yuv420 needs even sizes and offsets) inside the frame.
    public static func even(_ rect: CGRect, width: Int, height: Int) -> VideoCropRect {
        let maxW = width - width % 2, maxH = height - height % 2
        var w = Int(rect.width.rounded()); w -= w % 2
        var h = Int(rect.height.rounded()); h -= h % 2
        w = min(max(w, minimumSize), max(maxW, minimumSize))
        h = min(max(h, minimumSize), max(maxH, minimumSize))
        var x = Int(rect.minX.rounded()); x -= x % 2
        var y = Int(rect.minY.rounded()); y -= y % 2
        x = min(max(0, x), max(0, width - w)); x -= x % 2
        y = min(max(0, y), max(0, height - h)); y -= y % 2
        return VideoCropRect(x: x, y: y, width: w, height: h)
    }

    /// Moves the rectangle by (dx, dy) pixels, kept inside the frame.
    public static func moved(_ rect: CGRect, dx: Double, dy: Double, width: Int, height: Int) -> CGRect {
        var r = rect.offsetBy(dx: dx, dy: dy)
        r.origin.x = min(max(0, r.minX), max(0, Double(width) - r.width))
        r.origin.y = min(max(0, r.minY), max(0, Double(height) - r.height))
        return r
    }

    /// Drags `handle` to `point` (pixels). With a ratio the shape is kept, anchored on the opposite side.
    public static func resized(_ rect: CGRect, handle: VideoCropHandle, to point: CGPoint, ratio: Double?,
                               width: Int, height: Int, minimum: Double = 16) -> CGRect {
        let W = Double(width), H = Double(height)
        let minW = min(minimum, W), minH = min(minimum, H)
        let px = min(max(0, point.x), W), py = min(max(0, point.y), H)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle.xDirection {
        case -1: minX = min(px, maxX - minW)
        case 1: maxX = max(px, minX + minW)
        default: break
        }
        switch handle.yDirection {
        case -1: minY = min(py, maxY - minH)
        case 1: maxY = max(py, minY + minH)
        default: break
        }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio, ratio > 0 else { return r.intersection(CGRect(x: 0, y: 0, width: W, height: H)) }

        // Keep the ratio: the dragged axis leads; edges grow the other axis around its centre.
        var w = r.width, h = r.height
        if handle.xDirection != 0 && handle.yDirection != 0 {
            if w / h > ratio { h = w / ratio } else { w = h * ratio }
        } else if handle.xDirection != 0 {
            h = w / ratio
        } else {
            w = h * ratio
        }
        // Space available from the anchor in the growth direction.
        let availW: Double = {
            switch handle.xDirection {
            case -1: return rect.maxX
            case 1: return W - rect.minX
            default: return W
            }
        }()
        let availH: Double = {
            switch handle.yDirection {
            case -1: return rect.maxY
            case 1: return H - rect.minY
            default: return H
            }
        }()
        let fit = min(1, availW / w, availH / h)
        w *= fit; h *= fit
        if w < minW { w = minW; h = w / ratio }
        if h < minH { h = minH; w = h * ratio }

        let x: Double
        switch handle.xDirection {
        case -1: x = rect.maxX - w
        case 1: x = rect.minX
        default: x = rect.midX - w / 2
        }
        let y: Double
        switch handle.yDirection {
        case -1: y = rect.maxY - h
        case 1: y = rect.minY
        default: y = rect.midY - h / 2
        }
        r = CGRect(x: x, y: y, width: w, height: h)
        return moved(r, dx: 0, dy: 0, width: width, height: height)
    }

    /// Fits a free-form rectangle to `ratio` around its centre.
    public static func applying(ratio: Double?, to rect: CGRect, width: Int, height: Int) -> CGRect {
        guard let ratio, ratio > 0 else { return rect }
        var w = rect.width, h = rect.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        return moved(r, dx: 0, dy: 0, width: width, height: height)
    }

    public static func validationError(_ rect: VideoCropRect, width: Int, height: Int) -> String? {
        if rect.width < minimumSize || rect.height < minimumSize { return tooSmallMessage }
        if rect.x < 0 || rect.y < 0 || rect.maxX > width || rect.maxY > height { return insideMessage }
        return nil
    }
}

// MARK: - Redact

public enum VideoRedactStyle: String, CaseIterable, Sendable, Identifiable {
    case blur, pixelate, black

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .black: return "Black"
        }
    }
}

/// A rectangle hidden between `start` and `end` seconds.
public struct VideoRedactBox: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var rect: VideoCropRect
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), rect: VideoCropRect, start: Double, end: Double) {
        self.id = id; self.rect = rect; self.start = start; self.end = end
    }

    public func isActive(at time: Double) -> Bool { time >= start - 1e-6 && time <= end + 1e-6 }
}

public enum VideoRedactPlan {
    public static let emptyMessage = "Draw a rectangle over the area to hide."
    public static let insideMessage = "Keep each rectangle inside the preview."

    public static func validationError(_ boxes: [VideoRedactBox], width: Int, height: Int,
                                       duration: Double) -> String? {
        if boxes.isEmpty { return emptyMessage }
        for box in boxes {
            if VideoCropMath.validationError(box.rect, width: width, height: height) != nil { return insideMessage }
            if box.start < 0 || box.end <= box.start || box.start >= duration { return VideoToolError.invalidRange.message }
        }
        return nil
    }
}

// MARK: - Speed

public enum VideoSpeed {
    public static let range: ClosedRange<Double> = 0.25...4
    public static let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
    public static let rangeMessage = "Choose a speed between 0.25× and 4×."

    /// "2×", "0.25×".
    public static func label(_ factor: Double) -> String { VideoToolTimecode.compact(factor, maxFractionDigits: 2) + "×" }

    /// File-name suffix: " 2x", " 0.25x".
    public static func fileSuffix(_ factor: Double) -> String { " " + VideoToolTimecode.compact(factor, maxFractionDigits: 2) + "x" }
}
