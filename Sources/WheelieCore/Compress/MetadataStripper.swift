import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum MetadataError: LocalizedError, Equatable {
    case imageUnverified
    case unsupported(String)
    case pdfFailed
    case mediaUnverified
    case leftover

    public var errorDescription: String? {
        switch self {
        case .imageUnverified: return "The image could not be verified. No output was saved."
        case .unsupported(let ext):
            return "Can't remove metadata from .\(ext) files. Install ExifTool (brew install exiftool) to clean this format."
        case .pdfFailed: return "PDFKit could not write the cleaned PDF."
        case .mediaUnverified: return "The cleaned file could not be verified. No output was saved."
        case .leftover: return "Some private metadata could not be removed. No output was saved."
        }
    }
}

/// "Remove Metadata": writes "<name> clean.<ext>" without EXIF/GPS/IPTC/XMP, tags or document info.
/// The original is never touched; every output is verified before it is delivered.
public enum MetadataStripper {
    public static func strip(_ source: URL, outputDirectory: URL? = nil) async throws -> URL {
        let work = try TempDir.make("wheelie-clean")
        defer { try? FileManager.default.removeItem(at: work) }
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let temp = work.appendingPathComponent("clean").appendingPathExtension(ext)

        switch FileKind(url: source) {
        case .image: try await stripImage(source, to: temp, workDir: work)
        case .pdf: try stripPDF(source, to: temp)
        case .video, .audio: try await stripMedia(source, to: temp)
        default: throw MetadataError.unsupported(ext.lowercased())
        }

        // Last line of defence: nothing identifying may survive.
        let leftovers = await MetadataReader.read(temp).filter { [.camera, .location, .people].contains($0.category) }
        guard leftovers.isEmpty else { throw MetadataError.leftover }
        try Task.checkCancellation()

        let output = OutputNaming.uniqueURL(for: source, ext: ext, suffix: " clean", in: outputDirectory)
        try FileManager.default.moveItem(at: temp, to: output)
        return output
    }

    // MARK: Images

