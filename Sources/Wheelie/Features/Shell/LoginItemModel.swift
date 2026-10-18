import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// "Launch at login" via `SMAppService.mainApp`, reflecting the real status
/// (which the user can also change in System Settings › General › Login Items).
@MainActor
final class LoginItemModel: ObservableObject {
    static let shared = LoginItemModel()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?
    private var observers: [AnyCancellable] = []

    private init() {
        refresh()
        // The user may flip it in System Settings while Wheelie runs.
        observers.append(ShellFeature.observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.refresh()
        })
    }

    /// On, or registered and waiting for the user's approval.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// Login items registered from a build folder or a disk image break when it moves.
    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps)
    }

    var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.setEnabled($0) })
    }

    /// Re-reads the status. When it changed outside Wheelie (e.g. the user followed the error's
    /// advice and allowed Wheelie in System Settings), an earlier error no longer applies.
    func refresh() {
        if updateStatus() { errorMessage = nil }
    }

    /// Returns true when the status changed.
    @discardableResult
    private func updateStatus() -> Bool {
        let current = SMAppService.mainApp.status
        guard current != status else { return false }
        status = current
        return true
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = isAppBundle
                ? "Couldn't update launch at login: \(error.localizedDescription) You can try again, or set it up in System Settings › General › Login Items."
                : "Launch at login needs the Wheelie app bundle (run scripts/bundle.sh and open Wheelie.app)."
        }
        updateStatus()   // not refresh(): keep the error this attempt just produced
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Toggle plus status notes, shared by Settings and the welcome window.
struct LaunchAtLoginControl: View {
    @ObservedObject var model = LoginItemModel.shared
    var title = "Launch at login"
    var showsLocationHint = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: model.binding)
            if model.needsApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("One more step: allow Wheelie in System Settings › Login Items.")
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                        .controlSize(.small)
                }
                .font(.callout)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsLocationHint, !model.isInApplicationsFolder {
                Text("Works best when Wheelie is in your Applications folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refresh() }
    }
}
