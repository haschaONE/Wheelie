import AppKit
import SwiftUI
import WheelieCore

/// First-launch welcome (also "How to Use Wheelie…" in the menu): a borderless,
/// draggable glass window with an animated how-to.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: WelcomeWindow?

    func show() {
        UserDefaults.standard.set(true, forKey: SettingsKey.didShowWelcome)
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: WelcomeView(close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        // Taller when the Homebrew hint is showing.
        let size = NSSize(width: WelcomeView.width, height: ceil(host.fittingSize.height))
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: size))
        window.contentView = ShellUI.glassContainer(cornerRadius: 24, content: host)
        window.setContentSize(size)
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

final class WelcomeWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Welcome to Wheelie"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

struct WelcomeView: View {
    static let width: CGFloat = 520

    let close: () -> Void
    /// Essential tools that aren't installed (checked once, when the window opens).
    let missingTools: [ToolStatus]

    @AppStorage(SettingsKey.triggerModifier) private var triggerModifier = TriggerModifier.shift.rawValue
    @State private var hoveringClose = false

    init(close: @escaping () -> Void,
         missingTools: [ToolStatus] = ToolCatalog.check(ToolCatalog.essentials).filter { !$0.isFound }) {
        self.close = close
        self.missingTools = missingTools
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var modifier: TriggerModifier { TriggerModifier(setting: triggerModifier) }

    var body: some View {
        VStack(spacing: 16) {
            WelcomeIllustration(modifier: modifier, animated: !reduceMotion)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Welcome to Wheelie")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Drag a file, hold \(modifier.label), and drop it on the wheel to convert or edit it — right where you are.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WheelView.accent)
                    .frame(width: 34, height: 34)
                    .background(WheelView.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find the Wheelie icon near the clock in your menu bar")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open files, see recent results and change settings from there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            if let command = ToolCatalog.installCommand(for: missingTools) {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Video, audio and WebP conversions need free Homebrew tools (\(missingTools.map(\.requirement.name).joined(separator: ", "))). Install them in Terminal:")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    ShellCommandBox(command: command)
                    if ToolCatalog.homebrewPath() == nil {
                        HStack(spacing: 4) {
                            Text("No Homebrew yet?").foregroundStyle(.secondary)
                            Link("Get it at brew.sh", destination: URL(string: "https://brew.sh")!)
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Divider()
                .padding(.top, 4)

            HStack(alignment: .center) {
                LaunchAtLoginControl(title: "Launch Wheelie at login", showsLocationHint: false)
                Spacer()
                Button {
                    close()
                } label: {
                    Text("Get Started").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Empty areas of the window drag it around (it has no title bar).
        .background(ShellWindowDragArea())
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(hoveringClose ? 0.15 : 0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Close")
            .accessibilityLabel("Close")
            .padding(14)
        }
        .background(ShellCloseShortcuts(close: close))
    }
}