    static func stripImage(_ source: URL, to output: URL, workDir: URL) async throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src) as String?,
              CGImageSourceGetCount(src) > 0
        else { throw MetadataError.imageUnverified }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type)
        let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1

        if try losslessStrip(source, type: type, orientation: orientation, to: output) {
            // JPEG/PNG: image data copied byte for byte; only the orientation tag is kept.
        } else if writable {
            try? FileManager.default.removeItem(at: output)
            try reencode(src, type: type, to: output)
        } else if Tools.locate("exiftool") != nil {
            try await Tools.run("exiftool", ["-q", "-q", "-m", "-all=", "-tagsFromFile", "@", "-ICC_Profile", "-Orientation",
                                             "-o", output.path, source.path])
        } else if type == "org.webmproject.webp", Tools.locate("webpmux") != nil {
            try await stripWebP(source, to: output, workDir: workDir)
        } else {
            throw MetadataError.unsupported(source.pathExtension.lowercased())
        }
        try verifyImage(output, against: src)
    }

    /// JPEG and PNG are cleaned at the container level (no re-encoding). Returns false when the
    /// format isn't handled or the result doesn't check out, so the caller re-encodes instead.
    static func losslessStrip(_ source: URL, type: String, orientation: Int, to output: URL) throws -> Bool {
        let stripped: Data?
        switch type {
        case UTType.jpeg.identifier: stripped = ContainerStripper.stripJPEG(try Data(contentsOf: source), orientation: orientation)
        case UTType.png.identifier: stripped = ContainerStripper.stripPNG(try Data(contentsOf: source), orientation: orientation)
        default: return false
        }
        guard let stripped else { return false }
        try stripped.write(to: output, options: .atomic)
        guard let check = CGImageSourceCreateWithURL(output as CFURL, nil),
              CGImageSourceCreateImageAtIndex(check, CGImageSourceGetPrimaryImageIndex(check), nil) != nil,
              MetadataReader.readImage(output).isEmpty
        else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        return true
    }

    /// Re-encodes every frame without metadata. Orientation is baked into the pixels;
    /// the color profile stays with the image; animation timing is kept.
    static func reencode(_ src: CGImageSource, type: String, to output: URL) throws {
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, count, nil) else {
            throw MetadataError.imageUnverified
        }
        let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
        var containerProps: [CFString: Any] = [:]
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary] {
            if let dict = container[key] as? [CFString: Any], let loop = dict[kCGImagePropertyGIFLoopCount] ?? dict[kCGImagePropertyAPNGLoopCount] {
                containerProps[key] = [kCGImagePropertyGIFLoopCount: loop]
            }
        }
        if !containerProps.isEmpty { CGImageDestinationSetProperties(dest, containerProps as CFDictionary) }

        let lossy = [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, "public.avif",
                     "public.jpeg-2000"].contains(type)
        for index in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
            guard let image = orientedImage(src, index: index, props: props) else { throw MetadataError.imageUnverified }
            var frame: [CFString: Any] = [:]
            if lossy { frame[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary] {
                guard let dict = props[key] as? [CFString: Any] else { continue }
                let timing = dict.filter { [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime].contains($0.key) }
                if !timing.isEmpty { frame[key] = timing }
            }
            CGImageDestinationAddImage(dest, image, frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw MetadataError.imageUnverified }
    }

    static func orientedImage(_ src: CGImageSource, index: Int, props: [CFString: Any]) -> CGImage? {
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation == 1 { return CGImageSourceCreateImageAtIndex(src, index, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }

    /// webpmux fails on missing chunks, so only strip what `-info` reports.
    static func stripWebP(_ source: URL, to output: URL, workDir: URL) async throws {
        let info = try await Tools.capture("webpmux", ["-info", source.path]).stdout
        var current = source
        for (chunk, marker) in [("exif", "EXIF"), ("xmp", "XMP")] where info.contains(marker) {
            let next = workDir.appendingPathComponent("strip-\(chunk).webp")
            try await Tools.run("webpmux", ["-strip", chunk, current.path, "-o", next.path])
            current = next
        }
        try FileManager.default.copyItem(at: current, to: output)
    }

    /// The output must decode, with the same frame count and the same (upright) pixel size.
    static func verifyImage(_ output: URL, against src: CGImageSource) throws {
        func uprightSize(_ s: CGImageSource) -> (Int, Int)? {
            let index = CGImageSourceGetPrimaryImageIndex(s)
            guard let p = CGImageSourceCopyPropertiesAtIndex(s, index, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let o = p[kCGImagePropertyOrientation] as? Int ?? 1
            return o >= 5 ? (h, w) : (w, h)
        }
        guard let out = CGImageSourceCreateWithURL(output as CFURL, nil),
              CGImageSourceGetCount(out) == CGImageSourceGetCount(src),
              CGImageSourceCreateImageAtIndex(out, CGImageSourceGetPrimaryImageIndex(out), nil) != nil,
              let a = uprightSize(out), let b = uprightSize(src), a == b
        else {
            try? FileManager.default.removeItem(at: output)
            throw MetadataError.imageUnverified
        }
    }

    // MARK: PDF

    /// Document info, catalog XMP, annotation authors/edit times, and the EXIF/GPS/XMP that placed
    /// photos (JPEG streams), pages and forms carry. Fails closed if any of it can't be removed.
    static func stripPDF(_ source: URL, to output: URL) throws {
        guard let doc = PDFDocument(url: source), !doc.isLocked else { throw CompressionError.pdfLocked }
        let pages = doc.pageCount
        doc.documentAttributes = [:]
        PDFEmbeddedMetadata.scrubAnnotations(doc)
        guard doc.write(to: output) else { throw MetadataError.pdfFailed }

        if !(PDFDocument(url: output).map { $0.pageCount == pages && !MetadataReader.hasXMP($0) } ?? false) {
            // Rebuild from page copies if the catalog kept its XMP packet.
            try? FileManager.default.removeItem(at: output)
            let fresh = PDFDocument()
            for index in 0..<pages {
                guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw MetadataError.pdfFailed }
                fresh.insert(page, at: index)
            }
            fresh.documentAttributes = [:]
            guard fresh.write(to: output) else { throw MetadataError.pdfFailed }
        }

        // PDFKit writes image and XMP streams through unchanged: blank their metadata in place.
        try PDFEmbeddedMetadata.scrubStreams(in: output)

        guard let check = PDFDocument(url: output), check.pageCount == pages, !MetadataReader.hasXMP(check) else {
            try? FileManager.default.removeItem(at: output)
            throw MetadataError.pdfFailed
        }
        // Streams stored compressed or encrypted can't be patched in place; never deliver them as clean.
        guard PDFEmbeddedMetadata.annotationAuthors(check).isEmpty, !PDFEmbeddedMetadata.hasLeftovers(in: output) else {
            try? FileManager.default.removeItem(at: output)
            throw MetadataError.leftover
        }
    }

    // MARK: Video / audio

    static func mediaArguments(input: URL, output: URL) -> [String] {
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                    // Real video, audio and subtitles; no cover art, data/timecode tracks or chapters.
                    "-map", "0:V?", "-map", "0:a?", "-map", "0:s?", "-dn",
                    "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1",
                    "-c", "copy", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
                    "-metadata:s", "handler_name=", "-metadata:s", "vendor_id=", "-metadata:s", "encoder="]
        if ["mp4", "m4v", "mov", "m4a", "3gp"].contains(output.pathExtension.lowercased()) {
            args += ["-movflags", "+faststart"]
        }
        return args + [output.path]
    }

    static func stripMedia(_ source: URL, to output: URL) async throws {
        let before = try await MediaProbe.probe(source)
        do {
            try await Tools.run("ffmpeg", mediaArguments(input: source, output: output))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        guard let after = try? await MediaProbe.probe(output),
              after.videoStreams.count == before.videoStreams.count,
              after.audioStreams.count == before.audioStreams.count,
              after.subtitleStreams.count == before.subtitleStreams.count,
              before.duration <= 0 || abs(after.duration - before.duration) <= max(0.5, before.duration * 0.02)
        else {
            try? FileManager.default.removeItem(at: output)
            throw MetadataError.mediaUnverified
        }
    }
}
