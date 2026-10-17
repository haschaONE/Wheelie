import AppKit
import SwiftUI
import WheelieCore

enum ShellSettingsTab: String, CaseIterable, Identifiable {
    case general, output, terminal, tools, about
    var id: String { rawValue }
}

/// Which Settings tab is showing; lets other code open Settings at a tab.
@MainActor
final class ShellSettingsNavigation: ObservableObject {
    static let shared = ShellSettingsNavigation()
    @Published var tab: ShellSettingsTab = .general
}

struct ShellSettingsView: View {
    @ObservedObject private var navigation = ShellSettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(ShellSettingsTab.general)
            OutputSettingsTab()
                .tabItem { Label("Output", systemImage: "folder") }
                .tag(ShellSettingsTab.output)
            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(ShellSettingsTab.terminal)
            ToolsSettingsTab()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(ShellSettingsTab.tools)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(ShellSettingsTab.about)
        }
        .padding(.top, 8)
        .frame(width: 580, height: 500)
        .background(ShellCloseShortcuts { AppServices.shared.closeWindow(id: "shell.settings") })
    }
}

/// Writes go through @AppStorage (UserDefaults.standard); this re-applies them right away.
@MainActor
private func settingsChanged() {
    AppServices.shared.applySettings()
}

// MARK: General

private struct GeneralSettingsTab: View {
    @AppStorage(SettingsKey.wheelEnabled) private var wheelEnabled = true
    @AppStorage(SettingsKey.triggerModifier) private var triggerModifier = TriggerModifier.shift.rawValue
    @AppStorage(SettingsKey.playSounds) private var playSounds = true

    private var modifier: TriggerModifier { TriggerModifier(setting: triggerModifier) }

