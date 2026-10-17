import Foundation

/// A terminal app Wheelie can open a folder in.
public struct TerminalApp: Identifiable, Hashable, Sendable {
    public let name: String
    public let bundleID: String
    public var id: String { bundleID }

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// Terminal apps the Settings window offers (stored as `SettingsKey.terminalApp`).
public enum TerminalCatalog {
    public static let defaultBundleID = "com.apple.Terminal"

    public static let known: [TerminalApp] = [
        TerminalApp(name: "Terminal", bundleID: defaultBundleID),
        TerminalApp(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
        TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty"),
        TerminalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
    ]

    /// The catalog entry for `bundleID`, or an entry named after the bundle id's last part.
    public static func app(for bundleID: String) -> TerminalApp {
        if let app = known.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) { return app }
        let name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return TerminalApp(name: name.isEmpty ? bundleID : name, bundleID: bundleID)
    }

    public struct Choice: Identifiable, Hashable, Sendable {
        public let app: TerminalApp
        public let isInstalled: Bool
        public var id: String { app.bundleID }
    }

    /// Picker rows: installed terminals in catalog order, plus the saved choice
    /// when it isn't installed (shown as "Not installed" rather than vanishing).
    public static func choices(selected: String?, isInstalled: (String) -> Bool) -> [Choice] {
        var rows = known.filter { isInstalled($0.bundleID) }.map { Choice(app: $0, isInstalled: true) }
        if let selected, !selected.isEmpty, !rows.contains(where: { $0.app.bundleID == selected }) {
            rows.append(Choice(app: app(for: selected), isInstalled: isInstalled(selected)))
        }
        if rows.isEmpty {
            rows.append(Choice(app: known[0], isInstalled: isInstalled(defaultBundleID)))
        }
        return rows
    }

    /// Known terminals that aren't installed (for an "Also supported" hint).
    public static func notInstalled(isInstalled: (String) -> Bool) -> [TerminalApp] {
        known.filter { !isInstalled($0.bundleID) }
    }

    /// The terminal to actually open: the saved choice when installed, else Terminal.
    public static func resolve(selected: String?, isInstalled: (String) -> Bool) -> TerminalApp {
        if let selected, !selected.isEmpty, isInstalled(selected) { return app(for: selected) }
        return known[0]
    }
}
