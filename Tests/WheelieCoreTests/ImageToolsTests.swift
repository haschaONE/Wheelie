import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

// MARK: - Fixtures

private struct RGBA: Equatable {
    var r: Int, g: Int, b: Int, a: Int
    var luma: Double { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) }
}

/// Image drawn in pixel space with a top-left origin.
private func makeImage(_ width: Int, _ height: Int, alpha: Bool = false,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                       draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

private func solid(_ width: Int, _ height: Int, gray: CGFloat = 1) -> CGImage {
    makeImage(width, height) { ctx in
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Deterministic per-pixel noise: lots of detail for redaction tests.
private func noise(_ width: Int, _ height: Int) -> CGImage {
    var state: UInt64 = 0x9E3779B97F4A7C15
    return makeImage(width, height) { ctx in
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((state >> 33) & 0xFF) / 255
                ctx.setFillColor(CGColor(srgbRed: v, green: 1 - v, blue: v * 0.5, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
}

/// RGBA8 sRGB pixels; row 0 is the top row.
private func pixels(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return data
}

private func pixel(_ data: [UInt8], width: Int, _ x: Int, _ y: Int) -> RGBA {
    let i = (y * width + x) * 4
    return RGBA(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]), a: Int(data[i + 3]))
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
    pixel(pixels(image), width: image.width, x, y)
}

private func lumaStats(_ image: CGImage, in rect: CGRect? = nil) -> (mean: Double, variance: Double) {
    let data = pixels(image)
    let r = (rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    var values: [Double] = []
    for y in Int(r.minY)..<Int(r.maxY) {
        for x in Int(r.minX)..<Int(r.maxX) { values.append(pixel(data, width: image.width, x, y).luma) }
    }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance)
}

private func near(_ a: RGBA, _ b: RGBA, _ tolerance: Int = 3) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance && abs(a.a - b.a) <= tolerance
}

private func tempFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-imagetools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

/// Four colored quadrants: red TL, green TR, blue BL, yellow BR.
private func quadrants(_ width: Int, _ height: Int) -> CGImage {
    makeImage(width, height) { ctx in
        let hw = CGFloat(width) / 2, hh = CGFloat(height) / 2
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: hw, y: 0, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: hh, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: hw, y: hh, width: hw, height: hh))
    }
}

private let red = RGBA(r: 255, g: 0, b: 0, a: 255)
private let green = RGBA(r: 0, g: 255, b: 0, a: 255)
private let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
private let yellow = RGBA(r: 255, g: 255, b: 0, a: 255)

// MARK: - Crop

final class ImageCropTests: XCTestCase {
    func testCropOutputSizeAndContent() throws {
        let image = quadrants(200, 100)
        let out = try ImageCrop.render(image, CropSettings(cropRect: CGRect(x: 90, y: 40, width: 30, height: 20)))
        XCTAssertEqual(out.width, 30)
        XCTAssertEqual(out.height, 20)
        // Crop straddles the center: top-left pixel is red, bottom-right is yellow.
        XCTAssertEqual(pixel(out, 0, 0), red)
        XCTAssertEqual(pixel(out, 29, 19), yellow)

        // Fractional and out-of-bounds rects are snapped to whole pixels inside the image.
        let snapped = CropSettings(cropRect: CGRect(x: 180.4, y: -5, width: 40.6, height: 50.2))
        XCTAssertEqual(snapped.effectiveCrop(for: CGSize(width: 200, height: 100)), CGRect(x: 159, y: 0, width: 41, height: 50))
        XCTAssertEqual(try ImageCrop.render(image, snapped).width, 41)
    }

    func testAspectConstraintMath() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(CropGeometry.largest(ratio: 1, in: bounds), CGRect(x: 50, y: 0, width: 100, height: 100))
        XCTAssertEqual(CropGeometry.largest(ratio: 4, in: bounds), CGRect(x: 0, y: 25, width: 200, height: 50))
        XCTAssertEqual(CropAspect.original.ratio(for: CGSize(width: 300, height: 200)), 1.5)
        XCTAssertNil(CropAspect.free.ratio(for: bounds.size))
        XCTAssertEqual(CropAspect.nineSixteen.ratio(for: bounds.size)!, 9.0 / 16.0, accuracy: 1e-9)

        // Constrain keeps the center and stays inside.
        let c = CropGeometry.constrain(CGRect(x: 150, y: 10, width: 50, height: 80), ratio: 16.0 / 9.0, in: bounds)
        XCTAssertEqual(c.width / c.height, 16.0 / 9.0, accuracy: 1e-6)
        XCTAssertTrue(bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(c))

        // Full-image rect constrained to 1:1 becomes the largest square.
        let sq = CropGeometry.constrain(bounds, ratio: 1, in: bounds)
        XCTAssertEqual(sq.width, 100, accuracy: 1e-6)
        XCTAssertEqual(sq.height, 100, accuracy: 1e-6)

        // Corner drag with a locked ratio keeps the opposite corner and the shape.
        let start = CGRect(x: 20, y: 20, width: 40, height: 30)
        let r = CropGeometry.resize(start, handle: .bottomRight, to: CGPoint(x: 180, y: 50), ratio: 4.0 / 3.0, in: bounds)
        XCTAssertEqual(r.origin, start.origin)
        XCTAssertEqual(r.width / r.height, 4.0 / 3.0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(r.maxY, bounds.maxY + 1e-6)
        XCTAssertEqual(r.height, 80, accuracy: 1e-6) // limited by the bottom edge

        // Dragging past the edges clamps; free resize respects the minimum size.
        let free = CropGeometry.resize(start, handle: .topLeft, to: CGPoint(x: -50, y: 500), ratio: nil, in: bounds, minSize: 10)
        XCTAssertEqual(free, CGRect(x: 0, y: 40, width: 60, height: 10))

        // Edge drag with ratio grows symmetrically around the center line.
        let edge = CropGeometry.resize(start, handle: .right, to: CGPoint(x: 100, y: 0), ratio: 2, in: bounds)
        XCTAssertEqual(edge.minX, 20)
        XCTAssertEqual(edge.midY, start.midY, accuracy: 1e-6)
        XCTAssertEqual(edge.width / edge.height, 2, accuracy: 1e-6)

        // Pixel fields: width drives height under a ratio, clamped to the image.
        let sized = CropGeometry.setSize(start, width: 150, height: nil, ratio: 1.5, in: bounds)
        XCTAssertEqual(sized.width, 150)
        XCTAssertEqual(sized.height, 100)
        XCTAssertEqual(sized.minY, 0)
        XCTAssertEqual(sized.minX, 20)

        // Moving stops at the edges.
        XCTAssertEqual(CropGeometry.move(start, by: CGSize(width: 500, height: -500), in: bounds).origin, CGPoint(x: 160, y: 0))

        // A drag from a point spans a rect in any direction.
        XCTAssertEqual(CropGeometry.spanning(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20), ratio: nil, in: bounds),
                       CGRect(x: 10, y: 20, width: 40, height: 30))

        XCTAssertEqual(CropHandle.hit(CGPoint(x: 59, y: 51), rect: start, radius: 3), .bottomRight)
        XCTAssertNil(CropHandle.hit(CGPoint(x: 40, y: 35), rect: start, radius: 3))
    }

    func testResize() throws {
        XCTAssertEqual(ResizeMath.height(forWidth: 1000, original: CGSize(width: 4000, height: 3000)), 750)
        XCTAssertEqual(ResizeMath.width(forHeight: 500, original: CGSize(width: 1920, height: 1080)), 889)
        XCTAssertTrue(ResizeMath.scaled(CGSize(width: 333, height: 101), percent: 50) == (167, 51))

        let image = quadrants(200, 100)
        var settings = CropSettings(cropRect: CGRect(x: 0, y: 0, width: 100, height: 50))
        settings.outputWidth = 40
        settings.outputHeight = 20
        let out = try ImageCrop.render(image, settings)
        XCTAssertEqual(out.width, 40)
        XCTAssertEqual(out.height, 20)
        XCTAssertTrue(near(pixel(out, 20, 10), red))

        let up = try ImageCrop.resized(image, to: CGSize(width: 400, height: 200))
        XCTAssertEqual(up.width, 400)
        XCTAssertTrue(near(pixel(up, 399, 199), yellow))
        XCTAssertThrowsError(try ImageCrop.resized(image, to: CGSize(width: 0, height: 10)))
    }

    func testRotateAndFlipDimensions() throws {
        let image = quadrants(40, 20)
        let cw = try ImageCrop.oriented(image, quarterTurns: 1)
        XCTAssertEqual(cw.width, 20)
        XCTAssertEqual(cw.height, 40)
        // Clockwise: top-left (red) moves to top-right, bottom-left (blue) to top-left.
        XCTAssertEqual(pixel(cw, 19, 0), red)
        XCTAssertEqual(pixel(cw, 0, 0), blue)

        let ccw = try ImageCrop.oriented(image, quarterTurns: 3)
        XCTAssertEqual(pixel(ccw, 0, 39), red)
        XCTAssertEqual(pixel(ccw, 0, 0), green)

        let half = try ImageCrop.oriented(image, quarterTurns: 2)
        XCTAssertEqual(half.width, 40)
        XCTAssertEqual(pixel(half, 0, 0), yellow)

        let mirrored = try ImageCrop.oriented(image, quarterTurns: 0, flipHorizontal: true)
        XCTAssertEqual(pixel(mirrored, 0, 0), green)
        let flipped = try ImageCrop.oriented(image, quarterTurns: 0, flipVertical: true)
        XCTAssertEqual(pixel(flipped, 0, 0), blue)
    }

    /// Rotating/flipping the editor state must equal rotating/flipping the rendered result.
    func testRotateStateKeepsCrop() throws {
        let image = noise(30, 20)
        let size = CGSize(width: 30, height: 20)
        var settings = CropSettings(cropRect: CGRect(x: 3, y: 2, width: 17, height: 11), flipHorizontal: true)
        let before = try ImageCrop.render(image, settings)

        settings.rotate(clockwise: true, sourceSize: size)
        XCTAssertEqual(pixels(try ImageCrop.render(image, settings)), pixels(try ImageCrop.oriented(before, quarterTurns: 1)))

        settings.flip(horizontal: false, sourceSize: size)
        let expected = try ImageCrop.oriented(try ImageCrop.oriented(before, quarterTurns: 1), quarterTurns: 0, flipVertical: true)
        XCTAssertEqual(pixels(try ImageCrop.render(image, settings)), pixels(expected))

        settings.rotate(clockwise: false, sourceSize: size)
        let back = try ImageCrop.oriented(expected, quarterTurns: 3)
        XCTAssertEqual(pixels(try ImageCrop.render(image, settings)), pixels(back))
    }

    /// Baked EXIF orientation must match what ImageIO displays for all eight orientations.
    func testEXIFOrientationMatchesImageIO() throws {
        let dir = try tempFolder()
        let image = quadrants(40, 20)
        for raw in 1...8 {
            let url = dir.appendingPathComponent("o\(raw).tiff")
            try write(image, to: url, type: .tiff, properties: [kCGImagePropertyOrientation: raw])
            let loaded = try ImageToolsIO.load(url)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 40,
            ] as CFDictionary))
            XCTAssertEqual(loaded.image.width, reference.width, "orientation \(raw)")
            XCTAssertEqual(loaded.image.height, reference.height, "orientation \(raw)")
            for (x, y) in [(1, 1), (loaded.image.width - 2, 1), (1, loaded.image.height - 2),
                           (loaded.image.width - 2, loaded.image.height - 2)] {
                XCTAssertTrue(near(pixel(loaded.image, x, y), pixel(reference, x, y), 8), "orientation \(raw) at \(x),\(y)")
            }
            XCTAssertEqual(ImageToolsIO.pixelSize(of: url), CGSize(width: reference.width, height: reference.height))
        }
    }
}

