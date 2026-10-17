import AppKit
import WheelieCore

/// Owns every open Float: creation, "most recent" tracking, persistence, and
/// keeping items in sync with the file system.
@MainActor
final class FloatManager {
    static let shared = FloatManager()

    /// Open Floats, least recently used first.
    private(set) var floats: [FloatController] = []
    private var saveWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var defaults: UserDefaults { .standard }

    private init() {}

    var hasFloats: Bool { !floats.isEmpty }

    func start() {
        guard !started else { return }
        started = true
        restore()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .wheelieOutputsProduced, object: nil, queue: .main) { note in
            let urls = note.userInfo?["urls"] as? [URL] ?? []
            MainActor.assumeIsolated {
                guard UserDefaults.standard.bool(forKey: SettingsKey.addResultsToFloat) else { return }
                FloatManager.shared.deliver(urls)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FloatManager.shared.floats.forEach { $0.screenParametersChanged() } }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FloatManager.shared.saveNow() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FloatManager.shared.refreshFiles() }
        })
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { FloatManager.shared.refreshFiles() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: Creating and adding

    /// Wheel / results entry point: adds to the most recent Float on the pointer's
    /// screen, or opens a new one near the pointer (per `FloatSettings.wheelBehavior`).
    @discardableResult
    func deliver(_ urls: [URL]) -> FloatController? {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return nil }
        let pointer = NSEvent.mouseLocation
        if FloatSettings.addsToExistingFloat, let target = mostRecent(onScreenWith: pointer) {
            target.add(files, select: true)
            target.bringForward()
            return target
        }
        return newFloat(with: files, near: pointer)
    }

    @discardableResult
    func newFloat(with urls: [URL], near point: NSPoint) -> FloatController {
        let controller = FloatController()
        controller.add(urls)
        controller.placeFloating(centeredOn: point, avoiding: floats.map(\.panel.frame))
        open(controller)
        return controller
    }

    /// Empty Float just under the menu bar (the pointer is at the status item).
    func newEmptyFloat() {
        let controller = FloatController()
        controller.placeFloating(top: NSEvent.mouseLocation, avoiding: floats.map(\.panel.frame))
        open(controller)
    }

    private func open(_ controller: FloatController) {
        floats.append(controller)
        controller.show(animated: true)
        setNeedsSave()
    }

    private func mostRecent(onScreenWith point: NSPoint) -> FloatController? {
        let screen = NSScreen.floatScreen(containing: point)
        return floats.last { float in
            !float.isClosing && float.panel.isVisible && NSScreen.floatScreen(for: float.panel.frame) == screen
        }
    }

    // MARK: Bookkeeping

    func touch(_ controller: FloatController) {
        guard let index = floats.firstIndex(where: { $0 === controller }), index != floats.count - 1 else { return }
        floats.append(floats.remove(at: index))
    }

    func remove(_ controller: FloatController) {
        floats.removeAll { $0 === controller }
        setNeedsSave()
    }

    func showAll() {
        refreshFiles()
        for float in floats { float.bringForward() }
    }

    func closeAll() {
        for float in floats { float.close() }
    }

    func refreshFiles() {
        for float in floats { float.refreshFiles() }
    }

    // MARK: Persistence

    func setNeedsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { FloatManager.shared.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let snapshots = floats.filter { !$0.isClosing && !$0.group.isEmpty }.map { $0.snapshot() }
        FloatStore.save(snapshots, to: defaults)
    }

    private func restore() {
        for snapshot in FloatStore.load(from: defaults) {
            guard let controller = FloatController.restore(snapshot) else { continue }
            floats.append(controller)
            controller.show(animated: false)
        }
        saveNow()   // drops Floats whose files are all gone
    }
}

/// Float preferences (UserDefaults keys owned by this feature).
enum FloatSettings {
    /// "existing" (default): the wheel's Float item adds to the most recent Float on that screen.
    /// "new": it always opens a new Float.
    static let wheelBehaviorKey = "floatWheelBehavior"

    static var addsToExistingFloat: Bool {
        UserDefaults.standard.string(forKey: wheelBehaviorKey) != "new"
    }
}
