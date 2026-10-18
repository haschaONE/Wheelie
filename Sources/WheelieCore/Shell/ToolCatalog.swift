import Foundation

/// A command-line tool some Wheelie feature uses.
public struct ToolRequirement: Identifiable, Hashable, Sendable {
    public enum Importance: Int, Comparable, Sendable {
        /// Core conversions break without it.
        case essential
        /// A wheel tool is unavailable without it.
        case recommended
        /// Nice to have; Wheelie falls back or hides the item.
        case optional

        public static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }
    }

    /// The executable name, shown in Settings and looked up with `Tools.locate`.
    public let name: String
    /// Places to check besides the Homebrew/system bin folders (e.g. inside an app bundle).
    public let extraPaths: [String]
    /// What to pass to `brew install`: a formula ("webp") or "--cask <name>".
    public let brewPackage: String
    public let purpose: String
    public let importance: Importance

    public var id: String { name }
    public var isCask: Bool { brewPackage.hasPrefix("--cask ") }

    public init(name: String, extraPaths: [String] = [], brewPackage: String, purpose: String, importance: Importance) {
        self.name = name
        self.extraPaths = extraPaths
        self.brewPackage = brewPackage
        self.purpose = purpose
        self.importance = importance
    }
}

public struct ToolStatus: Identifiable, Hashable, Sendable {
    public let requirement: ToolRequirement
    /// Where the tool was found; nil when missing.
    public let path: URL?

    public var id: String { requirement.id }
    public var isFound: Bool { path != nil }

    public init(requirement: ToolRequirement, path: URL?) {
        self.requirement = requirement
        self.path = path
    }
}

public enum ToolCatalog {
    /// Every tool some feature runs or looks up. Archives need nothing extra: Extract uses
    /// the system's /usr/bin/tar (libarchive), which reads zip, 7z and rar.
    public static let all: [ToolRequirement] = [
        ToolRequirement(name: "ffmpeg", brewPackage: "ffmpeg",
                        purpose: "Video and audio conversion, GIFs, trimming", importance: .essential),
        ToolRequirement(name: "ffprobe", brewPackage: "ffmpeg",
                        purpose: "Reads durations and tracks of media files", importance: .essential),
        ToolRequirement(name: "cwebp", brewPackage: "webp",
                        purpose: "WebP images", importance: .essential),
        ToolRequirement(name: "exiftool", brewPackage: "exiftool",
                        purpose: "Removing metadata from more file types", importance: .optional),
        ToolRequirement(name: "soffice",
                        extraPaths: libreOfficeAppPaths(),
                        brewPackage: "--cask libreoffice",
                        purpose: "Word, Excel and PowerPoint documents (LibreOffice)", importance: .optional),
    ]

    /// LibreOffice.app's soffice in /Applications and ~/Applications, the same places
    /// `LibreOffice.executable` checks after PATH.
    public static func libreOfficeAppPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["/Applications", home + "/Applications"].map { $0 + "/LibreOffice.app/Contents/MacOS/soffice" }
    }

    /// Tools the welcome window asks for when missing.
    public static var essentials: [ToolRequirement] { all.filter { $0.importance == .essential } }

    /// Looks each tool up. `locate` defaults to `Tools.locate`; `isExecutable` checks `extraPaths`.
    public static func check(_ requirements: [ToolRequirement] = all,
                             locate: (String) -> URL? = Tools.locate,
                             isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [ToolStatus] {
        requirements.map { requirement in
            let found = locate(requirement.name)
                ?? requirement.extraPaths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
            return ToolStatus(requirement: requirement, path: found)
        }
    }

    /// `brew install …` for every missing tool, formulae first, de-duplicated
    /// (ffmpeg and ffprobe share a formula), casks as a second command. nil when nothing is missing.
    public static func installCommand(for statuses: [ToolStatus]) -> String? {
        var formulae: [String] = [], casks: [String] = []
        for status in statuses where !status.isFound {
            let package = status.requirement.brewPackage
            if status.requirement.isCask {
                let name = String(package.dropFirst("--cask ".count))
                if !casks.contains(name) { casks.append(name) }
            } else if !formulae.contains(package) {
                formulae.append(package)
            }
        }
        var commands: [String] = []
        if !formulae.isEmpty { commands.append("brew install " + formulae.joined(separator: " ")) }
        if !casks.isEmpty { commands.append("brew install --cask " + casks.joined(separator: " ")) }
        return commands.isEmpty ? nil : commands.joined(separator: " && ")
    }

    /// Homebrew's own executable, if installed.
    public static func homebrewPath(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isExecutable)
    }
}
