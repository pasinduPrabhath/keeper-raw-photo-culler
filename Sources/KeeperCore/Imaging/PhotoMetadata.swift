import Foundation
import ImageIO

public enum Flag: String, Codable, Sendable, CaseIterable {
    case none, pick, reject
}

public struct PhotoMetadata: Sendable, Codable, Equatable {
    public var captureDate: Date
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var orientation: Int

    public init(captureDate: Date, make: String? = nil, model: String? = nil, lens: String? = nil,
                iso: Int? = nil, exposureTime: Double? = nil, fNumber: Double? = nil, focalLength: Double? = nil,
                pixelWidth: Int = 0, pixelHeight: Int = 0, orientation: Int = 1) {
        self.captureDate = captureDate; self.make = make; self.model = model; self.lens = lens
        self.iso = iso; self.exposureTime = exposureTime; self.fNumber = fNumber; self.focalLength = focalLength
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.orientation = orientation
    }

    public var shutterText: String? {
        guard let t = exposureTime, t > 0 else { return nil }
        return t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))"
    }
    public var apertureText: String? { fNumber.map { String(format: "ƒ/%.1f", $0) } }
    public var focalText: String? { focalLength.map { String(format: "%.0f mm", $0) } }
    public var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
    public var cameraName: String? {
        guard let model else { return make }
        if let make, !model.lowercased().hasPrefix(make.lowercased()) { return "\(make) \(model)" }
        return model
    }
}

public enum MetadataReader {
    /// Reads EXIF from the file header; does not decode pixels, so it is fast even for RAW.
    public static func read(_ url: URL, fallbackDate: Date) -> PhotoMetadata {
        guard let props = properties(url) else { return PhotoMetadata(captureDate: fallbackDate) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        let date = dateString.flatMap { parseExifDate($0, subsec: subsec) } ?? fallbackDate

        return PhotoMetadata(
            captureDate: date,
            make: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces),
            model: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces),
            lens: exif[kCGImagePropertyExifLensModel] as? String,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            orientation: props[kCGImagePropertyOrientation] as? Int ?? (tiff[kCGImagePropertyTIFFOrientation] as? Int ?? 1)
        )
    }

    public static func properties(_ url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Parses `"2026:11:07 09:42:11"` plus an optional sub-second digit string (`"47"` → 0.47 s).
    /// EXIF has no time zone, so everything is read as UTC; only differences between shots matter.
    public static func parseExifDate(_ string: String, subsec: String?) -> Date? {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let base = utc.date(from: comps) else { return nil }
        var fraction = 0.0
        if let s = subsec?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.allSatisfy(\.isNumber), let f = Double("0." + s) {
            fraction = f
        }
        return base.addingTimeInterval(fraction)
    }
}
