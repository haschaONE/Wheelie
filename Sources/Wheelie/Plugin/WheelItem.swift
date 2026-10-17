import AppKit
import WheelieCore

/// Inner ring = output formats, outer ring = tools and file actions.
enum WheelRing: Int, Comparable {
    case inner, outer
    static func < (a: WheelRing, b: WheelRing) -> Bool { a.rawValue < b.rawValue }
}

enum WheelOutcome {
    /// Files written; recorded in history and announced via `.wheelieOutputsProduced`.
    case outputs([URL])
    /// Short confirmation shown in the wheel hub, e.g. "Copied 3 paths".
    case message(String)
    /// Nothing to report, e.g. an editor window was opened.
    case none
}

/// One petal on the wheel. Features return these from `wheelItems()`.
struct WheelItem: Identifiable {
    /// Stable, unique, dotted: "<feature>.<tool>", e.g. "video.trim".
    let id: String
    let label: String
    /// SF Symbol name.
    let symbol: String
    var ring: WheelRing = .outer
    /// Sort key within the ring; lower first.
    var order: Int = 0
    /// Whether this item applies to the dragged files. Keep it cheap: it runs on every drag.
    let accepts: @MainActor ([URL]) -> Bool
    /// Runs the item. Editors open their window and return `.none` right away.
    let perform: @MainActor ([URL]) async throws -> WheelOutcome
}

extension Collection where Element == URL {
    /// True when non-empty and every file is one of `kinds`.
    func allAre(_ kinds: FileKind...) -> Bool {
        !isEmpty && allSatisfy { kinds.contains(FileKind(url: $0)) }
    }

    var allFolders: Bool {
        !isEmpty && allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
