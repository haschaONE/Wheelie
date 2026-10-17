import AppKit
import WheelieCore

/// Views that start file drags out of a Float (grid and collapsed tab).
@MainActor
protocol FloatDragSource: AnyObject {
    var controller: FloatController? { get }
}

/// Starts an AppKit drag of `items` from `view`. `frames` gives each item's starting
/// rect in `view` coordinates; items without one start under the pointer.
@MainActor
enum FloatDragOut {
    static func begin(from view: NSView & NSDraggingSource, items: [FloatItem], frames: [UUID: NSRect],
                      event: NSEvent) {
        guard !items.isEmpty else { return }
        let mouse = view.convert(event.locationInWindow, from: nil)
        let side = FloatLayout.thumbnailSide
        let dragging: [NSDraggingItem] = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let image = FloatThumbnails.shared.cached(item.url) ?? NSWorkspace.shared.icon(forFile: item.url.path)
            let offset = CGFloat(min(index, 6)) * 3
            let box = frames[item.id] ?? NSRect(x: mouse.x - side / 2 + offset, y: mouse.y - side / 2 - offset,
                                                width: side, height: side)
            draggingItem.setDraggingFrame(FloatShape.aspectFit(image.size, in: box), contents: image)
            return draggingItem
        }
        let session = view.beginDraggingSession(with: dragging, event: event, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default
    }

    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        // Finder decides copy vs move (⌥/⌘ work as usual); no .delete, so the Dock's
        // Trash doesn't accept a Float drag by accident.
        [.copy, .move, .link, .generic]
    }
}

// MARK: - Root

/// Content view of a Float panel: material background, window moving, file drops,
/// and the two presentations (expanded grid, collapsed tab).
final class FloatRootView: NSView {
    weak var controller: FloatController?

    let material = FloatMaterialView()
    let border = FloatBorderView()
    let expanded = FloatPassthroughView()
    let header = FloatHeaderView()
    let scrollView = NSScrollView()
    let grid = FloatGridView()
    let tab = FloatTabView()
    let dropOverlay = FloatDropOverlay()

    /// Size of the expanded content (layout.panelSize).
    var panelSize = CGSize(width: 200, height: 150) { didSet { layoutChildren() } }
    /// Docked edge (nil while floating): squares that side and pins content to it.
    var dockEdge: FloatEdge? { didSet { updateShape(); layoutChildren() } }
    var isTab = false { didSet { updateShape() } }

    private var moveStart: NSPoint?
    private var didMove = false

    init(controller: FloatController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        autoresizesSubviews = true

        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = grid
        grid.controller = controller
        expanded.addSubview(scrollView)
        header.controller = controller
        expanded.addSubview(header)
        addSubview(expanded)

        tab.controller = controller
        addSubview(tab)
        addSubview(border)
        addSubview(dropOverlay)
        dropOverlay.isHidden = true

        registerForDraggedTypes([.fileURL])
        updateShape()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Float")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateShape() {
        let radius = isTab ? FloatShape.tabRadius : FloatShape.floatingRadius
        material.maskImage = FloatShape.maskImage(radius: radius, squareEdge: dockEdge)
        border.radius = radius
        border.squareEdge = dockEdge
        dropOverlay.squareEdge = dockEdge
        dropOverlay.radius = radius
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutChildren()
    }

    /// Positions children from the current bounds so frame animations slide the
    /// content in from the docked edge instead of squashing it.
    func layoutChildren() {
        let b = bounds
        material.frame = b
        border.frame = b
        dropOverlay.frame = b

        let size = panelSize
        let x: CGFloat
        let y: CGFloat
        switch dockEdge {
        case .none:
            x = 0
            y = b.height - size.height
        case .left?:
            x = b.width - size.width
            y = ((b.height - size.height) / 2).rounded()
        case .right?:
            x = 0
            y = ((b.height - size.height) / 2).rounded()
        }
        expanded.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let headerHeight = FloatLayout.headerHeight
        let margin = FloatLayout.margin
        header.frame = NSRect(x: 0, y: size.height - headerHeight, width: size.width, height: headerHeight)
        scrollView.frame = NSRect(x: margin, y: margin, width: size.width - 2 * margin,
                                  height: size.height - headerHeight - margin)

        let tabSize = FloatDocking.tabSize
        let tabX = dockEdge == .left ? 0 : b.width - tabSize.width
        tab.frame = NSRect(x: tabX, y: ((b.height - tabSize.height) / 2).rounded(),
                           width: tabSize.width, height: tabSize.height)
    }

