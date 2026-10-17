import AppKit
import Carbon.HIToolbox

/// Detects file drags started in any app by polling global input state, the
/// same approach Tangerine's DragGestureMonitor uses: no event taps, no
/// Accessibility permission.
///
/// - While idle it samples the drag pasteboard's changeCount, so it knows the
///   count from *before* the mouse went down.
/// - While the button is held it polls fast; a changed count with file URLs on
///   the drag pasteboard means a file drag is in progress.
/// - The wheel triggers only once the trigger modifier (Shift) is held during
///   that drag; it can be pressed at any point mid-drag.
@MainActor
final class DragMonitor {
    var onTrigger: ((_ files: [URL], _ at: NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onEscape: (() -> Void)?
    var triggerModifier: NSEvent.ModifierFlags = .shift

    private let idleInterval: TimeInterval = 0.08
    private let activeInterval: TimeInterval = 1.0 / 60
    private var timer: Timer?
    private var isPollingActively = false
    private var wasPrimaryButtonDown = false
    private var wasEscapeDown = false
    private var lastObservedChangeCount = NSPasteboard(name: .drag).changeCount
    private var changeCountBeforeMouseDown: Int?
    private var triggered = false

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

        if buttonDown, !triggered, let baseline = changeCountBeforeMouseDown,
           board.changeCount != baseline,
           NSEvent.modifierFlags.contains(triggerModifier) {
            let urls = (board.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                triggered = true
                onTrigger?(urls, NSEvent.mouseLocation)
            }
        }

        if !buttonDown && wasPrimaryButtonDown {
            if triggered { onDragEnded?() }
            triggered = false
            changeCountBeforeMouseDown = nil
            setActive(false)
        }

        if !buttonDown { lastObservedChangeCount = board.changeCount }
        wasPrimaryButtonDown = buttonDown
    }
}
