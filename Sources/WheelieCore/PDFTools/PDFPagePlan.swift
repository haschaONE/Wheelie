import CoreGraphics
import Foundation

/// One page of an organized PDF: which input file and page it comes from, and how far
/// it is turned clockwise on top of the page's own rotation.
public struct PlannedPage: Hashable, Identifiable, Sendable {
    /// Identity in the editor; duplicates of the same source page get their own id.
    public let id: UUID
    /// Index into the list of input files.
    public var file: Int
    /// Zero-based page index within that file.
    public var page: Int
    /// Extra clockwise rotation in degrees (0, 90, 180, 270).
    public var rotation: Int

    public init(id: UUID = UUID(), file: Int, page: Int, rotation: Int = 0) {
        self.id = id
        self.file = file
        self.page = page
        self.rotation = PDFPageGeometry.normalized(rotation)
    }

    public var key: PageKey { PageKey(file: file, page: page) }
}

/// A source page, independent of where it sits in the plan.
public struct PageKey: Hashable, Sendable {
    public let file: Int
    public let page: Int
    public init(file: Int, page: Int) { self.file = file; self.page = page }
}

/// The ordered list of pages an organized PDF will contain.
public struct PDFPagePlan: Equatable, Sendable {
    public var pages: [PlannedPage]

    public init(pages: [PlannedPage] = []) { self.pages = pages }

    /// Every page of every file once, files in `fileOrder` (default: as given).
    public static func identity(pageCounts: [Int], fileOrder: [Int]? = nil,
                                rotations: [PageKey: Int] = [:]) -> PDFPagePlan {
        let order = fileOrder ?? Array(pageCounts.indices)
        var pages: [PlannedPage] = []
        for file in order where pageCounts.indices.contains(file) {
            for page in 0..<pageCounts[file] {
                pages.append(PlannedPage(file: file, page: page,
                                         rotation: rotations[PageKey(file: file, page: page)] ?? 0))
            }
        }
        return PDFPagePlan(pages: pages)
    }

    /// A single-file plan from a page order (zero-based) and per-page rotations, as an
    /// editor would store it. The order must be a permutation of the file's pages.
    public init(order: [Int], rotations: [Int: Int] = [:], pageCount: Int) throws {
        try Self.validatePermutation(order, pageCount: pageCount)
        guard rotations.values.allSatisfy({ $0 % 90 == 0 }) else { throw PDFToolsError.rightAngles }
        pages = order.map { PlannedPage(file: 0, page: $0, rotation: rotations[$0] ?? 0) }
    }

    /// Throws unless `order` lists each of `0..<pageCount` exactly once.
    public static func validatePermutation(_ order: [Int], pageCount: Int) throws {
        guard pageCount > 0 else { throw PDFToolsError.noPages }
        guard order.count == pageCount, Set(order) == Set(0..<pageCount) else { throw PDFToolsError.pageOrder }
    }

    public var count: Int { pages.count }
    public var isEmpty: Bool { pages.isEmpty }

    public func index(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }

    /// True when the plan keeps every source page exactly once (only order/rotation changed).
    public func isPermutation(pageCounts: [Int]) -> Bool {
        let all = pageCounts.enumerated().flatMap { file, count in (0..<count).map { PageKey(file: file, page: $0) } }
        let keys = pages.map(\.key)
        return keys.count == all.count && Set(keys) == Set(all)
    }

    /// Checks the plan can be built from files with these page counts.
    public func validate(pageCounts: [Int]) throws {
        guard pageCounts.contains(where: { $0 > 0 }) else { throw PDFToolsError.noPages }
        guard !pages.isEmpty else { throw PDFToolsError.keepOnePage }
        for page in pages {
            guard pageCounts.indices.contains(page.file), (0..<pageCounts[page.file]).contains(page.page)
            else { throw PDFToolsError.pageOrder }
            guard page.rotation % 90 == 0 else { throw PDFToolsError.rightAngles }
        }
    }

    // MARK: Editing

    /// Turns the pages clockwise by `degrees` (a multiple of 90).
    public mutating func rotate(_ ids: Set<UUID>, by degrees: Int = 90) {
        for i in pages.indices where ids.contains(pages[i].id) {
            pages[i].rotation = PDFPageGeometry.normalized(pages[i].rotation + degrees)
        }
    }

    public mutating func delete(_ ids: Set<UUID>) {
        pages.removeAll { ids.contains($0.id) }
    }

    /// Inserts a copy right after each page; returns the copies' ids.
    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>) -> [UUID] {
        var result: [PlannedPage] = []
        var added: [UUID] = []
        for page in pages {
            result.append(page)
            if ids.contains(page.id) {
                let copy = PlannedPage(file: page.file, page: page.page, rotation: page.rotation)
                result.append(copy)
                added.append(copy.id)
            }
        }
        pages = result
        return added
    }

    /// Moves the pages (kept in their current relative order) to where `target` is,
    /// as when dropping them on it: moving forward lands after it, backward before it.
    public mutating func move(_ ids: Set<UUID>, onto target: UUID) {
        guard !ids.contains(target), let targetIndex = index(of: target),
              let firstMoved = pages.firstIndex(where: { ids.contains($0.id) }) else { return }
        let moved = pages.filter { ids.contains($0.id) }
        var remaining = pages.filter { !ids.contains($0.id) }
        guard let t = remaining.firstIndex(where: { $0.id == target }) else { return }
        remaining.insert(contentsOf: moved, at: firstMoved < targetIndex ? t + 1 : t)
        pages = remaining
    }

    /// Moves the pages to `offset` in the list without them (0 = start, count = end).
    public mutating func move(_ ids: Set<UUID>, toOffset offset: Int) {
        let moved = pages.filter { ids.contains($0.id) }
        var remaining = pages.filter { !ids.contains($0.id) }
        remaining.insert(contentsOf: moved, at: min(max(0, offset), remaining.count))
        pages = remaining
    }

    /// Groups pages by file in `fileOrder`, keeping each file's pages in their current order.
    public mutating func regroup(fileOrder: [Int]) {
        let rank = Dictionary(uniqueKeysWithValues: fileOrder.enumerated().map { ($1, $0) })
        pages = pages.enumerated().sorted { a, b in
            let ra = rank[a.element.file] ?? Int.max, rb = rank[b.element.file] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// Back to every page once in file order, keeping the rotation each page has now.
    public mutating func resetOrder(pageCounts: [Int], fileOrder: [Int]) {
        var rotations: [PageKey: Int] = [:]
        for page in pages where rotations[page.key] == nil { rotations[page.key] = page.rotation }
        self = .identity(pageCounts: pageCounts, fileOrder: fileOrder, rotations: rotations)
    }
}

/// "Make all pages the same width": scale factors that bring every page down to the
/// narrowest page's width, keeping proportions (heights may still differ).
public enum PDFPageScaling {
    public static func equalWidthScales(for sizes: [CGSize]) -> [CGFloat] {
        let widths = sizes.map(\.width).filter { $0 > 0 }
        guard let narrowest = widths.min() else { return sizes.map { _ in 1 } }
        return sizes.map { $0.width > 0 ? min(1, narrowest / $0.width) : 1 }
    }
}
