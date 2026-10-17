import CoreGraphics
import Foundation

/// How a Float lays out its files.
public enum FloatViewMode: String, Codable, Sendable, CaseIterable {
    case icons, list
}

/// Arrow-key directions for keyboard navigation inside a Float.
public enum FloatMove: Sendable {
    case left, right, up, down
}

/// Size and item geometry of a Float panel. All item frames are in the grid's
/// content coordinates with y pointing down (a flipped view), origin at the top-left
/// of the scrollable content.
public struct FloatLayout: Equatable, Sendable {
    // Icon mode
    public static let tileSize = CGSize(width: 84, height: 98)
    public static let thumbnailSide: CGFloat = 60
    public static let spacing: CGFloat = 4
    public static let minColumns = 2
    public static let maxColumns = 4
    public static let maxVisibleRows = 4
    // List mode
    public static let listRowHeight: CGFloat = 28
    public static let listWidth: CGFloat = 272
    public static let maxVisibleListRows = 9
    // Chrome
    /// Inset of the grid inside the scroll view.
    public static let contentInset: CGFloat = 8
    /// Gap between the scroll view and the panel's edges (draggable background).
    public static let margin: CGFloat = 4
    public static let headerHeight: CGFloat = 30

    public let mode: FloatViewMode
    public let count: Int
    public let columns: Int
    public let rows: Int

    public init(count: Int, mode: FloatViewMode = .icons) {
        self.mode = mode
        self.count = max(0, count)
        switch mode {
        case .icons:
            columns = Self.columns(for: self.count)
            rows = max(1, Int((Double(self.count) / Double(columns)).rounded(.up)))
        case .list:
            columns = 1
            rows = max(1, self.count)
        }
    }

    /// Roughly square grids: 1–4 items → 2 columns, 5–9 → 3, 10+ → 4.
    public static func columns(for count: Int) -> Int {
        let side = Int(Double(max(count, 1)).squareRoot().rounded(.up))
        return min(maxColumns, max(minColumns, side))
    }

    public var cellSize: CGSize {
        switch mode {
        case .icons: return Self.tileSize
        case .list: return CGSize(width: Self.listWidth - 2 * (Self.margin + Self.contentInset), height: Self.listRowHeight)
        }
    }

    private var rowSpacing: CGFloat { mode == .icons ? Self.spacing : 0 }

    /// Size of the whole scrollable grid (all rows).
    public var contentSize: CGSize {
        let cell = cellSize
        let width = CGFloat(columns) * cell.width + CGFloat(columns - 1) * Self.spacing + 2 * Self.contentInset
        let height = CGFloat(rows) * cell.height + CGFloat(rows - 1) * rowSpacing + 2 * Self.contentInset
        return CGSize(width: width, height: height)
    }

    public var visibleRows: Int {
        min(rows, mode == .icons ? Self.maxVisibleRows : Self.maxVisibleListRows)
    }

    /// Visible part of the grid; content taller than this scrolls.
    public var viewportSize: CGSize {
        let cell = cellSize
        let height = CGFloat(visibleRows) * cell.height + CGFloat(visibleRows - 1) * rowSpacing + 2 * Self.contentInset
        return CGSize(width: contentSize.width, height: height)
    }

    public var scrolls: Bool { rows > visibleRows }

    /// The whole panel: header + viewport + margins.
    public var panelSize: CGSize {
        let viewport = viewportSize
        return CGSize(width: viewport.width + 2 * Self.margin,
                      height: viewport.height + Self.headerHeight + Self.margin)
    }

    /// Frame of item `index` (y down, content coordinates).
    public func frame(at index: Int) -> CGRect {
        let cell = cellSize
        let column = index % columns
        let row = index / columns
        return CGRect(x: Self.contentInset + CGFloat(column) * (cell.width + Self.spacing),
                      y: Self.contentInset + CGFloat(row) * (cell.height + rowSpacing),
                      width: cell.width, height: cell.height)
    }

    /// Item under `point` (content coordinates, y down), nil for gaps and empty space.
    public func index(at point: CGPoint) -> Int? {
        let cell = cellSize
        let x = point.x - Self.contentInset
        let y = point.y - Self.contentInset
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / (cell.width + Self.spacing))
        let row = Int(y / (cell.height + rowSpacing))
        guard column < columns, row < rows else { return nil }
        let index = row * columns + column
        guard index < count, frame(at: index).contains(point) else { return nil }
        return index
    }

    /// Items whose cells intersect `rect` (rubber-band selection).
    public func indexes(in rect: CGRect) -> [Int] {
        guard count > 0, !rect.isNull else { return [] }
        return (0..<count).filter { frame(at: $0).intersects(rect) }
    }

    /// Keyboard navigation: the item reached by moving from `index`. Clamps at the edges.
    public func index(from index: Int?, moving direction: FloatMove) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index >= 0, index < count else {
            return direction == .left || direction == .up ? count - 1 : 0
        }
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            // Last partial row: jump to the final item when there is a row below.
            return index / columns < rows - 1 ? count - 1 : index
        }
    }
}

extension FloatLayout {
    /// Insertion position for a drop at `point` (reordering inside a Float): 0...count.
    public func insertionIndex(at point: CGPoint) -> Int {
        guard count > 0 else { return 0 }
        let cell = cellSize
        let rowPitch = cell.height + rowSpacing
        let row = min(max(0, Int((point.y - Self.contentInset) / rowPitch)), rows - 1)
        let column: Int
        switch mode {
        case .list:
            let within = point.y - Self.contentInset - CGFloat(row) * rowPitch
            column = within > cell.height / 2 ? 1 : 0
        case .icons:
            let pitch = cell.width + Self.spacing
            let x = point.x - Self.contentInset
            column = min(max(0, Int((x + pitch / 2) / pitch)), columns)
        }
        return min(count, row * columns + column)
    }
}
