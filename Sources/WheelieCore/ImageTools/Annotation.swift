import CoreGraphics
import CoreImage
import CoreText
import Foundation

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case pen, highlighter, arrow, line, rectangle, ellipse, text, counter, blur

    /// Drawn as a freehand path through `points`.
    public var isFreehand: Bool { self == .pen || self == .highlighter || self == .blur }
    /// Defined by a start and end point.
    public var isTwoPoint: Bool { self == .arrow || self == .line || self == .rectangle || self == .ellipse }
}

/// One vector mark on a photo, in image pixel space (top-left origin).
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    /// Freehand: the path. Two-point kinds: [start, end]. Text: [top-left of the box]. Counter: [center].
    public var points: [CGPoint]
    public var color: RGBAColor
    public var lineWidth: Double
    /// Rectangle/ellipse: fill instead of outline.
    public var filled: Bool
    public var text: String
    public var fontSize: Double
    public var bold: Bool
    /// Text box width in pixels (text wraps inside it).
    public var textWidth: Double
    /// Counter number.
    public var number: Int

    public init(id: UUID = UUID(), kind: AnnotationKind, points: [CGPoint], color: RGBAColor = RGBAColor(hex: 0xFF3B30),
                lineWidth: Double = 6, filled: Bool = false, text: String = "", fontSize: Double = 36,
                bold: Bool = false, textWidth: Double = 320, number: Int = 1) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.filled = filled
        self.text = text
        self.fontSize = fontSize
        self.bold = bold
        self.textWidth = textWidth
        self.number = number
    }

    public var start: CGPoint { points.first ?? .zero }
    public var end: CGPoint { points.last ?? .zero }

    public mutating func translate(by delta: CGSize) {
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    /// Too small to keep (a click without a drag, a 1-pixel box…).
    public func isMeaningful(scale: CGFloat = 1) -> Bool {
        switch kind {
        case .pen, .highlighter, .blur:
            guard points.count >= 2 else { return false }
            var length: CGFloat = 0
            for i in 1..<points.count { length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
            return length >= 3
        case .arrow, .line:
            return hypot(end.x - start.x, end.y - start.y) >= max(4, lineWidth * scale)
        case .rectangle, .ellipse:
            return abs(end.x - start.x) >= 3 && abs(end.y - start.y) >= 3
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter:
            return true
        }
    }
}

/// All annotations on one photo plus document-wide options.
public struct AnnotationDocument: Codable, Equatable, Sendable {
    public var annotations: [Annotation]
    /// "Make drawn annotations a little larger": scale strokes, text and counters with the photo size.
    public var enlarge: Bool

    public init(annotations: [Annotation] = [], enlarge: Bool = false) {
        self.annotations = annotations
        self.enlarge = enlarge
    }

    /// Multiplier applied to stroke widths, font sizes, text widths and counter sizes.
    public static func scale(enlarge: Bool, imageSize: CGSize) -> CGFloat {
        guard enlarge else { return 1 }
        return min(6, max(1.5, max(imageSize.width, imageSize.height) / 1000))
    }

    public func scale(for imageSize: CGSize) -> CGFloat { Self.scale(enlarge: enlarge, imageSize: imageSize) }

    /// Next counter number (one more than the highest so far).
    public var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }
}

