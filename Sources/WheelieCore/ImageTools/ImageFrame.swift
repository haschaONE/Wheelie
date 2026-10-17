import CoreGraphics
import Foundation

/// Output canvas shape for Frame and Collage.
public enum CanvasRatio: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, square, fourThree, threeTwo, sixteenNine, nineSixteen, fourFive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .fourFive: return "4:5"
        }
    }

    /// Width ÷ height; nil for Auto.
    public var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        case .fourFive: return 4.0 / 5.0
        }
    }
}

public struct FrameGradient: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let colors: [RGBAColor]
    /// Direction in degrees: 0 = left → right, 90 = top → bottom.
    public let angle: Double
}

public enum FrameBackground: Codable, Equatable, Sendable {
    case gradient(String)
    case solid(RGBAColor)
    /// A user-chosen picture, passed to `FrameRenderer.render(_:_:backgroundImage:)`.
    case image
    case transparent
}

/// Screenshot beautifier settings. Lengths are fractions of the photo's longer side,
/// so a preview of a downscaled copy looks the same as the export.
public struct FrameSettings: Codable, Equatable, Sendable {
    public var background: FrameBackground = .gradient("dusk")
    public var padding: Double = 0.08
    public var cornerRadius: Double = 0.02
    public var shadowRadius: Double = 0.03
    public var shadowOpacity: Double = 0.35
    public var shadowOffset: Double = 0.012
    public var canvasRatio: CanvasRatio = .auto
    /// Output pixel scale (0.5, 1, 2).
    public var scale: Double = 1

    public init() {}
}

public struct FrameLayoutResult: Equatable, Sendable {
    public var canvas: CGSize
    /// Where the photo goes, top-left origin.
    public var imageRect: CGRect
}

public enum FrameLayout {
    public static let maxSide: CGFloat = 16_384

    public static let gradients: [FrameGradient] = [
        FrameGradient(id: "dusk", name: "Dusk", colors: [RGBAColor(hex: 0x2C3E50), RGBAColor(hex: 0xFD746C)], angle: 45),
        FrameGradient(id: "peach", name: "Peach", colors: [RGBAColor(hex: 0xFFB88C), RGBAColor(hex: 0xDE6262)], angle: 45),
        FrameGradient(id: "ocean", name: "Ocean", colors: [RGBAColor(hex: 0x1A2980), RGBAColor(hex: 0x26D0CE)], angle: 45),
        FrameGradient(id: "forest", name: "Forest", colors: [RGBAColor(hex: 0x134E5E), RGBAColor(hex: 0x71B280)], angle: 60),
        FrameGradient(id: "candy", name: "Candy", colors: [RGBAColor(hex: 0xD53369), RGBAColor(hex: 0xDAAE51)], angle: 30),
        FrameGradient(id: "ice", name: "Ice", colors: [RGBAColor(hex: 0xE0EAFC), RGBAColor(hex: 0xCFDEF3)], angle: 90),
        FrameGradient(id: "ember", name: "Ember", colors: [RGBAColor(hex: 0xF12711), RGBAColor(hex: 0xF5AF19)], angle: 45),
        FrameGradient(id: "grape", name: "Grape", colors: [RGBAColor(hex: 0x41295A), RGBAColor(hex: 0x8E54E9)], angle: 60),
        FrameGradient(id: "sky", name: "Sky", colors: [RGBAColor(hex: 0x56CCF2), RGBAColor(hex: 0x2F80ED)], angle: 90),
        FrameGradient(id: "blossom", name: "Blossom", colors: [RGBAColor(hex: 0xFBD3E9), RGBAColor(hex: 0xBB377D)], angle: 45),
        FrameGradient(id: "lime", name: "Lime", colors: [RGBAColor(hex: 0xA8E063), RGBAColor(hex: 0x56AB2F)], angle: 45),
        FrameGradient(id: "night", name: "Night", colors: [RGBAColor(hex: 0x0F2027), RGBAColor(hex: 0x203A43), RGBAColor(hex: 0x2C5364)], angle: 90),
    ]

