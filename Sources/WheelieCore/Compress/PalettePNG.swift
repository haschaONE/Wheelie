import CoreGraphics
import Foundation

/// Lossy PNG compression: alpha-aware median-cut quantization to at most 256 colors with
/// Floyd–Steinberg dithering, written as an indexed PNG (PLTE + tRNS). Images that already
/// use few enough colors are stored exactly, so flat screenshots stay lossless.
enum PalettePNG {
    static func encode(_ image: CGImage, maxColors: Int, dither: Bool, dpi: Double?) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let colors = min(max(maxColors, 2), 256)
        // Quantize in the image's own RGB space and embed it, so colors don't shift.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? srgb
        let isSRGB = space.name.map { $0 == CGColorSpace.sRGB } ?? false
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              ctx.data != nil
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let count = width * height
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: count * 4)
        return withExtendedLifetime(ctx) { () -> Data? in
            unpremultiply(px, count: count)
            var indices = [UInt8](repeating: 0, count: count)
            let palette: [SIMD4<UInt8>]
            if let exact = exactPalette(px, count: count, maxColors: colors, indices: &indices) {
                palette = exact
            } else {
                let quantizer = Quantizer(px: px, count: count, colors: colors)
                palette = quantizer.palette
                quantizer.map(px: px, width: width, height: height, dither: dither, into: &indices)
            }
            return write(width: width, height: height, palette: palette, indices: indices,
                         icc: isSRGB ? nil : space.copyICCData() as Data?, dpi: dpi)
        }
    }

    // MARK: Pixels

    static func unpremultiply(_ px: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in 0..<count {
            let o = i * 4
            let a = Int(px[o + 3])
            if a == 255 { continue }
            if a == 0 {
                px[o] = 0; px[o + 1] = 0; px[o + 2] = 0
                continue
            }
            for c in 0..<3 {
                px[o + c] = UInt8(min(255, (Int(px[o + c]) * 255 + a / 2) / a))
            }
        }
    }

    /// Returns the exact palette when the image uses at most `maxColors` distinct RGBA values.
    static func exactPalette(_ px: UnsafeMutablePointer<UInt8>, count: Int, maxColors: Int,
                             indices: inout [UInt8]) -> [SIMD4<UInt8>]? {
        var lookup: [UInt32: UInt8] = [:]
        lookup.reserveCapacity(maxColors * 2)
        var palette: [SIMD4<UInt8>] = []
        var lastColor: UInt32 = 0, lastIndex: UInt8 = 0, hasLast = false
        for i in 0..<count {
            let o = i * 4
            let color = UInt32(px[o]) << 24 | UInt32(px[o + 1]) << 16 | UInt32(px[o + 2]) << 8 | UInt32(px[o + 3])
            if hasLast, color == lastColor { indices[i] = lastIndex; continue }
            let index: UInt8
            if let known = lookup[color] {
                index = known
            } else {
                guard palette.count < maxColors else { return nil }
                index = UInt8(palette.count)
                palette.append(SIMD4(px[o], px[o + 1], px[o + 2], px[o + 3]))
                lookup[color] = index
            }
            indices[i] = index
            lastColor = color; lastIndex = index; hasLast = true
        }
        return palette
    }

    // MARK: Median cut

    /// 5 bits per color channel, 3 bits of alpha.
    @inline(__always) static func binKey(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
        (r >> 3) << 13 | (g >> 3) << 8 | (b >> 3) << 3 | (a >> 5)
    }

    /// Channel value of a bin on a comparable 0...31 scale (alpha is weighted ×4).
    @inline(__always) static func channel(_ key: Int32, _ axis: Int) -> Int {
        let k = Int(key)
        switch axis {
        case 0: return (k >> 13) & 31
        case 1: return (k >> 8) & 31
        case 2: return (k >> 3) & 31
        default: return (k & 7) * 4
        }
    }

    final class Quantizer {
        private(set) var palette: [SIMD4<UInt8>] = []
        private var centers: [SIMD4<Float>] = []
        private var transparentIndex: Int?

        init(px: UnsafeMutablePointer<UInt8>, count: Int, colors: Int) {
            let binCount = 1 << 18
            var counts = [Int](repeating: 0, count: binCount)
            var sums = [Int](repeating: 0, count: binCount * 4)
            var hasTransparent = false
            for i in 0..<count {
                let o = i * 4
                let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2]), a = Int(px[o + 3])
                if a == 0 { hasTransparent = true; continue }
                let k = binKey(r, g, b, a)
                counts[k] += 1
                sums[k * 4] += r; sums[k * 4 + 1] += g; sums[k * 4 + 2] += b; sums[k * 4 + 3] += a
            }
            var bins: [Int32] = []
            for k in 0..<binCount where counts[k] > 0 { bins.append(Int32(k)) }

            struct Box { var start: Int, end: Int, count: Int, axis: Int, range: Int }
            func makeBox(_ start: Int, _ end: Int) -> Box {
                var lo = [Int](repeating: 255, count: 4), hi = [Int](repeating: 0, count: 4)
                var total = 0
                for i in start..<end {
                    let key = bins[i]
                    total += counts[Int(key)]
                    for axis in 0..<4 {
                        let v = channel(key, axis)
                        lo[axis] = min(lo[axis], v); hi[axis] = max(hi[axis], v)
                    }
                }
                var axis = 0, range = -1
                for a in 0..<4 where hi[a] - lo[a] > range { axis = a; range = hi[a] - lo[a] }
                return Box(start: start, end: end, count: total, axis: axis, range: range)
            }

            let target = max(1, hasTransparent ? colors - 1 : colors)
            var boxes = bins.isEmpty ? [] : [makeBox(0, bins.count)]
            while boxes.count < target {
                var pick = -1
                var bestScore = 0.0
                for (i, box) in boxes.enumerated() where box.end - box.start > 1 && box.range > 0 {
                    let score = Double(box.count) * Double(box.range)
                    if score > bestScore { bestScore = score; pick = i }
                }
                guard pick >= 0 else { break }
                let box = boxes[pick]
                let axis = box.axis
                bins[box.start..<box.end].sort { channel($0, axis) < channel($1, axis) }
                var running = 0
                var split = box.start + 1
                for i in box.start..<box.end {
                    running += counts[Int(bins[i])]
                    if running * 2 >= box.count { split = i + 1; break }
                }
                split = min(max(split, box.start + 1), box.end - 1)
                boxes[pick] = makeBox(box.start, split)
                boxes.append(makeBox(split, box.end))
            }

            centers = boxes.map { box in
                var s = SIMD4<Float>(repeating: 0)
                var n = 0
                for i in box.start..<box.end {
                    let k = Int(bins[i])
                    s += SIMD4(Float(sums[k * 4]), Float(sums[k * 4 + 1]), Float(sums[k * 4 + 2]), Float(sums[k * 4 + 3]))
                    n += counts[k]
                }
                return s / Float(max(n, 1))
            }

            // A couple of k-means passes over the bins tighten the median-cut palette.
            let iterations = bins.count * centers.count <= 40_000_000 ? 2 : 0
            for _ in 0..<iterations where centers.count > 1 {
                var acc = [SIMD4<Float>](repeating: .zero, count: centers.count)
                var weights = [Float](repeating: 0, count: centers.count)
                for key in bins {
                    let k = Int(key)
                    let w = Float(counts[k])
                    let mean = SIMD4(Float(sums[k * 4]), Float(sums[k * 4 + 1]), Float(sums[k * 4 + 2]), Float(sums[k * 4 + 3])) / w
                    let j = Quantizer.nearest(mean, in: centers)
                    acc[j] += mean * w
                    weights[j] += w
                }
                for j in centers.indices where weights[j] > 0 { centers[j] = acc[j] / weights[j] }
            }

            if hasTransparent {
                transparentIndex = centers.count
                centers.append(.zero)
            }
            palette = centers.map { c in
                let v = c.rounded(.toNearestOrAwayFromZero).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255))
                return SIMD4(UInt8(v.x), UInt8(v.y), UInt8(v.z), UInt8(v.w))
            }
            centers = palette.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
        }

        static func nearest(_ color: SIMD4<Float>, in centers: [SIMD4<Float>]) -> Int {
            var best = 0
            var bestDistance = Float.greatestFiniteMagnitude
            for (j, c) in centers.enumerated() {
                let d = c - color
                let distance = (d * d).sum()
                if distance < bestDistance { bestDistance = distance; best = j }
            }
            return best
        }

        /// Maps pixels to palette indices, diffusing the color error (Floyd–Steinberg, 85% strength).
        func map(px: UnsafeMutablePointer<UInt8>, width: Int, height: Int, dither: Bool, into indices: inout [UInt8]) {
            var cache = [Int16](repeating: -1, count: 1 << 18)
            let opaqueCenters = transparentIndex == nil ? centers : Array(centers.dropLast())
            var current = [Float](repeating: 0, count: (width + 2) * 3)
            var next = current
            let strength: Float = 0.85
            for y in 0..<height {
                swap(&current, &next)
                for i in next.indices { next[i] = 0 }
                for x in 0..<width {
                    let i = y * width + x
                    let o = i * 4
                    let a = Int(px[o + 3])
                    if a == 0, let t = transparentIndex { indices[i] = UInt8(t); continue }
                    let e = (x + 1) * 3
                    let r = min(max(Float(px[o]) + current[e], 0), 255)
                    let g = min(max(Float(px[o + 1]) + current[e + 1], 0), 255)
                    let b = min(max(Float(px[o + 2]) + current[e + 2], 0), 255)
                    let key = PalettePNG.binKey(Int(r), Int(g), Int(b), a)
                    var index = Int(cache[key])
                    if index < 0 {
                        index = Quantizer.nearest(SIMD4(r, g, b, Float(a)), in: opaqueCenters)
                        cache[key] = Int16(index)
                    }
                    indices[i] = UInt8(index)
                    guard dither else { continue }
                    let p = centers[index]
                    diffuse((r - p.x) * strength, at: e, current: &current, next: &next)
                    diffuse((g - p.y) * strength, at: e + 1, current: &current, next: &next)
                    diffuse((b - p.z) * strength, at: e + 2, current: &current, next: &next)
                }
            }
        }
    }

    /// Floyd–Steinberg weights: 7/16 right, 3/16 down-left, 5/16 down, 1/16 down-right.
    @inline(__always) static func diffuse(_ err: Float, at e: Int, current: inout [Float], next: inout [Float]) {
        current[e + 3] += err * 7 / 16
        next[e - 3] += err * 3 / 16
        next[e] += err * 5 / 16
        next[e + 3] += err / 16
    }

    // MARK: PNG writer

    static func write(width: Int, height: Int, palette: [SIMD4<UInt8>], indices: [UInt8], icc: Data?, dpi: Double?) -> Data? {
        // Entries with transparency first keeps tRNS short.
        let order = palette.indices.sorted { (palette[$0].w < 255 ? 0 : 1, $0) < (palette[$1].w < 255 ? 0 : 1, $1) }
        var remap = [UInt8](repeating: 0, count: 256)
        for (newIndex, oldIndex) in order.enumerated() { remap[oldIndex] = UInt8(newIndex) }
        let sorted = order.map { palette[$0] }

        let n = sorted.count
        let depth = n <= 2 ? 1 : n <= 4 ? 2 : n <= 16 ? 4 : 8
        let rowBytes = (width * depth + 7) / 8
        var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        let perByte = 8 / depth
        for y in 0..<height {
            let row = y * (rowBytes + 1) + 1   // filter byte 0 (None) precedes each row
            for x in 0..<width {
                let value = remap[Int(indices[y * width + x])]
                if depth == 8 {
                    raw[row + x] = value
                } else {
                    let shift = 8 - depth * (x % perByte + 1)
                    raw[row + x / perByte] |= value << UInt8(shift)
                }
            }
        }
        guard let idat = zlib(raw) else { return nil }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(width)); ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])
        png.appendChunk("IHDR", ihdr)
        if let icc, let compressed = zlib([UInt8](icc)) {
            var chunk = Data("ICC Profile".utf8)
            chunk.append(contentsOf: [0, 0])
            chunk.append(compressed)
            png.appendChunk("iCCP", chunk)
        } else {
            png.appendChunk("sRGB", Data([0]))
        }
        if let dpi, dpi > 0, abs(dpi - 72) > 0.5 {
            let ppm = UInt32((dpi / 0.0254).rounded())
            var phys = Data()
            phys.appendBE(ppm); phys.appendBE(ppm); phys.append(1)
            png.appendChunk("pHYs", phys)
        }
        png.appendChunk("PLTE", Data(sorted.flatMap { [$0.x, $0.y, $0.z] }))
        let alphas = sorted.prefix { $0.w < 255 }.map(\.w)
        if !alphas.isEmpty { png.appendChunk("tRNS", Data(alphas)) }
        png.appendChunk("IDAT", idat)
        png.appendChunk("IEND", Data())
        return png
    }

    /// zlib stream (RFC 1950): Foundation's .zlib is raw DEFLATE, so add the header and Adler-32.
    static func zlib(_ bytes: [UInt8]) -> Data? {
        guard let deflated = try? (Data(bytes) as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x78, 0x9C])
        out.append(deflated)
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = min(i + 5552, bytes.count)
            while i < end { a += UInt32(bytes[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        out.appendBE(b << 16 | a)
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBE(UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        append(typed)
        appendBE(PalettePNG.crc32(typed))
    }
}
