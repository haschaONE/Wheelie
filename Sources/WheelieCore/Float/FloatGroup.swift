import Foundation

/// One file or folder held by a Float. Floats only reference files; they never copy them.
public struct FloatItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL
    /// Bookmark data so a file that is moved or renamed can be found again.
    public var bookmark: Data?
    /// The file's volume isn't reachable right now (ejected disk, NAS share not
    /// reconnected yet). The item is kept, shown dimmed, until the volume is back.
    public var isUnavailable: Bool

    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil, isUnavailable: Bool = false) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.isUnavailable = isUnavailable
    }

    public var name: String { url.lastPathComponent }

    /// Identity used for de-duplication: the standardized path in one Unicode
    /// normalization form (Finder and Terminal can hand over different ones).
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

/// Modifier keys that change how a click or rubber band affects the selection.
public struct FloatSelectionModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// ⌘: toggle.
    public static let toggle = FloatSelectionModifiers(rawValue: 1)
    /// ⇧: extend from the anchor.
    public static let extend = FloatSelectionModifiers(rawValue: 2)
}

/// Items and selection of one Float. Order is insertion order; a file is held once.
public struct FloatGroup: Sendable {
    public private(set) var items: [FloatItem] = []
    public private(set) var selection: Set<UUID> = []
    /// Where ⇧-click ranges start.
    public private(set) var anchor: UUID?
    /// The moving end of a range extended with ⇧ (⇧-arrow keys continue from here).
    /// Any other kind of selection change resets it.
    public private(set) var focus: UUID?

    public init(items: [FloatItem] = []) {
        for item in items where index(ofKey: FloatItem.key(for: item.url)) == nil {
            self.items.append(item)
        }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func index(ofKey key: String) -> Int? {
        items.firstIndex { FloatItem.key(for: $0.url) == key }
    }

    public func contains(_ url: URL) -> Bool { index(ofKey: FloatItem.key(for: url)) != nil }

    /// Adds files not already present (also de-duplicates within `urls`).
    /// - Returns: the newly added items and the ids of files that were already here.
    @discardableResult
    public mutating func add(_ urls: [URL], bookmark: (URL) -> Data? = { _ in nil })
        -> (added: [FloatItem], existing: [UUID]) {
        var added: [FloatItem] = []
        var existing: [UUID] = []
        for url in urls where url.isFileURL {
            if let i = index(ofKey: FloatItem.key(for: url)) {
                let id = items[i].id
                if !existing.contains(id), !added.contains(where: { $0.id == id }) { existing.append(id) }
                continue
            }
            let item = FloatItem(url: url.standardizedFileURL, bookmark: bookmark(url))
            items.append(item)
            added.append(item)
        }
        return (added, existing)
    }

    /// Re-inserts known items (used when restoring); skips duplicates.
    public mutating func append(_ item: FloatItem) {
        guard index(ofKey: FloatItem.key(for: item.url)) == nil else { return }
        items.append(item)
    }

    public mutating func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let anchor, ids.contains(anchor) { self.anchor = nil }
        if let focus, ids.contains(focus) { self.focus = nil }
    }

    public mutating func updateURL(_ id: UUID, to url: URL, bookmark: Data?) {
        guard let i = index(of: id) else { return }
        items[i].url = url
        if let bookmark { items[i].bookmark = bookmark }
    }

    /// Moves items to a new position (drag reordering). `ids` keep their relative order.
    public mutating func move(_ ids: Set<UUID>, to destination: Int) {
        let moving = items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let before = items[..<min(max(0, destination), items.count)].filter { ids.contains($0.id) }.count
        items.removeAll { ids.contains($0.id) }
        let target = min(max(0, destination - before), items.count)
        items.insert(contentsOf: moving, at: target)
    }

    // MARK: Selection

