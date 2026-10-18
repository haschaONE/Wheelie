import CoreGraphics
import Darwin
import Foundation
import PDFKit

/// Metadata a PDF carries outside its Info dictionary: EXIF/GPS/XMP inside embedded JPEG images
/// (Quartz passes camera JPEGs through unchanged as DCTDecode streams), XMP packets attached to
/// pages, images and forms, and annotation authors.
enum PDFEmbeddedMetadata {
    /// One stream found while walking the document.
    enum Item {
        /// An image XObject (also soft masks and page thumbnails). `format` tells how `data` is encoded:
        /// `.jpegEncoded` is the JPEG file itself, `.JPEG2000` a JPX codestream/file.
        case image(data: Data, format: CGPDFDataFormat)
        /// A `/Metadata` XMP stream on a page, image or form (the catalog's is handled separately).
        case xmp(Data)
    }

    // MARK: Walking

    /// Calls `body` for every image and XMP stream reachable from the pages: page resources (inherited
    /// ones too), nested form XObjects, tiling patterns and annotation appearance streams.
    static func forEach(in doc: CGPDFDocument, _ body: (Item) -> Void) {
        guard doc.numberOfPages > 0 else { return }
        withoutActuallyEscaping(body) { body in
            var walker = Walker(body: body)
            for number in 1...doc.numberOfPages {
                guard let page = doc.page(at: number)?.dictionary else { continue }
                walker.visitPage(page)
            }
        }
    }

    private struct Walker {
        let body: (Item) -> Void
        var seen: Set<Int> = []   // stream addresses (CGPDF keeps one object per indirect reference)
        static let maxDepth = 24

        mutating func visitPage(_ page: CGPDFDictionaryRef) {
            visitMetadata(of: page)
            if let resources = inheritedResources(page) { visitResources(resources, depth: 0) }
            var thumb: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(page, "Thumb", &thumb), let thumb { visitStream(thumb, depth: 0, asImage: true) }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { return }
            for i in 0..<CGPDFArrayGetCount(annots) {
                var annot: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &annot), let annot else { continue }
                var appearances: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(annot, "AP", &appearances), let appearances else { continue }
                for key in ["N", "R", "D"] { visitAppearance(appearances, key: key) }
            }
        }

