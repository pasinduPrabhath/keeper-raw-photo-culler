import Foundation

/// Builds small TIFF-structured files that look like an ARW to Keeper: EXIF in IFD0/ExifIFD and a JPEG
/// preview in a SubIFD. Used by the unit tests and by `KeeperDemoGen` so contributors can try the app
/// without a camera. Not a real RAW: the "sensor data" is a single pixel.
public enum SyntheticRAW {
    public struct Shot: Sendable {
        public var jpeg: Data
        public var date: Date
        public var subsecond: Int            // milliseconds
        public var make = "SONY"
        public var model = "ILCE-6700"
        public var lens = "FE 200-600mm F5.6-6.3 G OSS"
        public var iso = 800
        public var exposure: (Int, Int) = (1, 2000)
        public var fNumber: (Int, Int) = (63, 10)
        public var focalLength: (Int, Int) = (600, 1)
        public var orientation = 1
        /// Store the preview via JPEGInterchangeFormat tags in IFD1 instead of strips in a SubIFD.
        public var useJPEGInterchangeTags = false

        public init(jpeg: Data, date: Date, subsecond: Int = 0) {
            self.jpeg = jpeg; self.date = date; self.subsecond = subsecond
        }
    }

    public static func make(_ shot: Shot) -> Data {
        var b = TIFFBuilder()
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.locale = Locale(identifier: "en_US_POSIX")
        let dateString = df.string(from: shot.date)

        var ifd0: [TIFFBuilder.Entry] = [
            .init(0x0100, .long(1)), .init(0x0101, .long(1)), .init(0x0102, .short(8)),
            .init(0x0103, .short(1)), .init(0x0106, .short(1)),
            .init(0x010F, .ascii(shot.make)), .init(0x0110, .ascii(shot.model)),
            .init(0x0111, .blobOffset("pixel")), .init(0x0112, .short(shot.orientation)),
            .init(0x0115, .short(1)), .init(0x0116, .long(1)), .init(0x0117, .long(1)),
            .init(0x0132, .ascii(dateString)),
            .init(0x8769, .ifdOffset("exif")),
        ]
        if !shot.useJPEGInterchangeTags { ifd0.append(.init(0x014A, .ifdOffset("sub"))) }

        b.ifds.append(.init(name: "ifd0", entries: ifd0, next: shot.useJPEGInterchangeTags ? "ifd1" : nil))
        b.ifds.append(.init(name: "exif", entries: [
            .init(0x829A, .rational(shot.exposure.0, shot.exposure.1)),
            .init(0x829D, .rational(shot.fNumber.0, shot.fNumber.1)),
            .init(0x8827, .short(shot.iso)),
            .init(0x9003, .ascii(dateString)),
            .init(0x920A, .rational(shot.focalLength.0, shot.focalLength.1)),
            .init(0x9291, .ascii(String(format: "%03d", shot.subsecond))),
            .init(0xA434, .ascii(shot.lens)),
        ], next: nil))

        if shot.useJPEGInterchangeTags {
            b.ifds.append(.init(name: "ifd1", entries: [
                .init(0x0103, .short(6)),
                .init(0x0201, .blobOffset("jpeg")), .init(0x0202, .blobLength("jpeg")),
            ], next: nil))
        } else {
            b.ifds.append(.init(name: "sub", entries: [
                .init(0x0100, .long(1620)), .init(0x0101, .long(1080)),
                .init(0x0103, .short(6)),
                .init(0x0111, .blobOffset("jpeg")), .init(0x0117, .blobLength("jpeg")),
            ], next: nil))
        }
        b.blobs = [("pixel", Data([0x80])), ("jpeg", shot.jpeg)]
        return b.build()
    }
}

/// Minimal little-endian TIFF writer with named IFDs and blobs.
struct TIFFBuilder {
    enum Value {
        case short(Int), long(Int), ascii(String), rational(Int, Int)
        case ifdOffset(String), blobOffset(String), blobLength(String)
    }
    struct Entry {
        let tag: Int; let value: Value
        init(_ tag: Int, _ value: Value) { self.tag = tag; self.value = value }
    }
    struct IFD { let name: String; let entries: [Entry]; let next: String? }

    var ifds: [IFD] = []
    var blobs: [(String, Data)] = []

    func build() -> Data {
        // Pass 1: lay everything out to learn offsets.
        var offsets: [String: Int] = [:]
        var cursor = 8
        var extraSizes: [[Int]] = []
        for ifd in ifds {
            offsets[ifd.name] = cursor
            cursor += 2 + ifd.entries.count * 12 + 4
            var sizes: [Int] = []
            for e in ifd.entries {
                let payload = Self.payloadSize(e.value)
                sizes.append(payload > 4 ? payload : 0)
                if payload > 4 { cursor += payload + (payload & 1) }
            }
            extraSizes.append(sizes)
        }
        var blobOffsets: [String: Int] = [:]
        for (name, data) in blobs {
            blobOffsets[name] = cursor
            cursor += data.count + (data.count & 1)
        }

        // Pass 2: write.
        var out = Data()
        out.append(contentsOf: [0x49, 0x49, 42, 0])
        out.appendLE32(8)
        for (index, ifd) in ifds.enumerated() {
            precondition(out.count == offsets[ifd.name]!)
            out.appendLE16(ifd.entries.count)
            var extras = Data()
            var extraCursor = out.count + ifd.entries.count * 12 + 4
            for e in ifd.entries {
                out.appendLE16(e.tag)
                let (type, count, bytes) = encode(e.value, offsets: offsets, blobOffsets: blobOffsets)
                out.appendLE16(type)
                out.appendLE32(count)
                if bytes.count <= 4 {
                    out.append(bytes)
                    out.append(Data(repeating: 0, count: 4 - bytes.count))
                } else {
                    out.appendLE32(extraCursor)
                    extras.append(bytes)
                    if bytes.count & 1 == 1 { extras.append(0) }
                    extraCursor += bytes.count + (bytes.count & 1)
                }
            }
            out.appendLE32(ifd.next.flatMap { offsets[$0] } ?? 0)
            out.append(extras)
            _ = index
        }
        for (_, data) in blobs {
            out.append(data)
            if data.count & 1 == 1 { out.append(0) }
        }
        return out
    }

    private static func payloadSize(_ v: Value) -> Int {
        switch v {
        case .short: 2
        case .long, .ifdOffset, .blobOffset, .blobLength: 4
        case .ascii(let s): s.utf8.count + 1
        case .rational: 8
        }
    }

    private func encode(_ v: Value, offsets: [String: Int], blobOffsets: [String: Int]) -> (type: Int, count: Int, bytes: Data) {
        var d = Data()
        switch v {
        case .short(let x): d.appendLE16(x); return (3, 1, d)
        case .long(let x): d.appendLE32(x); return (4, 1, d)
        case .ifdOffset(let n): d.appendLE32(offsets[n] ?? 0); return (4, 1, d)
        case .blobOffset(let n): d.appendLE32(blobOffsets[n] ?? 0); return (4, 1, d)
        case .blobLength(let n): d.appendLE32(blobs.first { $0.0 == n }?.1.count ?? 0); return (4, 1, d)
        case .ascii(let s): d.append(contentsOf: Array(s.utf8)); d.append(0); return (2, d.count, d)
        case .rational(let n, let den): d.appendLE32(n); d.appendLE32(den); return (5, 1, d)
        }
    }
}

extension Data {
    mutating func appendLE16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func appendLE32(_ v: Int) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