    public static let solids: [(name: String, color: RGBAColor)] = [
        ("White", RGBAColor(hex: 0xFFFFFF)), ("Mist", RGBAColor(hex: 0xF2F2F7)), ("Gray", RGBAColor(hex: 0x8E8E93)),
        ("Charcoal", RGBAColor(hex: 0x2C2C2E)), ("Black", RGBAColor(hex: 0x000000)), ("Red", RGBAColor(hex: 0xFF3B30)),
        ("Orange", RGBAColor(hex: 0xFF9500)), ("Yellow", RGBAColor(hex: 0xFFCC00)), ("Green", RGBAColor(hex: 0x34C759)),
        ("Teal", RGBAColor(hex: 0x30B0C7)), ("Blue", RGBAColor(hex: 0x007AFF)), ("Indigo", RGBAColor(hex: 0x5856D6)),
        ("Purple", RGBAColor(hex: 0xAF52DE)), ("Pink", RGBAColor(hex: 0xFF2D55)),
    ]

    public static func gradient(id: String) -> FrameGradient { gradients.first { $0.id == id } ?? gradients[0] }

    /// Canvas size and photo placement. Padding surrounds the photo on every side; a fixed
    /// ratio grows the canvas (never crops) and centers the photo.
    public static func layout(imageSize: CGSize, settings: FrameSettings) throws -> FrameLayoutResult {
        let w = imageSize.width, h = imageSize.height
        guard w > 0, h > 0 else { throw ImageToolError.invalid("The image has no pixels.") }
        let pad = max(0, settings.padding) * max(w, h)
        var cw = w + 2 * pad, ch = h + 2 * pad
        if let r = settings.canvasRatio.ratio {
            if cw / ch > r { ch = cw / r } else { cw = ch * r }
        }
        let s = CGFloat(max(0.05, settings.scale))
        let canvas = CGSize(width: max(1, (cw * s).rounded()), height: max(1, (ch * s).rounded()))
        guard canvas.width <= maxSide, canvas.height <= maxSide else {
            throw ImageToolError.invalid("This frame would be too large. Use less padding, a smaller scale or a closer canvas ratio.")
        }
        let iw = w * s, ih = h * s
        let rect = CGRect(x: ((canvas.width - iw) / 2).rounded(), y: ((canvas.height - ih) / 2).rounded(), width: iw, height: ih)
        return FrameLayoutResult(canvas: canvas, imageRect: rect)
    }
}

public enum FrameRenderer {
    /// Draws a linear gradient across `rect` (top-left context).
    static func fill(_ gradient: FrameGradient, in rect: CGRect, context ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = gradient.colors.map(\.cgColor) as CFArray
        let n = max(gradient.colors.count - 1, 1)
        let locations = (0...n).map { CGFloat($0) / CGFloat(n) }
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        let theta = gradient.angle * .pi / 180
        let dx = CGFloat(cos(theta)), dy = CGFloat(sin(theta))
        let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                               end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Rect of `size` scaled to cover `rect` (centered, may overflow).
    public static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Rect of `size` scaled to fit inside `rect` (centered).
    public static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Photo on a background with padding, rounded corners and a drop shadow.
    public static func render(_ image: CGImage, _ settings: FrameSettings, backgroundImage: CGImage? = nil) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let layout = try FrameLayout.layout(imageSize: size, settings: settings)
        let cw = Int(layout.canvas.width), ch = Int(layout.canvas.height)
        let ctx = try ImageToolsIO.makeContext(width: cw, height: ch, like: image, alpha: true)
        ImageToolsIO.flipToTopLeft(ctx, height: ch)
        let canvas = CGRect(origin: .zero, size: layout.canvas)

        switch settings.background {
        case .gradient(let id): fill(FrameLayout.gradient(id: id), in: canvas, context: ctx)
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(canvas)
        case .image:
            guard let backgroundImage else { throw ImageToolError.invalid("Choose a background image.") }
            ctx.saveGState()
            ctx.clip(to: canvas)
            let rect = aspectFill(CGSize(width: backgroundImage.width, height: backgroundImage.height), in: canvas)
            ImageToolsIO.draw(backgroundImage, in: rect, context: ctx)
            ctx.restoreGState()
        case .transparent: break
        }

        let long = max(size.width, size.height) * CGFloat(settings.scale)
        let rect = layout.imageRect
        let radius = min(CGFloat(max(0, settings.cornerRadius)) * long, min(rect.width, rect.height) / 2)
        let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        let blur = CGFloat(max(0, settings.shadowRadius)) * long
        if settings.shadowOpacity > 0 && (blur > 0 || settings.shadowOffset != 0) {
            // Shadow offsets are in device space, where y points up.
            ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(settings.shadowOffset) * long), blur: blur,
                          color: CGColor(gray: 0, alpha: min(1, max(0, settings.shadowOpacity))))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(clip)
        ctx.clip()
        ImageToolsIO.draw(image, in: rect, context: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("framed image") }
        return result
    }
}
