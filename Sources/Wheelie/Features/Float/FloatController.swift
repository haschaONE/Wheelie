import AppKit
import Quartz
import WheelieCore

extension NSScreen {
    var floatDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Screen under a point, else the main screen.
    static func floatScreen(containing point: NSPoint) -> NSScreen {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens[0]
    }

    /// Edges of this display a Float may dock to at height `y` (not shared with a neighbour).
    func floatOuterEdges(at y: CGFloat) -> Set<FloatEdge> {
        FloatDocking.outerEdges(of: frame, others: NSScreen.screens.map(\.frame), at: y)
    }

    /// Screen showing most of a rect, else the main screen.
    static func floatScreen(for rect: NSRect) -> NSScreen {
        let best = screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        if let best, best.frame.intersects(rect) { return best }
        return floatScreen(containing: NSPoint(x: rect.midX, y: rect.midY))
    }
}

/// One Float: its files, its panel, and how it sits on screen
/// (floating, or attached to a screen edge as a collapsed / expanded tab).
@MainActor
final class FloatController: NSObject, NSMenuDelegate {
    enum Placement: Equatable {
        case floating
        case docked(FloatEdge)
    }

    let id: UUID
    let panel = FloatPanel()
    private(set) var group: FloatGroup
    private(set) var viewMode: FloatViewMode
    private(set) var placement: Placement = .floating
    /// Docked Floats are collapsed to a tab unless hovered/clicked open.
    private(set) var isExpanded = true
    private var root: FloatRootView!

    /// Last frame while floating; also where a detached Float goes back to.
    private var floatingFrame: NSRect = .zero
    private var dockCenterY: CGFloat = 0
    private var displayID: CGDirectDisplayID?

    // Moving
    private var grabOffset = NSPoint.zero
    private(set) var isMoving = false
    private var isTransitioning = false
    private var latestPointer: NSPoint?
    /// A move ended mid-transition; settle on screen once it finishes.
    private var needsSettle = false

    // Interaction state that keeps a docked Float open
    private(set) var isDraggingFiles = false
    private var isMenuOpen = false
    private var isDropHovering = false
    private var hadItems = false
    private(set) var isClosing = false

    private var expandWork: DispatchWorkItem?
    private var watchTimer: Timer?
    private var outsideSince: Date?

    private let quickLook = FloatQuickLookSource()
    private var ownsQuickLook = false
    private var sharePicker: NSSharingServicePicker?
    private var typeBuffer = ""
    private var lastTypeTime = Date.distantPast

    var layout: FloatLayout { FloatLayout(count: group.count, mode: viewMode) }
    var dockedEdge: FloatEdge? {
        if case .docked(let edge) = placement { return edge }
        return nil
    }
    var isCollapsed: Bool { dockedEdge != nil && !isExpanded }

    init(id: UUID = UUID(), items: [FloatItem] = [], viewMode: FloatViewMode = .icons) {
        self.id = id
        self.group = FloatGroup(items: items)
        self.viewMode = viewMode
        super.init()
        root = FloatRootView(controller: self)
        panel.controller = self
        panel.contentView = root
        hadItems = !group.isEmpty
    }

    // MARK: Placement

    private var screen: NSScreen {
        if let displayID, let match = NSScreen.screens.first(where: { $0.floatDisplayID == displayID }) {
            return match
        }
        return NSScreen.floatScreen(for: panel.frame)
    }

    /// Floating, centred on `point`, avoiding other Floats' spots.
    func placeFloating(centeredOn point: NSPoint, avoiding others: [NSRect]) {
        let visible = NSScreen.floatScreen(containing: point).visibleFrame
        let frame = FloatDocking.frame(centeredOn: point, size: layout.panelSize, visibleFrame: visible)
        floatingFrame = FloatDocking.cascade(frame, avoiding: others, visibleFrame: visible)
        placement = .floating
        isExpanded = true
    }

