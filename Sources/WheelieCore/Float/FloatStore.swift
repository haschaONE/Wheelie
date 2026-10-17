import CoreGraphics
import Foundation

/// What is saved for one open Float so it comes back after relaunch.
public struct FloatSnapshot: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var path: String
        public var bookmark: Data?
        public init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    public var id: UUID
    /// Frame while floating (or the last floating frame while docked).
    public var frame: CGRect
    /// Docked edge; nil while floating.
    public var edge: FloatEdge?
    /// Vertical centre of the docked tab.
    public var dockCenterY: CGFloat?
    /// `CGDirectDisplayID` of the screen it was on.
    public var displayID: UInt32?
    public var viewMode: FloatViewMode
    public var items: [Record]

    public init(id: UUID, frame: CGRect, edge: FloatEdge? = nil, dockCenterY: CGFloat? = nil,
                displayID: UInt32? = nil, viewMode: FloatViewMode = .icons, items: [Record]) {
        self.id = id
        self.frame = frame
        self.edge = edge
        self.dockCenterY = dockCenterY
        self.displayID = displayID
        self.viewMode = viewMode
        self.items = items
    }
}

/// Persistence and file tracking for Floats.
public enum FloatStore {
    public static let defaultsKey = "floats.v1"

    public static func encode(_ snapshots: [FloatSnapshot]) throws -> Data {
        try JSONEncoder().encode(snapshots)
    }

    /// Corrupt or unknown data yields no Floats rather than an error.
    public static func decode(_ data: Data) -> [FloatSnapshot] {
        (try? JSONDecoder().decode([FloatSnapshot].self, from: data)) ?? []
    }

    public static func save(_ snapshots: [FloatSnapshot], to defaults: UserDefaults = .standard,
                            key: String = defaultsKey) {
        if snapshots.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? encode(snapshots) {
            defaults.set(data, forKey: key)
        }
    }

    public static func load(from defaults: UserDefaults = .standard, key: String = defaultsKey) -> [FloatSnapshot] {
        defaults.data(forKey: key).map(decode) ?? []
    }

    // MARK: Items

    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func record(for item: FloatItem) -> FloatSnapshot.Record {
        FloatSnapshot.Record(path: item.url.path, bookmark: item.bookmark ?? bookmark(for: item.url))
    }

    /// Restores an item: the saved path when the file is still there, else wherever its
    /// bookmark leads (renamed/moved), else nil (deleted or trashed).
    public static func item(from record: FloatSnapshot.Record) -> FloatItem? {
        let url = URL(fileURLWithPath: record.path)
        let probe = FloatItem(url: url, bookmark: record.bookmark)
        switch check(probe) {
        case .present: return probe
        case .moved(let moved, let bookmark): return FloatItem(url: moved, bookmark: bookmark ?? record.bookmark)
        case .missing: return nil
        }
    }

    /// Where an item's file is now. Files moved to the Trash count as missing.
    public static func check(_ item: FloatItem, fileManager: FileManager = .default) -> FloatGroup.Check {
        if fileManager.fileExists(atPath: item.url.path) { return .present }
        guard let data = item.bookmark else { return .missing }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              fileManager.fileExists(atPath: resolved.path),
              !isInTrash(resolved)
        else { return .missing }
        let url = resolved.standardizedFileURL
        if url.path == item.url.standardizedFileURL.path { return .present }
        return .moved(url, bookmark: stale ? bookmark(for: url) : data)
    }

    /// True for anything inside a Trash folder (home Trash or a volume's .Trashes).
    public static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".Trashes") { return true }
        if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
           url.standardizedFileURL.path.hasPrefix(trash.standardizedFileURL.path + "/") {
            return true
        }
        // ~/.Trash when the lookup above is unavailable.
        if let i = components.firstIndex(of: ".Trash"), i >= 2, components[i - 2] == "Users" { return true }
        return false
    }

    /// Finder-style duplicate name next to the original: "name copy.ext", "name copy 2.ext", ...
    public static func duplicateURL(for source: URL, fileManager: FileManager = .default) -> URL {
        let dir = source.deletingLastPathComponent()
        // Plain folders keep dots in their name ("v1.2 copy"); files and packages split the extension.
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let plainFolder = values?.isDirectory == true && values?.isPackage != true
        let ext = plainFolder ? "" : source.pathExtension
        let base = plainFolder ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        func candidate(_ suffix: String) -> URL {
            let name = base + suffix
            return dir.appendingPathComponent(ext.isEmpty ? name : name + "." + ext)
        }
        var url = candidate(" copy")
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = candidate(" copy \(n)")
            n += 1
        }
        return url
    }
}