// MARK: - Adjust

final class ImageAdjustTests: XCTestCase {
    func testExposureAndBrightness() throws {
        let image = solid(32, 32, gray: 0.4)
        let base = lumaStats(image).mean
        var s = AdjustSettings()
        XCTAssertTrue(s.isIdentity)
        XCTAssertEqual(try ImageAdjust.render(image, s), image)

        s.exposure = 1
        XCTAssertGreaterThan(lumaStats(try ImageAdjust.render(image, s)).mean, base + 20)
        s.exposure = -1
        XCTAssertLessThan(lumaStats(try ImageAdjust.render(image, s)).mean, base - 20)

        s = AdjustSettings()
        s.brightness = 0.8
        XCTAssertGreaterThan(lumaStats(try ImageAdjust.render(image, s)).mean, base + 10)
    }

    func testColorAdjustments() throws {
        let orange = makeImage(16, 16) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.5, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var s = AdjustSettings()
        s.saturation = -1
        let gray = pixel(try ImageAdjust.render(orange, s), 8, 8)
        XCTAssertLessThanOrEqual(abs(gray.r - gray.b), 3)

        let neutral = solid(16, 16, gray: 0.5)
        s = AdjustSettings()
        s.warmth = 0.8
        let warm = pixel(try ImageAdjust.render(neutral, s), 8, 8)
        XCTAssertGreaterThan(warm.r, warm.b + 10)
        s.warmth = -0.8
        let cool = pixel(try ImageAdjust.render(neutral, s), 8, 8)
        XCTAssertGreaterThan(cool.b, cool.r + 10)

        s = AdjustSettings()
        s.look = .mono
        let mono = pixel(try ImageAdjust.render(orange, s), 8, 8)
        XCTAssertLessThanOrEqual(abs(mono.r - mono.b), 3)

        // Vignette darkens corners more than the center.
        s = AdjustSettings()
        s.vignette = 1
        let v = try ImageAdjust.render(solid(200, 200, gray: 0.7), s)
        XCTAssertLessThan(pixel(v, 2, 2).luma, pixel(v, 100, 100).luma - 15)

        // Output keeps the size and stays opaque so JPEGs remain JPEGs.
        XCTAssertEqual(v.width, 200)
        XCTAssertFalse(ImageToolsIO.hasTransparency(v))
        XCTAssertEqual(ImageAdjust.presets.first?.settings.isIdentity, true)
        XCTAssertEqual(Set(ImageAdjust.presets.map(\.id)).count, ImageAdjust.presets.count)
    }
}