public enum AnnotationGeometry {
    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, max(1, size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, max(1, size), nil)
    }

    static func attributed(_ string: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// Text box frame: the stored width, height from wrapping the text.
    public static func textRect(_ a: Annotation, scale: CGFloat = 1) -> CGRect {
        let width = max(8, CGFloat(a.textWidth) * scale)
        let font = font(size: CGFloat(a.fontSize) * scale, bold: a.bold)
        let string = attributed(a.text.isEmpty ? " " : a.text, font: font, color: CGColor(gray: 0, alpha: 1))
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return CGRect(origin: a.start, size: CGSize(width: width, height: ceil(max(fit.height, lineHeight)) + 2))
    }

    /// Counter badge circle.
    public static func counterRect(_ a: Annotation, scale: CGFloat = 1) -> CGRect {
        let d = CGFloat(a.fontSize) * scale * 1.7
        return CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
    }

    public static func strokeWidth(_ a: Annotation, scale: CGFloat) -> CGFloat {
        let w = max(0.5, CGFloat(a.lineWidth) * scale)
        switch a.kind {
        case .highlighter: return w * 3
        case .blur: return w * 4
        default: return w
        }
    }

    /// Smooth path through freehand points (quadratic curves through midpoints).
    static func freehandPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first); return path }
        if points.count == 2 { path.addLine(to: points[1]); return path }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Geometry of an arrow: shaft end point and the filled head triangle.
    static func arrowParts(_ a: Annotation, scale: CGFloat) -> (shaftEnd: CGPoint, head: CGPath) {
        let w = strokeWidth(a, scale: scale)
        let s = a.start, e = a.end
        let length = max(hypot(e.x - s.x, e.y - s.y), 0.001)
        let ux = (e.x - s.x) / length, uy = (e.y - s.y) / length
        let headLength = min(max(w * 3.6, 10 * scale), length)
        let headHalf = headLength * 0.5
        let base = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)
        let head = CGMutablePath()
        head.move(to: e)
        head.addLine(to: CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf))
        head.addLine(to: CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf))
        head.closeSubpath()
        let shaftEnd = CGPoint(x: e.x - ux * headLength * 0.6, y: e.y - uy * headLength * 0.6)
        return (shaftEnd, head)
    }

    static func shapeRect(_ a: Annotation) -> CGRect {
        CGRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y),
               width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y))
    }

    /// The outline path that gets stroked (or filled), nil for text/counter.
    static func path(_ a: Annotation, scale: CGFloat) -> CGPath? {
        switch a.kind {
        case .pen, .highlighter, .blur: return freehandPath(a.points)
        case .line:
            let p = CGMutablePath(); p.move(to: a.start); p.addLine(to: a.end); return p
        case .arrow:
            let p = CGMutablePath(); p.move(to: a.start); p.addLine(to: arrowParts(a, scale: scale).shaftEnd); return p
        case .rectangle: return CGPath(rect: shapeRect(a), transform: nil)
        case .ellipse: return CGPath(ellipseIn: shapeRect(a), transform: nil)
        case .text, .counter: return nil
        }
    }

    /// Bounding box including stroke width.
    public static func bounds(_ a: Annotation, scale: CGFloat = 1) -> CGRect {
        switch a.kind {
        case .text: return textRect(a, scale: scale)
        case .counter: return counterRect(a, scale: scale)
        default:
            var box = path(a, scale: scale)?.boundingBoxOfPath ?? .zero
            if a.kind == .arrow { box = box.union(arrowParts(a, scale: scale).head.boundingBoxOfPath) }
            let w = strokeWidth(a, scale: scale)
            return box.insetBy(dx: -w / 2, dy: -w / 2)
        }
    }

    /// Whether `point` touches the annotation (within `tolerance` pixels of its stroke).
    public static func hitTest(_ a: Annotation, point: CGPoint, tolerance: CGFloat, scale: CGFloat = 1) -> Bool {
        switch a.kind {
        case .text: return textRect(a, scale: scale).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .counter: return counterRect(a, scale: scale).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            guard let p = path(a, scale: scale) else { return false }
            if a.filled && (a.kind == .rectangle || a.kind == .ellipse) && p.contains(point) { return true }
            let width = strokeWidth(a, scale: scale) + 2 * tolerance
            let outline = p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
            if outline.contains(point) { return true }
            if a.kind == .arrow { return arrowParts(a, scale: scale).head.contains(point) }
            return false
        }
    }

    /// Indices in the order they're painted: blur strokes first (they soften the photo itself),
    /// then everything else in creation order.
    public static func paintingOrder(_ annotations: [Annotation]) -> [Int] {
        annotations.indices.filter { annotations[$0].kind == .blur } + annotations.indices.filter { annotations[$0].kind != .blur }
    }

    /// Index of the topmost annotation under `point`.
    public static func topmost(at point: CGPoint, in annotations: [Annotation], tolerance: CGFloat,
                               scale: CGFloat = 1) -> Int? {
        paintingOrder(annotations).reversed().first {
            hitTest(annotations[$0], point: point, tolerance: tolerance, scale: scale)
        }
    }
}

public enum AnnotationRenderer {
    /// Draws annotations into a context whose user space is image pixels with a top-left origin.
    /// `blurSource` is a blurred copy of the photo (any resolution) used by the blur brush.
    public static func draw(_ annotations: [Annotation], in ctx: CGContext, imageSize: CGSize, scale: CGFloat,
                            blurSource: CGImage?) {
        for index in AnnotationGeometry.paintingOrder(annotations) {
            ctx.saveGState()
            draw(annotations[index], in: ctx, imageSize: imageSize, scale: scale, blurSource: blurSource)
            ctx.restoreGState()
        }
    }

