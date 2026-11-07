import Foundation

/// Location of a JPEG stream inside a TIFF-based RAW file.
public struct EmbeddedJPEGRange: Sendable, Equatable {
    public let offset: Int
    public let length: Int
    public let width: Int?
    public let height: Int?
}

/// Finds the JPEG previews that cameras embed in TIFF-based RAW files (ARW, DNG, NEF, CR2, ORF…).
///
/// This is the trick that makes browsing instant: instead of demosaicing a 26 MP RAW (seconds),
/// we walk the TIFF directory tree, locate the camera-rendered JPEG and decode only that (milliseconds).
public enum TIFFPreviewExtractor {
    /// Every embedded JPEG found, in discovery order.
    public static func candidates(in data: Data) -> [EmbeddedJPEGRange] {
        data.withUnsafeBytes { raw -> [EmbeddedJPEGRange] in
            var reader = ByteReader(p: raw)
            guard reader.parseHeader(), let first = reader.u32(4) else { return [] }
            var visited = Set<Int>()
            var found: [EmbeddedJPEGRange] = []
            walk(reader, ifd: first, depth: 0, visited: &visited, found: &found)
            return found
        }
    }

    /// The biggest embedded JPEG, copied out of `data`.
    public static func largestJPEG(in data: Data) -> Data? {
        if let best = candidates(in: data).max(by: { $0.length < $1.length }) {
            return data.subdata(in: best.offset ..< best.offset + best.length)
        }
        // Not TIFF-based (Canon CR3 is an ISO-BMFF container, Fujifilm RAF has its own header, CRW is CIFF):
        // fall back to scanning for embedded JPEG streams.
        return scanForJPEG(in: data)
    }

    /// Finds JPEG streams by their start-of-image marker, validates each, and returns the largest.
    /// A stream is taken to run until the next one starts (or the end of the file); decoders ignore trailing bytes.
    static func scanForJPEG(in data: Data) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            let r = ByteReader(p: raw)
            var starts: [Int] = []
            var i = 0
            let n = raw.count
            while i + 3 < n {
                if raw[i] == 0xFF, raw[i + 1] == 0xD8, raw[i + 2] == 0xFF { starts.append(i); i += 3 } else { i += 1 }
            }
            var best: (offset: Int, length: Int)?
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1] : n
                let length = end - start
                guard length > (best?.length ?? 1024), r.isJPEG(at: start, length: length) else { continue }
                best = (start, length)
            }
            guard let best else { return nil }
            return Data(raw[best.offset ..< best.offset + best.length])
        }
    }

    // MARK: - IFD walking

    private enum Tag {
        static let width = 0x0100, height = 0x0101, compression = 0x0103
        static let stripOffsets = 0x0111, stripByteCounts = 0x0117
        static let subIFDs = 0x014A, exifIFD = 0x8769
        static let jpegOffset = 0x0201, jpegLength = 0x0202
    }

    private static func walk(_ r: ByteReader, ifd: Int, depth: Int, visited: inout Set<Int>, found: inout [EmbeddedJPEGRange]) {
        guard depth < 8, ifd > 0, visited.insert(ifd).inserted, let n = r.u16(ifd), n > 0, n < 512 else { return }

        var compression: Int?, stripOffset: Int?, stripLength: Int?
        var jpegOffset: Int?, jpegLength: Int?, width: Int?, height: Int?
        var children: [Int] = []

        for i in 0 ..< n {
            let e = ifd + 2 + i * 12
            guard let tag = r.u16(e), let type = r.u16(e + 2), let count = r.u32(e + 4) else { return }
            let field = e + 8
            switch tag {
            case Tag.width: width = r.scalar(type: type, at: field)
            case Tag.height: height = r.scalar(type: type, at: field)
            case Tag.compression: compression = r.scalar(type: type, at: field)
            case Tag.stripOffsets: stripOffset = r.values(type: type, count: count, field: field, limit: 1).first
            case Tag.stripByteCounts: stripLength = r.values(type: type, count: count, field: field, limit: 1).first
            case Tag.jpegOffset: jpegOffset = r.scalar(type: type, at: field)
            case Tag.jpegLength: jpegLength = r.scalar(type: type, at: field)
            case Tag.subIFDs: children += r.values(type: type, count: count, field: field, limit: 16)
            case Tag.exifIFD: if let v = r.scalar(type: type, at: field) { children.append(v) }
            default: break
            }
        }

        if let o = jpegOffset, let l = jpegLength, r.isJPEG(at: o, length: l) {
            found.append(EmbeddedJPEGRange(offset: o, length: l, width: width, height: height))
        }
        // Old-style JPEG (6) or new-style JPEG (7) stored as a single strip.
        if let c = compression, c == 6 || c == 7, let o = stripOffset, let l = stripLength, r.isJPEG(at: o, length: l) {
            found.append(EmbeddedJPEGRange(offset: o, length: l, width: width, height: height))
        }

        for child in children { walk(r, ifd: child, depth: depth + 1, visited: &visited, found: &found) }
        if let next = r.u32(ifd + 2 + n * 12), next != 0 {
            walk(r, ifd: next, depth: depth + 1, visited: &visited, found: &found)
        }
    }
}

