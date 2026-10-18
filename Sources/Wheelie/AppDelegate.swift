import AppKit
import Combine
import WheelieCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let services = AppServices.shared
    private let dragMonitor = DragMonitor()
    private let model = WheelModel()
    private lazy var panel = WheelPanel(model: model)
    private var statusItem: NSStatusItem!
    private var hideWork: DispatchWorkItem?
    /// The job the wheel is currently showing progress for. A job only reports into the
    /// hub while it still owns it, so an older job can't claim a newer one's "working" state.
    private var wheelJob: UUID?
    private var observers: [AnyCancellable] = []

    private var wheelEnabled: Bool {
        get { services.bool(SettingsKey.wheelEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.wheelEnabled) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        services.$activeJobs.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &observers)

        model.onChoose = { [weak self] item, files in self?.perform(item, files: files) }
        model.onCancel = { [weak self] in self?.hideWheel() }

        // Modifier held while dragging files -> wheel opens under the cursor.
        dragMonitor.onTrigger = { [weak self] files, point in
            guard let self, !self.panel.isVisible || self.model.phase == .choosing else { return }
            let items = FeatureRegistry.items(for: files)
            guard !items.isEmpty else { return }
            self.showWheel(files: files, items: items, at: point, interactive: false)
        }
        dragMonitor.onDragEnded = { [weak self] in
            // A drop on the wheel lands just after mouse-up; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let self, self.model.phase == .choosing, !self.panel.allowsKey else { return }
                self.hideWheel()
            }
        }
        dragMonitor.onEscape = { [weak self] in
            guard let self, self.panel.isVisible, self.model.phase == .choosing else { return }
            self.hideWheel()
        }
        applySettings()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &observers)

        installMainMenu()
        FeatureRegistry.startAll()

        // Debug aid: `Wheelie --show-wheel <file>...` opens the wheel immediately.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show-wheel"), args.count > i + 1 {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            let frame = NSScreen.main?.frame ?? .zero
            showWheel(files: files, items: FeatureRegistry.items(for: files),
                      at: NSPoint(x: frame.midX, y: frame.midY), interactive: true)
        }
    }

    private func applySettings() {
        services.applySettings()
        let modifier: NSEvent.ModifierFlags
        switch UserDefaults.standard.string(forKey: SettingsKey.triggerModifier) ?? "shift" {
        case "control": modifier = .control
        case "option": modifier = .option
        case "command": modifier = .command
        default: modifier = .shift
        }
        dragMonitor.triggerModifier = modifier
        if wheelEnabled != dragMonitor.isRunning {
            wheelEnabled ? dragMonitor.start() : dragMonitor.stop()
        }
    }

    // MARK: Wheel

    private func showWheel(files: [URL], items: [WheelItem], at point: NSPoint, interactive: Bool) {
        hideWork?.cancel()
        wheelJob = nil
        model.files = files
        model.items = items
        model.hovered = nil
        model.phase = .choosing
        model.appeared = false
        panel.allowsKey = interactive
        panel.center(on: point)
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.async { self.model.appeared = true }
    }

    private func hideWheel(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard !self.model.appeared else { return }
                self.panel.orderOut(nil)
                self.panel.allowsKey = false
                self.model.phase = .choosing
                self.model.hovered = nil
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func perform(_ item: WheelItem, files: [URL]) {
        let job = UUID()
        wheelJob = job
        model.phase = .working(item.label)
        model.hovered = item.id
        // Long jobs keep running in the background; the wheel steps aside.
        hideWheel(after: 1.5)
        Task {
            let result = await services.run(item.label, sources: files) { try await item.perform(files) }
            guard wheelJob == job, panel.isVisible, model.phase == .working(item.label) else { return }
            wheelJob = nil
            switch result {
            case .success(.none):
                hideWheel()
            case .success(.message(let text)):
                model.phase = .done(text)
                hideWheel(after: 0.9)
            case .success(.outputs(let urls)):
                model.phase = .done(urls.count == 1 ? "Done" : "\(urls.count) files")
                hideWheel(after: 0.9)
            case .failure(let error):
                model.phase = .failed(error.localizedDescription)
                hideWheel(after: 3.5)
            }
        }
    }

    @objc private func openFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.message = "Choose files to convert or edit"
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        showWheel(files: open.urls, items: FeatureRegistry.items(for: open.urls), at: NSEvent.mouseLocation, interactive: true)
    }

    // MARK: Menu

    private func updateIcon() {
        let busy = services.activeJobs > 0
        let name = busy ? "arrow.triangle.2.circlepath" : "steeringwheel"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Wheelie")
            ?? NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Wheelie")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = busy ? "Wheelie — \(services.activeJobs) running…" : "Wheelie"
    }

    private var modifierName: String {
        switch UserDefaults.standard.string(forKey: SettingsKey.triggerModifier) ?? "shift" {
        case "control": return "⌃ Control"
        case "option": return "⌥ Option"
        case "command": return "⌘ Command"
        default: return "⇧ Shift"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Wheelie", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Hold \(modifierName) while dragging a file to open the wheel", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item("Open Files…", #selector(openFiles), key: "o"))
        let tools = FeatureRegistry.menuItems()
        if !tools.isEmpty {
            menu.addItem(.separator())
            tools.forEach(menu.addItem)
        }

        let missing = ["ffmpeg", "cwebp"].filter { Tools.locate($0) == nil }
        if !missing.isEmpty {
            menu.addItem(ClosureMenuItem("⚠︎ Missing \(missing.joined(separator: ", ")) — Show Fix…") {
                ShellFeature.showSettings(tab: .tools)
            })
        }

        if !services.history.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: services.activeJobs > 0 ? "Recent (\(services.activeJobs) running…)" : "Recent", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for record in services.history.prefix(10) {
                let source = record.sources.count == 1 ? record.sources[0].lastPathComponent : "\(record.sources.count) files"
                let name = "\(source) → \(record.title)"
                let entry = item(record.error == nil ? name : "⚠︎ \(name)", #selector(revealRecord(_:)))
                entry.representedObject = record.outputs.isEmpty ? record.sources : record.outputs
                entry.toolTip = record.error
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let toggle = item("Modifier-Drag Opens Wheel", #selector(toggleWheel))
        toggle.state = wheelEnabled ? .on : .off
        menu.addItem(toggle)
        ShellFeature.menuItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Wheelie", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    @objc private func revealRecord(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func toggleWheel() {
        wheelEnabled.toggle()
    }

    /// Accessory apps get no main menu, so without this ⌘C/⌘V/⌘A/⌘Z/⌘W do nothing
    /// in editor windows. The menu bar never shows it; it only routes key equivalents.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func entry(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        submenu("Wheelie", [
            ClosureMenuItem("Settings…", key: ",") { ShellFeature.showSettings() },
            entry("Hide Wheelie", #selector(NSApplication.hide(_:)), "h"),
            entry("Quit Wheelie", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            entry("Undo", Selector(("undo:")), "z"),
            entry("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            entry("Cut", #selector(NSText.cut(_:)), "x"),
            entry("Copy", #selector(NSText.copy(_:)), "c"),
            entry("Paste", #selector(NSText.paste(_:)), "v"),
            entry("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            entry("Close", #selector(NSWindow.performClose(_:)), "w"),
            entry("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
    }
}
