import CoreGraphics
import Foundation

public enum CollageLayoutKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Equal cells in rows and columns (2-up, 4-up, 3×3…).
    case grid
    /// Justified rows: each row's height adapts so photos keep their shape.
    case rows
    /// Justified columns of equal height.
    case columns
    /// First photo large, the rest beside it.
    case featured

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .grid: return "Grid"
        case .rows: return "Rows"
        case .columns: return "Columns"
        case .featured: return "Featured"
        }
    }
}

public struct CollageSettings: Codable, Equatable, Sendable {
    public var layout: CollageLayoutKind = .grid
    /// Grid columns; 0 = automatic.
    public var columns: Int = 0
    /// Canvas shape for Grid and Featured (Rows/Columns size themselves).
    public var canvasRatio: CanvasRatio = .auto
    /// Gap between photos, in output pixels.
    public var spacing: Double = 16
    /// Border around the collage, in output pixels.
    public var margin: Double = 16
    public var cornerRadius: Double = 0
    public var background: RGBAColor = .white
    public var outputWidth: Int = 2048
    /// Default cell mode: fill (crop edges) or fit whole photos.
    public var fillCells: Bool = true
    /// Per-photo override of `fillCells`, keyed by position.
    public var fillOverrides: [Int: Bool] = [:]

    public init() {}

    public func fills(_ index: Int) -> Bool { fillOverrides[index] ?? fillCells }
}

public struct CollageLayoutResult: Equatable, Sendable {
    public var canvas: CGSize
    /// One cell per photo, in order, top-left origin.
    public var cells: [CGRect]
}

public enum CollageLayout {
    public static let maxWidth = 8192
    public static let maxHeight: CGFloat = 16_384
    public static let minCell: CGFloat = 8

    public static func automaticColumns(for count: Int) -> Int {
        count <= 3 ? max(1, count) : Int(Double(count).squareRoot().rounded(.up))
    }

    /// Rows (or columns) used by the justified layouts.
    public static func automaticLines(for count: Int) -> Int {
        count <= 3 ? 1 : Int(Double(count).squareRoot().rounded())
    }

    /// Splits `count` items into `lines` groups, larger groups first: 5 into 2 → [3, 2].
    public static func distribute(_ count: Int, into lines: Int) -> [Int] {
        let lines = max(1, min(lines, count))
        let base = count / lines, extra = count % lines
        return (0..<lines).map { base + ($0 < extra ? 1 : 0) }
    }