/// Bounds-checked big/little-endian reads over a raw buffer.
struct ByteReader {
    let p: UnsafeRawBufferPointer
    var little = true

    mutating func parseHeader() -> Bool {
        guard p.count > 16 else { return false }
        switch (p[0], p[1]) {
        case (0x49, 0x49): little = true     // "II"
        case (0x4D, 0x4D): little = false    // "MM"
        default: return false
        }
        // 42 = TIFF; ORF/RW2 use their own magic numbers but share the structure.
        guard let magic = u16(2), [42, 0x4F52, 0x5352, 0x55].contains(magic) else { return false }
        return true
    }

    func u8(_ o: Int) -> Int? { o >= 0 && o < p.count ? Int(p[o]) : nil }

    func u16(_ o: Int) -> Int? {
        guard o >= 0, o + 2 <= p.count else { return nil }
        let a = Int(p[o]), b = Int(p[o + 1])
        return little ? (b << 8 | a) : (a << 8 | b)
    }

    func u32(_ o: Int) -> Int? {
        guard o >= 0, o + 4 <= p.count else { return nil }
        let b0 = Int(p[o]), b1 = Int(p[o + 1]), b2 = Int(p[o + 2]), b3 = Int(p[o + 3])
        return little ? (b3 << 24 | b2 << 16 | b1 << 8 | b0) : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }

    /// A single inline value of SHORT/LONG/BYTE type.
    func scalar(type: Int, at field: Int) -> Int? {
        switch type {
        case 3: return u16(field)
        case 4, 13: return u32(field)
        case 1, 7: return u8(field)
        default: return nil
        }
    }

    /// Up to `limit` SHORT/LONG values, following the offset when they don't fit inline.
    func values(type: Int, count: Int, field: Int, limit: Int) -> [Int] {
        let size = (type == 3) ? 2 : 4
        guard type == 3 || type == 4 || type == 13, count > 0 else { return [] }
        let base = count * size <= 4 ? field : (u32(field) ?? -1)
        var out: [Int] = []
        for i in 0 ..< min(count, limit) {
            let o = base + i * size
            if let v = (size == 2 ? u16(o) : u32(o)) { out.append(v) }
        }
        return out
    }

    /// True for a viewable JPEG (baseline, extended or progressive DCT).
    ///
    /// RAW containers also hide *lossless* JPEG streams (SOF3) that hold the actual sensor data.
    /// On a Sony A6700 that stream is the biggest "JPEG" in the file (31 MB), but it decodes to
    /// garbage/black, so it must never be picked as a preview.
    func isJPEG(at offset: Int, length: Int) -> Bool {
        guard length > 1024, offset > 0, offset + length <= p.count, p[offset] == 0xFF, p[offset + 1] == 0xD8 else { return false }
        var o = offset + 2
        let end = min(offset + length, offset + 1_000_000)
        while o + 4 <= end {
            guard p[o] == 0xFF else { return false }
            let marker = Int(p[o + 1])
            if marker == 0xFF { o += 1; continue }                       // fill byte
            switch marker {
            case 0xC0, 0xC1, 0xC2: return true                           // baseline / extended / progressive
            case 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF: return false   // lossless / differential / arithmetic
            case 0xD9, 0xDA: return false                                // end or scan before any frame header
            case 0x01, 0xD0 ... 0xD7: o += 2; continue                   // standalone markers
            default:
                guard let segment = u16Big(o + 2), segment >= 2 else { return false }
                o += 2 + segment
            }
        }
        return false
    }

    private func u16Big(_ o: Int) -> Int? {
        guard o >= 0, o + 2 <= p.count else { return nil }
        return Int(p[o]) << 8 | Int(p[o + 1])
    }
}
