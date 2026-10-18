import AppKit
import PDFKit
import Vision

/// PDF → DocModel ("editable paragraphs"): rebuilds paragraphs, headings, lists and code from the
/// positioned text PDFKit extracts, drops running headers/footers, keeps embedded pictures as cropped
/// images, and OCRs pages that have no text layer (falling back to the page image).
/// Not recovered: tables (their cells come out as paragraphs), multi-column order beyond PDFKit's,
/// vector-only figures, links.
enum PDFReflow {
    struct Line {
        var text: String
        var runs: [DocRun]
        var rect: CGRect
        var size: CGFloat
        var bold: Bool
        var mono: Bool
        var page: Int
        var recognized = false
    }

    enum Item {
        case line(Line)
        case image(DocImage)
    }

    static func read(_ url: URL, recognizeText: Bool = true) throws -> DocModel {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.unreadable("The PDF cannot be read, is empty, or is password-protected.")
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw DocumentError.unreadable("The PDF cannot be read, is empty, or is password-protected.")
        }
        guard document.pageCount > 0 else { throw DocumentError.unreadable("The PDF cannot be read, is empty, or is password-protected.") }
        guard document.allowsCopying else { throw DocumentError.unsupported("This PDF does not allow copying its content.") }
        guard document.pageCount <= DocumentLimits.maxPDFPages else {
            throw DocumentError.tooLarge("The PDF has more than \(DocumentLimits.maxPDFPages) pages.")
        }