// MARK: - Annotate

final class AnnotationTests: XCTestCase {
    private func changedPixels(_ a: CGImage, _ b: CGImage) -> [(Int, Int)] {
        let pa = pixels(a), pb = pixels(b)
        var out: [(Int, Int)] = []
        for y in 0..<a.height {
            for x in 0..<a.width where !near(pixel(pa, width: a.width, x, y), pixel(pb, width: a.width, x, y), 2) {
                out.append((x, y))
            }
        }
        return out
    }

    func testRasterizeChangesOnlyDrawnPixels() throws {
        let base = solid(200, 160)
        let marks: [Annotation] = [
            Annotation(kind: .rectangle, points: [CGPoint(x: 40, y: 30), CGPoint(x: 120, y: 90)], lineWidth: 4),
            Annotation(kind: .pen, points: [CGPoint(x: 10, y: 140), CGPoint(x: 30, y: 120), CGPoint(x: 60, y: 150)], lineWidth: 3),
            Annotation(kind: .arrow, points: [CGPoint(x: 140, y: 20), CGPoint(x: 190, y: 70)], lineWidth: 3),
            Annotation(kind: .text, points: [CGPoint(x: 130, y: 100)], text: "Hi", fontSize: 24, textWidth: 60),
            Annotation(kind: .counter, points: [CGPoint(x: 100, y: 130)], fontSize: 12, number: 3),
        ]
        for mark in marks {
            let out = try AnnotationRenderer.render(base, AnnotationDocument(annotations: [mark]))
            XCTAssertEqual(out.width, 200)
            let changed = changedPixels(base, out)
            XCTAssertFalse(changed.isEmpty, "\(mark.kind) drew nothing")
            let allowed = AnnotationGeometry.bounds(mark).insetBy(dx: -2, dy: -2)
            for (x, y) in changed {
                XCTAssertTrue(allowed.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                              "\(mark.kind) changed (\(x), \(y)) outside \(allowed)")
            }
        }
        // Outline rectangles leave their inside untouched; strokes use the annotation color.
        let rect = try AnnotationRenderer.render(base, AnnotationDocument(annotations: [marks[0]]))
        XCTAssertEqual(pixel(rect, 80, 60), RGBA(r: 255, g: 255, b: 255, a: 255))
        let stroke = pixel(rect, 40, 60)
        XCTAssertGreaterThan(stroke.r, 200)
        XCTAssertLessThan(stroke.g, 120)
    }

