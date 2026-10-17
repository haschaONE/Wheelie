import CoreGraphics
import Foundation
import ImageIO

// All tool geometry uses image pixel space: origin at the top-left corner, y pointing down.

/// Aspect ratio presets for the crop rectangle.
public enum CropAspect: String, CaseIterable, Codable, Sendable, Identifiable {
    case free, original, square, fourThree, threeTwo, sixteenNine, nineSixteen, fourFive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .fourFive: return "4:5"
        }
    }

    /// Width ÷ height, or nil for free cropping.
    public func ratio(for imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        case .fourFive: return 4.0 / 5.0
        }
    }
}

/// The eight drag handles of a crop (or redaction) rectangle.
public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Where the handle sits on `rect`.
    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
    }

    /// The handle within `radius` of `point`, preferring corners.
    public static func hit(_ point: CGPoint, rect: CGRect, radius: CGFloat) -> CropHandle? {
        let ordered = allCases.filter(\.isCorner) + allCases.filter { !$0.isCorner }
        return ordered.first { hypot($0.point(in: rect).x - point.x, $0.point(in: rect).y - point.y) <= radius }
    }
}

public enum CropGeometry {
    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

    /// Largest rectangle of `ratio` (w/h) centered in `bounds`.
    public static func largest(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var w = bounds.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Reshapes `rect` to `ratio`, keeping its center and roughly its area, then keeps it inside `bounds`.
    public static func constrain(_ rect: CGRect, ratio: CGFloat?, in bounds: CGRect, minSize: CGFloat = 1) -> CGRect {
        var r = rect.standardized
        if let ratio, ratio > 0 {
            let area = max(r.width * r.height, minSize * minSize)
            var w = (area * ratio).squareRoot(), h = w / ratio
            if w > bounds.width { w = bounds.width; h = w / ratio }
            if h > bounds.height { h = bounds.height; w = h * ratio }
            let minW = max(minSize, minSize * ratio)
            if w < minW { w = minW; h = w / ratio }
            r = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        } else {
            r.size.width = clamp(r.width, minSize, bounds.width)
            r.size.height = clamp(r.height, minSize, bounds.height)
        }
        r.origin.x = clamp(r.minX, bounds.minX, bounds.maxX - r.width)
        r.origin.y = clamp(r.minY, bounds.minY, bounds.maxY - r.height)
        return r
    }

    /// Moves `rect` by `delta`, stopping at the edges of `bounds`.
    public static func move(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var r = rect
        r.origin.x = clamp(rect.minX + delta.width, bounds.minX, bounds.maxX - rect.width)
        r.origin.y = clamp(rect.minY + delta.height, bounds.minY, bounds.maxY - rect.height)
        return r
    }

    /// Drags `handle` of `rect` to `point`. The opposite corner/edge stays put; with a `ratio`
    /// the rectangle keeps its shape. The result stays inside `bounds` and at least `minSize`.
    public static func resize(_ rect: CGRect, handle: CropHandle, to point: CGPoint, ratio: CGFloat?,
                              in bounds: CGRect, minSize: CGFloat = 1) -> CGRect {
        guard let ratio, ratio > 0 else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if handle.movesLeft { minX = clamp(point.x, bounds.minX, maxX - minSize) }
            if handle.movesRight { maxX = clamp(point.x, minX + minSize, bounds.maxX) }
            if handle.movesTop { minY = clamp(point.y, bounds.minY, maxY - minSize) }
            if handle.movesBottom { maxY = clamp(point.y, minY + minSize, bounds.maxY) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let minW = max(minSize, minSize * ratio)
        if handle.isCorner {
            let ax = handle.movesRight ? rect.minX : rect.maxX
            let ay = handle.movesBottom ? rect.minY : rect.maxY
            let dx: CGFloat = handle.movesRight ? 1 : -1, dy: CGFloat = handle.movesBottom ? 1 : -1
            var w = max((point.x - ax) * dx, 0), h = max((point.y - ay) * dy, 0)
            if w / ratio > h { h = w / ratio } else { w = h * ratio }
            let maxW = dx > 0 ? bounds.maxX - ax : ax - bounds.minX
            let maxH = dy > 0 ? bounds.maxY - ay : ay - bounds.minY
            if w > maxW { w = maxW; h = w / ratio }
            if h > maxH { h = maxH; w = h * ratio }
            if w < minW { w = minW; h = w / ratio }
            return CGRect(x: dx > 0 ? ax : ax - w, y: dy > 0 ? ay : ay - h, width: w, height: h)
        }
        if handle.movesLeft || handle.movesRight {
            let ax = handle.movesRight ? rect.minX : rect.maxX
            let dx: CGFloat = handle.movesRight ? 1 : -1
            let cy = rect.midY
            var w = max((point.x - ax) * dx, 0)
            let maxW = dx > 0 ? bounds.maxX - ax : ax - bounds.minX
            let maxH = 2 * min(cy - bounds.minY, bounds.maxY - cy)
            w = min(w, maxW)
            var h = w / ratio
            if h > maxH { h = maxH; w = h * ratio }
            if w < minW { w = minW; h = w / ratio }
            return CGRect(x: dx > 0 ? ax : ax - w, y: cy - h / 2, width: w, height: h)
        }
        let ay = handle.movesBottom ? rect.minY : rect.maxY
        let dy: CGFloat = handle.movesBottom ? 1 : -1
        let cx = rect.midX
        var h = max((point.y - ay) * dy, 0)
        let maxH = dy > 0 ? bounds.maxY - ay : ay - bounds.minY
        let maxW = 2 * min(cx - bounds.minX, bounds.maxX - cx)
        h = min(h, maxH)
        var w = h * ratio
        if w > maxW { w = maxW; h = w / ratio }
        if w < minW { w = minW; h = w / ratio }
        return CGRect(x: cx - w / 2, y: dy > 0 ? ay : ay - h, width: w, height: h)
    }

    /// A rectangle spanned by two points (e.g. a fresh drag), clamped to `bounds`, optionally
    /// with a fixed `ratio` anchored at `start`.
    public static func spanning(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        let s = CGPoint(x: clamp(start.x, bounds.minX, bounds.maxX), y: clamp(start.y, bounds.minY, bounds.maxY))
        let handle: CropHandle = end.x >= s.x ? (end.y >= s.y ? .bottomRight : .topRight)
                                             : (end.y >= s.y ? .bottomLeft : .topLeft)
        return resize(CGRect(origin: s, size: .zero), handle: handle, to: end, ratio: ratio, in: bounds, minSize: 0)
    }

    /// Sets the pixel size from the width/height fields. With a `ratio` the other side follows.
    /// Keeps the top-left corner where possible and stays inside `bounds`.
    public static func setSize(_ rect: CGRect, width: CGFloat?, height: CGFloat?, ratio: CGFloat?,
                               in bounds: CGRect, minSize: CGFloat = 1) -> CGRect {
        var w = width ?? rect.width, h = height ?? rect.height
        if let ratio, ratio > 0 {
            if width != nil { h = w / ratio } else if height != nil { w = h * ratio }
            if w > bounds.width { w = bounds.width; h = w / ratio }
            if h > bounds.height { h = bounds.height; w = h * ratio }
        }
        w = clamp(w, minSize, bounds.width)
        h = clamp(h, minSize, bounds.height)
        return CGRect(x: clamp(rect.minX, bounds.minX, bounds.maxX - w),
                      y: clamp(rect.minY, bounds.minY, bounds.maxY - h), width: w, height: h)
    }

    /// Whole-pixel rectangle inside `bounds`, at least 1 × 1.
    public static func integral(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let b = bounds.integral
        var w = max(1, rect.width.rounded()), h = max(1, rect.height.rounded())
        w = min(w, b.width); h = min(h, b.height)
        let x = clamp(rect.minX.rounded(), b.minX, b.maxX - w)
        let y = clamp(rect.minY.rounded(), b.minY, b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Size after `quarterTurns` clockwise 90° turns.
    public static func rotatedSize(_ size: CGSize, quarterTurns: Int) -> CGSize {
        ((quarterTurns % 4) + 4) % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// Maps a point in a `size` canvas to the canvas rotated 90° (clockwise or not).
    public static func rotationTransform(size: CGSize, clockwise: Bool) -> CGAffineTransform {
        clockwise ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
                  : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
    }

    /// Source pixel space → oriented pixel space: rotate clockwise by quarter turns, then mirror.
    public static func orientationTransform(size: CGSize, quarterTurns: Int, flipHorizontal: Bool,
                                            flipVertical: Bool) -> CGAffineTransform {
        let turns = ((quarterTurns % 4) + 4) % 4
        let w = size.width, h = size.height
        var t: CGAffineTransform
        switch turns {
        case 1: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: t = .identity
        }
        let out = rotatedSize(size, quarterTurns: turns)
        if flipHorizontal { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: out.width, ty: 0)) }
        if flipVertical { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)) }
        return t
    }
}

/// Width/height math for the Resize fields.
public enum ResizeMath {
    public static func height(forWidth width: Int, original: CGSize) -> Int {
        guard original.width > 0 else { return max(1, width) }
        return max(1, Int((CGFloat(width) * original.height / original.width).rounded()))
    }

