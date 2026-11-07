import Foundation

/// Which file extensions Keeper understands.
public enum FileTypes {
    public static let raw: Set<String> = [
        "arw", "srf", "sr2",            // Sony
        "cr2", "cr3", "crw",            // Canon
        "nef", "nrw",                   // Nikon
        "dng",                          // Adobe / Leica / many phones
        "raf",                          // Fujifilm
        "orf",                          // Olympus / OM System
        "rw2",                          // Panasonic
        "pef", "srw", "3fr", "erf", "raw", "rwl", "iiq",
    ]
    public static let image: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    public static func isRaw(_ url: URL) -> Bool { raw.contains(url.pathExtension.lowercased()) }
    public static func isImage(_ url: URL) -> Bool { image.contains(url.pathExtension.lowercased()) }
    public static func isSupported(_ url: URL) -> Bool { isRaw(url) || isImage(url) }
}

/// One logical photo on disk: a RAW (or plain image) plus its companion JPEG and sidecars.
public struct ScannedFile: Sendable, Hashable {
    /// The RAW file, or the image itself when there is no RAW.
    public let url: URL
    /// A JPEG/HEIC with the same base name, when shooting RAW+JPEG.
    public let companion: URL?
    /// `.xmp` sidecars that belong to this photo.
    public let sidecars: [URL]
    public let fileSize: Int64
    public let modified: Date

    public var isRaw: Bool { FileTypes.isRaw(url) }
    /// Every file that should move together when the photo is deleted.
    public var allFiles: [URL] { [url] + (companion.map { [$0] } ?? []) + sidecars }
}

public enum FolderScanner {
    /// Lists photos in `folder`, pairing RAW+JPEG by base name. Synchronous; call it off the main thread.
    public static func scan(_ folder: URL, recursive: Bool = false) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options) else {
            return []
        }

        struct Entry { var url: URL; var size: Int64; var modified: Date }
        var groups: [String: [Entry]] = [:]
        while let next = enumerator.nextObject() {
            guard let url = next as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard FileTypes.raw.contains(ext) || FileTypes.image.contains(ext) || ext == "xmp" else { continue }
            let key = url.deletingLastPathComponent().path + "/" + url.deletingPathExtension().lastPathComponent.lowercased()
            groups[key, default: []].append(Entry(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }

        var result: [ScannedFile] = []
        for (_, entries) in groups {
            let raw = entries.first { FileTypes.isRaw($0.url) }
            let image = entries.first { FileTypes.isImage($0.url) }
            let sidecars = entries.filter { $0.url.pathExtension.lowercased() == "xmp" }.map(\.url)
            if let raw {
                result.append(ScannedFile(url: raw.url, companion: image?.url, sidecars: sidecars, fileSize: raw.size, modified: raw.modified))
            } else if let image {
                result.append(ScannedFile(url: image.url, companion: nil, sidecars: sidecars, fileSize: image.size, modified: image.modified))
            }
        }
        return result.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}