    /// Lays out photos with the given aspect ratios (width ÷ height).
    public static func layout(aspects rawAspects: [CGFloat], settings: CollageSettings) throws -> CollageLayoutResult {
        let n = rawAspects.count
        guard n > 0 else { throw ImageToolError.invalid("Add at least two images.") }
        let aspects = rawAspects.map { $0.isFinite && $0 > 0 ? min(max($0, 0.05), 20) : 1 }
        let W = CGFloat(min(max(settings.outputWidth, 64), maxWidth))
        let m = CGFloat(max(0, settings.margin)), s = CGFloat(max(0, settings.spacing))
        var cells: [CGRect] = []
        var H: CGFloat

        switch settings.layout {
        case .grid:
            let cols = settings.columns > 0 ? min(settings.columns, n) : automaticColumns(for: n)
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            let cellW = (W - 2 * m - CGFloat(cols - 1) * s) / CGFloat(cols)
            let cellH: CGFloat
            if let r = settings.canvasRatio.ratio {
                H = W / r
                cellH = (H - 2 * m - CGFloat(rows - 1) * s) / CGFloat(rows)
            } else {
                let sorted = aspects.sorted()
                let median = min(max(sorted[sorted.count / 2], 0.5), 2)
                cellH = cellW / median
                H = 2 * m + CGFloat(rows) * cellH + CGFloat(rows - 1) * s
            }
            for i in 0..<n {
                let row = i / cols, col = i % cols
                let inRow = row == rows - 1 ? n - row * cols : cols
                let offset = CGFloat(cols - inRow) * (cellW + s) / 2
                cells.append(CGRect(x: m + offset + CGFloat(col) * (cellW + s), y: m + CGFloat(row) * (cellH + s),
                                    width: cellW, height: cellH))
            }

        case .rows:
            let counts = distribute(n, into: automaticLines(for: n))
            let available = W - 2 * m
            var y = m, index = 0
            for count in counts {
                let group = aspects[index..<(index + count)]
                let h = (available - CGFloat(count - 1) * s) / group.reduce(0, +)
                var x = m
                for a in group {
                    cells.append(CGRect(x: x, y: y, width: h * a, height: h))
                    x += h * a + s
                }
                y += h + s
                index += count
            }
            H = y - s + m

        case .columns:
            let counts = distribute(n, into: automaticLines(for: n))
            var groups: [ArraySlice<CGFloat>] = []
            var index = 0
            for count in counts { groups.append(aspects[index..<(index + count)]); index += count }
            // Column j at width w_j is w_j * S_j + (n_j - 1) * s tall, with S_j = Σ 1/a. Solve for equal heights.
            let sums = groups.map { $0.reduce(0) { $0 + 1 / $1 } }
            let available = W - 2 * m - CGFloat(groups.count - 1) * s
            let numerator = available + s * zip(groups, sums).reduce(0) { $0 + CGFloat($1.0.count - 1) / $1.1 }
            let columnHeight = numerator / sums.reduce(0) { $0 + 1 / $1 }
            var x = m
            for (group, sum) in zip(groups, sums) {
                let w = (columnHeight - CGFloat(group.count - 1) * s) / sum
                var y = m
                for a in group {
                    cells.append(CGRect(x: x, y: y, width: w, height: w / a))
                    y += w / a + s
                }
                x += w + s
            }
            H = columnHeight + 2 * m

        case .featured:
            let rest = n - 1
            let innerW = W - 2 * m
            if rest == 0 {
                H = settings.canvasRatio.ratio.map { W / $0 } ?? (2 * m + innerW / aspects[0])
                cells = [CGRect(x: m, y: m, width: innerW, height: H - 2 * m)]
                break
            }
            let sideCols = rest > 4 ? 2 : 1
            let share: CGFloat = sideCols == 2 ? 0.5 : 2.0 / 3.0
            let bigW = (innerW - s) * share
            if let r = settings.canvasRatio.ratio {
                H = W / r
            } else {
                H = 2 * m + bigW / min(max(aspects[0], 0.5), 2)
            }
            let innerH = H - 2 * m
            cells.append(CGRect(x: m, y: m, width: bigW, height: innerH))
            let sideX = m + bigW + s, sideW = innerW - bigW - s
            let sideRows = Int((Double(rest) / Double(sideCols)).rounded(.up))
            let cellW = (sideW - CGFloat(sideCols - 1) * s) / CGFloat(sideCols)
            let cellH = (innerH - CGFloat(sideRows - 1) * s) / CGFloat(sideRows)
            for i in 0..<rest {
                let row = i / sideCols, col = i % sideCols
                let inRow = row == sideRows - 1 ? rest - row * sideCols : sideCols
                // A lone last cell spans the full side width.
                let w = inRow < sideCols ? sideW : cellW
                cells.append(CGRect(x: sideX + CGFloat(col) * (cellW + s), y: m + CGFloat(row) * (cellH + s),
                                    width: w, height: cellH))
            }
        }

        let canvas = CGSize(width: W, height: max(1, H.rounded()))
        guard canvas.height <= maxHeight else {
            throw ImageToolError.invalid("The collage would be taller than \(Int(maxHeight)) pixels. Use a smaller width or another layout.")
        }
        guard H > 0, cells.allSatisfy({ $0.size.width >= minCell && $0.size.height >= minCell }) else {
            throw ImageToolError.invalid("Choose a canvas and spacing that leave at least 8 × 8 pixels for each image.")
        }
        return CollageLayoutResult(canvas: canvas, cells: cells)
    }
}

public enum CollageRenderer {
    /// Draws the collage. `scale` < 1 renders a smaller preview with identical proportions.
    public static func render(_ images: [CGImage], _ settings: CollageSettings, scale: CGFloat = 1,
                              colorSpace: CGColorSpace? = nil) throws -> CGImage {
        let aspects = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
        let layout = try CollageLayout.layout(aspects: aspects, settings: settings)
        let w = max(1, Int((layout.canvas.width * scale).rounded()))
        let h = max(1, Int((layout.canvas.height * scale).rounded()))
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try ImageToolsIO.makeContext(width: w, height: h, like: nil, alpha: true, colorSpace: space)
        ImageToolsIO.flipToTopLeft(ctx, height: h)
        ctx.scaleBy(x: scale, y: scale)
        if settings.background.alpha > 0 {
            ctx.setFillColor(settings.background.cgColor)
            ctx.fill(CGRect(origin: .zero, size: layout.canvas))
        }
        for (i, cell) in layout.cells.enumerated() {
            let image = images[i]
            let size = CGSize(width: image.width, height: image.height)
            let fill = settings.fills(i)
            let drawRect = fill ? FrameRenderer.aspectFill(size, in: cell) : FrameRenderer.aspectFit(size, in: cell)
            let clipRect = fill ? cell : drawRect
            let radius = min(CGFloat(max(0, settings.cornerRadius)), min(clipRect.width, clipRect.height) / 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: clipRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ImageToolsIO.draw(image, in: drawRect, context: ctx)
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw ImageToolError.renderFailed("collage") }
        return result
    }
}
