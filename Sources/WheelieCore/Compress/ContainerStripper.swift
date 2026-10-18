import Foundation

/// Lossless metadata removal for JPEG and PNG: the compressed image data is copied byte for byte,
/// only metadata segments/chunks are dropped. ImageIO's own lossless path keeps EXIF thumbnails
/// (which can show the uncropped original), so these work at the container level instead.
enum ContainerStripper {
    /// Minimal big-endian TIFF/EXIF block holding only the orientation tag (0x0112).
    static func orientationTIFF(_ orientation: Int) -> [UInt8] {
        let o = UInt8(clamping: orientation)
        return [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,   // "MM", 42, IFD at 8
                0x00, 0x01,                                        // one entry
                0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,    // Orientation, SHORT, count 1
                0x00, o, 0x00, 0x00,                               // value (padded)
                0x00, 0x00, 0x00, 0x00]                            // no next IFD
    }

    // MARK: JPEG

    /// Keeps the frame, tables, scans, JFIF (without thumbnail), ICC profile and Adobe color
    /// transform. Drops EXIF (and its thumbnail), XMP, IPTC/Photoshop, MPF (gain maps / extra images),
    /// comments, other APPn blocks and anything after the end-of-image marker.
    static func stripJPEG(_ data: Data, orientation: Int) -> Data? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(b.count)
        var i = 2
        var placedOrientation = orientation == 1

        func placeOrientation() {
            guard !placedOrientation else { return }
            placedOrientation = true
            let payload = Array("Exif\0\0".utf8) + orientationTIFF(orientation)
            let length = payload.count + 2
            out += [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        }

        while i + 1 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xD9 { out += [0xFF, 0xD9]; return Data(out) }   // EOI: drop any trailer
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { out += [0xFF, marker]; i += 2; continue }
            guard i + 3 < b.count else { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            let payload = b[(i + 4)..<(i + 2 + length)]
            func starts(with prefix: String) -> Bool { payload.starts(with: Array(prefix.utf8)) }

            if marker != 0xE0 { placeOrientation() }   // EXIF goes right after SOI/JFIF
            switch marker {
            case 0xE0:
                // JFIF header without its optional embedded thumbnail; JFXX (thumbnail extension) is dropped.
                if starts(with: "JFIF\0"), payload.count >= 14 {
                    let header = Array(payload.prefix(12)) + [0, 0]
                    out += [0xFF, 0xE0, 0x00, UInt8(header.count + 2)] + header
                }
            case 0xE2 where starts(with: "ICC_PROFILE\0"), 0xEE where starts(with: "Adobe"):
                out += b[i..<(i + 2 + length)]
            case 0xE1...0xEF, 0xFE:
                break   // EXIF, XMP, MPF, IPTC/Photoshop, maker blocks, comments
            default:
                out += b[i..<(i + 2 + length)]
            }
            i += 2 + length

            if marker == 0xDA {
                // Entropy-coded scan data runs until the next real marker (not stuffing or restart).
                let start = i
                while i + 1 < b.count {
                    if b[i] == 0xFF {
                        let next = b[i + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { i += 2; continue }
                        break
                    }
                    i += 1
                }
                out += b[start..<i]
            }
        }
        return nil   // no end-of-image marker: let the caller fall back to re-encoding
    }

    /// Byte ranges of a JPEG that hold metadata: the payloads of every segment `stripJPEG` drops,
    /// the JFIF thumbnail (from its size fields on) and anything after the end-of-image marker.
    /// Ranges that are already all zero are left out, so an empty result means "nothing left".
    /// Tolerant of a missing end-of-image marker (common for JPEGs embedded in PDFs).
    static func jpegMetadataRanges(_ b: [UInt8]) -> [Range<Int>] {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return [] }
        var ranges: [Range<Int>] = []
        var i = 2
        while i + 1 < b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD9 {
                if i + 2 < b.count { ranges.append((i + 2)..<b.count) }
                break
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            guard i + 3 < b.count else { break }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { break }
            let start = i + 4, end = i + 2 + length
            func starts(with prefix: String) -> Bool { b[start..<end].starts(with: Array(prefix.utf8)) }

            switch marker {
            case 0xE0:
                if !starts(with: "JFIF\0") { ranges.append(start..<end) } else if end - start > 12 { ranges.append((start + 12)..<end) }
            case 0xE2 where starts(with: "ICC_PROFILE\0"), 0xEE where starts(with: "Adobe"):
                break
            case 0xE1...0xEF, 0xFE:
                ranges.append(start..<end)
            default:
                break
            }
            i = end

            if marker == 0xDA {
                while i + 1 < b.count {
                    if b[i] == 0xFF {
                        let next = b[i + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { i += 2; continue }
                        break
                    }
                    i += 1
                }
            }
        }
        return ranges.filter { range in b[range].contains { $0 != 0 } }
    }

    /// Same-length copy of a JPEG with every metadata range zeroed: the segments stay (as empty
    /// padding) so the image data keeps its byte offsets. Returns nil when there is nothing to blank.
    /// Used where bytes can't move, such as JPEG streams inside a PDF.
    static func blankJPEGMetadata(_ data: Data) -> Data? {
        var b = [UInt8](data)
        let ranges = jpegMetadataRanges(b)
        guard !ranges.isEmpty else { return nil }
        for range in ranges { b.replaceSubrange(range, with: repeatElement(0, count: range.count)) }
        return Data(b)
    }

    // MARK: PNG

    /// Image data, color and animation chunks; text (tEXt/zTXt/iTXt), eXIf, tIME and private chunks are dropped.
    static let keptPNGChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP",
                                             "sBIT", "bKGD", "pHYs", "hIST", "acTL", "fcTL", "fdAT", "cICP", "mDCv", "cLLi"]

    static func stripPNG(_ data: Data, orientation: Int) -> Data? {
        let b = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count > 8, Array(b[0..<8]) == signature else { return nil }
        var out = Data(signature)
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 0, i + 12 + length <= b.count else { return nil }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if keptPNGChunks.contains(type) { out.append(contentsOf: b[i..<(i + 12 + length)]) }
            i += 12 + length
            if type == "IHDR", orientation != 1 {
                let body = orientationTIFF(orientation)
                var typed = Data("eXIf".utf8)
                typed.append(contentsOf: body)
                out.append(contentsOf: [0, 0, 0, UInt8(body.count)])
                out.append(typed)
                let crc = PalettePNG.crc32(typed)
                out.append(contentsOf: [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
            }
            if type == "IEND" { return out }
        }
        return nil
    }
}