        /// Appearance entries are either a form XObject or a dictionary of states → form XObjects.
        mutating func visitAppearance(_ dict: CGPDFDictionaryRef, key: String) {
            var stream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(dict, key, &stream), let stream { visitStream(stream, depth: 1, asImage: false); return }
            var states: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, key, &states), let states else { return }
            for stream in streams(in: states) { visitStream(stream, depth: 1, asImage: false) }
        }

        /// Resources may be inherited from an ancestor in the page tree.
        func inheritedResources(_ page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
            var node: CGPDFDictionaryRef? = page
            for _ in 0..<64 {
                guard let current = node else { return nil }
                var resources: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { return resources }
                var parent: CGPDFDictionaryRef?
                node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            }
            return nil
        }

        mutating func visitResources(_ resources: CGPDFDictionaryRef, depth: Int) {
            guard depth < Self.maxDepth else { return }
            for category in ["XObject", "Pattern"] {
                var dict: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(resources, category, &dict), let dict else { continue }
                for stream in streams(in: dict) { visitStream(stream, depth: depth + 1, asImage: false) }
            }
        }

        mutating func visitStream(_ stream: CGPDFStreamRef, depth: Int, asImage: Bool) {
            guard depth < Self.maxDepth, seen.insert(unsafeBitCast(stream, to: Int.self)).inserted,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            visitMetadata(of: dict)
            if asImage || name(dict, "Subtype") == "Image" {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format) as Data?, format != .raw {
                    body(.image(data: data, format: format))
                }
                var mask: CGPDFStreamRef?
                if CGPDFDictionaryGetStream(dict, "SMask", &mask), let mask { visitStream(mask, depth: depth + 1, asImage: true) }
            } else {
                // Form XObjects and tiling patterns draw with their own resources.
                var resources: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources {
                    visitResources(resources, depth: depth)
                }
            }
        }

        mutating func visitMetadata(of dict: CGPDFDictionaryRef) {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(dict, "Metadata", &stream), let stream,
                  seen.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return }
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format) as Data? { body(.xmp(data)) }
        }

        func streams(in dict: CGPDFDictionaryRef) -> [CGPDFStreamRef] {
            var found: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &found) { pointer in
                CGPDFDictionaryApplyBlock(dict, { _, object, info in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                        info?.assumingMemoryBound(to: [CGPDFStreamRef].self).pointee.append(stream)
                    }
                    return true
                }, pointer)
            }
            return found
        }

        func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dict, key, &value), let value else { return nil }
            return String(cString: value)
        }
    }

    // MARK: Annotations

    /// Authors of markup annotations (comments, highlights, notes). Form fields are skipped:
    /// a widget's `/T` is the field name, not a person.
    static func annotationAuthors(_ doc: PDFDocument) -> [String] {
        var names: [String] = []
        for index in 0..<doc.pageCount {
            for annotation in doc.page(at: index)?.annotations ?? [] where !isWidget(annotation) {
                if let name = annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                   !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// Removes author names and edit times from every markup annotation (popups included).
    static func scrubAnnotations(_ doc: PDFDocument) {
        for index in 0..<doc.pageCount {
            for annotation in doc.page(at: index)?.annotations ?? [] where !isWidget(annotation) {
                annotation.userName = nil
                annotation.modificationDate = nil
                annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/CreationDate"))
            }
        }
    }

    static func isWidget(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Widget" || annotation.type == PDFAnnotationSubtype.widget.rawValue
    }

    // MARK: Cleaning streams in place

    /// Blanks metadata inside embedded JPEGs and XMP streams of a PDF file, in place and without
    /// changing any byte offsets: the replacement has the same length, so the cross-reference table
    /// stays valid. Only streams stored verbatim (no extra compression or encryption) can be patched;
    /// anything else is left for the caller's verification to catch.
    static func scrubStreams(in file: URL) throws {
        var bytes = try Data(contentsOf: file)
        guard let provider = CGDataProvider(data: bytes as CFData), let doc = CGPDFDocument(provider) else {
            throw MetadataError.pdfFailed
        }
        var patches: [(old: Data, new: Data)] = []
        forEach(in: doc) { item in
            switch item {
            case .image(let data, .jpegEncoded):
                if let clean = ContainerStripper.blankJPEGMetadata(data) { patches.append((data, clean)) }
            case .xmp(let data):
                if !data.allSatisfy({ $0 == 0x20 }) { patches.append((data, Data(repeating: 0x20, count: data.count))) }
            default:
                break
            }
        }
        guard !patches.isEmpty else { return }
        var changed = false
        for patch in patches where !patch.old.isEmpty {
            for offset in occurrences(of: patch.old, in: bytes) {
                bytes.replaceSubrange(offset..<(offset + patch.old.count), with: patch.new)
                changed = true
            }
        }
        if changed { try bytes.write(to: file, options: .atomic) }
    }

    /// True while any embedded JPEG still has metadata segments, or any XMP stream still has content.
    static func hasLeftovers(in file: URL) -> Bool {
        guard let doc = CGPDFDocument(file as CFURL) else { return true }
        var found = false
        forEach(in: doc) { item in
            switch item {
            case .image(let data, .jpegEncoded):
                if ContainerStripper.blankJPEGMetadata(data) != nil { found = true }
            case .xmp(let data):
                if !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D, 0x00].contains($0) }) { found = true }
            default:
                break
            }
        }
        return found
    }

    /// Start offsets of every (non-overlapping) occurrence of `needle` in `haystack`.
    static func occurrences(of needle: Data, in haystack: Data) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Int] = []
        haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress else { return }
                var offset = 0
                while offset + needle.count <= hay.count,
                      let hit = memmem(hayBase + offset, hay.count - offset, pinBase, pin.count) {
                    let start = hayBase.distance(to: UnsafeRawPointer(hit))
                    result.append(start)
                    offset = start + needle.count
                }
            }
        }
        return result
    }
}
