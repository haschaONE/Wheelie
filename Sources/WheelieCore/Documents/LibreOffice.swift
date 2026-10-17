import Foundation

/// Optional LibreOffice bridge for formats Apple frameworks can't read (PowerPoint, Keynote, Excel 97,
/// Numbers, OpenDocument presentations/spreadsheets, Pages). Only used when `soffice` is installed.
public enum LibreOffice {
    /// Extensions that need LibreOffice; without it they're recognised but get no targets.
    static let requiredExtensions: Set<String> = ["pptx", "ppt", "pps", "ppsx", "key", "odp", "xls", "numbers", "ods", "pages"]

    /// `soffice` on PATH/Homebrew or inside LibreOffice.app. Cached for a few seconds because the wheel
    /// asks for targets many times per drag.
    public static var executable: URL? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let checked = cache.checked, Date().timeIntervalSince(checked) < 10 { return cache.url }
        cache.url = locate()
        cache.checked = Date()
        return cache.url
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var url: URL?
        var checked: Date?
    }

    private static let cache = Cache()

    private static func locate() -> URL? {
        if let found = Tools.locate("soffice") { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Applications/LibreOffice.app/Contents/MacOS/soffice", home + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static var isInstalled: Bool { executable != nil }

    /// Converts `source` with `soffice --headless --convert-to <filter>` into a temp folder and returns the
    /// produced file; the caller moves or reads it and then removes `workDirectory`.
    static func convert(_ source: URL, filter: String, ext: String, workDirectory: URL) async throws -> URL {
        guard let soffice = executable else { throw DocumentError.needsLibreOffice(source.pathExtension.lowercased()) }
        let out = workDirectory.appendingPathComponent("out", isDirectory: true)
        let profile = workDirectory.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A private profile avoids clashing with a running LibreOffice and its first-run dialogs.
        try await Tools.capture(soffice.path, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                                "--nolockcheck", "--nodefault", "--convert-to", filter, "--outdir", out.path, source.path])
        let expected = out.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        if let any = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == ext }) {
            return any
        }
        throw DocumentError.unreadable("LibreOffice couldn't convert \(source.lastPathComponent).")
    }

    /// LibreOffice filter names for each output.
    static func filter(for format: OutputFormat) -> (filter: String, ext: String)? {
        switch format {
        case .pdf: return ("pdf", "pdf")
        case .docx: return ("docx:MS Word 2007 XML", "docx")
        case .odt: return ("odt", "odt")
        case .rtf: return ("rtf", "rtf")
        case .xlsx: return ("xlsx:Calc MS Excel 2007 XML", "xlsx")
        case .csv: return ("csv:Text - txt - csv (StarCalc):44,34,76,1", "csv")
        default: return nil
        }
    }
}
