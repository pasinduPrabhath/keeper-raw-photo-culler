import AppKit
import SwiftUI

/// Developer tool: renders the app's own window to PNG files (no screen-recording permission needed).
/// Used to produce the README screenshots and to eyeball UI changes headlessly:
///
///   KEEPER_OPEN=./DemoShoot KEEPER_SNAPSHOT_DIR=./docs/screenshots dist/Keeper.app/Contents/MacOS/Keeper
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["KEEPER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(library: Library) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Wait for the folder to load and analysis to finish.
        let started = Date()
        for _ in 0 ..< 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !library.isEmpty, library.analysisTotal > 0, library.analysisDone >= library.analysisTotal { break }
        }
        print(String(format: "timing: %d photos opened + analysed in %.1f s", library.items.count, Date().timeIntervalSince(started)))
        print("folders: \(library.folders.count) → " + library.folders.map { "\($0.lastPathComponent)=\(library.folderCounts[$0] ?? 0)" }.joined(separator: ", ") + " · bursts=\(library.counts.bursts)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snap("1-grid", in: dir)

        library.autoCull()
        try? await Task.sleep(nanoseconds: 800_000_000)
        snap("2-after-autocull", in: dir)

        if let best = library.visible.first(where: { $0.isBestInBurst }) { library.select(best, .replace) }
        library.mode = .loupe
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        snap("3-loupe", in: dir)

        library.mode = .grid
        library.filter = .picks
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        snap("4-picks", in: dir)

        // Optional end-to-end check of the destructive path: trash every reject, then undo.
        // Only run it against a COPY of your photos.
        if ProcessInfo.processInfo.environment["KEEPER_SELFTEST_TRASH"] == "1", let folder = library.folder {
            func fileCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? -1 }
            library.filter = .all
            print("selftest: before   items=\(library.items.count) files=\(fileCount()) rejects=\(library.rejected.count)")
            library.confirmTrash(library.rejected)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("selftest: trashed  items=\(library.items.count) files=\(fileCount()) bursts=\(library.counts.bursts)")
            snap("5-after-trash", in: dir)
            library.undo()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("selftest: restored items=\(library.items.count) files=\(fileCount()) rejects=\(library.rejected.count)")
        }

        // Optional check that real mouse clicks on inspector buttons change state (KEEPER_SELFTEST_CLICK=1).
        if ProcessInfo.processInfo.environment["KEEPER_SELFTEST_CLICK"] == "1" {
            library.filter = .all
            if let first = library.visible.first { library.select(first, .replace) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for title in ["Reject", "Pick", "Pick"] {
                let before = library.activeItem?.flag.rawValue ?? "?"
                let found = click(buttonTitled: title)
                try? await Task.sleep(nanoseconds: 250_000_000)
                snap("click-\(title.lowercased())", in: dir)
                try? await Task.sleep(nanoseconds: 600_000_000)
                print("clicktest: \(title) found=\(found) flag \(before) -> \(library.activeItem?.flag.rawValue ?? "?")")
            }
        }

        // Optional check of pointer-anchored zoom: double-click off-centre in the loupe, expect the clicked spot to stay put.
        if ProcessInfo.processInfo.environment["KEEPER_SELFTEST_ZOOM"] == "1" {
            library.filter = .all
            if let item = library.visible.first(where: { $0.isBestInBurst }) ?? library.visible.first { library.select(item, .replace) }
            library.mode = .loupe
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let canvas = frames["canvas"], let window = NSApp.windows.first(where: { $0.isVisible }), let root = window.contentView {
                let target = CGPoint(x: canvas.minX + canvas.width * 0.74, y: canvas.minY + canvas.height * 0.62)
                let centre = CGPoint(x: canvas.midX, y: canvas.midY)
                library.resetZoom()
                try? await Task.sleep(nanoseconds: 400_000_000)
                print("zoomtest: before zoom=\(library.zoom) full=\(String(format: "%.2f", library.zoomFull))")
                snap("zoom-0-fit", in: dir)
                let point = NSPoint(x: target.x, y: root.bounds.height - target.y)
                for (n, type) in [(1, NSEvent.EventType.leftMouseDown), (1, .leftMouseUp), (2, .leftMouseDown), (2, .leftMouseUp)] {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) { NSApp.sendEvent(e) }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let a = CGSize(width: target.x - centre.x, height: target.y - centre.y)
                print(String(format: "zoomtest: after  zoom=%.2f pan=(%.0f, %.0f) anchor-offset=(%.0f, %.0f) expected pan≈(%.0f, %.0f) before clamping", library.zoom, library.pan.width, library.pan.height, a.width, a.height, a.width * (1 - library.zoom), a.height * (1 - library.zoom)))
                snap("zoom-1-100", in: dir)
            } else { print("zoomtest: no canvas frame") }
        }

        NSApp.terminate(nil)
    }

    /// Frames of tagged views (window coordinates, top-left origin), recorded only in snapshot/self-test mode.
    static var frames: [String: CGRect] = [:]

    /// Clicks the centre of a tagged view with real in-process mouse events, going through normal hit-testing.
    private static func click(buttonTitled title: String) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let root = window.contentView else { return "no window" }
        guard let frame = frames[title] else { return "no frame recorded" }
        let point = NSPoint(x: frame.midX, y: root.bounds.height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        return "yes at \(Int(point.x)),\(Int(point.y))"
    }

    private static func snap(_ name: String, in dir: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview ?? NSApp.windows.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            print("snapshot: \(name).png")
        }
    }
}

extension View {
    /// Dev-only: records this view's frame for `SnapshotRunner`'s click self-test.
    func snapshotFrame(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if SnapshotRunner.directory != nil { MainActor.assumeIsolated { SnapshotRunner.frames[name] = frame } }
        }
    }
}
