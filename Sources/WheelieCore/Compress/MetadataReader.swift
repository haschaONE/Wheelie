import CoreGraphics
import Foundation
import ImageIO
import PDFKit

public enum MetadataCategory: Int, CaseIterable, Sendable, Comparable {
    case camera, location, dates, people, description, document, media, software, other

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .camera: return "Camera"
        case .location: return "Location"
        case .dates: return "Dates"
        case .people: return "People & Rights"
        case .description: return "Description"
        case .document: return "Document Info"
        case .media: return "Media Tags"
        case .software: return "Software"
        case .other: return "Other"
        }
    }

    /// SF Symbol for the group header.
    public var symbol: String {
        switch self {
        case .camera: return "camera"
        case .location: return "location"
        case .dates: return "calendar"
        case .people: return "person"
        case .description: return "text.quote"
        case .document: return "doc.text"
        case .media: return "music.note"
        case .software: return "hammer"
        case .other: return "ellipsis.circle"
        }
    }
}

public struct MetadataEntry: Hashable, Sendable {
    public let label: String
    public let value: String
}

public struct MetadataGroup: Identifiable, Sendable {
    public let category: MetadataCategory
    public let entries: [MetadataEntry]
    public var id: Int { category.rawValue }
    public var title: String { category.title }
}

/// Reads the human-meaningful (and privacy-relevant) metadata of images, PDFs, video and audio.
/// Purely technical properties (pixel size, color model, codec details) are left out.
public enum MetadataReader {
    public static func read(_ url: URL) async -> [MetadataGroup] {
        switch FileKind(url: url) {
        case .image: return readImage(url)
        case .pdf: return readPDF(url)
        case .video, .audio: return await readMedia(url)
        case .unknown: return []
        }
    }

    // MARK: Images

