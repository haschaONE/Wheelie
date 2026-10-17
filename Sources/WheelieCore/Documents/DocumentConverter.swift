import AppKit
import PDFKit

/// Routes document, ebook, spreadsheet, presentation and PDF-reflow conversions.
/// Everything here runs off the main thread (no WebKit, no NSPrintOperation).
enum DocumentConverter {
    /// A loaded source: the structural model, plus the original rich text when the source was a
    /// Cocoa text format (RTF, DOC, ODT) so PDF/RTF/ODT output keeps its fonts and colours.
    struct Loaded {
        var model: DocModel
        var attributed: NSAttributedString?
    }

    static func convert(_ source: URL, to format: OutputFormat) async throws -> [URL] {
        let ext = source.pathExtension.lowercased()
        let kind = FileKind(url: source)
        if LibreOffice.requiredExtensions.contains(ext) {
            return try await convertWithLibreOffice(source, kind: kind, to: format)
        }
        if kind == .spreadsheet {
            return try convertSpreadsheet(try readSheets(source), source: source, to: format)
        }
        if kind == .pdf && format == .txt {
            // Keep the old behaviour as a fallback when reflow refuses (e.g. copy-protected PDFs).
            do { return [try write(try load(source, kind: kind), source: source, to: format)] } catch {
                guard let doc = PDFKitText.string(source) else { throw error }
                let output = OutputNaming.uniqueURL(for: source, ext: "txt")
                try doc.write(to: output, atomically: true, encoding: .utf8)
                return [output]
            }
        }
        return [try write(try load(source, kind: kind), source: source, to: format)]
    }

    // MARK: Loading

    static func load(_ source: URL, kind: FileKind) throws -> Loaded {
        let ext = source.pathExtension.lowercased()
        switch kind {
        case .pdf:
            return Loaded(model: try PDFReflow.read(source))
        case .ebook:
            return Loaded(model: try EPUBReader.read(source))
        default:
            break
        }
        switch ext {
        case "md", "markdown", "mdown", "mkd":
            return Loaded(model: try MarkdownReader.read(source))
        case "html", "htm", "xhtml":
            return Loaded(model: try HTMLReader.read(source))
        case "txt", "text":
            guard let data = try? Data(contentsOf: source) else { throw ConversionError.unreadable(source) }
            guard data.count <= DocumentLimits.maxTextCharacters else { throw DocumentError.tooLarge("The document text exceeds the conversion limit.") }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            return Loaded(model: DocModel.fromPlainText(text))
        case "docx", "docm", "dotx":
            do {
                return Loaded(model: try DocxReader.read(source))
            } catch {
                // Fall back to the Cocoa reader for odd producers.
                guard let rich = try? cocoaRead(source, type: .officeOpenXML) else { throw error }
                return Loaded(model: AttributedReader.read(rich), attributed: rich)
            }
        case "doc":
            let rich = try cocoaRead(source, type: .docFormat)
            return Loaded(model: AttributedReader.read(rich), attributed: rich)
        case "rtf":
            let rich = try cocoaRead(source, type: .rtf)
            return Loaded(model: AttributedReader.read(rich), attributed: rich)
        case "rtfd":
            let rich = CocoaText.sanitized(try CocoaText.readRTFD(source))
            return Loaded(model: AttributedReader.read(rich), attributed: rich)
        case "odt":
            let rich = try cocoaRead(source, type: .openDocument)
            return Loaded(model: AttributedReader.read(rich), attributed: rich)
        default:
            throw ConversionError.unreadable(source)
        }
    }

