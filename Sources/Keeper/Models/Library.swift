import AppKit
import KeeperCore
import SwiftUI

/// A burst (≥2 frames) or a run of single shots, as laid out in the grid.
struct GridSection: Identifiable {
    let id: String
    let burstID: Int?
    var items: [PhotoItem]
    let totalCount: Int
    var isBurst: Bool { burstID != nil }
}

struct LibraryCounts {
    var all = 0, picks = 0, rejects = 0, unflagged = 0, best = 0, bursts = 0
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Photos", picks = "Picks", unflagged = "Unflagged", rejects = "Rejected", best = "Best of Bursts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "photo.stack"
        case .picks: "flag.fill"
        case .unflagged: "circle.dashed"
        case .rejects: "xmark.circle"
        case .best: "sparkles"
        }
    }
}

enum SelectMode { case replace, toggle, extend }

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var symbol = "checkmark.circle.fill"
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

/// Drives the big ✓ / ✗ stamp that pops over the photo when you flag it.
struct FlagFlash: Equatable {
    let id = UUID()
    let flag: Flag
}

enum UndoEntry {
    case state([(item: PhotoItem, flag: Flag, rating: Int)])
    case trash(items: [PhotoItem], moves: [(original: URL, trashed: URL)])
}

@MainActor @Observable
final class Library {
    enum Mode { case grid, loupe }
    enum Phase: Equatable { case idle, scanning(done: Int, total: Int) }

