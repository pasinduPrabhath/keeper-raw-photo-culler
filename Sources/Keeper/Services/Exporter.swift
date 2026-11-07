import AppKit
import KeeperCore
import SwiftUI

/// Exports and shares JPEGs without a round-trip through an editor.
@MainActor @Observable
final class Exporter {
    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var failures: [String] = []
    private(set) var lastDestination: URL?

    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    func export(_ items: [PhotoItem], to folder: URL, options: ExportOptions) async {
        guard !isRunning else { return }
        isRunning = true; done = 0; total = items.count; failures = []; lastDestination = folder
        defer { isRunning = false }

        let jobs = items.map { (primary: $0.url, companion: $0.companion, base: $0.baseName) }
        let names = Self.uniqueNames(jobs.map(\.base), in: folder)

        await withTaskGroup(of: String?.self) { group in
            var iterator = jobs.indices.makeIterator()
            let limit = options.source == .developedRAW ? 2 : 4
            func add(_ i: Int, _ group: inout TaskGroup<String?>) {
                let job = jobs[i], destination = folder.appendingPathComponent(names[i])
                group.addTask(priority: .userInitiated) {
                    do { try JPEGExporter.export(primary: job.primary, companion: job.companion, to: destination, options: options); return nil }
                    catch { return job.primary.lastPathComponent }
                }
            }
            for _ in 0 ..< limit { if let i = iterator.next() { add(i, &group) } }
            for await failed in group {
                done += 1
                if let failed { failures.append(failed) }
                if let i = iterator.next() { add(i, &group) }
            }
        }
    }

    /// Writes 2048 px JPEGs to a temp folder and opens the system share sheet.
    static func share(_ items: [PhotoItem]) async -> [URL] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Keeper-Share", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let jobs = items.map { (primary: $0.url, companion: $0.companion, base: $0.baseName) }
        return await Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            for job in jobs {
                let destination = temp.appendingPathComponent(job.base + ".jpg")
                if (try? JPEGExporter.export(primary: job.primary, companion: job.companion, to: destination, options: ExportOptions(maxPixel: 2048))) != nil {
                    urls.append(destination)
                }
            }
            return urls
        }.value
    }

    static func showSharePicker(for urls: [URL]) {
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: view.bounds.maxX - 160, y: view.bounds.maxY - 4, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    static func copyImage(of item: PhotoItem) async -> Bool {
        let (primary, companion) = (item.url, item.companion)
        let image = await Task.detached { PreviewDecoder.image(primary: primary, companion: companion, maxPixel: 4096) }.value
        guard let image else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    private static func uniqueNames(_ bases: [String], in folder: URL) -> [String] {
        var used = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        return bases.map { base in
            var name = base + ".jpg", n = 2
            while used.contains(name) { name = "\(base)-\(n).jpg"; n += 1 }
            used.insert(name)
            return name
        }
    }
}