    /// Floating with its top edge at `top` (under the menu bar), centred on `x`.
    func placeFloating(top: NSPoint, avoiding others: [NSRect]) {
        let visible = NSScreen.floatScreen(containing: top).visibleFrame
        let size = layout.panelSize
        let frame = FloatDocking.clamp(NSRect(x: top.x - size.width / 2, y: visible.maxY - 8 - size.height,
                                              width: size.width, height: size.height), to: visible)
        floatingFrame = FloatDocking.cascade(frame, avoiding: others, visibleFrame: visible)
        placement = .floating
        isExpanded = true
    }

    private func targetFrame() -> NSRect {
        let size = layout.panelSize
        switch placement {
        case .floating:
            let frame = NSRect(x: floatingFrame.minX, y: floatingFrame.maxY - size.height,
                               width: size.width, height: size.height)
            return isMoving ? frame : FloatDocking.clamp(frame, to: NSScreen.floatScreen(for: frame).visibleFrame)
        case .docked(let edge):
            let visible = screen.visibleFrame
            return isExpanded
                ? FloatDocking.attachedFrame(edge: edge, centerY: dockCenterY, size: size, visibleFrame: visible)
                : FloatDocking.tabFrame(edge: edge, centerY: dockCenterY, visibleFrame: visible)
        }
    }