    func testHighlighterAndBlurBrush() throws {
        let base = noise(120, 80)
        let hl = Annotation(kind: .highlighter, points: [CGPoint(x: 10, y: 40), CGPoint(x: 110, y: 40)],
                            color: RGBAColor(hex: 0xFFCC00), lineWidth: 6)
        let highlighted = try AnnotationRenderer.render(base, AnnotationDocument(annotations: [hl]))
        XCTAssertEqual(pixel(highlighted, 60, 5), pixel(base, 60, 5))
        XCTAssertNotEqual(pixel(highlighted, 60, 40), pixel(base, 60, 40))

        // The live preview composites like the export: the highlighter multiplies onto the photo, so
        // black text under it stays black (regression: drawn on a transparent overlay it became an
        // olive smear in the preview only).
        let dark = solid(120, 80, gray: 0)
        let exportedDark = try AnnotationRenderer.render(dark, AnnotationDocument(annotations: [hl]))
        XCTAssertEqual(pixel(exportedDark, 60, 40), RGBA(r: 0, g: 0, b: 0, a: 255))
        let doc = AnnotationDocument(annotations: [hl])
        let size = CGSize(width: 120, height: 80)
        let samePreview = try AnnotationRenderer.preview([hl], on: dark, imageSize: size, scale: doc.scale(for: size),
                                                         blurSource: nil)
        XCTAssertEqual(pixels(samePreview), pixels(exportedDark))
        let halfPreview = try AnnotationRenderer.preview([hl], on: solid(60, 40, gray: 0), imageSize: size,
                                                         scale: doc.scale(for: size), blurSource: nil)
        XCTAssertEqual(halfPreview.width, 60)
        XCTAssertEqual(pixel(halfPreview, 30, 20), RGBA(r: 0, g: 0, b: 0, a: 255))
        // On white it's the highlight color, in the preview as in the export.
        let white = solid(60, 40)
        let onWhite = try AnnotationRenderer.preview([hl], on: white, imageSize: size, scale: doc.scale(for: size),
                                                     blurSource: nil)
        let tint = pixel(onWhite, 30, 20)
        XCTAssertEqual(tint.r, 255)
        XCTAssertLessThan(tint.b, 200)

        let brush = Annotation(kind: .blur, points: [CGPoint(x: 20, y: 40), CGPoint(x: 100, y: 40)], lineWidth: 5)
        let blurred = try AnnotationRenderer.render(base, AnnotationDocument(annotations: [brush]))
        let region = CGRect(x: 40, y: 34, width: 40, height: 12)
        XCTAssertLessThan(lumaStats(blurred, in: region).variance, lumaStats(base, in: region).variance * 0.5)
        XCTAssertEqual(pixel(blurred, 60, 2), pixel(base, 60, 2))
    }

    func testHitTestingAndModel() {
        let rect = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)], lineWidth: 4)
        XCTAssertTrue(AnnotationGeometry.hitTest(rect, point: CGPoint(x: 10, y: 30), tolerance: 2))
        XCTAssertFalse(AnnotationGeometry.hitTest(rect, point: CGPoint(x: 60, y: 35), tolerance: 2))
        var filled = rect
        filled.filled = true
        XCTAssertTrue(AnnotationGeometry.hitTest(filled, point: CGPoint(x: 60, y: 35), tolerance: 2))

        let text = Annotation(kind: .text, points: [CGPoint(x: 200, y: 200)], text: "Hello world", fontSize: 20, textWidth: 50)
        let box = AnnotationGeometry.textRect(text)
        XCTAssertEqual(box.width, 50)
        XCTAssertGreaterThan(box.height, 40, "text should wrap to two lines")
        XCTAssertEqual(AnnotationGeometry.topmost(at: CGPoint(x: 210, y: 210), in: [rect, text], tolerance: 2), 1)

        var moved = rect
        moved.translate(by: CGSize(width: 5, height: -5))
        XCTAssertEqual(moved.start, CGPoint(x: 15, y: 5))

        XCTAssertFalse(Annotation(kind: .pen, points: [CGPoint(x: 1, y: 1)]).isMeaningful())
        XCTAssertFalse(Annotation(kind: .text, points: [.zero], text: "  ").isMeaningful())
        XCTAssertTrue(rect.isMeaningful())

        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .counter, points: [.zero], number: 1), Annotation(kind: .counter, points: [.zero], number: 4),
        ])
        XCTAssertEqual(doc.nextCounterNumber, 5)
        XCTAssertEqual(AnnotationDocument.scale(enlarge: false, imageSize: CGSize(width: 6000, height: 4000)), 1)
        XCTAssertEqual(AnnotationDocument.scale(enlarge: true, imageSize: CGSize(width: 6000, height: 4000)), 6)
        XCTAssertEqual(AnnotationDocument.scale(enlarge: true, imageSize: CGSize(width: 400, height: 300)), 1.5)
    }

    func testEnlargeMakesStrokesThicker() throws {
        let base = solid(400, 100)
        let line = Annotation(kind: .line, points: [CGPoint(x: 20, y: 50), CGPoint(x: 380, y: 50)], lineWidth: 4)
        func thickness(_ image: CGImage) -> Int {
            let data = pixels(image)
            return (0..<100).filter { pixel(data, width: 400, 200, $0).g < 128 }.count
        }
        let normal = thickness(try AnnotationRenderer.render(base, AnnotationDocument(annotations: [line])))
        let larger = thickness(try AnnotationRenderer.render(base, AnnotationDocument(annotations: [line], enlarge: true)))
        XCTAssertEqual(normal, 4, accuracy: 1)
        XCTAssertGreaterThan(larger, normal)
    }
}

// MARK: - Frame

final class FrameTests: XCTestCase {
    func testLayoutForEveryRatioAndPadding() throws {
        let size = CGSize(width: 300, height: 200)
        for ratio in CanvasRatio.allCases {
            for padding in [0.0, 0.05, 0.2] {
                var s = FrameSettings()
                s.canvasRatio = ratio
                s.padding = padding
                let layout = try FrameLayout.layout(imageSize: size, settings: s)
                let pad = padding * 300
                XCTAssertGreaterThanOrEqual(layout.canvas.width, 300 + 2 * pad - 0.5, "\(ratio) \(padding)")
                XCTAssertGreaterThanOrEqual(layout.canvas.height, 200 + 2 * pad - 0.5, "\(ratio) \(padding)")
                if let r = ratio.ratio {
                    XCTAssertEqual(layout.canvas.width / layout.canvas.height, r, accuracy: 0.01, "\(ratio)")
                } else {
                    XCTAssertEqual(layout.canvas, CGSize(width: (300 + 2 * pad).rounded(), height: (200 + 2 * pad).rounded()))
                }
                XCTAssertEqual(layout.imageRect.size, size)
                XCTAssertTrue(CGRect(origin: .zero, size: layout.canvas).contains(layout.imageRect))
                XCTAssertEqual(layout.imageRect.midX, layout.canvas.width / 2, accuracy: 1)

                let out = try FrameRenderer.render(solid(300, 200, gray: 0.2), s)
                XCTAssertEqual(CGFloat(out.width), layout.canvas.width)
                XCTAssertEqual(CGFloat(out.height), layout.canvas.height)
            }
        }
        var big = FrameSettings()
        big.scale = 2
        let doubled = try FrameLayout.layout(imageSize: size, settings: big)
        XCTAssertEqual(doubled.imageRect.width, 600)
        big.padding = 30
        XCTAssertThrowsError(try FrameLayout.layout(imageSize: size, settings: big))
    }

