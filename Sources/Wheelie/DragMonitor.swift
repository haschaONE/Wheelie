import AppKit
import Carbon.HIToolbox
import OSLog
import WheelieCore

private let log = Logger(subsystem: "local.wheelie.Wheelie", category: "drag")

/// Detects file drags started in any app by polling global input state, the
/// same approach Tangerine's DragGestureMonitor uses: no event taps, no
/// Accessibility permission.
///
/// - While idle it samples the drag pasteboard's changeCount, so it knows the
///   count from *before* the mouse went down.
/// - While the button is held it polls fast; a changed count with file URLs on
///   the drag pasteboard means a file drag is in progress.
/// - A wheel opens when one of its keys is tapped during
///   that drag, is held when the drag begins, or was tapped just before it;
///   tapping another wheel's key switches wheels until the drop.
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
    private var modifiersAtMouseDown: NSEvent.ModifierFlags = []
    /// A wheel key tapped shortly before the drag began still opens that wheel.
    private var lastTap: (mode: WheelMode, time: TimeInterval)?
    private let tapGrace: TimeInterval = 0.6

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
            modifiersAtMouseDown = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
            triggered = false
            setActive(true)
        }

        let modifiers = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
        var dragJustStarted = false
        if buttonDown, dragFiles == nil, let baseline = changeCountBeforeMouseDown, board.changeCount != baseline {
            let urls = (board.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                dragFiles = urls
                dragJustStarted = true
                log.notice("file drag detected: \(urls.count) item(s), modifiers \(modifiers.rawValue), at mouse-down \(self.modifiersAtMouseDown.rawValue)")
            }
        }
        let newlyPressed = modifiers.subtracting(previousModifiers)
        if buttonDown, let files = dragFiles {
            var mode: WheelMode?
            if dragJustStarted {
                // Held when the drag begins counts (press-then-drag), except ⌘ held since the click:
                // that's Finder's ⌘-click multi-select / ⌘-drag move, not a request for the wheel.
                let held = modifiers.subtracting(modifiersAtMouseDown.intersection(.command))
                mode = triggers.first(where: { held.contains($0.0) })?.1
                if mode == nil, let tap = lastTap, ProcessInfo.processInfo.systemUptime - tap.time <= tapGrace {
                    mode = tap.mode
                }
            } else {
                // Tapping a key mid-drag opens or switches wheels.
                mode = triggers.first(where: { newlyPressed.contains($0.0) })?.1
            }
            if let mode {
                log.notice("opening \(mode.rawValue, privacy: .public) wheel")
                triggered = true
                lastTap = nil
                onTrigger?(mode, files, NSEvent.mouseLocation)
            }
        } else if let mode = triggers.first(where: { newlyPressed.contains($0.0) })?.1 {
            lastTap = (mode, ProcessInfo.processInfo.systemUptime)
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
