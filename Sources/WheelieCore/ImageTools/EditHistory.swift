import Foundation

/// Snapshot undo/redo for the image editors.
///
/// Call `checkpoint(_:group:)` with the state *before* each edit. Consecutive checkpoints with the
/// same non-nil `group` (e.g. "nudge-<id>" for a run of arrow-key nudges of one item) are coalesced
/// into one undo step; any other checkpoint, undo or redo ends the group.
public struct EditHistory<State> {
    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    private var group: String?
    public let limit: Int

    public init(limit: Int = 200) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records `current` as the state to return to, unless it continues the open `group`.
    public mutating func checkpoint(_ current: State, group: String? = nil) {
        if let group, group == self.group { return }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        self.group = group
    }

    /// The state to restore, or nil when there's nothing to undo. `current` becomes redoable.
    public mutating func undo(from current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        group = nil
        return previous
    }

    /// The state to restore, or nil when there's nothing to redo. `current` becomes undoable.
    public mutating func redo(from current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        group = nil
        return next
    }
}