    public var selectedItems: [FloatItem] { items.filter { selection.contains($0.id) } }
    public var selectedURLs: [URL] { selectedItems.map(\.url) }
    public var allURLs: [URL] { items.map(\.url) }

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// Index arrow-key navigation moves from: with ⇧, the moving end of the current ⇧-range
    /// (set only by ⇧-extending; any other selection change resets it), else the anchor,
    /// else the last selected item.
    public func navigationOrigin(extending: Bool) -> Int? {
        let current = anchor.flatMap(index(of:)) ?? selectedItems.last.flatMap { index(of: $0.id) }
        guard extending else { return current }
        return focus.flatMap(index(of:)) ?? current
    }

    public mutating func select(only id: UUID?) {
        selection = id.map { [$0] } ?? []
        anchor = id
        focus = nil
    }

    public mutating func setSelection(_ ids: Set<UUID>) {
        selection = ids.intersection(items.map(\.id))
        if let anchor, !selection.contains(anchor) { self.anchor = selectedItems.first?.id }
        if anchor == nil { anchor = selectedItems.first?.id }
        focus = nil
    }

    public mutating func selectAll() {
        selection = Set(items.map(\.id))
        if anchor == nil { anchor = items.first?.id }
        focus = nil
    }

    public mutating func clearSelection() {
        selection = []
        anchor = nil
        focus = nil
    }

    /// Finder-style click: plain click selects only the item, ⌘ toggles it,
    /// ⇧ selects the range from the anchor (⌘⇧ adds that range to the selection).
    public mutating func click(_ id: UUID, modifiers: FloatSelectionModifiers) {
        guard let target = index(of: id) else { return }
        if modifiers.contains(.extend), let anchor, let start = index(of: anchor) {
            let range = Set(items[min(start, target)...max(start, target)].map(\.id))
            selection = modifiers.contains(.toggle) ? selection.union(range) : range
            focus = id
            return
        }
        if modifiers.contains(.toggle) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            focus = nil
            return
        }
        select(only: id)
    }

    /// Rubber band over `hit` items, starting from `initial` (the selection at mouse-down).
    /// Plain: exactly the hit items. ⇧: union. ⌘: toggle the hit items.
    public mutating func rubberBand(hit: [UUID], initial: Set<UUID>, modifiers: FloatSelectionModifiers) {
        let hitSet = Set(hit)
        if modifiers.contains(.toggle) {
            selection = initial.symmetricDifference(hitSet)
        } else if modifiers.contains(.extend) {
            selection = initial.union(hitSet)
        } else {
            selection = hitSet
        }
        anchor = items.first { hitSet.contains($0.id) }?.id ?? anchor
        focus = nil
    }

    /// Type-to-select: first item whose name starts with `prefix` (case/diacritic-insensitive).
    public func firstItem(matching prefix: String) -> FloatItem? {
        guard !prefix.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        return items.first { $0.name.range(of: prefix, options: options) != nil }
    }

    // MARK: Keeping up with the file system

    public enum Check: Equatable, Sendable {
        /// File is where we think it is.
        case present
        /// File was moved or renamed; here is where it went.
        case moved(URL, bookmark: Data?)
        /// Deleted, trashed or otherwise gone.
        case missing
        /// Can't be checked right now: its volume is unmounted or unreachable.
        /// Not the same as gone; the item is kept and marked unavailable.
        case unavailable
    }

    /// Updates moved items, marks items on unreachable volumes, and drops missing ones.
    /// Returns true when anything changed.
    @discardableResult
    public mutating func refresh(_ check: (FloatItem) -> Check) -> Bool {
        var changed = false
        var gone: Set<UUID> = []
        for item in items {
            let result = check(item)
            if let i = index(of: item.id) {
                let unavailable = result == .unavailable
                if items[i].isUnavailable != unavailable {
                    items[i].isUnavailable = unavailable
                    changed = true
                }
            }
            switch result {
            case .present, .unavailable: break
            case .moved(let url, let bookmark):
                if let other = index(ofKey: FloatItem.key(for: url)), items[other].id != item.id {
                    gone.insert(item.id)   // moved onto a file we already hold
                } else {
                    updateURL(item.id, to: url, bookmark: bookmark)
                }
                changed = true
            case .missing:
                gone.insert(item.id)
                changed = true
            }
        }
        if !gone.isEmpty { remove(gone) }
        return changed
    }
}
