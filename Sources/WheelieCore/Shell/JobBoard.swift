import Foundation

/// State behind the progress HUD: which jobs are running, which finished ones
/// are still on screen, and when the next change is due. Pure and clock-free:
/// callers pass `now` and schedule one timer at `nextDeadline()`.
///
/// Rules:
/// - A job appears ("is revealed") once it has run for `showDelay`; quick jobs
///   never show (the wheel's hub already reports them).
/// - While anything is on screen, newly started jobs join right away.
/// - A finished job stays for `successLinger` / `failureLinger`, longer while
///   the pointer is over the HUD, then disappears; when nothing is left the HUD hides.
public struct JobBoard: Sendable {
    public enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)
    }

    /// What the user should hear when a job ends.
    public enum Feedback: Equatable, Sendable {
        case success, failure
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let sources: [URL]
        public let startedAt: Date
        public internal(set) var state: State = .running
        public internal(set) var outputs: [URL] = []
        public internal(set) var finishedAt: Date?
        public internal(set) var revealedAt: Date?
        public internal(set) var expiresAt: Date?

        public var isRunning: Bool { state == .running }
        public var isRevealed: Bool { revealedAt != nil }

        public var error: String? {
            if case .failed(let message) = state { return message }
            return nil
        }

        /// Files to select in Finder when the entry is clicked: outputs, else sources.
        public var revealTargets: [URL] { outputs.isEmpty ? sources : outputs }

        /// "photo.png", "3 files", or "" when there are no sources.
        public var sourceSummary: String {
            switch sources.count {
            case 0: return ""
            case 1: return sources[0].lastPathComponent
            default: return "\(sources.count) files"
            }
        }

        /// Chime only when files were written (a job that just opened an editor
        /// window also "succeeds"); always signal failures.
        public var feedback: Feedback? {
            switch state {
            case .running: return nil
            case .succeeded: return outputs.isEmpty ? nil : .success
            case .failed: return .failure
            }
        }
    }

    public struct Timing: Sendable {
        public var showDelay: TimeInterval
        public var successLinger: TimeInterval
        public var failureLinger: TimeInterval
        /// Extra time finished entries stay after the pointer leaves the HUD.
        public var hoverGrace: TimeInterval
        /// At most this many finished entries are kept on screen.
        public var maxFinished: Int

        public init(showDelay: TimeInterval = 1.2, successLinger: TimeInterval = 4,
                    failureLinger: TimeInterval = 8, hoverGrace: TimeInterval = 1.5, maxFinished: Int = 5) {
            self.showDelay = showDelay
            self.successLinger = successLinger
            self.failureLinger = failureLinger
            self.hoverGrace = hoverGrace
            self.maxFinished = maxFinished
        }
    }

    public var timing: Timing
    /// All tracked jobs in start order (running ones and finished ones still shown).
    public private(set) var entries: [Entry] = []
    public private(set) var isHovering = false
    private var pendingOutputs: [URL] = []

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Entries the HUD shows, oldest first.
    public var visibleEntries: [Entry] { entries.filter(\.isRevealed) }
    public var isPanelVisible: Bool { entries.contains(where: \.isRevealed) }
    public var runningCount: Int { entries.filter(\.isRunning).count }

    public func entry(id: UUID) -> Entry? { entries.first { $0.id == id } }

    // MARK: Events

    public mutating func start(id: UUID, title: String, sources: [URL], at now: Date) {
        guard entry(id: id) == nil else { return }
        entries.append(Entry(id: id, title: title, sources: sources, startedAt: now))
        advance(to: now)
    }

    /// `AppServices.run` announces a job's files right before it posts the job's
    /// finish, so the next successful `finish` claims them.
    public mutating func outputsProduced(_ urls: [URL]) {
        pendingOutputs += urls
    }

    /// Marks a job finished. Returns the finished entry (also when it was too quick
    /// to be shown and is dropped right away), or nil for an unknown id.
    @discardableResult
    public mutating func finish(id: UUID, error: String?, at now: Date) -> Entry? {
        let outputs = pendingOutputs
        pendingOutputs = []
        advance(to: now)
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isRunning else { return nil }
        var entry = entries[index]
        entry.finishedAt = now
        if let error {
            entry.state = .failed(error)
            entry.expiresAt = now.addingTimeInterval(timing.failureLinger)
        } else {
            entry.state = .succeeded
            entry.expiresAt = now.addingTimeInterval(timing.successLinger)
        }
        entry.outputs = error == nil ? outputs : []
        if entry.isRevealed {
            entries[index] = entry
        } else {
            entries.remove(at: index)
        }
        trimFinished()
        return entry
    }

    /// Pointer entered or left the HUD. Finished entries don't expire while hovered.
    public mutating func setHovering(_ hovering: Bool, at now: Date) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if !hovering {
            let earliest = now.addingTimeInterval(timing.hoverGrace)
            for i in entries.indices where !entries[i].isRunning {
                if let expiry = entries[i].expiresAt, expiry < earliest { entries[i].expiresAt = earliest }
            }
        }
        advance(to: now)
    }

    /// Removes a finished entry (the user clicked it or its close button).
    public mutating func dismiss(id: UUID) {
        entries.removeAll { $0.id == id && !$0.isRunning }
    }

    // MARK: Time

    /// Applies time-based changes: reveals long-running jobs, expires finished ones.
    public mutating func advance(to now: Date) {
        for i in entries.indices where entries[i].isRunning && !entries[i].isRevealed
            && now.timeIntervalSince(entries[i].startedAt) >= timing.showDelay {
            entries[i].revealedAt = now
        }
        if isPanelVisible {
            for i in entries.indices where entries[i].isRunning && !entries[i].isRevealed {
                entries[i].revealedAt = now
            }
        }
        if !isHovering {
            entries.removeAll { entry in
                guard !entry.isRunning, let expiry = entry.expiresAt else { return false }
                return expiry <= now
            }
        }
        if !isPanelVisible { isHovering = false }
    }

    /// When `advance` would next change something; nil when nothing is pending.
    public func nextDeadline() -> Date? {
        var deadlines: [Date] = []
        for entry in entries {
            if entry.isRunning {
                if !entry.isRevealed { deadlines.append(entry.startedAt.addingTimeInterval(timing.showDelay)) }
            } else if !isHovering, let expiry = entry.expiresAt {
                deadlines.append(expiry)
            }
        }
        return deadlines.min()
    }

    private mutating func trimFinished() {
        let finished = entries.filter { !$0.isRunning }
        guard finished.count > timing.maxFinished else { return }
        let drop = Set(finished.prefix(finished.count - timing.maxFinished).map(\.id))
        entries.removeAll { drop.contains($0.id) }
    }
}