    /// Lays out content for the current state and moves the panel there.
    private func apply(animated: Bool, duration: TimeInterval = 0.24, completion: (() -> Void)? = nil) {
        let frame = targetFrame()
        if placement == .floating { floatingFrame = frame }
        let edge = dockedEdge
        let showsTab = edge != nil && !isExpanded
        root.panelSize = layout.panelSize
        root.dockEdge = edge
        root.isTab = showsTab
        root.tab.edge = edge ?? .right
        reloadContent()
        root.expanded.isHidden = false
        root.tab.isHidden = false
        let expandedAlpha: CGFloat = showsTab ? 0 : 1
        let tabAlpha: CGFloat = showsTab ? 1 : 0

        let changes = panel.frame != frame || root.expanded.alphaValue != expandedAlpha
            || root.tab.alphaValue != tabAlpha
        guard animated, panel.isVisible, changes else {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            root.layoutChildren()
            root.expanded.alphaValue = expandedAlpha
            root.tab.alphaValue = tabAlpha
            finishTransition()
            completion?()
            return
        }
        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            root.expanded.animator().alphaValue = expandedAlpha
            root.tab.animator().alphaValue = tabAlpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTransitioning = false
                self.finishTransition()
                if self.isMoving, let pointer = self.latestPointer {
                    self.moved(to: pointer)
                } else if self.needsSettle {
                    self.needsSettle = false
                    self.apply(animated: true)
                }
                completion?()
            }
        })
    }

    private func finishTransition() {
        root.expanded.isHidden = root.isTab
        root.tab.isHidden = !root.isTab
        panel.invalidateShadow()
        updateWatch()
    }

    private func reloadContent() {
        let layout = self.layout
        root.grid.reload(items: group.items, selection: group.selection, layout: layout,
                         viewport: layout.viewportSize)
        root.scrollView.hasVerticalScroller = layout.scrolls
        let screen = self.screen
        root.header.update(count: group.count, mode: viewMode,
                           collapseEdge: dockedEdge ?? FloatDocking.collapseEdge(
                               for: panel.frame, visibleFrame: screen.visibleFrame,
                               allowed: screen.floatOuterEdges(at: panel.frame.midY)))
        root.tab.update(items: group.items)
    }

    func show(animated: Bool) {
        apply(animated: false)
        guard animated else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        let final = panel.frame
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: -10), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    /// Brings the Float forward; a collapsed tab wiggles out so it's noticed.
    func bringForward() {
        panel.orderFrontRegardless()
        nudge()
    }

    private func nudge() {
        guard let edge = dockedEdge, !isExpanded, panel.isVisible, !isTransitioning, !isMoving else { return }
        let base = targetFrame()
        var out = base
        out.size.width += 12
        if edge == .right { out.origin.x -= 12 }
        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(out, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.5, 1)
                    self.panel.animator().setFrame(self.targetFrame(), display: true)
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.isTransitioning = false
                        self?.panel.invalidateShadow()
                    }
                })
            }
        })
    }

    func screenParametersChanged() {
        guard !isClosing else { return }
        if dockedEdge != nil {
            if let displayID, !NSScreen.screens.contains(where: { $0.floatDisplayID == displayID }) {
                self.displayID = (NSScreen.main ?? NSScreen.screens.first)?.floatDisplayID
            }
        } else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(floatingFrame) }) {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            floatingFrame = FloatDocking.frame(centeredOn: NSPoint(x: visible.midX, y: visible.midY),
                                               size: layout.panelSize, visibleFrame: visible)
        }
        apply(animated: false)
    }

    // MARK: Moving & docking

    func moveBegan(at point: NSPoint) {
        expandWork?.cancel()
        isMoving = true
        latestPointer = point
        let frame = panel.frame
        grabOffset = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        FloatManager.shared.touch(self)
    }

    func moved(to point: NSPoint) {
        latestPointer = point
        guard isMoving, !isTransitioning else { return }
        switch placement {
        case .floating:
            let size = panel.frame.size
            let proposed = NSRect(x: point.x - grabOffset.x, y: point.y - grabOffset.y,
                                  width: size.width, height: size.height)
            let pointerScreen = NSScreen.floatScreen(containing: point)
            if let edge = FloatDocking.decision(cursor: point, frame: proposed,
                                                visibleFrame: pointerScreen.visibleFrame, current: nil,
                                                allowed: pointerScreen.floatOuterEdges(at: point.y)) {
                floatingFrame = FloatDocking.clamp(proposed, to: pointerScreen.visibleFrame)
                displayID = pointerScreen.floatDisplayID
                placement = .docked(edge)
                isExpanded = false
                dockCenterY = point.y
                endQuickLookIfOwner()
                regrab(at: point)
                feedback()
                apply(animated: true, duration: 0.22)
            } else {
                panel.setFrameOrigin(proposed.origin)
                floatingFrame = proposed
            }
        case .docked(let edge):
            let visible = screen.visibleFrame
            if FloatDocking.decision(cursor: point, frame: panel.frame, visibleFrame: visible, current: edge) == nil {
                placement = .floating
                isExpanded = true
                displayID = nil
                floatingFrame = FloatDocking.detachedFrame(cursor: point, size: layout.panelSize,
                                                           headerHeight: FloatLayout.headerHeight)
                regrab(at: point)
                feedback()
                apply(animated: true, duration: 0.22)
            } else {
                let height = panel.frame.height
                dockCenterY = FloatDocking.clampedCenterY(point.y - grabOffset.y + height / 2, height: height,
                                                          visibleFrame: visible)
                panel.setFrame(targetFrame(), display: true)
            }
        }
    }

    /// Keeps the pointer at the same spot of the panel's new frame.
    private func regrab(at point: NSPoint) {
        let frame = targetFrame()
        grabOffset = NSPoint(x: min(max(point.x - frame.minX, 0), frame.width),
                             y: min(max(point.y - frame.minY, 0), frame.height))
    }

    func moveEnded(at point: NSPoint) {
        moved(to: point)
        isMoving = false
        latestPointer = nil
        if isTransitioning { needsSettle = true } else { apply(animated: true) }   // settle on screen
        FloatManager.shared.setNeedsSave()
    }

    private func feedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func collapse() {
        switch placement {
        case .floating:
            let screen = NSScreen.floatScreen(for: panel.frame)
            displayID = screen.floatDisplayID
            dockCenterY = panel.frame.midY
            placement = .docked(FloatDocking.collapseEdge(for: panel.frame, visibleFrame: screen.visibleFrame,
                                                          allowed: screen.floatOuterEdges(at: panel.frame.midY)))
        case .docked:
            guard isExpanded else { return }
        }
        isExpanded = false
        endQuickLookIfOwner()
        apply(animated: true)
        FloatManager.shared.setNeedsSave()
    }

    func expand() {
        expandWork?.cancel()
        guard dockedEdge != nil, !isExpanded, !isClosing else { return }
        isExpanded = true
        outsideSince = nil
        apply(animated: true)
    }

    func toggleCollapsed() {
        if isCollapsed { expand() } else { collapse() }
    }

    func detach() {
        guard let edge = dockedEdge else { return }
        let frame = panel.frame
        let size = layout.panelSize
        let inset: CGFloat = 24
        let x = edge == .left ? frame.minX + inset : frame.maxX - inset - size.width
        floatingFrame = NSRect(x: x, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        placement = .floating
        isExpanded = true
        displayID = nil
        apply(animated: true)
        FloatManager.shared.setNeedsSave()
    }

    // MARK: Hover (docked Floats open on hover and close when the pointer leaves)

    func tabHoverChanged(_ inside: Bool) {
        expandWork?.cancel()
        guard inside, isCollapsed, !isMoving else { return }
        scheduleExpand(after: 0.3)
    }

    func tabPressed() { expandWork?.cancel() }

    func dropHoverChanged(_ hovering: Bool) {
        guard isDropHovering != hovering else { return }
        isDropHovering = hovering
        expandWork?.cancel()
        if hovering, isCollapsed { scheduleExpand(after: 0.45) }   // spring-load
    }

    private func scheduleExpand(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isMoving, NSEvent.pressedMouseButtons == 0 || self.isDropHovering else { return }
                self.expand()
            }
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateWatch() {
        let needed = dockedEdge != nil && isExpanded && !isClosing
        if needed, watchTimer == nil {
            outsideSince = nil
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchTimer = timer
        } else if !needed {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    private func watchTick() {
        guard dockedEdge != nil, isExpanded, !isClosing else { return updateWatch() }
        let inside = panel.frame.insetBy(dx: -18, dy: -18).contains(NSEvent.mouseLocation)
        let busy = isMoving || isTransitioning || isDraggingFiles || isMenuOpen || isDropHovering
            || NSEvent.pressedMouseButtons != 0 || quickLookVisible
        if inside || busy {
            outsideSince = nil
            return
        }
        let now = Date()
        if let since = outsideSince {
            if now.timeIntervalSince(since) > 0.45 {
                outsideSince = nil
                collapse()
            }
        } else {
            outsideSince = now
        }
    }

    // MARK: Files

    /// Adds files (duplicates are skipped). Returns how many were new.
    @discardableResult
    func add(_ urls: [URL], select: Bool = false) -> Int {
        let result = group.add(urls, bookmark: FloatStore.bookmark(for:))
        if select { group.setSelection(Set(result.added.map(\.id) + result.existing)) }
        if !group.isEmpty { hadItems = true }
        contentChanged()
        if let first = result.added.first?.id ?? result.existing.first { root.grid.scrollToItem(first) }
        if isCollapsed { nudge() }
        FloatManager.shared.touch(self)
        return result.added.count
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        group.remove(ids)
        if group.isEmpty, hadItems {
            close()
            return
        }
        contentChanged()
    }

    func remove(urls: [URL]) {
        let keys = Set(urls.map(FloatItem.key(for:)))
        remove(ids: Set(group.items.filter { keys.contains(FloatItem.key(for: $0.url)) }.map(\.id)))
    }

    func reorder(_ urls: [URL], to index: Int) {
        let keys = Set(urls.map(FloatItem.key(for:)))
        let ids = Set(group.items.filter { keys.contains(FloatItem.key(for: $0.url)) }.map(\.id))
        group.move(ids, to: index)
        contentChanged(animated: false)
    }

    private func contentChanged(animated: Bool = true) {
        apply(animated: animated && !isMoving)
        refreshQuickLook()
        FloatManager.shared.setNeedsSave()
    }

    /// Follows renamed/moved files and drops deleted or trashed ones.
    func refreshFiles() {
        guard !isClosing, !group.isEmpty else { return }
        var updated = group
        guard updated.refresh({ FloatStore.check($0) }) else { return }
        group = updated
        if group.isEmpty {
            close()
        } else {
            contentChanged()
        }
    }

    func dragOutBegan() {
        isDraggingFiles = true
        expandWork?.cancel()
    }

    func dragOutEnded(operation: NSDragOperation) {
        isDraggingFiles = false
        guard operation.contains(.move) || operation.contains(.delete) else { return }
        // Finder moves files on its own schedule; look again shortly.
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshFiles() }
        }
    }

    // MARK: Selection

    func noteInteraction() {
        FloatManager.shared.touch(self)
    }

    func click(_ id: UUID, modifiers: FloatSelectionModifiers) {
        group.click(id, modifiers: modifiers)
        selectionChanged()
    }

    func clearSelection() {
        guard !group.selection.isEmpty else { return }
        group.clearSelection()
        selectionChanged()
    }

    func selectAll() {
        group.selectAll()
        selectionChanged()
    }

    func rubberBand(hit: [UUID], initial: Set<UUID>, modifiers: FloatSelectionModifiers) {
        let before = group.selection
        group.rubberBand(hit: hit, initial: initial, modifiers: modifiers)
        if group.selection != before { selectionChanged() }
    }

    func backgroundClicked() { clearSelection() }

    private func selectionChanged() {
        root.grid.updateSelection(group.selection)
        refreshQuickLook()
    }

    func keyStateChanged() { root.grid.refreshEmphasis() }

    private var targetURLs: [URL] { group.selectedURLs }

    // MARK: Actions

    func openSelection() {
        for url in targetURLs { NSWorkspace.shared.open(url) }
    }

    private func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealSelection(_ urls: [URL]? = nil) {
        let urls = urls ?? targetURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelection() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func duplicateSelection() {
        var copies: [URL] = []
        var failure: Error?
        for url in targetURLs {
            let destination = FloatStore.duplicateURL(for: url)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                copies.append(destination)
            } catch {
                failure = failure ?? error
            }
        }
        if !copies.isEmpty { add(copies, select: true) }
        if let failure { present(failure, title: "Couldn't duplicate") }
    }

    func trashSelection() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { trashed, error in
            let gone = Array(trashed.keys)
            let message = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.remove(urls: gone)
                if let message { self.present(message: message, title: "Couldn't move to Trash") }
            }
        }
    }

    func removeSelection() {
        remove(ids: group.selection)
    }

    func toggleViewMode() {
        viewMode = viewMode == .icons ? .list : .icons
        contentChanged()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        expandWork?.cancel()
        updateWatch()
        endQuickLookIfOwner()
        FloatManager.shared.remove(self)
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Holds the controller until the fade is done.
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.controller = nil
                panel.contentView = nil
                _ = self
            }
        })
    }

    private func present(_ error: Error, title: String) {
        present(message: error.localizedDescription, title: title)
    }

    private func present(message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        switch Int(event.keyCode) {
        case 49 where !command:                      // space
            toggleQuickLook()
            return true
        case 53:                                     // esc
            escape()
            return true
        case 36, 76:                                 // return / enter
            openSelection()
            return true
        case 51, 117:                                // delete / forward delete
            if command { trashSelection() } else { removeSelection() }
            return true
        case 123: navigate(.left, extend: shift); return true
        case 124: navigate(.right, extend: shift); return true
        case 125:
            if command { openSelection() } else { navigate(.down, extend: shift) }
            return true
        case 126: navigate(.up, extend: shift); return true
        default: break
        }
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll()
            case "c": copySelection()
            case "o": openSelection()
            case "w": close()
            case "y": toggleQuickLook()
            case "d": duplicateSelection()
            case "r": revealSelection()
            default: return false
            }
            return true
        }
        guard flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return false }
        typeSelect(text)
        return true
    }

    func escape() {
        if quickLookVisible, let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        } else if !group.selection.isEmpty {
            clearSelection()
        } else if dockedEdge != nil, isExpanded {
            collapse()
        }
    }

    private func navigate(_ direction: FloatMove, extend: Bool) {
        let current = group.anchor.flatMap(group.index(of:)) ?? group.selectedItems.last.flatMap { group.index(of: $0.id) }
        let focus: Int? = extend ? lastFocus ?? current : current
        guard let next = layout.index(from: focus, moving: direction) else { return }
        let id = group.items[next].id
        if extend {
            group.click(id, modifiers: .extend)
            lastFocus = next
        } else {
            group.select(only: id)
            lastFocus = nil
        }
        selectionChanged()
        root.grid.scrollToItem(id)
    }

    private var lastFocus: Int?

    private func typeSelect(_ text: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypeTime) > 1 { typeBuffer = "" }
        lastTypeTime = now
        typeBuffer += text
        guard let item = group.firstItem(matching: typeBuffer) else { return }
        group.select(only: item.id)
        selectionChanged()
        root.grid.scrollToItem(item.id)
    }

    // MARK: Quick Look

    var hasQuickLookItems: Bool { !quickLookURLs.isEmpty }
    private var quickLookURLs: [URL] { group.selection.isEmpty ? group.allURLs : group.selectedURLs }

    private var quickLookVisible: Bool {
        ownsQuickLook && QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func toggleQuickLook() {
        if quickLookVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        } else {
            showQuickLook()
        }
    }

    func showQuickLook() {
        guard hasQuickLookItems, let preview = QLPreviewPanel.shared() else { return }
        prepareQuickLook()
        NSApp.activate()
        panel.makeKey()
        panel.makeMain()
        preview.updateController()
        if !ownsQuickLook {   // not found through the responder chain; drive it directly
            preview.dataSource = quickLook
            preview.delegate = quickLook
            ownsQuickLook = true
        }
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
    }

    func beginQuickLook(_ preview: QLPreviewPanel) {
        prepareQuickLook()
        preview.dataSource = quickLook
        preview.delegate = quickLook
        ownsQuickLook = true
    }

    func endQuickLook(_ preview: QLPreviewPanel) {
        if preview.dataSource === quickLook {
            preview.dataSource = nil
            preview.delegate = nil
        }
        ownsQuickLook = false
    }

    private func prepareQuickLook() {
        let urls = quickLookURLs
        quickLook.urls = urls
        quickLook.frames = [:]
        quickLook.images = [:]
        for item in group.items where urls.contains(item.url) {
            if let frame = root.grid.screenFrame(for: item.id) { quickLook.frames[item.url] = frame }
            if let image = FloatThumbnails.shared.cached(item.url) { quickLook.images[item.url] = image }
        }
    }

    private func refreshQuickLook() {
        guard quickLookVisible, let preview = QLPreviewPanel.shared() else { return }
        if quickLookURLs.isEmpty {
            preview.orderOut(nil)
            return
        }
        prepareQuickLook()
        preview.reloadData()
    }

    private func endQuickLookIfOwner() {
        if quickLookVisible { QLPreviewPanel.shared()?.orderOut(nil) }
    }

    // MARK: Menus

    /// Context menu for the selected files.
    func itemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let urls = targetURLs
        let count = urls.count
        let what = count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(count) Items"

        menu.addItem(ClosureMenuItem(count == 1 ? "Open" : "Open \(count) Items") { [weak self] in self?.openSelection() })
        menu.addItem(openWithItem(for: urls))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quick Look \(what)", key: "y") { [weak self] in self?.showQuickLook() })
        menu.addItem(ClosureMenuItem("Show in Finder", key: "r") { [weak self] in self?.revealSelection() })
        menu.addItem(ClosureMenuItem(count == 1 ? "Copy" : "Copy \(count) Items", key: "c") { [weak self] in
            self?.copySelection()
        })
        menu.addItem(ClosureMenuItem("Duplicate", key: "d") { [weak self] in self?.duplicateSelection() })
        let picker = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        sharePicker = picker
        menu.addItem(picker.standardShareMenuItem)
        menu.addItem(.separator())
        let remove = ClosureMenuItem("Remove from Float", key: "\u{8}") { [weak self] in self?.removeSelection() }
        remove.keyEquivalentModifierMask = []
        menu.addItem(remove)
        menu.addItem(ClosureMenuItem("Move to Trash", key: "\u{8}") { [weak self] in self?.trashSelection() })
        return menu
    }

    private func openWithItem(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        guard let first = urls.first else { return item }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
        var seen = Set<String>()
        let others = NSWorkspace.shared.urlsForApplications(toOpen: first)
            .filter { $0 != defaultApp && seen.insert($0.path).inserted }
            .sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
        if defaultApp == nil, others.isEmpty {
            let none = NSMenuItem(title: "No Applications Available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        if let defaultApp {
            submenu.addItem(appItem(defaultApp, title: "\(appName(defaultApp)) (default)", urls: urls))
            if !others.isEmpty { submenu.addItem(.separator()) }
        }
        for app in others.prefix(40) { submenu.addItem(appItem(app, title: appName(app), urls: urls)) }
        item.submenu = submenu
        return item
    }

    private func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func appItem(_ app: URL, title: String, urls: [URL]) -> NSMenuItem {
        let item = ClosureMenuItem(title) { [weak self] in self?.open(urls, with: app) }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    /// Context menu for the Float itself (background, header, tab).
    func floatMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let hasItems = !group.isEmpty

        let selectAll = ClosureMenuItem("Select All", key: "a") { [weak self] in self?.selectAll() }
        selectAll.isEnabled = hasItems && !isCollapsed
        menu.addItem(selectAll)
        let all = ClosureMenuItem("Show All in Finder") { [weak self] in
            guard let self else { return }
            self.revealSelection(self.group.allURLs)
        }
        all.isEnabled = hasItems
        menu.addItem(all)
        menu.addItem(ClosureMenuItem(viewMode == .icons ? "Show as List" : "Show as Icons") { [weak self] in
            self?.toggleViewMode()
        })
        menu.addItem(.separator())
        if dockedEdge != nil {
            if isExpanded {
                menu.addItem(ClosureMenuItem("Collapse Float") { [weak self] in self?.collapse() })
            } else {
                menu.addItem(ClosureMenuItem("Expand Float") { [weak self] in self?.expand() })
            }
            menu.addItem(ClosureMenuItem("Detach from Edge") { [weak self] in self?.detach() })
        } else {
            menu.addItem(ClosureMenuItem("Collapse to Edge") { [weak self] in self?.collapse() })
        }
        menu.addItem(.separator())
        let close = ClosureMenuItem("Close Float", key: "w") { [weak self] in self?.close() }
        close.toolTip = "Close Float without deleting files"
        menu.addItem(close)
        return menu
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { isMenuOpen = true }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        // The share picker stays alive until the next menu replaces it: its
        // actions fire after the menu has closed.
        MainActor.assumeIsolated { isMenuOpen = false }
    }

    // MARK: Persistence

    func snapshot() -> FloatSnapshot {
        let edge = dockedEdge
        return FloatSnapshot(id: id, frame: edge == nil ? panel.frame : floatingFrame, edge: edge,
                             dockCenterY: edge == nil ? nil : dockCenterY,
                             displayID: displayID ?? screen.floatDisplayID, viewMode: viewMode,
                             items: group.items.map(FloatStore.record(for:)))
    }

    /// Rebuilds a saved Float; nil when none of its files exist any more.
    static func restore(_ snapshot: FloatSnapshot) -> FloatController? {
        let items = snapshot.items.compactMap(FloatStore.item(from:))
        guard !items.isEmpty else { return nil }
        let controller = FloatController(id: snapshot.id, items: items, viewMode: snapshot.viewMode)
        controller.floatingFrame = snapshot.frame
        let known = NSScreen.screens.first { $0.floatDisplayID == snapshot.displayID }
        if let edge = snapshot.edge {
            let screen = known ?? NSScreen.main ?? NSScreen.screens[0]
            controller.displayID = screen.floatDisplayID
            controller.placement = .docked(edge)
            controller.isExpanded = false
            controller.dockCenterY = snapshot.dockCenterY ?? screen.visibleFrame.midY
        }
        controller.screenParametersChanged()
        return controller
    }
}
