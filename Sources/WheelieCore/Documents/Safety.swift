import AppKit

/// XML hardening: decode with the encoding the parser would use, refuse DTDs anywhere in the text,
/// then hand the parser exactly the text that was checked (re-encoded as UTF-8, declaration removed),
/// so neither a late `<!DOCTYPE` nor an alternative encoding can smuggle entity declarations through.
enum XMLSafety {
    /// Bytes → text: BOMs, BOM-less UTF-16/UTF-32 (detected from "<"), then the declared encoding.
    /// Unknown encodings (EBCDIC, UTF-7, ...) are refused rather than guessed.
    static func decode(_ data: Data, what: String) throws -> String {
        let unsupported = DocumentError.unsupported("\(what) uses an unsupported text encoding.")
        let b = [UInt8](data.prefix(4))
        var encoding: String.Encoding = .utf8
        var skip = 0
        switch b {
        case _ where b.starts(with: [0xEF, 0xBB, 0xBF]): skip = 3
        case _ where b.starts(with: [0x00, 0x00, 0xFE, 0xFF]): encoding = .utf32BigEndian; skip = 4
        case _ where b.starts(with: [0xFF, 0xFE, 0x00, 0x00]): encoding = .utf32LittleEndian; skip = 4
        case _ where b.starts(with: [0xFE, 0xFF]): encoding = .utf16BigEndian; skip = 2
        case _ where b.starts(with: [0xFF, 0xFE]): encoding = .utf16LittleEndian; skip = 2
        case [0x00, 0x00, 0x00, 0x3C]: encoding = .utf32BigEndian
        case [0x3C, 0x00, 0x00, 0x00]: encoding = .utf32LittleEndian
        case _ where b.starts(with: [0x00, 0x3C]): encoding = .utf16BigEndian
        case _ where b.starts(with: [0x3C, 0x00]): encoding = .utf16LittleEndian
        case [0x4C, 0x6F, 0xA7, 0x94]: throw unsupported // EBCDIC "<?xm"
        default:
            let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
            if head.hasPrefix("<?xml"), let declared = head.range(of: #"encoding\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                let name = head[declared].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map(String.init) ?? ""
                switch name {
                case "utf-8", "utf8": encoding = .utf8
                case "us-ascii", "ascii": encoding = .ascii
                case "iso-8859-1", "latin1", "iso_8859-1", "l1": encoding = .isoLatin1
                case "windows-1252", "cp1252": encoding = .windowsCP1252
                default: throw unsupported
                }
            }
        }
        guard let text = String(data: data.dropFirst(skip), encoding: encoding) else {
            throw DocumentError.malformed("\(what) is not valid text in its declared encoding.")
        }
        return text
    }

    /// Returns `text` ready for parsing, or throws if it contains a DTD.
    /// `htmlDoctype: true` (HTML/XHTML content) tolerates a DOCTYPE without an internal subset
    /// (`<!DOCTYPE html>`, XHTML 1.1's public identifier) and removes it; package XML allows none.
    static func prepare(_ text: String, what: String, htmlDoctype: Bool) throws -> String {
        var clean = text
        if clean.hasPrefix("\u{FEFF}") { clean.removeFirst() }
        if clean.contains("\u{0}") {
            // XML forbids NUL; in HTML it's junk. Never let the parser re-detect UTF-16 from it.
            guard htmlDoctype else { throw DocumentError.malformed("\(what) contains malformed XML.") }
            clean = clean.replacingOccurrences(of: "\u{0}", with: "")
        }
        let refused = DocumentError.unsupported("\(what) DTD and entity declarations are not supported.")
        if clean.range(of: "<!ENTITY", options: .caseInsensitive) != nil { throw refused }
        while let start = clean.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            guard htmlDoctype else { throw refused }
            guard let end = clean[start.upperBound...].firstIndex(of: ">") else { throw refused }
            if clean[start.upperBound..<end].contains("[") { throw refused } // internal subset
            clean.removeSubrange(start.lowerBound...end)
        }
        // The text is re-encoded as UTF-8, so a leftover encoding declaration would lie to the parser.
        if let declaration = clean.range(of: #"^\s*<\?xml[^>]*\?>"#, options: .regularExpression) {
            clean.removeSubrange(declaration)
        }
        return clean
    }
}

