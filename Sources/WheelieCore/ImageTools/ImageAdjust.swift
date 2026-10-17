import CoreGraphics
import CoreImage
import Foundation

/// One-tap photographic looks layered on top of the sliders.
public enum AdjustLook: String, Codable, CaseIterable, Sendable {
    case none, mono, noir, tonal, chrome, fade, instant, process, transfer

    var filterName: String? {
        switch self {
        case .none: return nil
        case .mono: return "CIPhotoEffectMono"
        case .noir: return "CIPhotoEffectNoir"
        case .tonal: return "CIPhotoEffectTonal"
        case .chrome: return "CIPhotoEffectChrome"
        case .fade: return "CIPhotoEffectFade"
        case .instant: return "CIPhotoEffectInstant"
        case .process: return "CIPhotoEffectProcess"
        case .transfer: return "CIPhotoEffectTransfer"
        }
    }
}

/// Photo adjustments. Signed values run -1...1 (0 = unchanged); exposure is in EV (-2...2);
/// sharpness and vignette run 0...1.
public struct AdjustSettings: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var brightness: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var sharpness: Double = 0
    public var vignette: Double = 0
    public var look: AdjustLook = .none

    public init() {}

    public var isIdentity: Bool { self == AdjustSettings() }
}

public struct AdjustPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let settings: AdjustSettings

    init(_ name: String, _ configure: (inout AdjustSettings) -> Void) {
        var s = AdjustSettings()
        configure(&s)
        id = name.lowercased()
        self.name = name
        settings = s
    }
}

public enum ImageAdjust {
    /// One GPU-backed context for the whole app; CIContext is thread-safe and expensive to create.
    public static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    public static let presets: [AdjustPreset] = [
        AdjustPreset("Original") { _ in },
        AdjustPreset("Vivid") { $0.saturation = 0.25; $0.vibrance = 0.4; $0.contrast = 0.15 },
        AdjustPreset("Warm") { $0.warmth = 0.45; $0.vibrance = 0.1 },
        AdjustPreset("Cool") { $0.warmth = -0.45; $0.tint = -0.05 },
        AdjustPreset("Dramatic") { $0.contrast = 0.4; $0.highlights = -0.4; $0.shadows = 0.15; $0.saturation = -0.15; $0.vignette = 0.45 },
        AdjustPreset("Bright") { $0.exposure = 0.35; $0.shadows = 0.25; $0.highlights = -0.15 },
        AdjustPreset("Mono") { $0.look = .mono },
        AdjustPreset("Noir") { $0.look = .noir },
        AdjustPreset("Silver") { $0.look = .tonal; $0.contrast = 0.1 },
        AdjustPreset("Chrome") { $0.look = .chrome },
        AdjustPreset("Fade") { $0.look = .fade },
        AdjustPreset("Instant") { $0.look = .instant },
        AdjustPreset("Vintage") { $0.look = .transfer; $0.vignette = 0.3 },
        AdjustPreset("Process") { $0.look = .process },
    ]

    /// The filter chain. `detailScale` (< 1 for downscaled previews) keeps pixel radii proportional.
    public static func apply(_ s: AdjustSettings, to input: CIImage, detailScale: CGFloat = 1) -> CIImage {
        let extent = input.extent
        var img = input.clampedToExtent()
        if s.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }
        if s.warmth != 0 || s.tint != 0 {
            // A higher source neutral makes CoreImage warm the picture, a lower one cools it.
            let kelvin = 6500 + s.warmth * (s.warmth > 0 ? 3500 : 2500)
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: kelvin, y: s.tint * 60),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if s.highlights < 0 || s.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, s.highlights),
                "inputShadowAmount": s.shadows,
            ])
        }
        if s.highlights > 0 {
            let h = s.highlights
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.04 * h),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.13 * h),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if s.brightness != 0 || s.contrast != 0 || s.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: s.brightness * 0.25,
                kCIInputContrastKey: 1 + s.contrast * (s.contrast > 0 ? 0.5 : 0.45),
                kCIInputSaturationKey: max(0, 1 + s.saturation),
            ])
        }
        if s.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance])
        }
        if let name = s.look.filterName {
            img = img.applyingFilter(name)
        }
        if s.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: s.sharpness * 1.2,
                kCIInputRadiusKey: max(0.5, 1.8 * detailScale),
            ])
        }
        if s.vignette > 0 {
            let diagonal = hypot(extent.width, extent.height)
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: diagonal * 0.3,
                kCIInputIntensityKey: s.vignette,
                "inputFalloff": 0.6,
            ])
        }
        return img.cropped(to: extent)
    }

    /// Renders the adjusted photo in its own color space (16-bit sources stay 16-bit).
    public static func render(_ image: CGImage, _ settings: AdjustSettings, detailScale: CGFloat = 1,
                              context: CIContext = sharedContext) throws -> CGImage {
        if settings.isIdentity { return image }
        let input = CIImage(cgImage: image)
        let output = apply(settings, to: input, detailScale: detailScale)
        let space = ImageToolsIO.workingColorSpace(for: image)
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let result = context.createCGImage(output, from: input.extent, format: format, colorSpace: space) else {
            throw ImageToolError.renderFailed("adjusted photo")
        }
        return result
    }
}
