import Foundation
import PDFKit

/// Parses page ranges such as "1-3, 4, 7-9" (1-based). Also accepts "7-" (to the last page),
/// en/em dashes, semicolons and spaces around the parts.
public enum PageRangeParser {
    public static let example = "1-3, 4, 7-9"

    public static func parse(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        guard pageCount > 0 else { throw PDFToolsError.noPages }
        let normalized = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let parts = normalized.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw PDFToolsError("Enter pages or ranges, like \(example).")
        }
        return try parts.map { try parseRange($0, pageCount: pageCount) }
    }

    private static func parseRange(_ part: String, pageCount: Int) throws -> ClosedRange<Int> {
        let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let invalid = PDFToolsError("“\(part)” isn't a page or a range. Use a form like \(example).")
        func number(_ s: String) throws -> Int {
            guard !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = Int(s) else { throw invalid }
            guard n >= 1, n <= pageCount else {
                throw PDFToolsError(pageCount == 1 ? "Page \(n) doesn't exist; this PDF has 1 page."
                                                   : "Page \(n) doesn't exist; this PDF has \(pageCount) pages.")
            }
            return n
        }
        if ends.count == 1 {
            let n = try number(ends[0])
            return n...n
        }
        let lower = try number(ends[0])
        let upper = ends[1].isEmpty ? pageCount : try number(ends[1])
        guard lower <= upper else {
            throw PDFToolsError("The range \(lower)-\(upper) runs backwards. Write it as \(upper)-\(lower).")
        }
        return lower...upper
    }

    /// "1-3, 5" for zero-based page indices (consecutive runs collapsed).
    public static func describe(_ indices: [Int], separator: String = ", ") -> String {
        var runs: [ClosedRange<Int>] = []
        for i in indices {
            if let last = runs.last, last.upperBound + 1 == i { runs[runs.count - 1] = last.lowerBound...i }
            else { runs.append(i...i) }
        }
        return runs.map { $0.count == 1 ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound + 1)" }
            .joined(separator: separator)
    }
}

public enum PDFSplitMode: Equatable, Sendable {
    /// One file per page.
    case everyPage
    /// One file per `n` pages; the last file may have fewer.
    case everyNPages(Int)
    /// One file per range (1-based, as parsed by `PageRangeParser`).
    case ranges([ClosedRange<Int>])
    /// The chosen pages (1-based) together in one file.
    case extract([Int])
}

/// "Split": one PDF into several.
public enum PDFSplitter {
    /// The zero-based page indices of each output file.
    public static func groups(for mode: PDFSplitMode, pageCount: Int) throws -> [[Int]] {
        guard pageCount > 0 else { throw PDFToolsError.noPages }
        switch mode {
        case .everyPage:
            return (0..<pageCount).map { [$0] }
        case .everyNPages(let n):
            guard n >= 1 else { throw PDFToolsError("Choose at least 1 page per file.") }
            return stride(from: 0, to: pageCount, by: n).map { Array($0..<min($0 + n, pageCount)) }
        case .ranges(let ranges):
            guard !ranges.isEmpty else { throw PDFToolsError("Enter pages or ranges, like \(PageRangeParser.example).") }
            return try ranges.map { range in
                guard range.lowerBound >= 1, range.upperBound <= pageCount else {
                    throw PDFToolsError("Page \(range.upperBound) doesn't exist; this PDF has \(pageCount) pages.")
                }
                return range.map { $0 - 1 }
            }
        case .extract(let pages):
            let chosen = Array(Set(pages)).sorted()
            guard !chosen.isEmpty else { throw PDFToolsError("Choose at least one page.") }
            guard chosen.allSatisfy({ (1...pageCount).contains($0) }) else {
                throw PDFToolsError("The selection includes a page this PDF doesn't have.")
            }
            return [chosen.map { $0 - 1 }]
        }
    }

    /// Name suffix for an output file: " p4", " p1-3", " p1-3, 5"; long selections become " selected pages".
    public static func suffix(for group: [Int]) -> String {
        let text = PageRangeParser.describe(group)
        return text.count > 32 ? " selected pages" : " p" + text
    }

    /// Name of the folder used when splitting into a folder: "<name> pages".
    public static let folderSuffix = " pages"

    /// Writes one PDF per group. With `intoFolder`, they go into a new folder
    /// "<name> pages" and the folder is returned; otherwise the files are returned.
    @discardableResult
    public static func split(_ url: URL, mode: PDFSplitMode, intoFolder: Bool) throws -> [URL] {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { throw PDFToolsError.unreadable(url) }
        let groups = try groups(for: mode, pageCount: doc.pageCount)
        let fm = FileManager.default
        var folder: URL?
        if intoFolder {
            let dir = PDFSourceLoader.uniqueFolder(for: url, suffix: folderSuffix)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir
        }
        var written: [URL] = []
        do {
            for group in groups {
                let part = PDFDocument()
                for index in group {
                    guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw PDFToolsError("Could not read PDF page \(index + 1).") }
                    part.insert(page, at: part.pageCount)
                }
                if let attributes = doc.documentAttributes { part.documentAttributes = attributes }
                let output = OutputNaming.uniqueURL(for: url, ext: "pdf", suffix: suffix(for: group), in: folder)
                try PDFOrganizer.write(part, to: output, expectedPages: group.count,
                                       writeError: "PDFKit could not write “\(output.lastPathComponent)”.",
                                       verifyError: "“\(output.lastPathComponent)” could not be verified.")
                written.append(output)
            }
        } catch {
            written.forEach { try? fm.removeItem(at: $0) }
            if let folder { try? fm.removeItem(at: folder) }
            throw error
        }
        return folder.map { [$0] } ?? written
    }
}