    func testRenderedBackgroundsAndCorners() throws {
        let photo = solid(100, 100, gray: 0.5)
        var s = FrameSettings()
        s.background = .transparent
        s.cornerRadius = 0.2
        s.shadowOpacity = 0
        s.padding = 0.1
        let clear = try FrameRenderer.render(photo, s)
        XCTAssertEqual(pixel(clear, 2, 2).a, 0)
        XCTAssertEqual(pixel(clear, 11, 11).a, 0, "rounded corner should be cut")
        XCTAssertEqual(pixel(clear, 60, 60).a, 255)

        s.background = .solid(RGBAColor(hex: 0x007AFF))
        let solidOut = try FrameRenderer.render(photo, s)
        XCTAssertTrue(near(pixel(solidOut, 2, 2), RGBA(r: 0, g: 122, b: 255, a: 255), 4))

        s.background = .gradient("ocean")
        let gradient = try FrameRenderer.render(photo, s)
        XCTAssertNotEqual(pixel(gradient, 1, 1), pixel(gradient, 118, 118))

        s.background = .image
        XCTAssertThrowsError(try FrameRenderer.render(photo, s))
        let bg = try FrameRenderer.render(photo, s, backgroundImage: quadrants(50, 50))
        XCTAssertTrue(near(pixel(bg, 1, 1), red, 4))

        // The shadow darkens the padding below the photo.
        s.background = .solid(.white)
        s.shadowOpacity = 0.8
        s.shadowRadius = 0.05
        s.shadowOffset = 0.03
        let shadowed = try FrameRenderer.render(photo, s)
        XCTAssertLessThan(pixel(shadowed, 60, 113).luma, 250)
    }
}

// MARK: - Redact

final class RedactionTests: XCTestCase {
    let region = CGRect(x: 20, y: 30, width: 60, height: 40)

    func testBlackBoxDestroysDetail() throws {
        let image = noise(120, 100)
        let out = try Redactor.render(image, RedactSettings(rects: [RedactionRect(rect: region)], style: .blackBox))
        let stats = lumaStats(out, in: region)
        XCTAssertEqual(stats.variance, 0, accuracy: 0.001)
        XCTAssertEqual(stats.mean, 0, accuracy: 0.001)
        // Outside the rectangle nothing changes.
        XCTAssertEqual(pixel(out, 5, 5), pixel(image, 5, 5))
        XCTAssertEqual(pixel(out, 100, 90), pixel(image, 100, 90))
    }

    func testPixelateAndBlurReduceVariance() throws {
        let image = noise(120, 100)
        let original = lumaStats(image, in: region).variance
        let pixelated = try Redactor.render(image, RedactSettings(rects: [RedactionRect(rect: region)], style: .pixelate))
        XCTAssertLessThan(lumaStats(pixelated, in: region).variance, original * 0.25)
        XCTAssertEqual(pixel(pixelated, 5, 5), pixel(image, 5, 5))
        // Neighboring pixels inside one block are identical.
        XCTAssertEqual(pixel(pixelated, 21, 31), pixel(pixelated, 22, 32))

        let blurred = try Redactor.render(image, RedactSettings(rects: [RedactionRect(rect: region)], style: .blur))
        XCTAssertLessThan(lumaStats(blurred, in: region).variance, original * 0.25)
        XCTAssertEqual(pixel(blurred, 110, 5), pixel(image, 110, 5))

        XCTAssertNotNil(Redactor.previewPatch(image, rect: region, style: .pixelate))
        XCTAssertNil(Redactor.previewPatch(image, rect: region, style: .blackBox))
    }

    /// The live preview must show exactly what export burns in: per-rectangle grid anchored at the
    /// rectangle's corner, sampling only the rectangle's own pixels (regression: the preview used a
    /// whole-photo effect with the grid at the image origin and blur bleeding in from outside).
    func testPreviewPatchMatchesExport() throws {
        let image = noise(300, 200)
        // Off the image-origin block grid on purpose, with a bright frame around it that a whole-photo
        // blur would pull in.
        let rect = CGRect(x: 107, y: 41, width: 90, height: 70)
        for style in [RedactionStyle.pixelate, .blur] {
            let exported = try Redactor.render(image, RedactSettings(rects: [RedactionRect(rect: rect)], style: style))
            let patch = try XCTUnwrap(Redactor.previewPatch(image, rect: rect, style: style))
            XCTAssertEqual(patch.rect, rect)
            XCTAssertEqual(patch.image.width, Int(rect.width))
            let p = pixels(patch.image), e = pixels(exported)
            var mismatches = 0
            for y in 0..<Int(rect.height) {
                for x in 0..<Int(rect.width)
                where !near(pixel(p, width: patch.image.width, x, y),
                            pixel(e, width: exported.width, x + Int(rect.minX), y + Int(rect.minY)), 1) {
                    mismatches += 1
                }
            }
            XCTAssertEqual(mismatches, 0, "\(style) preview differs from export")
        }
        // Pixelation blocks start at the rectangle's own corner.
        let block = Int(Redactor.blockSize(for: CGSize(width: 300, height: 200)))
        let patch = try XCTUnwrap(Redactor.previewPatch(image, rect: rect, style: .pixelate)).image
        let first = pixel(patch, 0, 0)
        XCTAssertEqual(pixel(patch, block - 1, 0), first)
        XCTAssertNotEqual(pixel(patch, block, 0), first)
    }