        var pages: [[Item]] = []
        var totalCharacters = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { pages.append([]); continue }
            var lines = extractLines(page, index: index)
            totalCharacters += lines.reduce(0) { $0 + $1.text.count }
            guard totalCharacters <= DocumentLimits.maxTextCharacters else {
                throw DocumentError.tooLarge("The document text exceeds the conversion limit.")
            }
            var items: [Item] = []
            let visible = lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
            if visible < 4 {
                // Scanned page: OCR it, else keep the page as a picture.
                lines = recognizeText ? recognize(page, index: index) : []
                if lines.isEmpty {
                    if let image = try? Converter.render(page, scale: 2, box: .mediaBox), let docImage = DocImage(cgImage: image, jpeg: true) {
                        var docImage = docImage
                        docImage.displayWidth = Double(page.bounds(for: .mediaBox).width)
                        items.append(.image(docImage))
                    }
                } else {
                    items = lines.map { .line($0) }
                }
            } else {
                items = interleave(lines: lines, images: pictures(on: page, lines: lines))
            }
            pages.append(items)
        }
        removeRunningHeaders(&pages, document: document)
        let model = Assembler(items: pages.flatMap { $0 }).assemble()
        var title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        if title?.isEmpty != false { title = nil }
        return DocModel(title: title, blocks: model)
    }

    // MARK: Text lines

    /// Lines with geometry from `selectionsByLine()` (PDFKit's `characterBounds(at:)` index space skips the
    /// newlines it synthesises in `page.string` on some systems) and fonts from one `attributedString` per page.
    static func extractLines(_ page: PDFPage, index: Int) -> [Line] {
        guard let string = page.string, !string.isEmpty,
              let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        let ns = string as NSString
        let attributed = page.attributedString
        let fonts = attributed?.length == ns.length ? attributed : nil
        var cursor = 0
        var lines: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            guard let raw = lineSelection.string else { continue }
            let text = raw.trimmingCharacters(in: .newlines)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rect = lineSelection.bounds(for: page)
            guard rect.width > 0, rect.height > 0 else { continue }

            // Find the line in page.string (normally right after the previous one) to read its fonts.
            var range = ns.range(of: text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            if range.location == NSNotFound { range = ns.range(of: text) }
            if range.location != NSNotFound { cursor = NSMaxRange(range) }

            var runs: [DocRun] = []
            var sizeSum: CGFloat = 0, sizeCount = 0, boldCount = 0, monoCount = 0
            if let fonts, range.location != NSNotFound {
                fonts.enumerateAttribute(.font, in: range) { value, r, _ in
                    let chunk = ns.substring(with: r)
                    var style: DocStyle = []
                    if let font = value as? NSFont {
                        let traits = PDFReflow.traits(of: font)
                        if traits.bold { style.insert(.bold) }
                        if traits.italic { style.insert(.italic) }
                        if traits.mono { style.insert(.code) }
                        let visible = chunk.filter { !$0.isWhitespace }.count
                        sizeSum += font.pointSize * CGFloat(visible)
                        sizeCount += visible
                        if traits.bold { boldCount += visible }
                        if traits.mono { monoCount += visible }
                    }
                    runs.append(DocRun(chunk, style: style))
                }
            } else {
                runs = [DocRun(text)]
            }
            let visible = max(text.filter { !$0.isWhitespace }.count, 1)
            let size = sizeCount > 0 ? sizeSum / CGFloat(sizeCount) : rect.height * 0.8
            lines.append(Line(text: text, runs: runs.merged(), rect: rect, size: size,
                              bold: boldCount * 10 >= visible * 8, mono: sizeCount > 0 && monoCount * 10 >= visible * 9, page: index))
        }
        return lines
    }

    static func traits(of font: NSFont) -> (bold: Bool, italic: Bool, mono: Bool) {
        let name = font.fontName.lowercased()
        let symbolic = font.fontDescriptor.symbolicTraits
        let bold = symbolic.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains(where: name.contains)
        let italic = symbolic.contains(.italic) || name.contains("italic") || name.contains("oblique")
        let mono = font.isFixedPitch || symbolic.contains(.monoSpace)
            || ["mono", "courier", "consolas", "menlo", "monaco", "code"].contains(where: name.contains)
        return (bold, italic, mono)
    }

    // MARK: OCR

    static func recognize(_ page: PDFPage, index: Int) -> [Line] {
        guard let image = try? Converter.render(page, scale: 2, box: .mediaBox) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        let bounds = page.bounds(for: .mediaBox)
        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let box = observation.boundingBox
            let rect = CGRect(x: bounds.minX + box.minX * bounds.width, y: bounds.minY + box.minY * bounds.height,
                              width: box.width * bounds.width, height: box.height * bounds.height)
            lines.append(Line(text: candidate.string, runs: [DocRun(candidate.string)], rect: rect, size: rect.height * 0.8,
                              bold: false, mono: false, page: index, recognized: true))
        }
        guard lines.reduce(0, { $0 + $1.text.count }) >= 3 else { return [] }
        return lines.sorted { abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) / 2 ? $0.rect.midY > $1.rect.midY : $0.rect.minX < $1.rect.minX }
    }

    // MARK: Pictures

    /// Rectangles (page space) where image XObjects are drawn, found by scanning the content stream.
    static func imageRects(_ page: PDFPage) -> [CGRect] {
        guard let cgPage = page.pageRef, page.rotation % 360 == 0 else { return [] }
        let scanner = ImageScanner()
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        scanner.scan(stream, depth: 0)
        CGPDFContentStreamRelease(stream)
        return scanner.rects
    }

    static func pictures(on page: PDFPage, lines: [Line]) -> [(rect: CGRect, image: DocImage)] {
        let pageBox = page.bounds(for: .mediaBox)
        var result: [(CGRect, DocImage)] = []
        for raw in imageRects(page) {
            let rect = raw.intersection(pageBox)
            guard !rect.isNull, rect.width >= 36, rect.height >= 36 else { continue }
            if rect.width * rect.height > pageBox.width * pageBox.height * 0.9 { continue } // background
            // Skip images that sit behind running text (watermarks, textures).
            if lines.filter({ rect.insetBy(dx: 2, dy: 2).contains($0.rect) }).count > 3 { continue }
            if result.contains(where: { $0.0.insetBy(dx: -2, dy: -2).contains(rect) }) { continue }
            guard let cropped = crop(page, to: rect, scale: 2) else { continue }
            let jpeg = rect.width * rect.height > 40_000
            guard var image = DocImage(cgImage: cropped, alt: "", jpeg: jpeg) else { continue }
            image.displayWidth = Double(rect.width)
            result.append((rect, image))
            if result.count >= 200 { break }
        }
        return result
    }

    static func crop(_ page: PDFPage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0, width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Places each picture before the first line that starts below its top edge.
    static func interleave(lines: [Line], images: [(rect: CGRect, image: DocImage)]) -> [Item] {
        var items = lines.map { Item.line($0) }
        for picture in images.sorted(by: { $0.rect.maxY < $1.rect.maxY }) {
            let index = items.firstIndex { item in
                if case .line(let line) = item { return line.rect.maxY <= picture.rect.maxY + 1 }
                return false
            } ?? items.count
            items.insert(.image(picture.image), at: index)
        }
        return items
    }

    // MARK: Running headers / footers

    static func removeRunningHeaders(_ pages: inout [[Item]], document: PDFDocument) {
        guard pages.count >= 2 else { return }
        func key(_ line: Line) -> String? {
            guard let page = document.page(at: line.page) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let relative = (line.rect.midY - box.minY) / max(box.height, 1)
            guard relative > 0.9 || relative < 0.1 else { return nil }
            let normalized = line.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return (relative > 0.5 ? "top:" : "bottom:") + normalized
        }
        var counts: [String: Int] = [:]
        for items in pages {
            var seen = Set<String>()
            for case .line(let line) in items { if let k = key(line), seen.insert(k).inserted { counts[k, default: 0] += 1 } }
        }
        let threshold = max(2, pages.count / 2)
        for p in pages.indices {
            pages[p].removeAll { item in
                guard case .line(let line) = item, let k = key(line) else { return false }
                return counts[k, default: 0] >= threshold || k.hasSuffix(":#") || k.hasSuffix(":- # -") || k.hasSuffix(":page #")
            }
        }
    }

    // MARK: Paragraph assembly

    struct Assembler {
        let items: [Item]
        let bodySize: CGFloat
        let leadingRatio: CGFloat

        static let listPattern = try! NSRegularExpression(pattern: #"^\s*([•●▪◦‣∙·○■□➢►–—\-\*]|\(?\d{1,3}[.)]|\(?[a-zA-Z][.)])\s+"#)

        init(items: [Item]) {
            self.items = items
            var weights: [CGFloat: Int] = [:]
            var ratios: [CGFloat] = []
            var previous: Line?
            for case .line(let line) in items where !line.recognized {
                weights[(line.size * 2).rounded() / 2, default: 0] += line.text.count
                if let prev = previous, prev.page == line.page, abs(prev.size - line.size) < 0.5 {
                    let distance = prev.rect.minY - line.rect.minY
                    if distance > 0, distance < line.size * 3 { ratios.append(distance / max(line.size, 1)) }
                }
                previous = line
            }
            bodySize = weights.max { $0.value < $1.value }?.key ?? 11
            ratios.sort()
            leadingRatio = ratios.isEmpty ? 1.25 : ratios[ratios.count / 2]
        }

        func assemble() -> [DocBlock] {
            var blocks: [DocBlock] = []
            var current: [Line] = []

            func flush() {
                guard !current.isEmpty else { return }
                defer { current = [] }
                if current.allSatisfy(\.mono) {
                    blocks.append(.code(current.map(\.text).joined(separator: "\n")))
                    return
                }
                var kind = DocParagraph.Kind.body
                var runs = joinedRuns(current)
                let text = runs.plainText
                if let match = Assembler.listPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let markerRange = Range(match.range, in: text) {
                    let marker = text[markerRange].trimmingCharacters(in: .whitespaces)
                    let ordered = marker.first.map { $0.isNumber || $0.isLetter || $0 == "(" } ?? false
                    kind = .listItem(ordered: ordered, level: 1)
                    runs = dropPrefix(runs, count: text.distance(from: text.startIndex, to: markerRange.upperBound))
                } else if let level = headingLevel(current, text: text) {
                    kind = .heading(level)
                    runs = runs.map { DocRun($0.text, style: $0.style.subtracting(.bold), link: $0.link) }
                }
                let trimmed = runs.trimmed()
                if !trimmed.isEmpty { blocks.append(.paragraph(DocParagraph(kind, runs: trimmed))) }
            }

            for item in items {
                switch item {
                case .image(let image):
                    flush()
                    blocks.append(.image(image))
                case .line(let line):
                    if let last = current.last, continues(current, last: last, next: line) {
                        current.append(line)
                    } else {
                        flush()
                        current = [line]
                    }
                }
            }
            flush()
            return blocks
        }

        func isListStart(_ line: Line) -> Bool {
            Assembler.listPattern.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil
        }

        func endsSentence(_ text: String) -> Bool {
            guard let last = text.trimmingCharacters(in: .whitespaces).last else { return true }
            return ".!?:;\"”’)".contains(last)
        }

        func continues(_ paragraph: [Line], last: Line, next: Line) -> Bool {
            if last.mono != next.mono { return false }
            if last.mono && next.mono { return last.page == next.page && last.rect.minY - next.rect.minY < next.size * 2.2 }
            if isListStart(next) { return false }
            let startsLower = next.text.trimmingCharacters(in: .whitespaces).first?.isLowercase ?? false
            // New page or column (text jumps up): join only mid-sentence.
            if next.page != last.page || next.rect.maxY > last.rect.maxY + 2 {
                return !endsSentence(last.text) && startsLower && abs(next.size - last.size) < 1
            }
            if abs(next.size - last.size) > 1 { return false }
            if last.bold != next.bold && (paragraph.allSatisfy(\.bold) || next.bold) { return false }
            let distance = last.rect.minY - next.rect.minY
            if distance <= 0 { return false }
            if distance / max(next.size, 1) > leadingRatio * 1.3 + 0.1 { return false }
            let left = paragraph.map(\.rect.minX).min() ?? last.rect.minX
            let right = paragraph.map(\.rect.maxX).max() ?? last.rect.maxX
            // First-line indent starts a paragraph.
            if next.rect.minX > left + max(next.size, 8), endsSentence(last.text) { return false }
            // A short line ending a sentence ends the paragraph.
            if paragraph.count >= 2 || last.rect.width > 0, last.rect.maxX < right - next.size * 5, endsSentence(last.text), !startsLower {
                return false
            }
            return true
        }

        func headingLevel(_ lines: [Line], text: String) -> Int? {
            guard lines.count <= 3, text.count <= 200, !lines.contains(where: \.recognized) else { return nil }
            let size = lines.map(\.size).reduce(0, +) / CGFloat(lines.count)
            let ratio = size / max(bodySize, 1)
            if ratio >= 1.7 { return 1 }
            if ratio >= 1.35 { return 2 }
            if ratio >= 1.12 { return 3 }
            if lines.allSatisfy(\.bold), ratio >= 0.95, lines.count <= 2, text.count <= 90,
               !text.hasSuffix("."), text.contains(where: \.isLetter) { return 4 }
            return nil
        }

        /// Concatenates line runs, de-hyphenating words broken across lines.
        func joinedRuns(_ lines: [Line]) -> [DocRun] {
            var runs: [DocRun] = []
            for line in lines {
                let lineRuns = line.runs.map { DocRun($0.text.replacingOccurrences(of: "\u{00AD}", with: ""), style: $0.style, link: $0.link) }
                if var last = runs.last {
                    let trimmedLast = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                    let nextStartsLower = lineRuns.first?.text.trimmingCharacters(in: .whitespaces).first?.isLowercase ?? false
                    if trimmedLast.hasSuffix("-"), trimmedLast.dropLast().last?.isLetter == true, nextStartsLower {
                        last.text = String(trimmedLast.dropLast())
                        runs[runs.count - 1] = last
                    } else if !(last.text.last?.isWhitespace ?? true) {
                        runs.append(DocRun(" ", style: last.style.intersection(lineRuns.first?.style ?? [])))
                    }
                }
                runs += lineRuns
            }
            return runs.merged()
        }

        func dropPrefix(_ runs: [DocRun], count: Int) -> [DocRun] {
            var remaining = count
            var out: [DocRun] = []
            for run in runs {
                if remaining <= 0 { out.append(run); continue }
                if run.text.count <= remaining { remaining -= run.text.count; continue }
                out.append(DocRun(String(run.text.dropFirst(remaining)), style: run.style, link: run.link))
                remaining = 0
            }
            return out
        }
    }
}

/// Walks a PDF content stream tracking the CTM to find where image XObjects are painted.
private final class ImageScanner {
    var rects: [CGRect] = []
    private var stack: [CGAffineTransform] = [.identity]
    private var depth = 0
    private var operations = 0
    /// Stack depth the current content stream started at. Unbalanced `Q`s inside a
    /// Form XObject (or the page) must never pop state that belongs to an outer stream.
    private var base = 1

    private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let scanner = ImageScanner.from(info) else { return }
            scanner.stack.append(scanner.stack.last ?? .identity)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let scanner = ImageScanner.from(info), scanner.stack.count > scanner.base else { return }
            scanner.stack.removeLast()
        }
        CGPDFOperatorTableSetCallback(table, "cm") { pdfScanner, info in
            guard let scanner = ImageScanner.from(info) else { return }
            var values = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(pdfScanner, &value) else { return }
                values[i] = value
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            let current = scanner.stack.popLast() ?? .identity
            scanner.stack.append(matrix.concatenating(current))
        }
        CGPDFOperatorTableSetCallback(table, "Do") { pdfScanner, info in
            guard let scanner = ImageScanner.from(info) else { return }
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(pdfScanner, &namePointer), let namePointer else { return }
            let contentStream = CGPDFScannerGetContentStream(pdfScanner)
            guard let object = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            let ctm = scanner.stack.last ?? .identity
            switch String(cString: subtype) {
            case "Image":
                scanner.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm))
            case "Form":
                guard scanner.depth < 6 else { return }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                // The form gets its own frame: [outer stack…, form matrix]. Its `Q`s may not
                // pop below that frame, and whatever it leaves behind (extra `q`s) is cut off.
                let outerBase = scanner.base
                let outerCount = scanner.stack.count
                scanner.stack.append(matrix.concatenating(ctm))
                scanner.base = scanner.stack.count
                let formStream = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, contentStream)
                scanner.depth += 1
                scanner.scan(formStream, depth: scanner.depth)
                CGPDFContentStreamRelease(formStream)
                scanner.depth -= 1
                scanner.base = outerBase
                if scanner.stack.count > outerCount {
                    scanner.stack.removeLast(scanner.stack.count - outerCount)
                }
            default:
                break
            }
        }
        return table
    }()

    static func from(_ info: UnsafeMutableRawPointer?) -> ImageScanner? {
        guard let info else { return nil }
        let scanner = Unmanaged<ImageScanner>.fromOpaque(info).takeUnretainedValue()
        scanner.operations += 1
        return scanner.operations < 2_000_000 && scanner.rects.count < 1000 ? scanner : nil
    }

    func scan(_ stream: CGPDFContentStreamRef, depth: Int) {
        let scanner = CGPDFScannerCreate(stream, ImageScanner.table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }
}