    // MARK: Source
    private(set) var folders: [URL] = []
    var folder: URL? { folders.first }
    private(set) var folderCounts: [URL: Int] = [:]
    private(set) var items: [PhotoItem] = []
    var includeSubfolders: Bool = UserDefaults.standard.bool(forKey: "includeSubfolders") {
        didSet { UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders") }
    }
    private(set) var phase: Phase = .idle
    private(set) var analysisDone = 0
    private(set) var analysisTotal = 0

    // MARK: View state
    var mode: Mode = .grid
    var filter: LibraryFilter = .all { didSet { if oldValue != filter { refresh() } } }
    var thumbSize: Double = 210
    var showInspector = true
    var gridColumns = 4
    var collapsedBursts: Set<Int> = []
    var burstGap: Double = UserDefaults.standard.object(forKey: "burstGap") as? Double ?? 1.0 {
        didSet { if oldValue != burstGap { UserDefaults.standard.set(burstGap, forKey: "burstGap"); rebuildBursts(); refresh() } }
    }
    // Loupe zoom: `zoom` is relative to "fit" (1 = whole photo visible); `zoomFull` is the zoom that shows 1 image pixel per screen pixel.
    private(set) var zoom = 1.0
    var pan: CGSize = .zero
    var zoomFull = 1.0
    var zoomed: Bool { zoom > 1.01 }
    var maxZoom: Double { max(3, zoomFull * 2) }

    func resetZoom() { zoom = 1; pan = .zero }
    func zoomIn() { applyZoom(zoom * 1.4) }
    func zoomOut() { applyZoom(zoom / 1.4) }
    /// 1 = 100% (one image pixel per screen pixel), 2 = 200%.
    func zoomTo(actualPixels factor: Double) { applyZoom(zoomFull * factor) }
    func toggleZoom() { if zoomed { resetZoom() } else { zoomTo(actualPixels: 1) } }

    func applyZoom(_ requested: Double, anchor: CGSize = .zero) {
        let z = min(max(requested, 1), maxZoom)
        let f = z / zoom
        pan = CGSize(width: (pan.width - anchor.width) * f + anchor.width, height: (pan.height - anchor.height) * f + anchor.height)
        zoom = z
        if z <= 1.01 { zoom = 1; pan = .zero }
    }

    // MARK: Selection
    var selection: Set<String> = []
    var activeID: String?
    private var anchorID: String?

    // MARK: Derived (rebuilt by refresh())
    private(set) var sections: [GridSection] = []
    private(set) var visible: [PhotoItem] = []
    /// Show the most recently shot photos first (bursts stay together).
    var newestFirst: Bool = UserDefaults.standard.bool(forKey: "newestFirst") {
        didSet { UserDefaults.standard.set(newestFirst, forKey: "newestFirst"); refresh() }
    }
    private(set) var counts = LibraryCounts()
    private var burstMembers: [Int: [PhotoItem]] = [:]
    private var byID: [String: PhotoItem] = [:]

    // MARK: Transient UI
    var pendingTrash: [PhotoItem]?
    var toast: Toast?
    var errorMessage: String?
    var isPresenting = false
    private(set) var presentIDs: [String] = []
    var presentIndex = 0
    private(set) var undoStack: [UndoEntry] = []
    private(set) var flash: FlagFlash?
    private var flashTask: Task<Void, Never>?

    private var scanTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    var canUndo: Bool { !undoStack.isEmpty }
    var activeItem: PhotoItem? { activeID.flatMap { byID[$0] } }
    var selectedItems: [PhotoItem] { visible.filter { selection.contains($0.id) } }
    var rejected: [PhotoItem] { items.filter { $0.flag == .reject } }
    var hasFolder: Bool { !folders.isEmpty }
    var title: String {
        switch folders.count {
        case 0: "Keeper"
        case 1: folders[0].lastPathComponent
        default: "\(folders.count) folders"
        }
    }
    var isEmpty: Bool { items.isEmpty }

    /// What an action applies to: the selection, or the active photo when nothing is selected.
    var targets: [PhotoItem] {
        let chosen = selectedItems
        if !chosen.isEmpty { return chosen }
        return activeItem.map { [$0] } ?? []
    }

    var subtitle: String {
        guard hasFolder else { return "" }
        return "\(counts.all) photos · \(counts.bursts) bursts"
    }

    // MARK: - Opening

    func chooseFolder(add: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = add ? "Add" : "Open"
        panel.message = add ? "Choose more folders to add to this library."
                            : "Choose one or more folders of photos (hold ⌘ to pick several), or a single photo to open its folder."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if add { addFolders(panel.urls) } else { openExternal(urls: panel.urls) }
    }

    /// Opens folders, or the folders that contain the given files (focusing the first file).
    func openExternal(urls: [URL]) {
        var dirs: [URL] = [], focus: URL?
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { dirs.append(url) } else { dirs.append(url.deletingLastPathComponent()); focus = focus ?? url }
        }
        if !dirs.isEmpty { open(folders: dirs, focus: focus) }
    }

    func openExternal(_ url: URL) { openExternal(urls: [url]) }