    // MARK: Moving (background drag)

    override func mouseDown(with event: NSEvent) {
        controller?.noteInteraction()
        moveStart = NSEvent.mouseLocation
        didMove = false
        if event.clickCount == 2 { controller?.toggleCollapsed() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = moveStart else { return }
        let now = NSEvent.mouseLocation
        if !didMove {
            guard hypot(now.x - start.x, now.y - start.y) > 2 else { return }
            didMove = true
            controller?.moveBegan(at: start)
        }
        controller?.moved(to: now)
    }

    override func mouseUp(with event: NSEvent) {
        if didMove { controller?.moveEnded(at: NSEvent.mouseLocation) }
        else if event.clickCount == 1 { controller?.backgroundClicked() }
        moveStart = nil
        didMove = false
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.noteInteraction()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.floatMenu() }

    // MARK: Drops

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let controller else { return [] }
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        let source = (info.draggingSource as? FloatDragSource)?.controller
        if source === controller {
            // Reordering inside this Float.
            guard !isTab, let point = gridPoint(info) else {
                grid.insertionIndex = nil
                showDropHint(nil)
                return []
            }
            grid.insertionIndex = grid.layout.insertionIndex(at: point)
            showDropHint(nil)
            return .move
        }
        let fresh = urls.filter { !controller.group.contains($0) }.count
        info.numberOfValidItemsForDrop = max(fresh, 1)
        showDropHint(fresh)
        controller.dropHoverChanged(true)
        if source != nil, info.draggingSourceOperationMask.contains(.move),
           !NSEvent.modifierFlags.contains(.option) {
            return .move
        }
        return .copy
    }

    private func gridPoint(_ info: NSDraggingInfo) -> NSPoint? {
        let point = grid.convert(info.draggingLocation, from: nil)
        return grid.visibleRect.contains(point) ? point : nil
    }

    private func showDropHint(_ count: Int?) {
        dropOverlay.isHidden = count == nil
        dropOverlay.count = count ?? 0
        dropOverlay.compact = isTab
        border.highlight = count == nil ? nil : .controlAccentColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropHint(nil)
        grid.insertionIndex = nil
        controller?.dropHoverChanged(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        showDropHint(nil)
        grid.insertionIndex = nil
        controller?.dropHoverChanged(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            showDropHint(nil)
            grid.insertionIndex = nil
            controller?.dropHoverChanged(false)
        }
        guard let controller else { return false }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        let source = (sender.draggingSource as? FloatDragSource)?.controller
        if source === controller {
            guard let point = gridPoint(sender) else { return false }
            controller.reorder(urls, to: grid.layout.insertionIndex(at: point))
            return true
        }
        let moveFromFloat = source != nil && sender.draggingSourceOperationMask.contains(.move)
            && !NSEvent.modifierFlags.contains(.option)
        controller.add(urls, select: true)
        if moveFromFloat, let source { source.remove(urls: urls) }
        return true
    }
}

// MARK: - Header

final class FloatHeaderView: FloatPassthroughView {
    weak var controller: FloatController?