/// The only link targets Wheelie writes into HTML, Markdown, DOCX, RTF/ODT and PDF output.
enum LinkPolicy {
    static let schemes: Set<String> = ["http", "https", "mailto"]

    /// http(s) with a host, mailto, or an in-document "#anchor"; nil for everything else
    /// (javascript:, file:, data:, relative paths, anything with whitespace or control characters).
    static func sanitize(_ link: String?) -> String? {
        guard let raw = link?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 4096 else { return nil }
        guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if raw.hasPrefix("#") {
            return raw.count > 1 && !raw.contains(where: { "\"'<>`".contains($0) }) ? raw : nil
        }
        guard let url = URL(string: raw, encodingInvalidCharacters: false), let scheme = url.scheme?.lowercased(),
              schemes.contains(scheme) else { return nil }
        if scheme != "mailto" && (url.host ?? "").isEmpty { return nil }
        return url.absoluteString
    }

    /// Absolute URL for a PDF link annotation (anchors have no target there).
    static func externalURL(_ value: Any?) -> URL? {
        let string = (value as? URL)?.absoluteString ?? (value as? String)
        guard let safe = sanitize(string), !safe.hasPrefix("#") else { return nil }
        return URL(string: safe)
    }
}

/// Files a document may pull in by reference (HTML `<img src>`, Markdown images): only relative paths
/// that, with every symlink resolved, stay inside the document's own folder and name a regular file.
enum LocalResource {
    static func read(_ href: String, inside folder: URL) -> Data? {
        guard let url = resolve(href, inside: folder) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func resolve(_ href: String, inside folder: URL) -> URL? {
        var path = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        // Anything with a scheme (file:, http:, data:, C:) is refused; so are absolute and home paths.
        if let colon = path.firstIndex(of: ":"),
           path[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) { return nil }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\u{0}"),
              let root = canonical(folder.path) else { return nil }
        guard let target = canonical(URL(fileURLWithPath: root).appendingPathComponent(path).path),
              target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        let url = URL(fileURLWithPath: target)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= DocumentLimits.maxImageBytes else { return nil }
        return url
    }

    /// realpath(3): absolute, every symlink and ".." resolved; nil if the path doesn't exist.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Rich text from Cocoa readers (RTF, RTFD, DOC, ODT) before it reaches a writer or the PDF paginator:
/// unsafe links removed (text kept) and attachments that aren't plain in-memory files dropped.
enum CocoaText {
    static func sanitized(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.link, in: all) { value, range, _ in
            guard value != nil else { return }
            let string = (value as? URL)?.absoluteString ?? (value as? String)
            if let safe = LinkPolicy.sanitize(string), let url = URL(string: safe) {
                copy.addAttribute(.link, value: url, range: range)
            } else {
                copy.removeAttribute(.link, range: range)
            }
        }
        var unsafe: [NSRange] = []
        copy.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            // Keep only attachments backed by bytes we hold: a regular in-memory file or raw contents.
            // Symlink/folder wrappers and placeholders for files that weren't loaded are dropped.
            if let wrapper = attachment.fileWrapper {
                if !wrapper.isRegularFile { unsafe.append(range) }
            } else if attachment.contents == nil {
                unsafe.append(range)
            }
        }
        for range in unsafe.reversed() { copy.deleteCharacters(in: range) }
        return copy
    }

    /// Reads an .rtfd package without following anything outside it: only regular files directly
    /// inside the package (no symlinks, no subfolders), within a size budget, into in-memory wrappers.
    static func readRTFD(_ url: URL) throws -> NSAttributedString {
        let limit = 256 * 1024 * 1024
        let unsafe = DocumentError.unsupported("The RTFD package contains unsafe files or exceeds the 256 MB limit.")
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var wrappers: [String: FileWrapper] = [:]
        var total = 0
        for item in contents {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
            guard total <= limit else { throw unsafe }
            let wrapper = FileWrapper(regularFileWithContents: try Data(contentsOf: item))
            wrapper.preferredFilename = item.lastPathComponent
            wrappers[item.lastPathComponent] = wrapper
        }
        guard wrappers["TXT.rtf"] != nil else { throw ConversionError.unreadable(url) }
        guard let text = NSAttributedString(rtfdFileWrapper: FileWrapper(directoryWithFileWrappers: wrappers), documentAttributes: nil) else {
            throw ConversionError.unreadable(url)
        }
        return text
    }
}
