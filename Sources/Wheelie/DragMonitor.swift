import AppKit
import Carbon.HIToolbox
import WheelieCore

/// Detects file drags started in any app by polling global input state, the
/// same approach Tangerine's DragGestureMonitor uses: no event taps, no
/// Accessibility permission.
///
/// - While idle it samples the drag pasteboard's changeCount, so it knows the
///   count from *before* the mouse went down.
/// - While the button is held it polls fast; a changed count with file URLs on
///   the drag pasteboard means a file drag is in progress.
/// - A wheel opens when one of its keys is tapped during
///   that drag; tapping another wheel's key switches wheels until the drop.
@MainActor
final class DragMonitor {
    /// A wheel key was tapped during a file drag (or was already down when the drag began).
    var onTrigger: ((_ mode: WheelMode, _ files: [URL], _ at: NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Key → wheel, Tangerine-style (⇧ formats, ⌘ tools, ⌃ actions by default).
    var triggers: [(NSEvent.ModifierFlags, WheelMode)] = [(.shift, .convert)]

    private let idleInterval: TimeInterval = 0.08
    private let activeInterval: TimeInterval = 1.0 / 60
    private var timer: Timer?
    private var isPollingActively = false
    private var wasPrimaryButtonDown = false
    private var wasEscapeDown = false
    private var lastObservedChangeCount = NSPasteboard(name: .drag).changeCount
    private var changeCountBeforeMouseDown: Int?
    private var triggered = false
    /// Files of the drag in progress, read once it's detected; nil while no file drag is active.
    private var dragFiles: [URL]?
    private var previousModifiers: NSEvent.ModifierFlags = []

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        schedule(interval: idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        triggered = false
        wasPrimaryButtonDown = false
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func setActive(_ active: Bool) {
        guard active != isPollingActively else { return }
        isPollingActively = active
        schedule(interval: active ? activeInterval : idleInterval)
    }

    private func tick() {
        let board = NSPasteboard(name: .drag)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0

        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
        if escapeDown && !wasEscapeDown { onEscape?() }
        wasEscapeDown = escapeDown

        if buttonDown && !wasPrimaryButtonDown {
            // Baseline from the last idle sample, taken before this press.
            changeCountBeforeMouseDown = lastObservedChangeCount
            triggered = false
            setActive(true)
        }

        let modifiers = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
        var dragJustStarted = false
        if buttonDown, dragFiles == nil, let baseline = changeCountBeforeMouseDown, board.changeCount != baseline {
            let urls = (board.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty { dragFiles = urls; dragJustStarted = true }
        }
        if buttonDown, let files = dragFiles {
            // A tap = the key going down after the drag began. Keys already held then (⌘/⇧-click
            // multi-selection in Finder) don't count until released and pressed again.
            let pressed = dragJustStarted ? [] : modifiers.subtracting(previousModifiers)
            if let (_, mode) = triggers.first(where: { pressed.contains($0.0) }) {
                triggered = true
                onTrigger?(mode, files, NSEvent.mouseLocation)
            }
        }
        previousModifiers = modifiers

        if !buttonDown && wasPrimaryButtonDown {
            if triggered { onDragEnded?() }
            triggered = false
            dragFiles = nil
            changeCountBeforeMouseDown = nil
            setActive(false)
        }

        if !buttonDown { lastObservedChangeCount = board.changeCount }
        wasPrimaryButtonDown = buttonDown
    }
}
