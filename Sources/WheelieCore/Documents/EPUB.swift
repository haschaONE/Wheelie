import Foundation

/// EPUB 2/3 → DocModel: container.xml → OPF package → spine order; each XHTML chapter goes through
/// `HTMLReader` with images resolved inside the archive. Chapters are separated by page breaks.
/// Not supported: DRM-encrypted books, fixed-layout SVG spine items, CSS styling, audio/video.
enum EPUBReader {
    struct Book {
        var title: String?
        var chapters: [String]   // archive paths, spine order
    }

    static func read(_ url: URL) throws -> DocModel {
        let zip = try ZipArchive(url: url)
        let book = try package(zip)
        var blocks: [DocBlock] = []
        for path in book.chapters {
            guard let data = try zip.read(path) else { continue }
            let html = HTMLReader.decode(data)
            let directory = (path as NSString).deletingLastPathComponent
            let chapter = try HTMLReader.parse(html, xhtml: true) { href in
                let clean = href.components(separatedBy: "#")[0]
                guard !clean.isEmpty, !clean.contains("://") else { return nil }
                return try? zip.read(resolve(clean, relativeTo: directory))
            }
            guard !chapter.isEmpty else { continue }
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks += chapter.blocks
            guard blocks.count <= DocumentLimits.maxBlocks else {
                throw DocumentError.tooLarge("EPUB content is nested too deeply or too large.")
            }
        }
        guard !blocks.isEmpty else { throw DocumentError.malformed("The EPUB has no readable chapters.") }
        return DocModel(title: book.title, blocks: blocks)
    }

    static func package(_ zip: ZipArchive) throws -> Book {
        if let mimetype = try zip.readString("mimetype"),
           mimetype.trimmingCharacters(in: .whitespacesAndNewlines) != "application/epub+zip" {
            throw DocumentError.malformed("The file is not a valid EPUB container.")
        }
        if let encryption = try zip.read("META-INF/encryption.xml") {
            let doc = try XML.document(encryption, what: "The EPUB")
            let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
            let algorithms = doc.rootElement()?.descendants("EncryptionMethod").compactMap { $0.attr("Algorithm") } ?? []
            if algorithms.contains(where: { !fontObfuscation.contains($0) }) {
                throw DocumentError.unsupported("Encrypted (DRM-protected) EPUB files are not supported.")
            }
        }
        guard let containerData = try zip.read("META-INF/container.xml") else {
            throw DocumentError.malformed("The EPUB does not identify a readable package document.")
        }
        let container = try XML.document(containerData, what: "The EPUB container document")
        guard let opfPath = container.rootElement()?.descendants("rootfile").first?.attr("full-path"),
              let opfData = try zip.read(opfPath) else {
            throw DocumentError.malformed("The EPUB does not identify a readable package document.")
        }
        guard opfData.count < 16 * 1024 * 1024 else { throw DocumentError.tooLarge("An EPUB package document is too large.") }
        let opf = try XML.document(opfData, what: "The EPUB package document")
        guard let root = opf.rootElement() else { throw DocumentError.malformed("The EPUB package document is malformed.") }
        let base = (opfPath as NSString).deletingLastPathComponent

        var manifest: [String: (href: String, type: String)] = [:]
        for item in root.child("manifest")?.children("item") ?? [] {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            manifest[id] = (resolve(href, relativeTo: base), item.attr("media-type") ?? "")
        }
        let itemrefs = root.child("spine")?.children("itemref") ?? []
        guard !itemrefs.isEmpty else { throw DocumentError.malformed("The EPUB spine is malformed.") }
        let linear = itemrefs.filter { $0.attr("linear")?.lowercased() != "no" }
        var chapters: [String] = []
        for ref in linear.isEmpty ? itemrefs : linear {
            guard let id = ref.attr("idref"), let item = manifest[id] else { continue }
            let type = item.type.lowercased()
            guard type.contains("html") || type.isEmpty || item.href.lowercased().hasSuffix("html") else { continue }
            chapters.append(item.href)
        }
        guard !chapters.isEmpty else { throw DocumentError.malformed("The EPUB has no readable chapters.") }
        let title = root.child("metadata")?.descendants("title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Book(title: title?.isEmpty == false ? title : nil, chapters: chapters)
    }

    /// Resolves a (percent-encoded) href against an archive directory, normalising "." and "..".
    static func resolve(_ href: String, relativeTo directory: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }
        var parts = directory.split(separator: "/").map(String.init)
        for component in decoded.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }
}