    func testPixelRectAndDedupe() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(Redactor.pixelRect(CGRect(x: -5.5, y: 10.2, width: 20, height: 200), in: size),
                       CGRect(x: 0, y: 10, width: 15, height: 90))
        XCTAssertTrue(Redactor.pixelRect(CGRect(x: 200, y: 0, width: 5, height: 5), in: size).isNull)
        let found = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 50, y: 50, width: 10, height: 10),
                     CGRect(x: 51, y: 51, width: 10, height: 10)]
        let added = RedactionDetector.newRects(found, excluding: [CGRect(x: 0, y: 0, width: 12, height: 12)])
        XCTAssertEqual(added, [CGRect(x: 50, y: 50, width: 10, height: 10)])
    }

    func testTextDetection() throws {
        let image = makeImage(640, 200) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 200))
            AnnotationRenderer.drawText("SECRET 4815", in: CGRect(x: 40, y: 60, width: 600, height: 100), fontSize: 64,
                                        bold: true, color: CGColor(gray: 0, alpha: 1), centered: false, context: ctx)
        }
        let rects = try RedactionDetector.detect(.text, in: image)
        try XCTSkipIf(rects.isEmpty, "Vision text recognition unavailable in this environment")
        XCTAssertTrue(rects.contains { $0.intersects(CGRect(x: 40, y: 60, width: 400, height: 80)) })
        XCTAssertEqual(try RedactionDetector.detect(.faces, in: solid(64, 64)), [])
    }
}

// MARK: - Collage

final class CollageTests: XCTestCase {
    func testLayoutsAreNonOverlappingAndInBounds() throws {
        let pool: [CGFloat] = [1.5, 0.75, 1, 1.78, 0.5625, 1.33, 0.8, 2, 1.2]
        for n in 2...9 {
            let aspects = Array(pool.prefix(n))
            for kind in CollageLayoutKind.allCases {
                for ratio in [CanvasRatio.auto, .square, .sixteenNine] {
                    var s = CollageSettings()
                    s.layout = kind
                    s.canvasRatio = ratio
                    s.spacing = 12
                    s.margin = 20
                    let layout = try CollageLayout.layout(aspects: aspects, settings: s)
                    let label = "\(kind) n=\(n) \(ratio)"
                    XCTAssertEqual(layout.cells.count, n, label)
                    let canvas = CGRect(origin: .zero, size: layout.canvas).insetBy(dx: 20 - 0.6, dy: 20 - 0.6)
                    for cell in layout.cells {
                        XCTAssertTrue(canvas.contains(cell), "\(label): \(cell) outside \(canvas)")
                        XCTAssertGreaterThanOrEqual(cell.width, 8, label)
                    }
                    for i in 0..<n {
                        for j in (i + 1)..<n {
                            let overlap = layout.cells[i].insetBy(dx: 0.01, dy: 0.01).intersection(layout.cells[j])
                            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01,
                                          "\(label): cells \(i) and \(j) overlap")
                        }
                    }
                    if kind == .rows || kind == .columns {
                        for (cell, a) in zip(layout.cells, aspects) {
                            XCTAssertEqual(cell.width / cell.height, a, accuracy: 0.01, "\(label) keeps shapes")
                        }
                    }
                    if ratio != .auto && (kind == .grid || kind == .featured) {
                        XCTAssertEqual(layout.canvas.width / layout.canvas.height, ratio.ratio!, accuracy: 0.01, label)
                    }
                }
            }
        }
    }

    func testColumnsEqualHeightAndCounts() throws {
        XCTAssertEqual(CollageLayout.distribute(5, into: 2), [3, 2])
        XCTAssertEqual(CollageLayout.distribute(7, into: 3), [3, 2, 2])
        XCTAssertEqual(CollageLayout.automaticColumns(for: 3), 3)
        XCTAssertEqual(CollageLayout.automaticColumns(for: 5), 3)
        var s = CollageSettings()
        s.layout = .columns
        let layout = try CollageLayout.layout(aspects: [1, 0.5, 2, 1.5], settings: s)
        let bottoms = Dictionary(grouping: layout.cells, by: { $0.minX.rounded() }).values.map { $0.map(\.maxY).max()! }
        for b in bottoms { XCTAssertEqual(b, layout.canvas.height - s.margin, accuracy: 0.6) }

        s.spacing = 3000
        XCTAssertThrowsError(try CollageLayout.layout(aspects: [1, 1, 1, 1], settings: s))
    }

    func testRenderSizeFitAndFill() throws {
        var s = CollageSettings()
        s.outputWidth = 400
        s.spacing = 0
        s.margin = 0
        s.background = RGBAColor(hex: 0x000000)
        s.canvasRatio = .square
        s.columns = 2
        let wide = quadrants(200, 50)
        let out = try CollageRenderer.render([wide, wide], s)
        let layout = try CollageLayout.layout(aspects: [4, 4], settings: s)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(CGFloat(out.height), layout.canvas.height)
        // Fill covers the whole cell; fit leaves background above/below the wide photo.
        XCTAssertNotEqual(pixel(out, 100, 2), RGBA(r: 0, g: 0, b: 0, a: 255))
        s.fillOverrides[1] = false
        let fit = try CollageRenderer.render([wide, wide], s)
        XCTAssertEqual(pixel(fit, 300, 2), RGBA(r: 0, g: 0, b: 0, a: 255))
        let preview = try CollageRenderer.render([wide, wide], s, scale: 0.5)
        XCTAssertEqual(preview.width, 200)
    }
}

// MARK: - Export

