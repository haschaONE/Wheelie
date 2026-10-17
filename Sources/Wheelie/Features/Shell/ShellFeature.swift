import AppKit
import Combine
import WheelieCore

extension SettingsKey {
    /// Bool: the welcome window was shown once (first launch).
    static let didShowWelcome = ShellSettings.Key.didShowWelcome
}

/// App shell: Settings window, first-run welcome, progress HUD and sounds.
enum ShellFeature: WheelieFeature {
    static func menuItems() -> [NSMenuItem] {
        [
            ClosureMenuItem("How to Use Wheelie…") { WelcomeWindowController.shared.show() },
            ClosureMenuItem("Settings…", key: ",") { showSettings() },
        ]
    }

    static func start() {
        assert(ShellSettings.Key.wheelEnabled == SettingsKey.wheelEnabled
            && ShellSettings.Key.triggerModifier == SettingsKey.triggerModifier
            && ShellSettings.Key.outputLocation == SettingsKey.outputLocation
            && ShellSettings.Key.customOutputFolder == SettingsKey.customOutputFolder
            && ShellSettings.Key.playSounds == SettingsKey.playSounds
            && ShellSettings.Key.addResultsToFloat == SettingsKey.addResultsToFloat
            && ShellSettings.Key.revealResults == SettingsKey.revealResults
            && ShellSettings.Key.terminalApp == SettingsKey.terminalApp,
            "ShellSettings.Key is out of sync with SettingsKey")
        UserDefaults.standard.register(defaults: ShellSettings.registrationDefaults())

        ShellFeedback.shared.start()
        JobProgressController.shared.start()

        let debugLaunch = CommandLine.arguments.contains("--show-wheel")
        if !debugLaunch, !UserDefaults.standard.bool(forKey: SettingsKey.didShowWelcome) {
            // Let the status item settle first, so "near the clock" is true when the window appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WelcomeWindowController.shared.show()
            }
        }
    }

    static func showSettings(tab: ShellSettingsTab? = nil) {
        if let tab { ShellSettingsNavigation.shared.tab = tab }
        AppServices.shared.presentWindow(id: "shell.settings", title: "Wheelie Settings",
                                         size: CGSize(width: 580, height: 500), resizable: false) {
            ShellSettingsView()
        }
    }
}

extension ShellFeature {
    /// Subscribes a main-thread handler to a notification. Wheelie's notifications
    /// are posted on the main thread and delivered synchronously (so a job's
    /// outputs arrive right before its finish); anything else hops to main.
    static func observe(_ name: Notification.Name,
                        _ handler: @escaping @MainActor (Notification) -> Void) -> AnyCancellable {
        NotificationCenter.default.publisher(for: name).sink { note in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(note) }
            } else {
                DispatchQueue.main.async { handler(note) }
            }
        }
    }
}
