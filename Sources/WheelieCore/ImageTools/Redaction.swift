import CoreGraphics
import CoreImage
import Foundation
import Vision

public enum RedactionStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case blackBox, blur, pixelate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .blackBox: return "Black Box"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        }
    }
}

public struct RedactionRect: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Pixel rectangle, top-left origin.
    public var rect: CGRect

    public init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

public struct RedactSettings: Codable, Equatable, Sendable {
    public var rects: [RedactionRect]
    public var style: RedactionStyle

    public init(rects: [RedactionRect] = [], style: RedactionStyle = .blackBox) {
        self.rects = rects
        self.style = style
    }
}

public enum Redactor {
    /// Pixelation block edge, proportional to the photo so previews match exports.
    public static func blockSize(for size: CGSize) -> CGFloat { max(8, max(size.width, size.height) / 45) }
    public static func blurRadius(for size: CGSize) -> CGFloat { max(10, max(size.width, size.height) / 45) }

    /// The rectangle expanded to whole pixels and clipped to the photo.
    public static func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        let r = rect.standardized
        let x0 = max(0, floor(r.minX)), y0 = max(0, floor(r.minY))
        let x1 = min(size.width, ceil(r.maxX)), y1 = min(size.height, ceil(r.maxY))
        guard x1 > x0, y1 > y0 else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Burns the redactions into the pixels. Each covered pixel is replaced (black, or derived only
    /// from blurred/pixelated pixels of its own rectangle); nothing is merely overlaid.
    public static func render(_ image: CGImage, _ settings: RedactSettings,
                              context: CIContext = ImageAdjust.sharedContext) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let ctx = try ImageToolsIO.makeContext(width: image.width, height: image.height, like: image,
                                               alpha: ImageCrop.hasAlpha(image))
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ImageToolsIO.flipToTopLeft(ctx, height: image.height)
        let input = CIImage(cgImage: image)
        let space = ImageToolsIO.workingColorSpace(for: image)
        for item in settings.rects {
            let rect = pixelRect(item.rect, in: size)
            guard !rect.isNull, !rect.isEmpty else { continue }
            switch settings.style {
            case .blackBox:
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(rect)
            case .blur, .pixelate:
                guard let patch = patch(input, pixelRect: rect, imageSize: size, style: settings.style,
                                        colorSpace: space, context: context) else {
                    throw ImageToolError.renderFailed("redacted photo")
                }
                ImageToolsIO.draw(patch, in: rect, context: ctx)
            }
        }
        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("redacted photo") }
        return result
    }

    /// The blurred or pixelated pixels for one rectangle (whole pixels, top-left origin, as returned by
    /// `pixelRect`), derived only from that rectangle: it's cropped and edge-clamped first, and the
    /// pixelation grid starts at its own corner. Nil for black boxes.
    static func patch(_ input: CIImage, pixelRect rect: CGRect, imageSize size: CGSize, style: RedactionStyle,
                      colorSpace: CGColorSpace, context: CIContext) -> CGImage? {
        // CoreImage is y-up.
        let ciRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        let region = input.cropped(to: ciRect).clampedToExtent()
        let processed: CIImage
        switch style {
        case .blackBox: return nil
        case .pixelate:
            processed = region.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: blockSize(for: size),
                kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY),
            ])
        case .blur:
            processed = region.applyingGaussianBlur(sigma: blurRadius(for: size))
        }
        return context.createCGImage(processed.cropped(to: ciRect), from: ciRect, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Live preview of one blur/pixelate rectangle on `image` (typically a downscaled copy of the photo,
    /// with `rect` in its pixels): the same per-rectangle effect `render` burns in, at this resolution.
    /// Returns the whole-pixel rectangle covered and its replacement pixels; nil for black boxes or
    /// rectangles outside the image.
    public static func previewPatch(_ image: CGImage, rect: CGRect, style: RedactionStyle,
                                    context: CIContext = ImageAdjust.sharedContext) -> (rect: CGRect, image: CGImage)? {
        let size = CGSize(width: image.width, height: image.height)
        let pixels = pixelRect(rect, in: size)
        guard !pixels.isNull, !pixels.isEmpty,
              let patch = patch(CIImage(cgImage: image), pixelRect: pixels, imageSize: size, style: style,
                                colorSpace: ImageToolsIO.workingColorSpace(for: image), context: context)
        else { return nil }
        return (pixels, patch)
    }
}

public enum RedactionDetector {
    public enum Kind: Sendable {
        case faces, text
    }

    /// Finds faces or text with Vision. Returns padded pixel rectangles (top-left origin).
    public static func detect(_ kind: Kind, in image: CGImage) throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                   width: box.width * size.width, height: box.height * size.height)
        }
        let bounds = CGRect(origin: .zero, size: size)
        switch kind {
        case .faces:
            let request = VNDetectFaceRectanglesRequest()
            try handler.perform([request])
            return (request.results ?? []).map { face in
                let r = pixels(face.boundingBox)
                // Vision's face box stops at the brows; cover forehead and hair too.
                return CGRect(x: r.minX - r.width * 0.15, y: r.minY - r.height * 0.35,
                              width: r.width * 1.3, height: r.height * 1.5).intersection(bounds)
            }.filter { !$0.isNull && !$0.isEmpty }
        case .text:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try handler.perform([request])
            return (request.results ?? []).map { line in
                let r = pixels(line.boundingBox)
                let pad = max(2, r.height * 0.15)
                return r.insetBy(dx: -pad, dy: -pad).intersection(bounds)
            }.filter { !$0.isNull && !$0.isEmpty }
        }
    }

    /// `found` minus rectangles that are already (mostly) covered by `existing`.
    public static func newRects(_ found: [CGRect], excluding existing: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for r in found {
            let area = r.width * r.height
            guard area > 0 else { continue }
            let covered = (existing + kept).contains { other in
                let i = r.intersection(other)
                return !i.isNull && (i.width * i.height) / area > 0.6
            }
            if !covered { kept.append(r) }
        }
        return kept
    }
}