final class ImageExportTests: XCTestCase {
    func testExportKeepsFormatProfileAndOrientation() async throws {
        let dir = try tempFolder()

        // JPEG stays JPEG (with metadata carried over, orientation reset after baking).
        let jpeg = dir.appendingPathComponent("photo.jpg")
        try write(quadrants(60, 40), to: jpeg, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "hello"],
        ])
        let source = try ImageToolsIO.load(jpeg)
        XCTAssertEqual(source.size, CGSize(width: 40, height: 60), "orientation 6 baked in")
        let cropped = try ImageCrop.render(source.image, CropSettings(cropRect: CGRect(x: 0, y: 0, width: 20, height: 30)))
        let out = try await ImageToolsIO.export(cropped, source: source, suffix: " crop")
        XCTAssertEqual(out.lastPathComponent, "photo crop.jpg")
        let outSource = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(outSource) as String?, UTType.jpeg.identifier)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 20)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifUserComment] as? String, "hello")
        // Second export doesn't overwrite.
        let again = try await ImageToolsIO.export(cropped, source: source, suffix: " crop")
        XCTAssertEqual(again.lastPathComponent, "photo crop 2.jpg")

        // A transparent result from a JPEG falls back to PNG.
        var frame = FrameSettings()
        frame.background = .transparent
        let framed = try FrameRenderer.render(source.image, frame)
        let png = try await ImageToolsIO.export(framed, source: source, suffix: " frame")
        XCTAssertEqual(png.pathExtension, "png")

        // Display P3 PNG keeps its profile and alpha.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let pngURL = dir.appendingPathComponent("wide.png")
        try write(makeImage(30, 30, alpha: true, space: p3) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }, to: pngURL, type: .png)
        let wide = try ImageToolsIO.load(pngURL)
        var adjust = AdjustSettings()
        adjust.contrast = 0.2
        let adjusted = try ImageAdjust.render(wide.image, adjust)
        let wideOut = try await ImageToolsIO.export(adjusted, source: wide, suffix: " adjust")
        XCTAssertEqual(wideOut.lastPathComponent, "wide adjust.png")
        let reloaded = try ImageToolsIO.load(wideOut)
        XCTAssertEqual(reloaded.image.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertTrue(ImageToolsIO.hasTransparency(reloaded.image))

        // HEIC and TIFF round-trip in their own format.
        for (name, type) in [("pic.heic", UTType.heic), ("pic.tiff", UTType.tiff)] {
            let url = dir.appendingPathComponent(name)
            try write(quadrants(32, 32), to: url, type: type)
            let src = try ImageToolsIO.load(url)
            let marked = try AnnotationRenderer.render(src.image, AnnotationDocument(annotations: [
                Annotation(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 31, y: 31)]),
            ]))
            let written = try await ImageToolsIO.export(marked, source: src, suffix: " annotate")
            XCTAssertEqual(written.pathExtension, url.pathExtension)
            let typeOut = CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))) as String?
            XCTAssertEqual(typeOut, type.identifier)
        }
    }

    func testExportPlan() {
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.jpeg.identifier, sourceExtension: "jpeg", transparent: false).fileExtension, "jpeg")
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.jpeg.identifier, sourceExtension: "jpg", transparent: true).type, .png)
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.heic.identifier, sourceExtension: "heic", transparent: true).type, .heic)
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.webP.identifier, sourceExtension: "webp", transparent: false,
                                         cwebpAvailable: false).type, .png)
        XCTAssertTrue(ImageToolsIO.plan(sourceType: UTType.webP.identifier, sourceExtension: "webp", transparent: false,
                                        cwebpAvailable: true).useCWebP)
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.bmp.identifier, sourceExtension: "bmp", transparent: true).type, .png)
    }

    /// The extension always names the encoded format (regression: it came from the file name while the
    /// encoder came from the sniffed content).
    func testExportPlanExtensionFollowsContent() {
        func plan(_ type: UTType, _ ext: String, transparent: Bool = false) -> ImageToolsIO.ExportPlan {
            ImageToolsIO.plan(sourceType: type.identifier, sourceExtension: ext, transparent: transparent,
                              cwebpAvailable: true)
        }
        // Matching names keep their spelling.
        XCTAssertEqual(plan(.jpeg, "JPG").fileExtension, "JPG")
        XCTAssertEqual(plan(.jpeg, "jpe").fileExtension, "jpe")
        XCTAssertEqual(plan(.tiff, "tif").fileExtension, "tif")
        XCTAssertEqual(plan(.heic, "heif").fileExtension, "heif")
        // Misnamed files get the real format's extension.
        XCTAssertEqual(plan(.jpeg, "png"), ImageToolsIO.ExportPlan(type: .jpeg, fileExtension: "jpg", useCWebP: false))
        XCTAssertEqual(plan(.png, "jpg", transparent: true), ImageToolsIO.ExportPlan(type: .png, fileExtension: "png", useCWebP: false))
        XCTAssertEqual(plan(.webP, "jpg"), ImageToolsIO.ExportPlan(type: .webP, fileExtension: "webp", useCWebP: true))
        XCTAssertEqual(plan(.png, "webp"), ImageToolsIO.ExportPlan(type: .png, fileExtension: "png", useCWebP: false))
        XCTAssertEqual(plan(.jpeg, "").fileExtension, "jpg")
        XCTAssertEqual(plan(.jpeg, "download").fileExtension, "jpg")
    }

    /// ICO/ICNS only hold a few square sizes; other results go to PNG (regression: Crop of an icon
    /// failed at finalize with "Couldn't save … crop.icns.").
    func testExportPlanIconSizes() {
        func type(_ t: UTType, _ w: Int, _ h: Int) -> UTType {
            ImageToolsIO.plan(sourceType: t.identifier, sourceExtension: t.preferredFilenameExtension ?? "",
                              transparent: true, pixelSize: CGSize(width: w, height: h)).type
        }
        for side in [16, 32, 64, 128, 256, 512, 1024] { XCTAssertEqual(type(.icns, side, side), .icns, "\(side)") }
        for (w, h) in [(800, 800), (100, 80), (257, 257), (200, 200), (2048, 2048)] { XCTAssertEqual(type(.icns, w, h), .png) }
        for side in [16, 32, 48, 64, 128, 256] { XCTAssertEqual(type(.ico, side, side), .ico, "\(side)") }
        for (w, h) in [(200, 150), (200, 200), (512, 512), (300, 300)] { XCTAssertEqual(type(.ico, w, h), .png) }
        // Unknown size: don't promise an icon.
        XCTAssertEqual(ImageToolsIO.plan(sourceType: UTType.ico.identifier, sourceExtension: "ico", transparent: false).type, .png)
    }

    func testIconExportFallsBackToPNG() async throws {
        let dir = try tempFolder()
        func icon(_ side: Int) -> CGImage {
            makeImage(side, side, alpha: true) { ctx in
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.8))
                ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        // An iconutil-style .icns: frame 0 is 1024 px at 144 DPI.
        let icns = dir.appendingPathComponent("App.icns")
        try write(icon(1024), to: icns, type: .icns, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let icnsSource = try ImageToolsIO.load(icns)
        XCTAssertEqual(icnsSource.typeIdentifier, UTType.icns.identifier)

        let crop800 = try ImageCrop.render(icnsSource.image, CropSettings(cropRect: CGRect(x: 0, y: 0, width: 800, height: 800)))
        let out800 = try await ImageToolsIO.export(crop800, source: icnsSource, suffix: " crop")
        XCTAssertEqual(out800.lastPathComponent, "App crop.png")
        XCTAssertEqual(try ImageToolsIO.load(out800).size, CGSize(width: 800, height: 800))

        // Supported sizes stay icons, whatever DPI the source carried.
        let crop512 = try ImageCrop.render(icnsSource.image, CropSettings(cropRect: CGRect(x: 0, y: 0, width: 512, height: 512)))
        let out512 = try await ImageToolsIO.export(crop512, source: icnsSource, suffix: " crop")
        XCTAssertEqual(out512.pathExtension, "icns")
        let full = try await ImageToolsIO.export(icnsSource.image, source: icnsSource, suffix: " plain", preserveMetadata: false)
        XCTAssertEqual(full.pathExtension, "icns")
        XCTAssertEqual(try ImageToolsIO.load(full).size, CGSize(width: 1024, height: 1024))

        // A 256 px favicon cropped to a non-square size.
        let ico = dir.appendingPathComponent("favicon.ico")
        try write(icon(256), to: ico, type: .ico)
        let icoSource = try ImageToolsIO.load(ico)
        let cropIco = try ImageCrop.render(icoSource.image, CropSettings(cropRect: CGRect(x: 0, y: 0, width: 200, height: 150)))
        let outIco = try await ImageToolsIO.export(cropIco, source: icoSource, suffix: " crop")
        XCTAssertEqual(outIco.lastPathComponent, "favicon crop.png")
        XCTAssertTrue(ImageToolsIO.hasTransparency(try ImageToolsIO.load(outIco).image))
        let sameIco = try await ImageToolsIO.export(icoSource.image, source: icoSource, suffix: " adjust")
        XCTAssertEqual(sameIco.pathExtension, "ico")
    }

    func testMisnamedSourceExportsWithMatchingExtension() async throws {
        let dir = try tempFolder()
        let misnamed = dir.appendingPathComponent("x.png")
        try write(quadrants(40, 30), to: misnamed, type: .jpeg)
        let source = try ImageToolsIO.load(misnamed)
        XCTAssertEqual(source.typeIdentifier, UTType.jpeg.identifier)
        let out = try await ImageToolsIO.export(source.image, source: source, suffix: " adjust")
        XCTAssertEqual(out.lastPathComponent, "x adjust.jpg")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.jpeg.identifier)
    }
}

