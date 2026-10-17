import AppKit
import Quartz

/// Borderless, non-activating panel: floats above normal windows on every Space
/// (and over full-screen apps) without stealing focus from the app you're in.
/// It still becomes key on click, so the keyboard (space for Quick Look, ⌘A, ⌫…) works.
final class FloatPanel: NSPanel {
    weak var controller: FloatController?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false            // moved by FloatController (edge docking needs the pointer)
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    // Main status keeps Quick Look attached to us while its panel is key.
    override var canBecomeMain: Bool { true }

    /// Tabs sit flush with screen edges; never let AppKit nudge the frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every window; only act on our own keystrokes.
        if isKeyWindow, event.modifierFlags.contains(.command), controller?.handleKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.escape()
    }

    override func becomeKey() {
        super.becomeKey()
        controller?.keyStateChanged()
    }

    override func resignKey() {
        super.resignKey()
        controller?.keyStateChanged()
    }

    // MARK: Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        controller?.hasQuickLookItems ?? false
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.endQuickLook(panel)
    }
}
