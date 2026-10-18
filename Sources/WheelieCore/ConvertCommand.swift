import Foundation

/// Headless mode for scripting and smoke tests: `Wheelie --convert <format> <file>...`
public enum ConvertCommand: Equatable {
    /// Not a `--convert` invocation: start the menu-bar app.
    case app
    /// `--convert` with something missing or wrong: print the message and exit with status 2.
    /// (Never fall through to the app, or a script would hang on a second menu-bar instance.)
    case usageError(String)
    case convert(OutputFormat, [URL])

    public static func parse(_ args: [String]) -> ConvertCommand {
        guard args.count >= 2, args[1] == "--convert" else { return .app }
        let formats = OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")
        guard args.count >= 3 else {
            return .usageError("Usage: Wheelie --convert <format> <file>...\nFormats: \(formats)")
        }
        let name = args[2].lowercased()
        guard let format = OutputFormat(rawValue: name) ?? (name == "jpg" ? .jpeg : nil) else {
            return .usageError("Unknown format \(args[2]). Options: \(formats)")
        }
        guard args.count >= 4 else {
            return .usageError("No files given. Usage: Wheelie --convert \(args[2]) <file>...")
        }
        return .convert(format, args.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL })
    }
}