// MARK: - Undo history

final class EditHistoryTests: XCTestCase {
    /// Redact's scenario: draw a rectangle, nudge it with the arrow keys, ⌘Z. The nudges must undo as
    /// one step back to the drawn position (regression: they skipped the checkpoint, so ⌘Z removed
    /// the rectangle instead).
    func testNudgesCoalesceIntoOneUndoStep() {
        var history = EditHistory<[CGRect]>()
        var rects: [CGRect] = []
        let drawn = CGRect(x: 10, y: 10, width: 50, height: 40)
        history.checkpoint(rects)              // draw
        rects = [drawn]
        for _ in 0..<3 {                       // three nudges of the same rectangle
            history.checkpoint(rects, group: "nudge-a")
            rects[0].origin.x += 10
        }
        XCTAssertEqual(history.undoStack.count, 2)
        rects = history.undo(from: rects) ?? rects
        XCTAssertEqual(rects, [drawn], "undo moves the rectangle back instead of removing it")
        rects = history.undo(from: rects) ?? rects
        XCTAssertEqual(rects, [])
        XCTAssertFalse(history.canUndo)
        rects = history.redo(from: rects) ?? rects
        rects = history.redo(from: rects) ?? rects
        XCTAssertEqual(rects.first?.minX, 40)
        XCTAssertFalse(history.canRedo)
    }

    func testGroupsEndOnOtherEditsAndUndo() {
        var history = EditHistory<Int>(limit: 3)
        history.checkpoint(0, group: "nudge-a")
        history.checkpoint(1, group: "nudge-a")    // coalesced
        history.checkpoint(1)                      // other edit ends the group
        history.checkpoint(2, group: "nudge-a")    // new group
        XCTAssertEqual(history.undoStack, [0, 1, 2])
        XCTAssertEqual(history.undo(from: 3), 2)
        history.checkpoint(2, group: "nudge-a")    // after undo, the same group starts a new step
        XCTAssertEqual(history.undoStack, [0, 1, 2])
        XCTAssertFalse(history.canRedo, "a new edit clears redo")
        history.checkpoint(3, group: "nudge-b")
        XCTAssertEqual(history.undoStack, [1, 2, 3], "limited to the newest steps")
    }
}