    /// Reads from bytes, not the URL, so the reader has no folder to resolve references against;
    /// unsafe links and non-file attachments are removed before anything else sees the text.
    static func cocoaRead(_ url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            let data = try Data(contentsOf: url)
            return CocoaText.sanitized(try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))
        } catch {
            throw ConversionError.unreadable(url)
        }
    }

    // MARK: Writing

    static func write(_ loaded: Loaded, source: URL, to format: OutputFormat) throws -> URL {
        let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
        var model = loaded.model
        if model.title == nil { model.title = source.deletingPathExtension().lastPathComponent }
        let setup = PDFLayout.PageSetup.current
        var theme = DocTheme()
        theme.contentWidth = setup.contentSize.width
        theme.contentHeight = setup.contentSize.height
        func rich() -> NSAttributedString {
            if let attributed = loaded.attributed {
                return fitAttachments(attributed, maxSize: CGSize(width: theme.contentWidth, height: theme.contentHeight - 24))
            }
            return AttributedBuilder.build(model, theme: theme)
        }
        do {
            switch format {
            case .markdown:
                try MarkdownWriter.render(model).write(to: output, atomically: true, encoding: .utf8)
            case .html:
                try HTMLWriter.render(model).write(to: output, atomically: true, encoding: .utf8)
            case .txt:
                var text: String
                if let attributed = loaded.attributed {
                    text = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
                    if !text.hasSuffix("\n") { text += "\n" }
                } else {
                    text = TextWriter.render(model)
                }
                try text.write(to: output, atomically: true, encoding: .utf8)
            case .docx:
                try DocxWriter.write(model, to: output, setup: setup)
            case .rtf, .odt:
                let text = rich()
                let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .openDocument
                var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
                if let title = model.title { attributes[.title] = title }
                let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
                try data.write(to: output, options: .atomic)
            case .pdf:
                try PDFLayout.write(rich(), to: output, title: model.title, setup: setup)
            default:
                throw ConversionError.unsupported(FileKind(url: source), format)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// Scales oversized images in Cocoa-loaded rich text so they fit the page.
    static func fitAttachments(_ text: NSAttributedString, maxSize: CGSize) -> NSAttributedString {
        guard text.containsAttachments else { return text }
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let cell = attachment.attachmentCell as? NSTextAttachmentCell
            if let wrapper = attachment.fileWrapper, !wrapper.isRegularFile { return }
            let fileImage = attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
            guard let image = cell?.image ?? attachment.image ?? fileImage else { return }
            guard image.size.width > maxSize.width || image.size.height > maxSize.height, image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height)
            let scaled = image.copy() as! NSImage
            scaled.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: scaled)
            attachment.bounds = CGRect(origin: .zero, size: scaled.size)
            copy.addAttribute(.attachment, value: attachment, range: range)
        }
        return copy
    }

    // MARK: Spreadsheets

    static func readSheets(_ source: URL) throws -> [Sheet] {
        switch source.pathExtension.lowercased() {
        case "csv", "tsv": return [try CSV.read(source)]
        case "xlsx", "xlsm": return try XLSX.read(source)
        default: throw ConversionError.unreadable(source)
        }
    }

    static func convertSpreadsheet(_ sheets: [Sheet], source: URL, to format: OutputFormat) throws -> [URL] {
        let title = source.deletingPathExtension().lastPathComponent
        switch format {
        case .csv:
            let nonEmpty = sheets.filter { !$0.rows.isEmpty }
            let list = nonEmpty.isEmpty ? Array(sheets.prefix(1)) : nonEmpty
            return try list.map { sheet in
                let suffix = list.count > 1 ? " - " + sheet.name.replacingOccurrences(of: "/", with: "-") : ""
                let output = OutputNaming.uniqueURL(for: source, ext: "csv", suffix: suffix)
                try CSV.write(sheet).write(to: output, atomically: true, encoding: .utf8)
                return output
            }
        case .xlsx:
            let output = OutputNaming.uniqueURL(for: source, ext: "xlsx")
            try XLSX.write(sheets, to: output)
            return [output]
        case .html:
            var blocks: [DocBlock] = []
            for sheet in sheets {
                if sheets.count > 1 { blocks.append(.paragraph(DocParagraph(.heading(2), runs: [DocRun(sheet.name)]))) }
                if !sheet.rows.isEmpty { blocks.append(.table(sheet.table)) }
            }
            let output = OutputNaming.uniqueURL(for: source, ext: "html")
            try HTMLWriter.render(DocModel(title: title, blocks: blocks)).write(to: output, atomically: true, encoding: .utf8)
            return [output]
        case .pdf:
            let output = OutputNaming.uniqueURL(for: source, ext: "pdf")
            do { try TablePDF.write(sheets, to: output, title: title) } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            return [output]
        default:
            throw ConversionError.unsupported(.spreadsheet, format)
        }
    }

    // MARK: LibreOffice

    static func convertWithLibreOffice(_ source: URL, kind: FileKind, to format: OutputFormat) async throws -> [URL] {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        func direct(_ format: OutputFormat) async throws -> URL {
            guard let (filter, ext) = LibreOffice.filter(for: format) else { throw ConversionError.unsupported(kind, format) }
            let produced = try await LibreOffice.convert(source, filter: filter, ext: ext, workDirectory: work)
            let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
            try FileManager.default.moveItem(at: produced, to: output)
            return output
        }

        switch kind {
        case .presentation:
            if format == .pdf { return [try await direct(.pdf)] }
            let pdf = try await LibreOffice.convert(source, filter: "pdf", ext: "pdf", workDirectory: work)
            return try Converter.convertPDF(pdf, to: format, naming: source)
        case .spreadsheet:
            if format == .html {
                let xlsx = try await LibreOffice.convert(source, filter: "xlsx:Calc MS Excel 2007 XML", ext: "xlsx", workDirectory: work)
                return try convertSpreadsheet(try XLSX.read(xlsx), source: source, to: .html)
            }
            return [try await direct(format)]
        default:
            if [.pdf, .docx, .odt, .rtf].contains(format) { return [try await direct(format)] }
            let docx = try await LibreOffice.convert(source, filter: "docx:MS Word 2007 XML", ext: "docx", workDirectory: work)
            return [try write(Loaded(model: try DocxReader.read(docx)), source: source, to: format)]
        }
    }
}

enum PDFKitText {
    static func string(_ url: URL) -> String? { PDFDocument(url: url)?.string }
}