    static func draw(_ a: Annotation, in ctx: CGContext, imageSize: CGSize, scale: CGFloat, blurSource: CGImage?) {
        let color = a.color.cgColor
        let width = AnnotationGeometry.strokeWidth(a, scale: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        switch a.kind {
        case .pen, .line:
            guard let p = AnnotationGeometry.path(a, scale: scale) else { return }
            ctx.addPath(p)
            ctx.strokePath()
        case .highlighter:
            guard let p = AnnotationGeometry.path(a, scale: scale) else { return }
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.square)
            ctx.setStrokeColor(a.color.withAlpha(a.color.alpha * 0.42).cgColor)
            ctx.addPath(p)
            ctx.strokePath()
        case .blur:
            guard let blurSource, let p = AnnotationGeometry.path(a, scale: scale) else { return }
            let mask = p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(mask)
            ctx.clip()
            ImageToolsIO.draw(blurSource, in: CGRect(origin: .zero, size: imageSize), context: ctx)
        case .arrow:
            let parts = AnnotationGeometry.arrowParts(a, scale: scale)
            if let p = AnnotationGeometry.path(a, scale: scale) {
                ctx.addPath(p)
                ctx.strokePath()
            }
            ctx.setLineWidth(max(1, width * 0.35))
            ctx.addPath(parts.head)
            ctx.drawPath(using: .fillStroke)
        case .rectangle, .ellipse:
            guard let p = AnnotationGeometry.path(a, scale: scale) else { return }
            ctx.addPath(p)
            if a.filled { ctx.fillPath() } else { ctx.strokePath() }
        case .text:
            drawText(a.text, in: AnnotationGeometry.textRect(a, scale: scale), fontSize: CGFloat(a.fontSize) * scale,
                     bold: a.bold, color: color, centered: false, context: ctx)
        case .counter:
            let rect = AnnotationGeometry.counterRect(a, scale: scale)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(1, rect.width * 0.06))
            ctx.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.03, dy: rect.width * 0.03))
            let textColor = a.color.luminance > 0.6 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let fontSize = CGFloat(a.fontSize) * scale * (a.number >= 10 ? 0.8 : 1)
            let font = AnnotationGeometry.font(size: fontSize, bold: true)
            let line = CTLineCreateWithAttributedString(AnnotationGeometry.attributed("\(a.number)", font: font, color: textColor))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.saveGState()
            ctx.translateBy(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY + (CTFontGetCapHeight(font) / 2))
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// Wrapped text in a top-left context.
    static func drawText(_ text: String, in rect: CGRect, fontSize: CGFloat, bold: Bool, color: CGColor,
                         centered: Bool, context ctx: CGContext) {
        guard !text.isEmpty else { return }
        let font = AnnotationGeometry.font(size: fontSize, bold: bold)
        let string = AnnotationGeometry.attributed(text, font: font, color: color)
        let setter = CTFramesetterCreateWithAttributedString(string)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// Blurred copy of the photo for the blur brush.
    public static func blurredCopy(of image: CGImage, context: CIContext = ImageAdjust.sharedContext) -> CGImage? {
        let input = CIImage(cgImage: image)
        let radius = max(6, CGFloat(max(image.width, image.height)) / 70)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return context.createCGImage(blurred, from: input.extent, format: .RGBA8,
                                     colorSpace: ImageToolsIO.workingColorSpace(for: image))
    }

    /// The annotations drawn onto `photo`, a (usually downscaled) copy of the image, for live previews.
    /// Annotation coordinates are in `imageSize` pixels. Composited exactly like `render`, so blend modes
    /// (the highlighter multiplies onto the photo) look the same as in the saved file.
    public static func preview(_ annotations: [Annotation], on photo: CGImage, imageSize: CGSize, scale: CGFloat,
                               blurSource: CGImage?) throws -> CGImage {
        try composite(annotations, onto: photo, imageSize: imageSize, scale: scale, blurSource: blurSource)
    }

    /// Burns the annotations into the photo at full resolution.
    public static func render(_ image: CGImage, _ document: AnnotationDocument,
                              context: CIContext = ImageAdjust.sharedContext) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let blur = document.annotations.contains { $0.kind == .blur } ? blurredCopy(of: image, context: context) : nil
        return try composite(document.annotations, onto: image, imageSize: size, scale: document.scale(for: size),
                             blurSource: blur)
    }

    /// Copies `photo` into a new canvas of its size, then draws the annotations (given in `imageSize`
    /// pixel space) on top of the photo's own pixels.
    private static func composite(_ annotations: [Annotation], onto photo: CGImage, imageSize: CGSize, scale: CGFloat,
                                  blurSource: CGImage?) throws -> CGImage {
        let ctx = try ImageToolsIO.makeContext(width: photo.width, height: photo.height, like: photo,
                                               alpha: ImageCrop.hasAlpha(photo))
        ctx.setBlendMode(.copy)
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        ctx.setBlendMode(.normal)
        ImageToolsIO.flipToTopLeft(ctx, height: photo.height)
        ctx.scaleBy(x: CGFloat(photo.width) / max(imageSize.width, 1), y: CGFloat(photo.height) / max(imageSize.height, 1))
        ctx.clip(to: CGRect(origin: .zero, size: imageSize))
        draw(annotations, in: ctx, imageSize: imageSize, scale: scale, blurSource: blurSource)
        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("annotated image") }
        return result
    }
}
