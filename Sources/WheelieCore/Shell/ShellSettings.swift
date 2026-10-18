import Foundation

/// Keys, defaults and value types for the settings the Settings window edits.
///
/// The raw key strings mirror the app target's `SettingsKey` (the app asserts
/// they match at launch); they live here too so the resolution logic is testable.
public enum ShellSettings {
    public enum Key {
        public static let wheelEnabled = "wheelOnDrag"
        public static let triggerModifier = "triggerModifier"
        public static let outputLocation = "outputLocation"
        public static let customOutputFolder = "customOutputFolder"
        public static let playSounds = "playSounds"
        public static let addResultsToFloat = "addResultsToFloat"
        public static let revealResults = "revealResults"
        public static let terminalApp = "terminalApp"
        /// Bool: the welcome window has been shown once.
        public static let didShowWelcome = "shell.didShowWelcome"
    }

    /// Values for `UserDefaults.register(defaults:)`, so every reader of a key
    /// (including plain `bool(forKey:)`) sees the same default.
    public static func registrationDefaults() -> [String: Any] {
        [
            Key.wheelEnabled: true,
            Key.triggerModifier: TriggerModifier.shift.rawValue,
            WheelMode.tools.settingsKey: TriggerModifier.command.rawValue,
            WheelMode.actions.settingsKey: TriggerModifier.control.rawValue,
            Key.outputLocation: OutputLocation.original.rawValue,
            Key.playSounds: true,
            Key.addResultsToFloat: false,
            Key.revealResults: false,
            Key.terminalApp: TerminalCatalog.defaultBundleID,
        ]
    }

    /// Bool setting with a fallback for when it was never written (and no default is registered).
    public static func bool(_ key: String, in defaults: UserDefaults, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

/// The key held while dragging files to open the wheel.
public enum TriggerModifier: String, CaseIterable, Identifiable, Sendable {
    case shift, control, option, command

    public var id: String { rawValue }

    /// Unknown or missing values fall back to Shift.
    public init(setting: String?) {
        self = setting.flatMap(TriggerModifier.init(rawValue:)) ?? .shift
    }

    public var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    public var name: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    /// "⇧ Shift"
    public var label: String { "\(symbol) \(name)" }

    /// Lower-case key cap text, as printed on Mac keyboards: "⇧ shift".
    public var keyCap: String { "\(symbol) \(name.lowercased())" }

    /// Finder reads Option (copy) and Command (move) during a drag, so holding
    /// them also changes what happens when the file is dropped outside the wheel.
    public var affectsFinderDrops: Bool { self == .option || self == .command }
}

/// Where conversion results are saved.
public enum OutputLocation: String, CaseIterable, Identifiable, Sendable {
    case original, downloads, custom

    public var id: String { rawValue }

    /// Unknown or missing values fall back to "next to the original".
    public init(setting: String?) {
        self = setting.flatMap(OutputLocation.init(rawValue:)) ?? .original
    }

    public var title: String {
        switch self {
        case .original: return "Next to the original"
        case .downloads: return "In Downloads"
        case .custom: return "In a folder…"
        }
    }

    /// The folder results go to; nil means next to each original.
    /// A custom location without a folder falls back to next to the original.
    public func directory(customPath: String?, downloads: URL?) -> URL? {
        switch self {
        case .original:
            return nil
        case .downloads:
            return downloads
        case .custom:
            guard let path = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    /// True when `url` is an existing, writable folder.
    public static func isUsableFolder(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: url.path)
    }

    /// "~/Pictures/Converted" style display path.
    public static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Tangerine-style: three wheels, each opened by tapping its own key while dragging files.
/// ⇧ formats, ⌘ file tools, ⌃ file actions by default; each key can be changed or turned off.
public enum WheelMode: String, CaseIterable, Identifiable, Sendable {
    case convert, tools, actions

    public var id: String { rawValue }

    /// UserDefaults key holding a `TriggerModifier` raw value, or "off".
    /// Convert keeps the old single-wheel key so existing choices carry over.
    public var settingsKey: String {
        switch self {
        case .convert: return ShellSettings.Key.triggerModifier
        case .tools: return "wheelKey.tools"
        case .actions: return "wheelKey.actions"
        }
    }

    public var defaultModifier: TriggerModifier {
        switch self {
        case .convert: return .shift
        case .tools: return .command
        case .actions: return .control
        }
    }

    public var title: String {
        switch self {
        case .convert: return "Convert formats"
        case .tools: return "File tools"
        case .actions: return "File actions"
        }
    }

    public static let offValue = "off"

    /// The key for this wheel, or nil when turned off. Unknown values fall back to the default.
    public func modifier(in defaults: UserDefaults) -> TriggerModifier? {
        let value = defaults.string(forKey: settingsKey)
        if value == Self.offValue { return nil }
        return value.flatMap(TriggerModifier.init(rawValue:)) ?? defaultModifier
    }

    /// Key → wheel for every wheel that's on. If two wheels share a key, the first one
    /// (convert, tools, actions) wins, so a tap is never ambiguous.
    public static func assignments(in defaults: UserDefaults) -> [(TriggerModifier, WheelMode)] {
        var taken = Set<TriggerModifier>()
        var result: [(TriggerModifier, WheelMode)] = []
        for mode in allCases {
            guard let key = mode.modifier(in: defaults), taken.insert(key).inserted else { continue }
            result.append((key, mode))
        }
        return result
    }
}
