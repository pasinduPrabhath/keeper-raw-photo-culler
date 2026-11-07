import Foundation
import KeeperCore

/// One photo in the library. Observable per item so toggling a flag only redraws that thumbnail.
@MainActor @Observable
final class PhotoItem: Identifiable {
    nonisolated let id: String
    let file: ScannedFile
    /// The folder the user opened that this photo was found in.
    let root: URL
    var meta: PhotoMetadata

    var flag: Flag = .none
    var rating = 0
    var sharpness: Double?
    var burstID = 0
    var isBestInBurst = false

    init(file: ScannedFile, meta: PhotoMetadata, root: URL) {
        self.id = file.url.path
        self.file = file
        self.root = root
        self.meta = meta
    }

    var url: URL { file.url }
    var companion: URL? { file.companion }
    var name: String { file.url.lastPathComponent }
    var baseName: String { file.url.deletingPathExtension().lastPathComponent }
    var isRaw: Bool { file.isRaw }
    var state: PhotoState { PhotoState(flag: flag, rating: rating) }

    /// Size of every file that belongs to the photo (RAW + JPEG + sidecars).
    var totalBytes: Int64 {
        file.allFiles.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
