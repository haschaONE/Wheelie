import Foundation

/// Bytes → text for plain-text sources (TXT, CSV/TSV, Markdown): a BOM first (UTF-8, UTF-16 and
/// UTF-32 in either byte order), then BOM-less UTF-16 recognised from its NUL bytes, then UTF-8,
/// then Windows-1252. Notepad's "Unicode", PowerShell redirection and Excel's "Unicode Text"
/// export all write UTF-16, which Windows-1252 would otherwise "decode" into NUL-filled garbage.
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        var text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            text = utf32(data.dropFirst(4), bigEndian: true)
        } else if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            text = utf32(data.dropFirst(4), bigEndian: false)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = utf16(data.dropFirst(2), bigEndian: true)
        } else if data.starts(with: [0xFF, 0xFE]) {
            text = utf16(data.dropFirst(2), bigEndian: false)
        } else if let bigEndian = bomlessUTF16(data) {
            text = utf16(data, bigEndian: bigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Text in UTF-16 without a BOM has a NUL in (nearly) every other byte for Latin text; real UTF-8
    /// and Windows-1252 text has none. Returns the byte order, or nil when it doesn't look like UTF-16.
    static func bomlessUTF16(_ data: Data) -> Bool? {
        let sample = [UInt8](data.prefix(4096))
        let pairs = sample.count / 2
        guard pairs >= 2 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for offset in 0..<(pairs * 2) where sample[offset] == 0 {
            if offset % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        if oddZeros * 10 >= pairs * 4 && evenZeros * 20 <= pairs { return false } // "A\0B\0": little-endian
        if evenZeros * 10 >= pairs * 4 && oddZeros * 20 <= pairs { return true }  // "\0A\0B": big-endian
        return nil
    }

    /// Lossy: unpaired surrogates and a trailing odd byte become U+FFFD instead of failing the whole file.
    private static func utf16(_ data: Data, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let a = UInt16(data[index]), b = UInt16(data[index + 1])
            units.append(bigEndian ? a << 8 | b : b << 8 | a)
            index += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if data.count % 2 == 1 { text.append("\u{FFFD}") }
        return text
    }

    private static func utf32(_ data: Data, bigEndian: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var index = data.startIndex
        while index + 3 < data.endIndex {
            let b0 = UInt32(data[index]), b1 = UInt32(data[index + 1]), b2 = UInt32(data[index + 2]), b3 = UInt32(data[index + 3])
            let value = bigEndian ? b0 << 24 | b1 << 16 | b2 << 8 | b3 : b3 << 24 | b2 << 16 | b1 << 8 | b0
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            index += 4
        }
        return String(scalars)
    }
}