    public static func readImage(_ url: URL) -> [MetadataGroup] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        var c = Collector()
        if let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any] {
            collectImageProperties(props, into: &c)
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, index, nil) {
            collectXMP(meta, into: &c)
        }
        return c.groups
    }

    static func collectImageProperties(_ props: [String: Any], into c: inout Collector) {
        func dict(_ key: CFString) -> [String: Any] { props[key as String] as? [String: Any] ?? [:] }
        let tiff = dict(kCGImagePropertyTIFFDictionary)
        let exif = dict(kCGImagePropertyExifDictionary)
        let aux = dict(kCGImagePropertyExifAuxDictionary)
        let gps = dict(kCGImagePropertyGPSDictionary)
        let iptc = dict(kCGImagePropertyIPTCDictionary)
        let png = dict(kCGImagePropertyPNGDictionary)

        c.add(.camera, "Make", tiff[kCGImagePropertyTIFFMake as String])
        c.add(.camera, "Model", tiff[kCGImagePropertyTIFFModel as String])
        c.add(.camera, "Lens make", exif[kCGImagePropertyExifLensMake as String])
        c.add(.camera, "Lens", exif[kCGImagePropertyExifLensModel as String] ?? aux[kCGImagePropertyExifAuxLensModel as String])
        c.add(.camera, "Serial number", exif[kCGImagePropertyExifBodySerialNumber as String] ?? aux[kCGImagePropertyExifAuxSerialNumber as String])
        c.add(.camera, "Lens serial number", exif[kCGImagePropertyExifLensSerialNumber as String] ?? aux[kCGImagePropertyExifAuxLensSerialNumber as String])
        if let f = number(exif[kCGImagePropertyExifFNumber as String]) { c.add(.camera, "Aperture", "ƒ/" + trimmed(f, digits: 1)) }
        if let t = number(exif[kCGImagePropertyExifExposureTime as String]), t > 0 {
            c.add(.camera, "Exposure", t >= 1 ? trimmed(t, digits: 1) + " s" : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] { c.add(.camera, "ISO", iso) }
        if let focal = number(exif[kCGImagePropertyExifFocalLength as String]) { c.add(.camera, "Focal length", trimmed(focal, digits: 1) + " mm") }
        if let focal35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]), focal35 > 0 {
            c.add(.camera, "35 mm equivalent", "\(Int(focal35)) mm")
        }
        if let flash = number(exif[kCGImagePropertyExifFlash as String]) {
            c.add(.camera, "Flash", Int(flash) & 1 == 1 ? "Fired" : "Did not fire")
        }

        addGPS(gps, into: &c)

        c.add(.dates, "Taken", exifDate(exif[kCGImagePropertyExifDateTimeOriginal as String],
                                        offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String]))
        c.add(.dates, "Digitized", exifDate(exif[kCGImagePropertyExifDateTimeDigitized as String],
                                            offset: exif[kCGImagePropertyExifOffsetTimeDigitized as String]))
        c.add(.dates, "Modified", exifDate(tiff[kCGImagePropertyTIFFDateTime as String], offset: exif[kCGImagePropertyExifOffsetTime as String]))
        if let day = gps[kCGImagePropertyGPSDateStamp as String] {
            let time = gps[kCGImagePropertyGPSTimeStamp as String].map { " \($0)" } ?? ""
            c.add(.dates, "GPS time", exifDate("\(day)\(time) UTC", offset: nil))
        }
        c.add(.dates, "Created", iptcDate(iptc[kCGImagePropertyIPTCDateCreated as String], time: iptc[kCGImagePropertyIPTCTimeCreated as String]))
        c.add(.dates, "Created", png[kCGImagePropertyPNGCreationTime as String])

        c.add(.people, "Artist", tiff[kCGImagePropertyTIFFArtist as String])
        c.add(.people, "Author", iptc[kCGImagePropertyIPTCByline as String] ?? png[kCGImagePropertyPNGAuthor as String])
        c.add(.people, "Camera owner", exif[kCGImagePropertyExifCameraOwnerName as String] ?? aux[kCGImagePropertyExifAuxOwnerName as String])
        c.add(.people, "Copyright", tiff[kCGImagePropertyTIFFCopyright as String]
              ?? iptc[kCGImagePropertyIPTCCopyrightNotice as String] ?? png[kCGImagePropertyPNGCopyright as String])
        c.add(.people, "Credit", iptc[kCGImagePropertyIPTCCredit as String])
        c.add(.people, "Source", iptc[kCGImagePropertyIPTCSource as String])
        c.add(.people, "Writer", iptc[kCGImagePropertyIPTCWriterEditor as String])
        if let contact = iptc[kCGImagePropertyIPTCCreatorContactInfo as String] as? [String: Any] {
            c.add(.people, "Contact", contact.values.compactMap(describe).joined(separator: ", "))
        }

        c.add(.description, "Title", iptc[kCGImagePropertyIPTCObjectName as String] ?? png[kCGImagePropertyPNGTitle as String])
        c.add(.description, "Description", tiff[kCGImagePropertyTIFFImageDescription as String] ?? png[kCGImagePropertyPNGDescription as String])
        c.add(.description, "Caption", iptc[kCGImagePropertyIPTCCaptionAbstract as String])
        c.add(.description, "Keywords", iptc[kCGImagePropertyIPTCKeywords as String])
        c.add(.description, "Comment", exif[kCGImagePropertyExifUserComment as String] ?? png[kCGImagePropertyPNGComment as String])
        c.add(.description, "Instructions", iptc[kCGImagePropertyIPTCSpecialInstructions as String])

        c.add(.location, "City", iptc[kCGImagePropertyIPTCCity as String])
        c.add(.location, "Sublocation", iptc[kCGImagePropertyIPTCSubLocation as String])
        c.add(.location, "State", iptc[kCGImagePropertyIPTCProvinceState as String])
        c.add(.location, "Country", iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String])

        c.add(.software, "Software", tiff[kCGImagePropertyTIFFSoftware as String] ?? png[kCGImagePropertyPNGSoftware as String])
        c.add(.software, "Host computer", tiff[kCGImagePropertyTIFFHostComputer as String])
        let program = [iptc[kCGImagePropertyIPTCOriginatingProgram as String], iptc[kCGImagePropertyIPTCProgramVersion as String]]
            .compactMap { $0.map { "\($0)" } }.joined(separator: " ")
        c.add(.software, "Program", program)

        c.add(.other, "Unique image ID", exif[kCGImagePropertyExifImageUniqueID as String])
        let makers = props.keys.filter { $0.hasPrefix("{Maker") }.map { $0.dropFirst(6).dropLast() }
        if !makers.isEmpty { c.add(.other, "Camera maker data", "Present (\(makers.sorted().joined(separator: ", ")))") }
        if props[kCGImageProperty8BIMDictionary as String] != nil { c.add(.other, "Photoshop data", "Present") }
    }

    static func addGPS(_ gps: [String: Any], into c: inout Collector) {
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]) {
            let ref = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? (lat < 0 ? "S" : "N")
            c.add(.location, "Latitude", String(format: "%.6f° %@", abs(lat), ref))
        }
        if let lon = number(gps[kCGImagePropertyGPSLongitude as String]) {
            let ref = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? (lon < 0 ? "W" : "E")
            c.add(.location, "Longitude", String(format: "%.6f° %@", abs(lon), ref))
        }
        if let alt = number(gps[kCGImagePropertyGPSAltitude as String]) {
            let below = number(gps[kCGImagePropertyGPSAltitudeRef as String]) == 1
            c.add(.location, "Altitude", (below ? "−" : "") + trimmed(alt, digits: 1) + " m")
        }
        if let error = number(gps[kCGImagePropertyGPSHPositioningError as String]) {
            c.add(.location, "Accuracy", "± " + trimmed(error, digits: 0) + " m")
        }
        if let direction = number(gps[kCGImagePropertyGPSImgDirection as String]) {
            c.add(.location, "Direction", trimmed(direction, digits: 0) + "°")
        }
        if let speed = number(gps[kCGImagePropertyGPSSpeed as String]), speed > 0 {
            let unit = (gps[kCGImagePropertyGPSSpeedRef as String] as? String).map { ["K": "km/h", "M": "mph", "N": "knots"][$0] ?? $0 } ?? "km/h"
            c.add(.location, "Speed", trimmed(speed, digits: 1) + " " + unit)
        }
        c.add(.location, "Area", gps[kCGImagePropertyGPSAreaInformation as String])
    }

    /// XMP adds what the EXIF/IPTC dictionaries don't cover (creator tools, Dublin Core, …).
    static func collectXMP(_ meta: CGImageMetadata, into c: inout Collector) {
        let mapped: [String: (MetadataCategory, String)] = [
            "xmp:CreatorTool": (.software, "Created with"),
            "xmp:CreateDate": (.dates, "Created"),
            "xmp:ModifyDate": (.dates, "Modified"),
            "xmp:MetadataDate": (.dates, "Metadata date"),
            "photoshop:DateCreated": (.dates, "Created"),
            "dc:creator": (.people, "Creator"),
            "dc:rights": (.people, "Rights"),
            "dc:title": (.description, "Title"),
            "dc:description": (.description, "Description"),
            "dc:subject": (.description, "Keywords"),
            "photoshop:City": (.location, "City"),
            "photoshop:State": (.location, "State"),
            "photoshop:Country": (.location, "Country"),
            "Iptc4xmpCore:Location": (.location, "Sublocation"),
            "aux:SerialNumber": (.camera, "Serial number"),
            "aux:Lens": (.camera, "Lens"),
            "aux:OwnerName": (.people, "Camera owner"),
        ]
        // Namespaces ImageIO mirrors from EXIF/TIFF/IPTC (already shown above) or purely technical ones.
        let mirrored: Set<String> = ["exif", "tiff", "exifEX", "aux", "Iptc4xmpCore", "Iptc4xmpExt", "photoshop", "xmp", "dc", "xmpMM"]
        var unmapped = 0
        guard let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return }
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let key = "\(prefix):\(name)"
            if let (category, label) = mapped[key] {
                c.add(category, label, xmpValue(tag))
            } else if !mirrored.contains(prefix) {
                unmapped += 1
            }
        }
        if unmapped > 0 { c.add(.other, "Other XMP properties", "\(unmapped)") }
    }

    static func xmpValue(_ tag: CGImageMetadataTag) -> String? {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let tags = value as? [CGImageMetadataTag] {
            return tags.compactMap(xmpValue).joined(separator: ", ")
        }
        if let dict = value as? [String: CGImageMetadataTag] {
            // Alternative-language text: prefer x-default.
            return (dict["x-default"] ?? dict.values.first).flatMap(xmpValue)
        }
        return describe(value)
    }

    // MARK: PDF

    public static func readPDF(_ url: URL) -> [MetadataGroup] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var c = Collector()
        let attrs = doc.documentAttributes ?? [:]
        func attr(_ key: PDFDocumentAttribute) -> Any? { attrs[key] ?? attrs[key.rawValue] }
        c.add(.document, "Title", attr(.titleAttribute))
        c.add(.document, "Author", attr(.authorAttribute))
        c.add(.document, "Subject", attr(.subjectAttribute))
        c.add(.document, "Keywords", attr(.keywordsAttribute))
        c.add(.software, "Created with", attr(.creatorAttribute))
        c.add(.software, "Producer", attr(.producerAttribute))
        c.add(.dates, "Created", attr(.creationDateAttribute))
        c.add(.dates, "Modified", attr(.modificationDateAttribute))
        if hasXMP(doc) { c.add(.other, "XMP metadata", "Present") }
        return c.groups
    }

    static func hasXMP(_ doc: PDFDocument) -> Bool {
        guard let catalog = doc.documentRef?.catalog else { return false }
        var stream: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(catalog, "Metadata", &stream)
    }

    // MARK: Video / audio

    public static func readMedia(_ url: URL) async -> [MetadataGroup] {
        guard let probe = try? await MediaProbe.probe(url) else { return [] }
        return mediaGroups(probe)
    }

    /// Container/stream tags that only describe the file's structure.
    static let technicalTags: Set<String> = [
        "major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id", "language", "duration",
        "rotate", "bps", "number_of_frames", "number_of_bytes", "_statistics_tags", "_statistics_writing_date_utc",
        "timecode", "com.apple.quicktime.player.movie.audio.gain", "com.apple.quicktime.player.movie.audio.treble",
        "com.apple.quicktime.player.movie.audio.bass", "com.apple.quicktime.player.movie.audio.balance",
        "com.apple.quicktime.player.movie.audio.mute", "com.apple.quicktime.player.version",
        "com.apple.quicktime.player.movie.visual.brightness", "com.apple.quicktime.player.movie.visual.color",
        "com.apple.quicktime.player.movie.visual.tint", "com.apple.quicktime.player.movie.visual.contrast",
        "itunsmpb", "itunnorm", "itunes_cddb_1", "gapless_playback", "hd_video", "media_type", "encoder_options",
    ]

    static let mediaTagMap: [String: (MetadataCategory, String)] = [
        "title": (.media, "Title"), "album": (.media, "Album"), "genre": (.media, "Genre"), "track": (.media, "Track"),
        "disc": (.media, "Disc"), "show": (.media, "Show"), "episode_id": (.media, "Episode"), "network": (.media, "Network"),
        "grouping": (.media, "Grouping"), "compilation": (.media, "Compilation"),
        "artist": (.people, "Artist"), "album_artist": (.people, "Album artist"), "composer": (.people, "Composer"),
        "performer": (.people, "Performer"), "publisher": (.people, "Publisher"), "copyright": (.people, "Copyright"),
        "author": (.people, "Author"), "com.apple.quicktime.author": (.people, "Author"),
        "com.apple.quicktime.artist": (.people, "Artist"),
        "date": (.dates, "Date"), "year": (.dates, "Year"), "creation_time": (.dates, "Created"),
        "com.apple.quicktime.creationdate": (.dates, "Recorded"), "date_recorded": (.dates, "Recorded"),
        "comment": (.description, "Comment"), "description": (.description, "Description"),
        "synopsis": (.description, "Synopsis"), "lyrics": (.description, "Lyrics"), "keywords": (.description, "Keywords"),
        "com.apple.quicktime.description": (.description, "Description"), "com.apple.quicktime.comment": (.description, "Comment"),
        "com.apple.quicktime.keywords": (.description, "Keywords"), "com.apple.quicktime.title": (.media, "Title"),
        "com.apple.quicktime.displayname": (.media, "Title"),
        "encoder": (.software, "Encoder"), "encoded_by": (.software, "Encoded by"),
        "com.apple.quicktime.software": (.software, "Software"), "com.android.version": (.software, "Android version"),
        "_statistics_writing_app": (.software, "Writing app"), "writing_application": (.software, "Writing app"),
        "com.apple.quicktime.make": (.camera, "Make"), "com.apple.quicktime.model": (.camera, "Model"),
        "com.android.manufacturer": (.camera, "Make"), "com.android.model": (.camera, "Model"),
        "com.apple.quicktime.camera.lens_model": (.camera, "Lens"),
        "com.apple.quicktime.camera.focal_length.35mm_equivalent": (.camera, "35 mm equivalent"),
        "com.apple.quicktime.location.accuracy.horizontal": (.location, "Accuracy"),
        "com.apple.quicktime.location.name": (.location, "Place"),
        "com.apple.quicktime.content.identifier": (.other, "Content identifier"),
    ]

    static let locationTags: Set<String> = ["location", "location-eng", "com.apple.quicktime.location.iso6709", "©xyz", "xyz"]

    static func mediaGroups(_ probe: MediaProbe) -> [MetadataGroup] {
        var c = Collector()
        func collect(_ tags: [String: String], streamLevel: Bool) {
            for key in tags.keys.sorted() {
                guard let value = tags[key] else { continue }
                let lower = key.lowercased()
                if technicalTags.contains(lower) { continue }
                if locationTags.contains(lower) {
                    if let point = parseISO6709(value) {
                        c.add(.location, "Latitude", String(format: "%.6f° %@", abs(point.latitude), point.latitude < 0 ? "S" : "N"))
                        c.add(.location, "Longitude", String(format: "%.6f° %@", abs(point.longitude), point.longitude < 0 ? "W" : "E"))
                        if let alt = point.altitude { c.add(.location, "Altitude", trimmed(alt, digits: 1) + " m") }
                    } else {
                        c.add(.location, "Location", value)
                    }
                } else if let (category, label) = mediaTagMap[lower] {
                    // Stream encoder tags ("Lavc… libx264") just echo the codec.
                    if streamLevel, lower == "encoder" || lower == "title" { continue }
                    c.add(category, label, category == .dates ? isoDate(value) : value)
                } else if !streamLevel {
                    c.add(.other, key, value)
                }
            }
        }
        collect(probe.formatTags, streamLevel: false)
        for stream in probe.streams where !stream.isAttachedPicture { collect(stream.tags, streamLevel: true) }
        if probe.chapterCount > 0 { c.add(.other, "Chapters", "\(probe.chapterCount)") }
        if probe.hasArtwork { c.add(.other, "Artwork", "Embedded") }
        return c.groups
    }

    /// Parses ISO 6709 decimal-degree strings as written by QuickTime/Android: "+37.3349-122.0090+012.3/".
    public static func parseISO6709(_ string: String) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        var numbers: [Double] = []
        var current = ""
        for ch in string {
            if ch == "+" || ch == "-" || ch == "/" {
                if let n = Double(current) { numbers.append(n) }
                current = ch == "/" ? "" : String(ch)
                if ch == "/" { break }
            } else if ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                return nil
            }
        }
        if let n = Double(current) { numbers.append(n) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
    }

    // MARK: Formatting

    struct Collector {
        private var entries: [MetadataCategory: [MetadataEntry]] = [:]

        mutating func add(_ category: MetadataCategory, _ label: String, _ value: Any?) {
            guard let value, let text = MetadataReader.describe(value) else { return }
            var list = entries[category, default: []]
            guard !list.contains(where: { $0.label == label }) else { return }
            list.append(MetadataEntry(label: label, value: text))
            entries[category] = list
        }

        var groups: [MetadataGroup] {
            entries.keys.sorted().map { MetadataGroup(category: $0, entries: entries[$0]!) }
        }
    }

    static func describe(_ value: Any) -> String? {
        var text: String?
        switch value {
        case let s as String: text = s
        case let d as Date: text = d.formatted(date: .abbreviated, time: .standard)
        case let n as NSNumber: text = trimmed(n.doubleValue, digits: 4)
        case let list as [Any]: text = list.compactMap(describe).joined(separator: ", ")
        default: text = nil
        }
        guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !cleaned.isEmpty else { return nil }
        return cleaned.count > 500 ? String(cleaned.prefix(500)) + "…" : cleaned
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        if let list = value as? [Any] { return number(list.first) }
        return nil
    }

    static func trimmed(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "2024:05:06 07:08:09" → "2024-05-06 07:08:09" (+ offset when known).
    static func exifDate(_ value: Any?, offset: Any?) -> String? {
        guard var text = value.flatMap(describe) else { return nil }
        if text.count >= 10 {
            let datePart = text.prefix(10).replacingOccurrences(of: ":", with: "-")
            text = datePart + text.dropFirst(10)
        }
        if let offset = offset.flatMap(describe) { text += " " + offset }
        return text
    }

    /// IPTC "20240506" + "070809+0200" → "2024-05-06 07:08:09 +0200".
    static func iptcDate(_ date: Any?, time: Any?) -> String? {
        guard let day = date.flatMap(describe) else { return nil }
        func split(_ s: Substring, _ parts: [Int], _ separator: String) -> String {
            var rest = s, out: [Substring] = []
            for n in parts { out.append(rest.prefix(n)); rest = rest.dropFirst(n) }
            return out.joined(separator: separator)
        }
        let isDigits = { (s: Substring) in !s.isEmpty && s.allSatisfy(\.isNumber) }
        var text = day.count == 8 && isDigits(Substring(day)) ? split(Substring(day), [4, 2, 2], "-") : day
        if let clock = time.flatMap(describe) {
            let digits = clock.prefix(6)
            text += " " + (digits.count == 6 && isDigits(digits) ? split(digits, [2, 2, 2], ":") : String(digits))
            let zone = clock.dropFirst(6)
            if !zone.isEmpty { text += " " + zone }
        }
        return text
    }

    /// ffprobe's "2024-05-06T07:08:09.000000Z" → "2024-05-06 07:08:09 UTC".
    static func isoDate(_ value: String) -> String {
        let pattern = #"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.\d+)?Z$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let day = Range(match.range(at: 1), in: value), let time = Range(match.range(at: 2), in: value)
        else { return value }
        return "\(value[day]) \(value[time]) UTC"
    }
}
