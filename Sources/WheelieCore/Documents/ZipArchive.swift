import Foundation

/// Minimal in-memory ZIP reader (stored + deflate) for DOCX, XLSX and EPUB containers.
/// Rejects encryption, ZIP64, symlinks and unsafe names, and enforces `DocumentLimits`.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [Entry] = []
    private var index: [String: Int] = [:]
    private var lowercasedIndex: [String: Int] = [:]

    init(url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= DocumentLimits.maxArchiveBytes else {
            throw DocumentError.tooLarge("The archive is too large to open safely.")
        }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        let bad = DocumentError.malformed("The ZIP container is damaged or unsupported.")
        guard data.count >= 22 else { throw bad }

        // End of central directory: last occurrence of PK\5\6 within the trailing 64 KB comment window.
        var eocd = -1
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while position >= lowest {
            if u32(position) == 0x0605_4b50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw bad }
        let count = Int(u16(eocd + 10))
        let cdSize = Int(u32(eocd + 12))
        let cdOffset = Int(u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
            throw DocumentError.unsupported("ZIP64 archives are not supported.")
        }
        guard count <= DocumentLimits.maxArchiveEntries else { throw DocumentError.tooLarge("The archive has too many entries.") }
        guard cdOffset + cdSize <= data.count else { throw bad }

        var offset = cdOffset
        var expanded = 0
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x0201_4b50 else { throw bad }
            let flags = u16(offset + 8)
            let method = u16(offset + 10)
            let crc = u32(offset + 16)
            let compressed = Int(u32(offset + 20))
            let uncompressed = Int(u32(offset + 24))
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            let externalAttributes = u32(offset + 38)
            let localOffset = Int(u32(offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw bad }
            let nameData = data.subdata(in: data.startIndex + offset + 46 ..< data.startIndex + offset + 46 + nameLength)
            let name = (flags & 0x0800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue } // directory
            let unixMode = (externalAttributes >> 16) & 0o170000
            if unixMode == 0o120000 { throw DocumentError.unsupported("Symbolic links inside archives are not supported.") }
            guard ZipArchive.isSafe(name) else { throw DocumentError.malformed("The archive contains an unsafe filename.") }
            expanded += uncompressed
            guard expanded <= DocumentLimits.maxExpandedBytes else {
                throw DocumentError.tooLarge("The archive expands beyond the safety limit.")
            }
            let entry = Entry(name: name, method: method, flags: flags, crc: crc, compressedSize: compressed,
                              uncompressedSize: uncompressed, localHeaderOffset: localOffset)
            if index[name] != nil { throw DocumentError.malformed("The archive contains duplicate paths.") }
            index[name] = entries.count
            lowercasedIndex[name.lowercased()] = entries.count
            entries.append(entry)
        }
    }

    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/").contains("..")
    }

    var names: [String] { entries.map(\.name) }

    func contains(_ name: String) -> Bool { entry(named: name) != nil }

    private func entry(named name: String) -> Entry? {
        if let i = index[name] { return entries[i] }
        if let i = lowercasedIndex[name.lowercased()] { return entries[i] }
        return nil
    }

    /// Uncompressed contents of `name` (case-insensitive fallback), or nil when absent.
    func read(_ name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        let bad = DocumentError.malformed("The archive contains a damaged file: \(name)")
        if entry.flags & 0x0001 != 0 { throw DocumentError.unsupported("Encrypted archive entries cannot be opened.") }
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, u32(local) == 0x0403_4b50 else { throw bad }
        let start = local + 30 + Int(u16(local + 26)) + Int(u16(local + 28))
        guard start + entry.compressedSize <= data.count else { throw bad }
        let raw = data.subdata(in: data.startIndex + start ..< data.startIndex + start + entry.compressedSize)
        let output: Data
        switch entry.method {
        case 0:
            output = raw
        case 8:
            if entry.uncompressedSize == 0 { return Data() }
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else { throw bad }
            output = inflated
        default:
            throw DocumentError.unsupported("The archive uses an unsupported compression method.")
        }
        guard output.count == entry.uncompressedSize else { throw bad }
        return output
    }

    func readString(_ name: String) throws -> String? {
        guard let data = try read(name) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func u16(_ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}

/// Minimal ZIP writer (deflate or stored), enough for DOCX, XLSX and EPUB packages.
struct ZipWriter {
    private var output = Data()
    private var central = Data()
    private var count = 0

    /// `compress: false` stores the entry (required for EPUB's leading "mimetype").
    mutating func add(_ name: String, _ contents: Data, compress: Bool = true) {
        let crc = CRC32.checksum(contents)
        var method: UInt16 = 0
        var payload = contents
        if compress, contents.count > 64,
           let deflated = try? (contents as NSData).compressed(using: .zlib) as Data, deflated.count < contents.count {
            method = 8
            payload = deflated
        }
        let nameData = Data(name.utf8)
        let offset = output.count
        // 2020-01-01 00:00 in DOS format keeps output deterministic.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = UInt16((2020 - 1980) << 9 | 1 << 5 | 1)

        var local = Data()
        local.le32(0x0403_4b50); local.le16(20); local.le16(0x0800); local.le16(method)
        local.le16(dosTime); local.le16(dosDate); local.le32(crc)
        local.le32(UInt32(payload.count)); local.le32(UInt32(contents.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        output.append(local)
        output.append(nameData)
        output.append(payload)

        var entry = Data()
        entry.le32(0x0201_4b50); entry.le16(0x031E); entry.le16(20); entry.le16(0x0800); entry.le16(method)
        entry.le16(dosTime); entry.le16(dosDate); entry.le32(crc)
        entry.le32(UInt32(payload.count)); entry.le32(UInt32(contents.count))
        entry.le16(UInt16(nameData.count)); entry.le16(0); entry.le16(0); entry.le16(0); entry.le16(0)
        entry.le32(UInt32(0o100644) << 16); entry.le32(UInt32(offset))
        central.append(entry)
        central.append(nameData)
        count += 1
    }

    mutating func add(_ name: String, _ text: String, compress: Bool = true) {
        add(name, Data(text.utf8), compress: compress)
    }

    func data() -> Data {
        var result = output
        let cdOffset = result.count
        result.append(central)
        var end = Data()
        end.le32(0x0605_4b50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(cdOffset)); end.le16(0)
        result.append(end)
        return result
    }

    func write(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8(value >> 24))
    }
}

// MARK: XML helpers shared by the DOCX/XLSX/EPUB readers

enum XML {
    /// Parses XML with external entities disabled; rejects entity declarations (billion laughs).
    static func document(_ data: Data, what: String) throws -> XMLDocument {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.range(of: "<!ENTITY", options: .caseInsensitive) != nil {
            throw DocumentError.unsupported("\(what) entity declarations are not supported.")
        }
        do {
            return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw DocumentError.malformed("\(what) contains malformed XML.")
        }
    }
}

extension XMLNode {
    /// Element children only.
    var elements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    /// Local name without namespace prefix ("w:p" → "p").
    var local: String {
        if let l = localName, !l.isEmpty { return l }
        let n = name ?? ""
        if let colon = n.lastIndex(of: ":") { return String(n[n.index(after: colon)...]) }
        return n
    }

    func child(_ local: String) -> XMLElement? { elements.first { $0.local == local } }

    func children(_ local: String) -> [XMLElement] { elements.filter { $0.local == local } }

    /// Depth-first search for descendants with this local name.
    func descendants(_ local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        var stack: [XMLNode] = [self]
        while let node = stack.popLast() {
            for child in (node.children ?? []).reversed() {
                if let e = child as? XMLElement {
                    if e.local == local { out.append(e) }
                    stack.append(e)
                }
            }
        }
        return out
    }
}

extension XMLElement {
    /// Attribute by local name (ignores prefixes: "w:val" matches "val").
    func attr(_ local: String) -> String? {
        if let a = attribute(forName: local)?.stringValue { return a }
        for a in attributes ?? [] where a.local == local { return a.stringValue }
        return nil
    }
}