    /// Adds folders to what's already open (e.g. a second memory card).
    func addFolders(_ urls: [URL]) {
        guard hasFolder else { return openExternal(urls: urls) }
        open(folders: folders + urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    func removeFolder(_ url: URL) {
        let remaining = folders.filter { $0 != url }
        if remaining.isEmpty { closeAll() } else { open(folders: remaining) }
    }

    func closeAll() {
        scanTask?.cancel(); analysisTask?.cancel()
        folders = []; items = []; byID = [:]; burstMembers = [:]; selection = []; activeID = nil
        phase = .idle; analysisDone = 0; analysisTotal = 0
        refresh()
    }

    func open(_ folder: URL, focus: URL? = nil) { open(folders: [folder], focus: focus) }

    func open(folders requested: [URL], focus: URL? = nil) {
        var seen = Set<String>()
        let roots = requested.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        guard !roots.isEmpty else { return }
        scanTask?.cancel(); analysisTask?.cancel()
        folders = roots
        roots.reversed().forEach(RecentFolders.add)
        RecentFolders.saveSession(roots)
        items = []; selection = []; activeID = nil; anchorID = nil
        undoStack = []; collapsedBursts = []; mode = .grid; resetZoom()
        refresh()
        phase = .scanning(done: 0, total: 0)

        let recursive = includeSubfolders
        scanTask = Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> [(root: URL, file: ScannedFile)] in
                var seenPaths = Set<String>()
                var out: [(root: URL, file: ScannedFile)] = []
                for root in roots {
                    for file in FolderScanner.scan(root, recursive: recursive) where seenPaths.insert(file.url.path).inserted {
                        out.append((root, file))
                    }
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            let files = scanned.map(\.file)
            phase = .scanning(done: 0, total: files.count)

            var metas = [PhotoMetadata?](repeating: nil, count: files.count)
            await withTaskGroup(of: (Int, PhotoMetadata).self) { group in
                var next = files.indices.makeIterator()
                for _ in 0 ..< max(2, ProcessInfo.processInfo.activeProcessorCount) {
                    if let i = next.next() { let f = files[i]; group.addTask(priority: .userInitiated) { (i, MetadataReader.read(f.url, fallbackDate: f.modified)) } }
                }
                var done = 0
                for await (i, meta) in group {
                    metas[i] = meta
                    done += 1
                    if done % 20 == 0 { phase = .scanning(done: done, total: files.count) }
                    if let j = next.next() { let f = files[j]; group.addTask(priority: .userInitiated) { (j, MetadataReader.read(f.url, fallbackDate: f.modified)) } }
                }
            }
            guard !Task.isCancelled else { return }

            var saved: [URL: [String: PhotoState]] = [:]
            for root in roots { saved[root] = StateStore.load(folder: root) }
            let built: [PhotoItem] = scanned.enumerated().map { i, entry in
                let item = PhotoItem(file: entry.file, meta: metas[i] ?? PhotoMetadata(captureDate: entry.file.modified), root: entry.root)
                if let s = saved[entry.root]?[Self.stateKey(entry.file.url, in: entry.root)] { item.flag = s.flag; item.rating = s.rating }
                return item
            }
            items = built.sorted {
                $0.meta.captureDate != $1.meta.captureDate ? $0.meta.captureDate < $1.meta.captureDate
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            phase = .idle
            rebuildBursts()
            refresh()
            if let focus, let hit = byID[focus.path] { select(hit, .replace) }
            else if let first = visible.first { select(first, .replace) }
            startAnalysis()
        }
    }

    private static func stateKey(_ url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: - Bursts & analysis

    func rebuildBursts() {
        let ids = BurstGrouper.assign(dates: items.map { $0.meta.captureDate }, maxGap: burstGap)
        for (i, id) in ids.enumerated() { items[i].burstID = id }
        burstMembers = Dictionary(grouping: items, by: \.burstID)
        for members in burstMembers.values { updateBest(in: members) }
    }

    private func updateBest(in members: [PhotoItem]) {
        guard members.count > 1, members.allSatisfy({ $0.sharpness != nil }) else {
            members.forEach { $0.isBestInBurst = false }
            return
        }
        let best = members.max { ($0.sharpness ?? 0) < ($1.sharpness ?? 0) }
        for m in members { m.isBestInBurst = (m === best) }
    }

    func burst(of item: PhotoItem) -> [PhotoItem] { burstMembers[item.burstID] ?? [item] }

    private func startAnalysis() {
        analysisTask?.cancel()
        let work = items.map { (id: $0.id, file: $0.file) }
        analysisTotal = work.count
        analysisDone = 0
        analysisTask = Task {
            let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
            await withTaskGroup(of: (String, Double?).self) { group in
                func job(_ w: (id: String, file: ScannedFile)) -> @Sendable () async -> (String, Double?) {
                    { (w.id, await ThumbnailService.shared.analysis(primary: w.file.url, companion: w.file.companion, size: w.file.fileSize,
                                                                     modified: w.file.modified, priority: .utility)?.sharpness) }
                }
                var next = work.makeIterator()
                for _ in 0 ..< limit { if let w = next.next() { let j = job(w); group.addTask { await j() } } }
                var sinceRefresh = 0
                for await (id, score) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let item = byID[id], let score { applySharpness(score, to: item) }
                    analysisDone += 1
                    sinceRefresh += 1
                    if filter == .best, sinceRefresh >= 60 { refresh(); sinceRefresh = 0 }
                    if let w = next.next() { let j = job(w); group.addTask { await j() } }
                }
            }
            if !Task.isCancelled { refresh() }
        }
    }

    private func applySharpness(_ score: Double, to item: PhotoItem) {
        guard item.sharpness == nil else { return }
        item.sharpness = score
        updateBest(in: burst(of: item))
    }

    /// Thumbnail for a grid cell. Requests from visible cells jump the background queue.
    func thumbnail(for item: PhotoItem) async -> CGImage? {
        let f = item.file
        let result = await ThumbnailService.shared.analysis(primary: f.url, companion: f.companion, size: f.fileSize, modified: f.modified)
        if let result { applySharpness(result.sharpness, to: item) }
        return result?.thumbnail
    }

    // MARK: - Filtering / layout

    func refresh() {
        func matches(_ item: PhotoItem) -> Bool {
            switch filter {
            case .all: true
            case .picks: item.flag == .pick
            case .unflagged: item.flag == .none
            case .rejects: item.flag == .reject
            case .best: item.isBestInBurst || (burstMembers[item.burstID]?.count ?? 1) < 2
            }
        }

        var c = LibraryCounts()
        c.all = items.count
        for item in items {
            switch item.flag { case .pick: c.picks += 1; case .reject: c.rejects += 1; case .none: c.unflagged += 1 }
            if item.isBestInBurst || (burstMembers[item.burstID]?.count ?? 1) < 2 { c.best += 1 }
        }
        c.bursts = burstMembers.values.filter { $0.count > 1 }.count
        counts = c
        folderCounts = Dictionary(grouping: items, by: \.root).mapValues(\.count)

        var result: [GridSection] = []
        var singles: [PhotoItem] = []
        func flushSingles() {
            guard let first = singles.first else { return }
            result.append(GridSection(id: "s-\(first.id)", burstID: nil, items: singles, totalCount: singles.count))
            singles = []
        }
        var run: [PhotoItem] = []
        func flushRun() {
            guard let first = run.first else { return }
            defer { run = [] }
            let size = burstMembers[first.burstID]?.count ?? 1
            if size < 2 { singles += run; return }
            flushSingles()
            let collapsed = collapsedBursts.contains(first.burstID)
            let shown = collapsed ? [run.first(where: \.isBestInBurst) ?? run[0]] : run
            result.append(GridSection(id: "b-\(first.burstID)", burstID: first.burstID, items: shown, totalCount: run.count))
        }
        for item in (newestFirst ? Array(items.reversed()) : items) where matches(item) {
            if let last = run.last, last.burstID != item.burstID { flushRun() }
            run.append(item)
        }
        flushRun()
        flushSingles()

        sections = result
        visible = result.flatMap(\.items)

        let ids = Set(visible.map(\.id))
        selection.formIntersection(ids)
        if activeID == nil || !ids.contains(activeID!) { activeID = visible.first?.id; anchorID = activeID }
    }

    func toggleCollapse(_ burstID: Int) {
        if collapsedBursts.contains(burstID) { collapsedBursts.remove(burstID) } else { collapsedBursts.insert(burstID) }
        refresh()
    }

    // MARK: - Selection & navigation

    func select(_ item: PhotoItem, _ mode: SelectMode = .replace) {
        switch mode {
        case .replace:
            selection = [item.id]; anchorID = item.id
        case .toggle:
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        case .extend:
            let a = anchorID.flatMap { id in visible.firstIndex { $0.id == id } } ?? visible.firstIndex { $0.id == activeID } ?? 0
            let b = visible.firstIndex { $0.id == item.id } ?? a
            selection = Set(visible[min(a, b) ... max(a, b)].map(\.id))
        }
        activeID = item.id
        resetZoom()
    }

    func selectAll() { selection = Set(visible.map(\.id)) }
    func clearSelection() { selection = activeID.map { [$0] } ?? [] }

    func move(_ delta: Int, extend: Bool = false) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == activeID } ?? 0
        let target = min(max(current + delta, 0), visible.count - 1)
        select(visible[target], extend ? .extend : .replace)
    }

    func moveVertical(_ rows: Int, extend: Bool = false) {
        guard let id = activeID, let s = sections.firstIndex(where: { $0.items.contains { $0.id == id } }),
              let i = sections[s].items.firstIndex(where: { $0.id == id }) else { return move(rows * gridColumns, extend: extend) }
        let cols = max(1, gridColumns)
        let section = sections[s]
        let row = i / cols, col = i % cols, lastRow = (section.items.count - 1) / cols
        var target: PhotoItem?
        if rows > 0 {
            if row < lastRow { target = section.items[min(i + cols, section.items.count - 1)] }
            else if s + 1 < sections.count { let n = sections[s + 1].items; target = n[min(col, n.count - 1)] }
        } else {
            if row > 0 { target = section.items[i - cols] }
            else if s > 0 { let p = sections[s - 1].items; target = p[min(((p.count - 1) / cols) * cols + col, p.count - 1)] }
        }
        if let target { select(target, extend ? .extend : .replace) }
    }

    /// Jump to the first frame of the next (or previous) burst.
    func jumpBurst(_ direction: Int) {
        guard let current = activeItem else { return }
        var index = visible.firstIndex { $0.id == current.id } ?? 0
        while visible.indices.contains(index + direction) {
            index += direction
            if visible[index].burstID != current.burstID {
                var start = index
                if direction < 0 { while start > 0, visible[start - 1].burstID == visible[index].burstID { start -= 1 } }
                select(visible[start], .replace)
                return
            }
        }
    }

    // MARK: - Culling

    func setFlag(_ flag: Flag, on targets: [PhotoItem]? = nil, advance: Bool = true) {
        let chosen = targets ?? self.targets
        guard !chosen.isEmpty else { return }
        let value: Flag = chosen.allSatisfy { $0.flag == flag } ? .none : flag
        let single = chosen.count == 1
        record(chosen) { $0.flag = value }
        showFlash(value)
        if value == .reject {
            let shown = UserDefaults.standard.integer(forKey: "rejectHintCount")
            if shown < 3 {
                UserDefaults.standard.set(shown + 1, forKey: "rejectHintCount")
                showToast("Marked as reject. Nothing is deleted until you click the trash button.", symbol: "xmark.circle.fill",
                          actionTitle: "Undo") { [weak self] in self?.undo() }
            }
        }
        let autoAdvance = UserDefaults.standard.object(forKey: "autoAdvance") as? Bool ?? true
        if advance, autoAdvance, single, value != .none, filter == .all { move(1) }
    }

    func setRating(_ rating: Int, on targets: [PhotoItem]? = nil) {
        let chosen = targets ?? self.targets
        guard !chosen.isEmpty else { return }
        let value = chosen.allSatisfy { $0.rating == rating } ? 0 : rating
        record(chosen) { $0.rating = value }
    }

    private func showFlash(_ flag: Flag) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        flash = FlagFlash(flag: flag)
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            flash = nil
        }
    }

    private func record(_ chosen: [PhotoItem], _ mutate: (PhotoItem) -> Void) {
        undoStack.append(.state(chosen.map { ($0, $0.flag, $0.rating) }))
        chosen.forEach(mutate)
        stateChanged(chosen)
    }

    /// Keep the sharpest frame of a burst, reject the rest (frames you already flagged are left alone).
    @discardableResult
    func keepBest(inBurst id: Int, record shouldRecord: Bool = true) -> Int {
        guard let members = burstMembers[id], members.count > 1,
              let best = members.first(where: \.isBestInBurst) else { return 0 }
        let changed = members.filter { $0 !== best && $0.flag == .none } + (best.flag == .none ? [best] : [])
        guard !changed.isEmpty else { return 0 }
        if shouldRecord { undoStack.append(.state(changed.map { ($0, $0.flag, $0.rating) })) }
        for m in changed { m.flag = (m === best) ? .pick : .reject }
        if shouldRecord { stateChanged(changed) }
        return changed.count - (changed.contains { $0 === best } ? 1 : 0)
    }

    /// The headline feature: in every burst, pick the sharpest frame and reject the others.
    func autoCull() {
        guard analysisDone >= analysisTotal || analysisTotal == 0 else {
            showToast("Still analysing sharpness (\(analysisDone)/\(analysisTotal)). Try again in a moment.", symbol: "hourglass")
            return
        }
        var all: [(item: PhotoItem, flag: Flag, rating: Int)] = []
        var rejectedCount = 0, burstCount = 0
        for (id, members) in burstMembers where members.count > 1 {
            let before = members.map { ($0, $0.flag, $0.rating) }
            let n = keepBest(inBurst: id, record: false)
            if n > 0 { rejectedCount += n; burstCount += 1; all += before }
        }
        guard burstCount > 0 else { showToast("Nothing to cull. Every burst already has your flags.", symbol: "checkmark.circle"); return }
        undoStack.append(.state(all))
        stateChanged(all.map(\.item))
        showToast("Kept the best of \(burstCount) bursts · \(rejectedCount) marked as rejects", symbol: "sparkles",
                  actionTitle: "Undo") { [weak self] in self?.undo() }
    }

    private func stateChanged(_ changed: [PhotoItem]) {
        refresh()
        scheduleSave()
        if UserDefaults.standard.bool(forKey: "writeXMP") {
            let snapshot = changed.map { ($0.url, $0.flag, $0.rating) }
            Task.detached(priority: .utility) {
                for (url, flag, rating) in snapshot {
                    try? XMPSidecar.write(for: url, rating: flag == .reject ? -1 : rating, label: flag == .pick ? "Green" : nil)
                }
            }
        }
    }

    private func scheduleSave() {
        guard hasFolder else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            var payload: [URL: [String: PhotoState]] = [:]
            for root in folders { payload[root] = [:] }
            for item in items where !item.state.isDefault { payload[item.root, default: [:]][Self.stateKey(item.url, in: item.root)] = item.state }
            let snapshot = payload
            await Task.detached(priority: .utility) { for (root, states) in snapshot { StateStore.save(states, folder: root) } }.value
        }
    }

    // MARK: - Trash & undo

    func requestTrashSelection() {
        let chosen = targets
        guard !chosen.isEmpty else { return }
        pendingTrash = chosen
    }

    func requestTrashRejects() {
        let chosen = rejected
        guard !chosen.isEmpty else { return }
        pendingTrash = chosen
    }

    func confirmTrash(_ chosen: [PhotoItem]) {
        pendingTrash = nil
        Task { await trash(chosen) }
    }

    private func trash(_ chosen: [PhotoItem]) async {
        let nextFocus = nextSurvivor(afterRemoving: chosen)
        let files = chosen.flatMap { $0.file.allFiles }
        let outcome = await Task.detached(priority: .userInitiated) { () -> (moves: [(URL, URL)], failed: [URL]) in
            var moves: [(URL, URL)] = [], failed: [URL] = []
            for url in files {
                var result: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                    if let result { moves.append((url, result as URL)) }
                } catch { failed.append(url) }
            }
            return (moves, failed)
        }.value

        let movedPaths = Set(outcome.moves.map { $0.0.path })
        let removed = chosen.filter { movedPaths.contains($0.url.path) }
        guard !removed.isEmpty else {
            errorMessage = "Couldn't move the files to the Trash. Check that you have permission for this folder."
            return
        }
        let gone = Set(removed.map(\.id))
        items.removeAll { gone.contains($0.id) }
        byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        rebuildBursts()
        refresh()
        if let nextFocus, let item = byID[nextFocus] { select(item, .replace) }
        scheduleSave()

        undoStack.append(.trash(items: removed, moves: outcome.moves.map { (original: $0.0, trashed: $0.1) }))
        let note = outcome.failed.isEmpty ? "" : " (\(outcome.failed.count) files couldn't be moved)"
        showToast("Moved \(removed.count) photo\(removed.count == 1 ? "" : "s") to the Trash\(note)", symbol: "trash.fill",
                  actionTitle: "Undo") { [weak self] in self?.undo() }
    }

    private func nextSurvivor(afterRemoving removing: [PhotoItem]) -> String? {
        let gone = Set(removing.map(\.id))
        guard let start = visible.firstIndex(where: { $0.id == activeID }) else { return visible.first { !gone.contains($0.id) }?.id }
        return visible[start...].first { !gone.contains($0.id) }?.id ?? visible[..<start].last { !gone.contains($0.id) }?.id
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        switch entry {
        case .state(let before):
            for (item, flag, rating) in before { item.flag = flag; item.rating = rating }
            stateChanged(before.map(\.item))
            showToast("Undid flag change", symbol: "arrow.uturn.backward")
        case .trash(let removed, let moves):
            var restored = 0
            for move in moves {
                do { try FileManager.default.moveItem(at: move.trashed, to: move.original); restored += 1 } catch {}
            }
            items.append(contentsOf: removed)
            items.sort {
                $0.meta.captureDate != $1.meta.captureDate ? $0.meta.captureDate < $1.meta.captureDate
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            rebuildBursts()
            refresh()
            if let first = removed.first { select(first, .replace) }
            showToast("Restored \(removed.count) photo\(removed.count == 1 ? "" : "s")", symbol: "arrow.uturn.backward")
        }
    }

    // MARK: - Presentation

    func startPresentation() {
        let chosen = selectedItems
        let pool = chosen.count > 1 ? chosen : visible
        guard !pool.isEmpty else { return }
        presentIDs = pool.map(\.id)
        presentIndex = max(0, presentIDs.firstIndex(of: activeID ?? "") ?? 0)
        withAnimation(.easeInOut(duration: 0.25)) { isPresenting = true }
        setFullScreen(true)
    }

    func endPresentation() {
        if let id = presentIDs[safe: presentIndex], let item = byID[id], visible.contains(where: { $0.id == id }) { select(item, .replace) }
        withAnimation(.easeInOut(duration: 0.2)) { isPresenting = false }
        setFullScreen(false)
    }

    func presentMove(_ delta: Int) {
        guard !presentIDs.isEmpty else { return }
        presentIndex = (presentIndex + delta + presentIDs.count) % presentIDs.count
    }

    var presentItem: PhotoItem? { presentIDs[safe: presentIndex].flatMap { byID[$0] } }
    func item(id: String) -> PhotoItem? { byID[id] }

    private var enteredFullScreenForPresentation = false
    private func setFullScreen(_ on: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on, !isFull { enteredFullScreenForPresentation = true; window.toggleFullScreen(nil) }
        else if !on, isFull, enteredFullScreenForPresentation { enteredFullScreenForPresentation = false; window.toggleFullScreen(nil) }
    }

    // MARK: - Toasts

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill", actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        toast = Toast(message: message, symbol: symbol, actionTitle: actionTitle, action: action)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.spring) { toast = nil }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum RecentFolders {
    private static let key = "recentFolders"
    private static let sessionKey = "lastSessionFolders"

    /// The folders open when the app was last used, so a multi-folder library can be reopened in one click.
    static var session: [URL] {
        (UserDefaults.standard.stringArray(forKey: sessionKey) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func saveSession(_ urls: [URL]) { UserDefaults.standard.set(urls.map(\.path), forKey: sessionKey) }

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func add(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