    public static func width(forHeight height: Int, original: CGSize) -> Int {
        guard original.height > 0 else { return max(1, height) }
        return max(1, Int((CGFloat(height) * original.width / original.height).rounded()))
    }

    public static func scaled(_ size: CGSize, percent: Double) -> (width: Int, height: Int) {
        (max(1, Int((size.width * percent / 100).rounded())), max(1, Int((size.height * percent / 100).rounded())))
    }

    /// Largest allowed output side, to keep memory sane.
    public static let maxSide = 16_384
}

/// Everything the Crop tool does, in order: rotate/flip, crop, resize.
public struct CropSettings: Codable, Equatable, Sendable {
    /// Crop in oriented pixel space (after rotation and flips). nil = whole image.
    public var cropRect: CGRect?
    /// Clockwise 90° turns, 0...3.
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Resize the cropped result to this size; nil keeps the cropped size.
    public var outputWidth: Int?
    public var outputHeight: Int?

    public init(cropRect: CGRect? = nil, quarterTurns: Int = 0, flipHorizontal: Bool = false,
                flipVertical: Bool = false, outputWidth: Int? = nil, outputHeight: Int? = nil) {
        self.cropRect = cropRect
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public func orientedSize(for sourceSize: CGSize) -> CGSize {
        CropGeometry.rotatedSize(sourceSize, quarterTurns: quarterTurns)
    }

    /// The crop actually used, as whole pixels inside the oriented image.
    public func effectiveCrop(for sourceSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: orientedSize(for: sourceSize))
        return CropGeometry.integral(cropRect ?? bounds, in: bounds)
    }

