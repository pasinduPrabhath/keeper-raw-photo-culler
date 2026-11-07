import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A thumbnail plus the sharpness score computed from the same decode.
public struct PhotoAnalysis: @unchecked Sendable {
    public let thumbnail: CGImage
    public let sharpness: Double
}

private final class AnalysisBox {
    let value: PhotoAnalysis
    init(_ value: PhotoAnalysis) { self.value = value }
}

/// Produces thumbnails + sharpness scores, with a memory cache, a disk cache and in-flight de-duplication.
/// Re-opening a folder you've already seen is therefore instant.
public actor ThumbnailService {
    public static let shared = ThumbnailService()
    public static let thumbnailPixels = 480

    private let memory = NSCache<NSString, AnalysisBox>()
    private var inflight: [String: Task<PhotoAnalysis?, Never>] = [:]
    private let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Keeper/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        memory.totalCostLimit = 180_000_000   // ~300 thumbnails
    }

    public func analysis(primary: URL, companion: URL?, size: Int64, modified: Date, priority: TaskPriority = .userInitiated) async -> PhotoAnalysis? {
        let key = Self.cacheKey(primary, size: size, modified: modified, companion: companion)
        if let hit = memory.object(forKey: key as NSString) { return hit.value }
        if let running = inflight[key] { return await running.value }

        let dir = directory
        let task = Task.detached(priority: priority) { () -> PhotoAnalysis? in
            if let cached = Self.readCache(key: key, in: dir) { return cached }
            guard let computed = Self.compute(primary: primary, companion: companion) else { return nil }
            Self.writeCache(computed, key: key, in: dir)
            return computed
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result { memory.setObject(AnalysisBox(result), forKey: key as NSString, cost: result.thumbnail.width * result.thumbnail.height * 4) }
        return result
    }

    public func clearDiskCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func diskCacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - Compute

    static func compute(primary: URL, companion: URL?) -> PhotoAnalysis? {
        guard let image = PreviewDecoder.image(primary: primary, companion: companion, maxPixel: 1024) else { return nil }
        let sharpness = SharpnessAnalyzer.score(image)
        let thumb = ImageResizer.resize(image, maxPixel: thumbnailPixels)
        return PhotoAnalysis(thumbnail: thumb, sharpness: sharpness)
    }

    // MARK: - Disk cache

    static func cacheKey(_ url: URL, size: Int64, modified: Date, companion: URL?) -> String {
        let raw = "\(url.path)|\(size)|\(Int(modified.timeIntervalSince1970))|\(companion?.path ?? "")|v3"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func readCache(key: String, in dir: URL) -> PhotoAnalysis? {
        let jpg = dir.appendingPathComponent(key + ".jpg")
        let meta = dir.appendingPathComponent(key + ".score")
        guard let text = try? String(contentsOf: meta, encoding: .utf8), let score = Double(text),
              let source = CGImageSourceCreateWithURL(jpg as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return PhotoAnalysis(thumbnail: image, sharpness: score)
    }

    private static func writeCache(_ analysis: PhotoAnalysis, key: String, in dir: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, analysis.thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (data as Data).write(to: dir.appendingPathComponent(key + ".jpg"), options: .atomic)
        try? String(analysis.sharpness).write(to: dir.appendingPathComponent(key + ".score"), atomically: true, encoding: .utf8)
    }
}

/// Larger images for the loupe / presentation views, cached in memory.
public final class PreviewCache: @unchecked Sendable {
    public static let shared = PreviewCache()
    fileprivate final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    fileprivate let cache = NSCache<NSString, Box>()
    private init() { cache.countLimit = 28 }

    public func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: "\(url.path)|\(maxPixel)" as NSString)?.image
    }

    public func image(primary: URL, companion: URL?, maxPixel: Int) async -> CGImage? {
        if let hit = cached(primary, maxPixel: maxPixel) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            PreviewDecoder.image(primary: primary, companion: companion, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(Box(image), forKey: "\(primary.path)|\(maxPixel)" as NSString) }
        return image
    }
}

extension PreviewCache {
    /// Sharper image for presentations: develops the RAW (a second or so), cached in memory.
    public func developed(primary: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(primary.path)|dev|\(maxPixel)"
        if let hit = cache.object(forKey: key as NSString)?.image { return hit }
        let image = await Task.detached(priority: .utility) { PreviewDecoder.developRAW(primary, maxPixel: maxPixel) }.value
        if let image { cache.setObject(Box(image), forKey: key as NSString) }
        return image
    }

    public func cachedDeveloped(primary: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: "\(primary.path)|dev|\(maxPixel)" as NSString)?.image
    }
}
