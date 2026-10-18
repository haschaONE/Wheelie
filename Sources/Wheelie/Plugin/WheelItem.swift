import AppKit
import WheelieCore

/// Ring within a wheel. Each wheel (WheelMode) now shows a single ring, drawn as .inner;
/// `ring` still tells formats (.inner) from tools/actions (.outer) when assigning wheels.
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

extension WheelItem {
    /// Tangerine's file actions; everything else on the outer ring is a file tool.
    static let actionIDs: Set<String> = [
        "fileactions.airdrop", "float.add", "fileactions.copyFiles", "fileactions.move",
        "fileactions.copyPath", "fileactions.terminal",
    ]

    /// Which wheel this item appears on: ⇧ formats, ⌘ tools, ⌃ actions (by default).
    var mode: WheelMode {
        if ring == .inner { return .convert }
        return Self.actionIDs.contains(id) ? .actions : .tools
    }
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