    /// Final pixel size.
    public func outputSize(for sourceSize: CGSize) -> CGSize {
        let crop = effectiveCrop(for: sourceSize)
        return CGSize(width: outputWidth ?? Int(crop.width), height: outputHeight ?? Int(crop.height))
    }

    /// Turns the displayed image a quarter turn; the crop and resize follow.
    public mutating func rotate(clockwise: Bool, sourceSize: CGSize) {
        let current = orientedSize(for: sourceSize)
        if let rect = cropRect {
            cropRect = rect.applying(CropGeometry.rotationTransform(size: current, clockwise: clockwise)).standardized
        }
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        // Mirroring then turning equals turning then mirroring the other axis.
        swap(&flipHorizontal, &flipVertical)
        if outputWidth != nil || outputHeight != nil { swap(&outputWidth, &outputHeight) }
    }

    /// Mirrors the displayed image; the crop follows.
    public mutating func flip(horizontal: Bool, sourceSize: CGSize) {
        let current = orientedSize(for: sourceSize)
        if let r = cropRect {
            cropRect = horizontal
                ? CGRect(x: current.width - r.maxX, y: r.minY, width: r.width, height: r.height)
                : CGRect(x: r.minX, y: current.height - r.maxY, width: r.width, height: r.height)
        }
        if horizontal { flipHorizontal.toggle() } else { flipVertical.toggle() }
    }
}

public enum ImageCrop {
    /// Whether the bitmap has an alpha channel (it may still be fully opaque).
    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Rotates (clockwise quarter turns) then mirrors, in the image's own color space and depth.
    public static func oriented(_ image: CGImage, quarterTurns: Int, flipHorizontal: Bool = false,
                                flipVertical: Bool = false) throws -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 && !flipHorizontal && !flipVertical { return image }
        let size = CGSize(width: image.width, height: image.height)
        let out = CropGeometry.rotatedSize(size, quarterTurns: turns)
        let ctx = try ImageToolsIO.makeContext(width: Int(out.width), height: Int(out.height), like: image,
                                               alpha: hasAlpha(image))
        ctx.interpolationQuality = .none
        ImageToolsIO.flipToTopLeft(ctx, height: Int(out.height))
        ctx.concatenate(CropGeometry.orientationTransform(size: size, quarterTurns: turns,
                                                          flipHorizontal: flipHorizontal, flipVertical: flipVertical))
        ctx.setBlendMode(.copy)
        ImageToolsIO.draw(image, in: CGRect(origin: .zero, size: size), context: ctx)
        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("rotated image") }
        return result
    }

    /// Bakes an EXIF orientation into the pixels so the result displays upright with orientation 1.
    public static func applyingEXIFOrientation(_ orientation: CGImagePropertyOrientation, to image: CGImage) throws -> CGImage {
        switch orientation {
        case .up: return image
        case .upMirrored: return try oriented(image, quarterTurns: 0, flipHorizontal: true)
        case .down: return try oriented(image, quarterTurns: 2)
        case .downMirrored: return try oriented(image, quarterTurns: 0, flipVertical: true)
        case .leftMirrored: return try oriented(image, quarterTurns: 3, flipVertical: true)
        case .right: return try oriented(image, quarterTurns: 1)
        case .rightMirrored: return try oriented(image, quarterTurns: 1, flipVertical: true)
        case .left: return try oriented(image, quarterTurns: 3)
        @unknown default: return image
        }
    }

    /// High-quality resample to exactly `size`.
    public static func resized(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w >= 1, h >= 1, w <= ResizeMath.maxSide, h <= ResizeMath.maxSide else {
            throw ImageToolError.invalid("Choose a size from 1 to \(ResizeMath.maxSide) pixels per side.")
        }
        if w == image.width && h == image.height { return image }
        let ctx = try ImageToolsIO.makeContext(width: w, height: h, like: image, alpha: hasAlpha(image))
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("resized image") }
        return result
    }

    /// Rotate/flip → crop → resize.
    public static func render(_ image: CGImage, _ settings: CropSettings) throws -> CGImage {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let oriented = try oriented(image, quarterTurns: settings.quarterTurns,
                                    flipHorizontal: settings.flipHorizontal, flipVertical: settings.flipVertical)
        let crop = settings.effectiveCrop(for: sourceSize)
        var result = oriented
        if crop.size != CGSize(width: oriented.width, height: oriented.height) {
            guard let cropped = oriented.cropping(to: crop) else { throw ImageToolError.renderFailed("cropped image") }
            result = cropped
        }
        let target = settings.outputSize(for: sourceSize)
        if Int(target.width) != result.width || Int(target.height) != result.height {
            result = try resized(result, to: target)
        }
        return result
    }
}
