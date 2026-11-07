import SwiftUI

/// Design tokens. The whole app is dark: photos look best against a neutral, low-chroma surround.
enum Theme {
    static let bg = Color(red: 0.050, green: 0.054, blue: 0.065)
    static let surface = Color(red: 0.078, green: 0.083, blue: 0.098)
    static let elevated = Color(red: 0.112, green: 0.118, blue: 0.139)
    static let cell = Color(red: 0.092, green: 0.097, blue: 0.114)
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.14)

    static let text = Color(white: 0.95)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.40)

    static let accent = Color(red: 0.31, green: 0.65, blue: 1.00)
    static let pick = Color(red: 0.24, green: 0.80, blue: 0.48)
    static let reject = Color(red: 1.00, green: 0.34, blue: 0.34)
    static let star = Color(red: 1.00, green: 0.78, blue: 0.22)
    static let burst = Color(red: 0.70, green: 0.55, blue: 1.00)

    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.12)
}

extension Date {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()

    /// Wall-clock time as the camera recorded it (EXIF has no time zone).
    var shotTime: String { Date.timeFormatter.string(from: self) }
    var shotTimePrecise: String {
        let ms = Int((timeIntervalSince1970 - floor(timeIntervalSince1970)) * 100)
        return Date.timeFormatter.string(from: self) + String(format: ".%02d", ms)
    }
    var shotDay: String { Date.dayFormatter.string(from: self) }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