    var body: some View {
        Form {
            Section {
                Toggle("Modifier-drag opens the wheel", isOn: $wheelEnabled)
                Picker("Trigger key", selection: $triggerModifier) {
                    ForEach(TriggerModifier.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!wheelEnabled)
            } header: {
                Text("Wheel")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start dragging files in Finder or any app, then hold \(modifier.label) to open the wheel under the pointer. Drop on a petal to convert or edit.")
                    if modifier.affectsFinderDrops {
                        Label {
                            Text("While held, \(modifier.label) also changes what Finder does with a drop: Option copies instead of moving, Command moves instead of copying. If you let go outside the wheel, Finder uses that behaviour.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } else {
                        Text("Shift and Control don't change what Finder does with a drop, so they're the safest choice.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                LaunchAtLoginControl()
            }

            Section("Feedback") {
                HStack {
                    Toggle("Play sounds and haptic feedback", isOn: $playSounds)
                    Spacer()
                    Button("Preview") { ShellFeedback.shared.preview() }
                        .controlSize(.small)
                }
                Text("A soft tick as you move across petals, and a chime when a file is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: wheelEnabled) { settingsChanged() }
        .onChange(of: triggerModifier) { settingsChanged() }
        .onChange(of: playSounds) { settingsChanged() }
    }
}

// MARK: Output

private struct OutputSettingsTab: View {
    @AppStorage(SettingsKey.outputLocation) private var outputLocation = OutputLocation.original.rawValue
    @AppStorage(SettingsKey.customOutputFolder) private var customFolder = ""
    @AppStorage(SettingsKey.revealResults) private var revealResults = false
    @AppStorage(SettingsKey.addResultsToFloat) private var addResultsToFloat = false
    @AppStorage(SettingsKey.floatWheelBehavior) private var floatWheelBehavior = "existing"

    private var location: OutputLocation { OutputLocation(setting: outputLocation) }

    var body: some View {
        Form {
            Section {
                // fixedSize keeps the radio buttons stacked (a grouped Form lays them out in a row).
                Picker("Save results", selection: locationBinding) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .fixedSize()

                if location == .custom {
                    HStack(spacing: 8) {
                        if !customFolder.isEmpty {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: customFolder))
                                .resizable().frame(width: 18, height: 18)
                        }
                        Text(customFolder.isEmpty ? "No folder chosen" : OutputLocation.displayPath(customFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(customFolder.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { _ = chooseFolder() }
                    }
                    if let warning = folderWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Originals are never changed. When a name is taken, Wheelie adds a number, like “photo 2.jpg”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("After saving") {
                Toggle("Reveal results in Finder", isOn: $revealResults)
                Toggle("Add results to a Float", isOn: $addResultsToFloat)
                Picker("Float on the wheel", selection: $floatWheelBehavior) {
                    Text("Add Files to an Existing Float").tag("existing")
                    Text("Create a New Float").tag("new")
                }
                Text("A Float is a small shelf that keeps new files handy, so you can drag them on to Mail, Messages or the web.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: outputLocation) { settingsChanged() }
        .onChange(of: customFolder) { settingsChanged() }
        .onChange(of: revealResults) { settingsChanged() }
        .onChange(of: addResultsToFloat) { settingsChanged() }
        .onChange(of: floatWheelBehavior) { settingsChanged() }
    }

    /// Picking "In a folder…" without a folder asks for one; cancelling keeps the old choice.
    private var locationBinding: Binding<OutputLocation> {
        Binding(get: { location }, set: { newValue in
            if newValue == .custom, customFolder.isEmpty || !folderExists {
                guard chooseFolder() else { return }
            }
            outputLocation = newValue.rawValue
        })
    }

    private var folderExists: Bool {
        !customFolder.isEmpty && FileManager.default.fileExists(atPath: customFolder)
    }

    private var folderWarning: String? {
        guard !customFolder.isEmpty else { return "Choose a folder, or results are saved next to the originals." }
        let url = URL(fileURLWithPath: customFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) { return "This folder no longer exists. Choose another one." }
        if !OutputLocation.isUsableFolder(url) { return "Wheelie can't write to this folder. Choose another one." }
        return nil
    }

    /// Returns true when a folder was chosen.
    private func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Wheelie saves converted files"
        if !customFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: customFolder, isDirectory: true) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        customFolder = url.path
        outputLocation = OutputLocation.custom.rawValue
        return true
    }
}

// MARK: Terminal

private struct TerminalSettingsTab: View {
    @AppStorage(SettingsKey.terminalApp) private var terminalApp = TerminalCatalog.defaultBundleID
    @State private var refresh = 0

    var body: some View {
        let choices = TerminalCatalog.choices(selected: terminalApp, isInstalled: Self.isInstalled)
        let others = TerminalCatalog.notInstalled(isInstalled: Self.isInstalled)
        Form {
            Section {
                ForEach(choices) { choice in
                    TerminalRow(choice: choice, selected: choice.app.bundleID == terminalApp) {
                        terminalApp = choice.app.bundleID
                    }
                }
            } header: {
                Text("Open in Terminal uses")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if choices.first(where: { $0.app.bundleID == terminalApp })?.isInstalled == false {
                        Text("\(TerminalCatalog.app(for: terminalApp).name) isn't installed, so Terminal opens instead.")
                            .foregroundStyle(.orange)
                    }
                    Text("Drop files or folders on the wheel's Terminal petal to open a window there.")
                    if !others.isEmpty {
                        Text("Also supported when installed: \(others.map(\.name).joined(separator: ", ")).")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .onChange(of: terminalApp) { settingsChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1   // re-detect after the user installs a terminal
        }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

private struct TerminalRow: View {
    let choice: TerminalCatalog.Choice
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                appIcon.frame(width: 22, height: 22)
                Text(choice.app.name)
                if !choice.isInstalled {
                    Text("(Not installed)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var appIcon: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.app.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }
}

// MARK: Tools

private struct ToolsSettingsTab: View {
    @State private var statuses: [ToolStatus] = ToolCatalog.check()
    @State private var hasHomebrew = ToolCatalog.homebrewPath() != nil

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(summary)
                    Spacer()
                    Button("Re-check") { recheck() }
                }
                if let command = ToolCatalog.installCommand(for: statuses) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Install what's missing by pasting this into Terminal:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ShellCommandBox(command: command)
                        if !hasHomebrew {
                            HStack(spacing: 4) {
                                Text("Homebrew isn't installed yet.")
                                    .foregroundStyle(.secondary)
                                Link("Get Homebrew…", destination: URL(string: "https://brew.sh")!)
                            }
                            .font(.callout)
                        }
                    }
                }
            }

            Section {
                ForEach(statuses) { status in
                    ToolRow(status: status)
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Wheelie uses free Homebrew tools for video, audio, WebP, archives and Office files, and looks for them in /opt/homebrew/bin, /usr/local/bin and /usr/bin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { recheck() }
    }

    private var summary: String {
        let found = statuses.filter(\.isFound).count
        if found == statuses.count { return "All \(found) tools found." }
        let missingEssentials = statuses.filter { !$0.isFound && $0.requirement.importance == .essential }.count
        if missingEssentials > 0 { return "\(missingEssentials) essential tool\(missingEssentials == 1 ? " is" : "s are") missing." }
        return "\(found) of \(statuses.count) tools found."
    }

    private func recheck() {
        statuses = ToolCatalog.check()
        hasHomebrew = ToolCatalog.homebrewPath() != nil
    }
}

private struct ToolRow: View {
    let status: ToolStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusIcon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.requirement.name).font(.system(.body, design: .monospaced))
                    if status.requirement.importance == .optional {
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(status.requirement.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.path.map { OutputLocation.displayPath($0.path) } ?? "Not installed")
                .font(.caption)
                .foregroundStyle(status.isFound ? .secondary : statusColor)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if status.isFound { return .green }
        return status.requirement.importance == .optional ? .secondary : .orange
    }

    private var statusIcon: some View {
        Image(systemName: status.isFound ? "checkmark.circle.fill"
              : status.requirement.importance == .optional ? "minus.circle" : "exclamationmark.circle.fill")
            .foregroundStyle(statusColor)
            .accessibilityLabel(status.isFound ? "Found" : "Missing")
    }
}

// MARK: About

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Wheelie")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(ShellUI.appVersion())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Convert and edit files right where you drag them.")
                .padding(.top, 4)
            Text("Built with ffmpeg, libwebp and Apple frameworks.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("How to Use Wheelie…") { WelcomeWindowController.shared.show() }
                Button("Show Tools") { ShellSettingsNavigation.shared.tab = .tools }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