    let title = FloatLabel.make(size: 12, weight: .semibold, color: .secondaryLabelColor)
    private(set) lazy var closeButton = FloatButton.symbol("xmark.circle.fill", help: "Close Float without deleting files",
                                                           target: self, action: #selector(close))
    private(set) lazy var modeButton = FloatButton.symbol("list.bullet", help: "Show as List",
                                                          target: self, action: #selector(toggleMode))
    private(set) lazy var collapseButton = FloatButton.symbol("arrow.right.to.line", help: "Collapse Float",
                                                              target: self, action: #selector(collapse))

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        [title, closeButton, modeButton, collapseButton].forEach(addSubview)
        toolTip = "Move Float; drag near an edge to attach, or away to detach"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let side: CGFloat = 22
        let y = ((h - side) / 2).rounded()
        closeButton.frame = NSRect(x: 7, y: y, width: side, height: side)
        collapseButton.frame = NSRect(x: bounds.width - 7 - side, y: y, width: side, height: side)
        modeButton.frame = NSRect(x: collapseButton.frame.minX - side - 2, y: y, width: side, height: side)
        let inset = side * 2 + 14
        title.frame = NSRect(x: inset, y: ((h - 16) / 2).rounded(), width: max(0, bounds.width - 2 * inset), height: 16)
    }

    func update(count: Int, mode: FloatViewMode, collapseEdge: FloatEdge) {
        title.stringValue = count == 0 ? "Float" : count == 1 ? "1 item" : "\(count) items"
        modeButton.setSymbol(mode == .icons ? "list.bullet" : "square.grid.2x2",
                             help: mode == .icons ? "Show as List" : "Show as Icons")
        collapseButton.setSymbol(collapseEdge == .left ? "arrow.left.to.line" : "arrow.right.to.line",
                                 help: "Collapse Float, \(title.stringValue)")
        needsLayout = true
    }

    @objc private func close() { controller?.close() }
    @objc private func toggleMode() { controller?.toggleViewMode() }
    @objc private func collapse() { controller?.collapse() }
}

// MARK: - Grid

/// The file grid: selection (click, ⌘/⇧-click, rubber band), drag out, context menus.
final class FloatGridView: NSView, NSDraggingSource, FloatDragSource {
    weak var controller: FloatController?
    private(set) var layout = FloatLayout(count: 0)
    private var tiles: [UUID: FloatTileView] = [:]
    private var order: [UUID] = []
    private let rubberBand = FloatRubberBandView()
    private let placeholder = FloatPlaceholderView()

    /// Insertion marker while reordering by drag.
    var insertionIndex: Int? { didSet { if insertionIndex != oldValue { needsDisplay = true } } }

    // Mouse tracking
    private var mouseDownEvent: NSEvent?
    private var pressedItem: UUID?
    private var reselectOnMouseUp: UUID?
    private var bandOrigin: NSPoint?
    private var bandInitial: Set<UUID> = []
    private var bandModifiers: FloatSelectionModifiers = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(placeholder)
        addSubview(rubberBand)
        rubberBand.isHidden = true
        setAccessibilityLabel("File selection area. Drag empty space to select multiple files.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func reload(items: [FloatItem], selection: Set<UUID>, layout: FloatLayout, viewport: CGSize) {
        self.layout = layout
        let content = layout.contentSize
        setFrameSize(NSSize(width: content.width, height: max(content.height, viewport.height)))
        let ids = items.map(\.id)
        for (id, tile) in tiles where !ids.contains(id) {
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        for (index, item) in items.enumerated() {
            let tile: FloatTileView
            if let existing = tiles[item.id] {
                tile = existing
            } else {
                tile = FloatTileView()
                addSubview(tile, positioned: .below, relativeTo: rubberBand)
                tiles[item.id] = tile
            }
            tile.configure(item: item, mode: layout.mode)
            tile.frame = layout.frame(at: index)
            tile.isSelected = selection.contains(item.id)
        }
        order = ids
        placeholder.isHidden = !items.isEmpty
        placeholder.frame = NSRect(origin: .zero, size: NSSize(width: content.width, height: max(content.height, viewport.height)))
        rubberBand.frame = bounds
        needsDisplay = true
    }

    func updateSelection(_ selection: Set<UUID>) {
        for (id, tile) in tiles { tile.isSelected = selection.contains(id) }
    }

    func refreshEmphasis() { tiles.values.forEach { $0.needsDisplay = true } }

    /// Thumbnail rect of an item in this view's coordinates, when it is scrolled into view.
    func thumbnailFrame(for id: UUID) -> NSRect? {
        guard let tile = tiles[id], visibleRect.intersects(tile.frame) else { return nil }
        return tile.convert(tile.thumbnailRect, to: self)
    }

    func screenFrame(for id: UUID) -> NSRect? {
        guard let rect = thumbnailFrame(for: id), let window else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func scrollToItem(_ id: UUID) {
        guard let index = order.firstIndex(of: id) else { return }
        scrollToVisible(layout.frame(at: index).insetBy(dx: 0, dy: -FloatLayout.contentInset))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let index = insertionIndex, layout.count > 0 else { return }
        NSColor.controlAccentColor.setFill()
        let cell = layout.cellSize
        let reference = layout.frame(at: min(index, layout.count - 1))
        let atEnd = index >= layout.count
        switch layout.mode {
        case .icons:
            let x = atEnd ? reference.maxX + FloatLayout.spacing / 2 : reference.minX - FloatLayout.spacing / 2
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: reference.minY + 6, width: 3, height: cell.height - 12),
                         xRadius: 1.5, yRadius: 1.5).fill()
        case .list:
            let y = atEnd ? reference.maxY : reference.minY
            NSBezierPath(roundedRect: NSRect(x: reference.minX + 4, y: y - 1.5, width: cell.width - 8, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    // MARK: Mouse

    private func item(at event: NSEvent) -> UUID? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = layout.index(at: point), order.indices.contains(index) else { return nil }
        return order[index]
    }

    private func modifiers(_ event: NSEvent) -> FloatSelectionModifiers {
        var result: FloatSelectionModifiers = []
        if event.modifierFlags.contains(.command) { result.insert(.toggle) }
        if event.modifierFlags.contains(.shift) { result.insert(.extend) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        controller.noteInteraction()
        mouseDownEvent = event
        reselectOnMouseUp = nil
        let mods = modifiers(event)
        if let id = item(at: event) {
            pressedItem = id
            if event.clickCount == 2, mods.isEmpty {
                controller.openSelection()
                pressedItem = nil
                return
            }
            if mods.isEmpty, controller.group.isSelected(id) {
                reselectOnMouseUp = id   // keep the selection so it can be dragged as a whole
            } else {
                controller.click(id, modifiers: mods)
            }
        } else {
            pressedItem = nil
            bandOrigin = convert(event.locationInWindow, from: nil)
            bandModifiers = mods
            bandInitial = mods.isEmpty ? [] : controller.group.selection
            if mods.isEmpty { controller.clearSelection() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let down = mouseDownEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        let start = convert(down.locationInWindow, from: nil)
        if let pressed = pressedItem {
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            if !controller.group.isSelected(pressed) { controller.click(pressed, modifiers: []) }
            let items = controller.group.selectedItems
            var frames: [UUID: NSRect] = [:]
            for item in items { frames[item.id] = thumbnailFrame(for: item.id) }
            pressedItem = nil
            reselectOnMouseUp = nil
            mouseDownEvent = nil
            controller.dragOutBegan()
            FloatDragOut.begin(from: self, items: items, frames: frames, event: down)
            return
        }
        guard let origin = bandOrigin else { return }
        autoscroll(with: event)
        let current = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                          width: abs(current.x - origin.x), height: abs(current.y - origin.y))
        rubberBand.isHidden = false
        rubberBand.frame = bounds
        rubberBand.band = rect
        let hit = layout.indexes(in: rect).compactMap { order.indices.contains($0) ? order[$0] : nil }
        controller.rubberBand(hit: hit, initial: bandInitial, modifiers: bandModifiers)
    }

    override func mouseUp(with event: NSEvent) {
        if let id = reselectOnMouseUp { controller?.click(id, modifiers: []) }
        reselectOnMouseUp = nil
        pressedItem = nil
        mouseDownEvent = nil
        bandOrigin = nil
        rubberBand.band = nil
        rubberBand.isHidden = true
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.noteInteraction()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        if let id = item(at: event) {
            if !controller.group.isSelected(id) { controller.click(id, modifiers: []) }
            return controller.itemMenu()
        }
        return controller.floatMenu()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FloatDragOut.operationMask(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragOutEnded(operation: operation)
    }
}

/// Empty-Float hint.
final class FloatPlaceholderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let text = NSAttributedString(string: "Drop files here", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color,
        ])
        let textSize = text.size()
        let imageSize = symbol?.size ?? .zero
        let total = imageSize.height + 6 + textSize.height
        var y = (bounds.height - total) / 2
        if let symbol {
            let tinted = NSImage(size: imageSize, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: (bounds.width - imageSize.width) / 2, y: y, width: imageSize.width,
                                   height: imageSize.height), from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            y += imageSize.height + 6
        }
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: y))
    }
}

/// Selection rectangle drawn above the tiles.
final class FloatRubberBandView: NSView {
    var band: NSRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let band, band.width > 0 || band.height > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        band.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: band.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Tile

/// One file: thumbnail + name. Purely visual; the grid handles all mouse input.
final class FloatTileView: NSView {
    private let imageView = NSImageView()
    private let label = FloatLabel.make(size: 11)
    private(set) var item: FloatItem?
    private var mode: FloatViewMode = .icons

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateColors()
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        imageView.shadow = shadow
        addSubview(imageView)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(item: FloatItem, mode: FloatViewMode) {
        let urlChanged = self.item?.url != item.url
        let modeChanged = self.mode != mode
        self.item = item
        self.mode = mode
        if urlChanged {
            let url = item.url
            label.stringValue = FileManager.default.displayName(atPath: url.path)
            imageView.image = FloatThumbnails.shared.image(for: url) { [weak self] image in
                guard self?.item?.url == url else { return }
                self?.imageView.image = image
            }
            setAccessibilityLabel(label.stringValue)
            setAccessibilityHelp("Double-click to open; drag to carry the file.")
        }
        if urlChanged || modeChanged {
            label.font = .systemFont(ofSize: mode == .icons ? 11 : 12)
            label.alignment = mode == .icons ? .center : .left
            label.maximumNumberOfLines = mode == .icons ? 2 : 1
            label.lineBreakMode = mode == .icons ? .byWordWrapping : .byTruncatingMiddle
            label.cell?.truncatesLastVisibleLine = true
            needsLayout = true
        }
        updateColors()
    }

    /// Where the thumbnail sits, in tile coordinates.
    var thumbnailRect: NSRect {
        switch mode {
        case .icons:
            let side = FloatLayout.thumbnailSide
            return NSRect(x: (bounds.width - side) / 2, y: 5, width: side, height: side)
        case .list:
            return NSRect(x: 6, y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = thumbnailRect
        switch mode {
        case .icons:
            let maxWidth = bounds.width - 6
            let top = thumbnailRect.maxY + 4
            let fit = label.sizeThatFits(NSSize(width: maxWidth, height: 30))
            let width = min(maxWidth, ceil(fit.width))
            let height = min(bounds.height - top - 1, ceil(fit.height))
            label.preferredMaxLayoutWidth = maxWidth
            label.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
        case .list:
            let x = thumbnailRect.maxX + 8
            label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: bounds.width - x - 8, height: 16)
        }
    }

    private var emphasized: Bool { window?.isKeyWindow ?? false }

    private func updateColors() {
        let selectedText = emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
        label.textColor = isSelected ? selectedText : .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        updateColors()
        let fill = emphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        switch mode {
        case .icons:
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: thumbnailRect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6).fill()
            fill.setFill()
            NSBezierPath(roundedRect: label.frame.insetBy(dx: -4, dy: -1), xRadius: 4, yRadius: 4).fill()
        case .list:
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }
}

// MARK: - Collapsed tab

/// The slim tab a docked Float collapses into: stacked thumbnails + count.
/// Drag the stack to carry all files; drag elsewhere to move along the edge or detach.
final class FloatTabView: NSView, NSDraggingSource, FloatDragSource {
    weak var controller: FloatController?

    var edge: FloatEdge = .right { didSet { needsDisplay = true } }
    private var items: [FloatItem] = []
    private var images: [NSImage] = []
    private var hovering = false { didSet { needsDisplay = true } }

    private var downEvent: NSEvent?
    private var downOnStack = false
    private var moving = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var stackRect: NSRect {
        let side: CGFloat = 46
        return NSRect(x: (bounds.width - side) / 2, y: 26, width: side, height: side)
    }

    func update(items: [FloatItem]) {
        self.items = items
        let shown = Array(items.suffix(3))
        images = shown.map { item in
            FloatThumbnails.shared.image(for: item.url) { [weak self] _ in self?.reloadImages() }
        }
        let count = items.count
        let noun = count == 1 ? "1 item" : "\(count) items"
        toolTip = "Float, \(noun). Click to expand; drag the stack to carry all files."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Float, \(noun). Drag to move or detach.")
        needsDisplay = true
    }

    private func reloadImages() {
        images = items.suffix(3).map { FloatThumbnails.shared.cached($0.url) ?? NSWorkspace.shared.icon(forFile: $0.url.path) }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        controller?.tabHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        controller?.tabHoverChanged(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Grip
        NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.8 : 0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 11, y: 9, width: 22, height: 4), xRadius: 2, yRadius: 2).fill()

        // Stacked thumbnails, newest on top, fanned slightly.
        let rect = stackRect
        let angles: [CGFloat] = images.count == 1 ? [0] : images.count == 2 ? [-7, 5] : [-10, 8, -1]
        for (index, image) in images.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: angles[index] * (edge == .left ? -1 : 1))
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.set()
            let box = FloatShape.aspectFit(image.size, in: rect.insetBy(dx: 2, dy: 2))
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if images.isEmpty {
            let symbol = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            symbol?.draw(in: FloatShape.aspectFit(symbol?.size ?? .zero, in: rect.insetBy(dx: 10, dy: 10)),
                         from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
        }

        // Paper clip holding the stack.
        if !images.isEmpty, let clip = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            let tinted = NSImage(size: clip.size, flipped: false) { r in
                clip.draw(in: r)
                NSColor.white.withAlphaComponent(0.92).set()
                r.fill(using: .sourceAtop)
                return true
            }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            let center = NSPoint(x: rect.maxX - 6, y: rect.minY + 3)
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: 20)
            transform.translateX(by: -center.x, yBy: -center.y)
            transform.concat()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 1.5
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.set()
            tinted.draw(in: NSRect(x: center.x - clip.size.width / 2, y: center.y - clip.size.height / 2,
                                   width: clip.size.width, height: clip.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Count
        let text = NSAttributedString(string: items.isEmpty ? "Empty" : "\(items.count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: items.isEmpty ? 10 : 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: rect.maxY + 8))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        controller?.noteInteraction()
        controller?.tabPressed()
        downEvent = event
        moving = false
        let point = convert(event.locationInWindow, from: nil)
        downOnStack = !items.isEmpty && stackRect.insetBy(dx: -4, dy: -4).contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let controller else { return }
        let start = convert(down.locationInWindow, from: nil)
        let point = convert(event.locationInWindow, from: nil)
        if !moving {
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            if downOnStack {
                downEvent = nil
                var frames: [UUID: NSRect] = [:]
                for (i, item) in items.enumerated() {
                    let offset = CGFloat(min(i, 5)) * 2
                    frames[item.id] = stackRect.offsetBy(dx: offset, dy: offset)
                }
                controller.dragOutBegan()
                FloatDragOut.begin(from: self, items: items, frames: frames, event: down)
                return
            }
            moving = true
            controller.moveBegan(at: window?.convertPoint(toScreen: down.locationInWindow) ?? NSEvent.mouseLocation)
        }
        controller.moved(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        if moving {
            controller?.moveEnded(at: NSEvent.mouseLocation)
        } else if downEvent != nil {
            controller?.expand()
        }
        downEvent = nil
        moving = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.floatMenu() }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FloatDragOut.operationMask(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragOutEnded(operation: operation)
    }
}

// MARK: - Drop hint

final class FloatDropOverlay: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var compact = false { didSet { needsDisplay = true } }
    var squareEdge: FloatEdge? { didSet { needsDisplay = true } }
    var radius: CGFloat = FloatShape.floatingRadius

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        FloatShape.path(in: bounds, radius: radius, squareEdge: squareEdge).fill()
        let noun = count == 1 ? "item" : "items"
        let string = compact ? "+\(count)" : "Drop to add \(count) \(noun)"
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 12 : 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let pill = NSRect(x: (bounds.width - size.width) / 2 - 9, y: compact ? 6 : 10,
                          width: size.width + 18, height: size.height + 6)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 9, y: pill.minY + 3))
    }
}
