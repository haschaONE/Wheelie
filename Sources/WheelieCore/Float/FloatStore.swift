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

    /// The saved item as it was, without touching the file system (cheap; check it later).
    public static func unverifiedItem(from record: FloatSnapshot.Record) -> FloatItem {
        FloatItem(url: URL(fileURLWithPath: record.path), bookmark: record.bookmark)
    }

    /// Restores an item: the saved path when the file is still there, else wherever its
    /// bookmark leads (renamed/moved), kept but marked unavailable while its volume is
    /// unmounted, else nil (deleted or trashed).
    public static func item(from record: FloatSnapshot.Record,
                            volumeIsMounted: (URL) -> Bool = FloatStore.isMountedVolume) -> FloatItem? {
        let probe = unverifiedItem(from: record)
        switch check(probe, volumeIsMounted: volumeIsMounted) {
        case .present: return probe
        case .moved(let moved, let bookmark): return FloatItem(url: moved, bookmark: bookmark ?? record.bookmark)
        case .unavailable: return FloatItem(url: probe.url, bookmark: record.bookmark, isUnavailable: true)
        case .missing: return nil
        }
    }

    /// Where an item's file is now. Files moved to the Trash count as missing. A file whose
    /// volume is unmounted (ejected disk, network share not connected yet) or that can't be
    /// looked up for another reason than "no such file" is `.unavailable`, not missing.
    /// May block on slow or unreachable volumes: call it off the main thread.
    public static func check(_ item: FloatItem, fileManager: FileManager = .default,
                             volumeIsMounted: (URL) -> Bool = FloatStore.isMountedVolume) -> FloatGroup.Check {
        switch lookUp(item.url.path) {
        case .exists: return .present
        case .unreachable: return .unavailable
        case .absent: break
        }
        if let data = item.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale),
               fileManager.fileExists(atPath: resolved.path) {
                if isInTrash(resolved) { return .missing }
                let url = resolved.standardizedFileURL
                if url.path == item.url.standardizedFileURL.path { return .present }
                return .moved(url, bookmark: stale ? bookmark(for: url) : data)
            }
        }
        if let volume = volumeURL(for: item), !volumeIsMounted(volume) { return .unavailable }
        return .missing
    }

    private enum Lookup { case exists, absent, unreachable }

    /// `stat` the path: only "no such file" style errors mean the file is gone; anything
    /// else (timeouts, I/O errors on a dropped network share, permissions) means unknown.
    private static func lookUp(_ path: String) -> Lookup {
        var info = stat()
        if stat(path, &info) == 0 { return .exists }
        switch errno {
        case ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG: return .absent
        default: return .unreachable
        }
    }

    /// The volume an item lives on: as recorded in its bookmark, else `/Volumes/<name>`
    /// from its path. Nil when unknown (then the file is on the startup disk, or treated so).
    public static func volumeURL(for item: FloatItem) -> URL? {
        if let data = item.bookmark,
           let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: data)?.volume {
            return volume
        }
        let components = item.url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(components[2], isDirectory: true)
    }

    /// True when a volume is mounted at `volume` right now (reads the mount table; doesn't
    /// touch the volume itself, so it's quick even for a dead network share).
    public static func isMountedVolume(_ volume: URL) -> Bool {
        let path = volume.standardizedFileURL.path
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return mounted.contains { $0.standardizedFileURL.path == path }
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

    /// Copies `source` next to itself under a Finder-style duplicate name and returns the copy.
    /// A copy that fails partway is removed, so no incomplete "copy" is left behind.
    /// Can take long (no clone on non-APFS volumes, big folders): call it off the main thread.
    public static func duplicate(_ source: URL, fileManager: FileManager = .default) throws -> URL {
        var attempts = 0
        while true {
            let destination = duplicateURL(for: source, fileManager: fileManager)
            do {
                try fileManager.copyItem(at: source, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists && attempts < 5 {
                attempts += 1   // someone else took that name meanwhile: pick the next one
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw error     // not ours; leave it alone
            } catch {
                // The name was free, so whatever is there now is our partial copy.
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }
}
