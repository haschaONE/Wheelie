import AppKit
import WheelieCore

/// Sends files with AirDrop. NSSharingService only holds its delegate weakly, so each share keeps
/// itself (and its service) alive in `active` until the service reports success or failure.
@MainActor
final class AirDropShare: NSObject, NSSharingServiceDelegate {
    private static var active: [AirDropShare] = []
    private let service: NSSharingService

    private init(service: NSSharingService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    /// Opens the AirDrop sheet for `files`; returns once it is showing.
    static func share(_ files: [URL]) throws {
        guard !files.isEmpty, files.allSatisfy(\.isFileURL) else {
            throw FileActionError.notLocal(verb: "be shared with AirDrop")
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
            throw FileActionError.airDropUnavailable
        }
        let share = AirDropShare(service: service)
        active.append(share)
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
    }

    private func finish() {
        service.delegate = nil
        Self.active.removeAll { $0 === self }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't AirDrop files"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
