import AppKit
import KeeperCore
import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(DriveController.self) private var drive
    @Environment(UpdateService.self) private var updates
    @State private var showUpload = false
    @State private var showExport = false
    @State private var sidebar: NavigationSplitViewVisibility = .all
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var lib = library

        ZStack {
            NavigationSplitView(columnVisibility: $sidebar) {
                SidebarView(showUpload: $showUpload)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            } detail: {
                detail
            }
            .navigationTitle(lib.title)
            .navigationSubtitle(lib.subtitle)
            .toolbar(lib.isPresenting ? .hidden : .automatic, for: .windowToolbar)

            if lib.isPresenting {
                PresentationView().transition(.opacity).zIndex(10)
            }
        }
        .background(Theme.bg)
        .onChange(of: lib.isPresenting) { _, presenting in if !presenting { focused = true } }
        .onChange(of: showUpload) { _, _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
        .onChange(of: showExport) { _, _ in focused = true }
        .sheet(isPresented: $showUpload) { DriveUploadSheet() }
        .sheet(isPresented: $showExport) { ExportSheet() }
        .confirmationDialog(trashTitle(lib.pendingTrash ?? []),
                            isPresented: Binding(get: { lib.pendingTrash != nil }, set: { if !$0 { lib.pendingTrash = nil } }),
                            titleVisibility: .visible, presenting: lib.pendingTrash) { items in
            Button("Move to Trash", role: .destructive) { lib.confirmTrash(items) }
            Button("Cancel", role: .cancel) { lib.pendingTrash = nil }
        } message: { items in
            let bytes = items.reduce(Int64(0)) { $0 + $1.totalBytes }
            Text("\(bytes.fileSizeText) including RAW, JPEG and sidecar files. You can undo this with ⌘Z.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .keeperUpdateResult)) { _ in
            switch updates.state {
            case .upToDate: lib.showToast("Keeper \(updates.currentVersion) is the latest version", symbol: "checkmark.circle.fill")
            case .failed(let m): lib.showToast(m, symbol: "wifi.slash")
            default: break
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { lib.errorMessage != nil }, set: { if !$0 { lib.errorMessage = nil } })) {
            Button("OK") { lib.errorMessage = nil }
        } message: { Text(lib.errorMessage ?? "") }
        .task {
            focused = true
            Task { await updates.checkOnLaunch() }
            let env = ProcessInfo.processInfo.environment
            if let paths = env["KEEPER_OPEN"] { library.openExternal(urls: paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
            else if !library.hasFolder {
                // Pick up where the last session left off.
                var isDir: ObjCBool = false
                let last = RecentFolders.session.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
                if !last.isEmpty { library.open(folders: last) }
            }
            if SnapshotRunner.directory != nil { await SnapshotRunner.run(library: library) }
        }
        .background(MenuBridge(showUpload: $showUpload, showExport: $showExport))
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        @Bindable var lib = library
        ZStack(alignment: .bottom) {
            Theme.bg
            if lib.isEmpty { EmptyStateView() }
            else if lib.mode == .grid { GridView().transition(.opacity) }
            else { LoupeView().transition(.opacity) }

            if let flash = lib.flash {
                FlagFlashView(flash: flash).id(flash.id).frame(maxHeight: .infinity, alignment: .center)
            }

            VStack(spacing: 10) {
                HStack(alignment: .bottom) {
                    if lib.analysisDone < lib.analysisTotal {
                        Pill {
                            ProgressView().controlSize(.mini)
                            Text("Analysing sharpness  \(lib.analysisDone)/\(lib.analysisTotal)").monospacedDigit()
                        }
                        .transition(.opacity)
                    }
                    Spacer()
                    if lib.mode == .grid, !lib.isEmpty { shortcutHints }
                }
                if let release = updates.banner {
                    UpdateBanner(release: release).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toast = lib.toast { ToastView(toast: toast).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(16)
            .animation(Theme.spring, value: lib.toast?.id)
            .animation(Theme.quick, value: lib.analysisDone < lib.analysisTotal)
        }
        .animation(Theme.quick, value: lib.mode)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            // Dropping onto an open library adds folders; dropping onto the empty screen opens them.
            if lib.hasFolder && !lib.isEmpty { lib.addFolders(urls) } else { lib.openExternal(urls: urls) }
            return true
        }
        .inspector(isPresented: $lib.showInspector) {
            InspectorView(showUpload: $showUpload, showExport: $showExport)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
        }
        .toolbar { toolbarContent }
    }

    private var shortcutHints: some View {
        HStack(spacing: 10) {
            hint("P", "Pick"); hint("X", "Reject"); hint("1–5", "Stars"); hint("⌫", "Trash"); hint("Space", "Loupe")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) { KeyCap(text: key); Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        @Bindable var lib = library
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $lib.mode) {
                Label("Grid", systemImage: "square.grid.3x3.fill").tag(Library.Mode.grid)
                Label("Loupe", systemImage: "photo.fill").tag(Library.Mode.loupe)
            }
            .pickerStyle(.segmented)
            .disabled(lib.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if lib.mode == .grid {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Slider(value: $lib.thumbSize, in: 130 ... 340).frame(width: 96).controlSize(.small)
                    Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .disabled(lib.isEmpty)
            }

            Menu {
                Picker("Sort", selection: $lib.newestFirst) {
                    Label("Newest first", systemImage: "arrow.down").tag(true)
                    Label("Oldest first", systemImage: "arrow.up").tag(false)
                }
                .pickerStyle(.inline)
            } label: { Label(lib.newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down") }
            .help("Sort order")
            .disabled(lib.isEmpty)

            Button { lib.autoCull() } label: { Label("Auto-cull bursts", systemImage: "sparkles") }
                .help("In every burst, pick the sharpest frame and reject the rest (undoable)")
                .disabled(lib.counts.bursts == 0)

            Button { lib.requestTrashRejects() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    if lib.counts.rejects > 0 { Text("\(lib.counts.rejects)").font(.system(size: 12, weight: .semibold).monospacedDigit()) }
                }
            }
            .help("Move all rejected photos to the Trash")
            .disabled(lib.counts.rejects == 0)

            Button { lib.startPresentation() } label: { Label("Present", systemImage: "play.rectangle.fill") }
                .help("Full-screen slideshow (⌘↩)")
                .disabled(lib.isEmpty)

            Menu {
                Button("Export JPEGs…", systemImage: "square.and.arrow.up") { showExport = true }
                Button("Share…", systemImage: "square.and.arrow.up.on.square") { share() }
                Button("Copy Image", systemImage: "doc.on.doc") { copyImage() }
                Divider()
                Button("Upload to Google Drive…", systemImage: "icloud.and.arrow.up") { showUpload = true }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .disabled(lib.isEmpty)

            Button { withAnimation(Theme.spring) { lib.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
    }

    // MARK: - Actions

    private func share() {
        let items = library.targets
        Task { Exporter.showSharePicker(for: await Exporter.share(items)) }
    }

    private func copyImage() {
        guard let item = library.activeItem else { return }
        Task { if await Exporter.copyImage(of: item) { library.showToast("Image copied", symbol: "doc.on.doc.fill") } }
    }

    private func trashTitle(_ items: [PhotoItem]) -> String {
        "Move \(items.count) photo\(items.count == 1 ? "" : "s") to the Trash?"
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let lib = library
        guard lib.hasFolder, !lib.isEmpty, !lib.isPresenting else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        let chars = press.characters.lowercased()

        if command {
            switch (press.key, chars) {
            case (_, "a"): lib.selectAll()
            case (_, "z"): lib.undo()
            case (_, "c"): copyImage()
            case (.delete, _), (.deleteForward, _): lib.requestTrashSelection()
            default: return .ignored
            }
            return .handled
        }

        switch press.key {
        case .leftArrow: lib.move(-1, extend: shift)
        case .rightArrow: lib.move(1, extend: shift)
        case .upArrow: lib.mode == .grid ? lib.moveVertical(-1, extend: shift) : lib.move(-1, extend: shift)
        case .downArrow: lib.mode == .grid ? lib.moveVertical(1, extend: shift) : lib.move(1, extend: shift)
        case .space, .return: withAnimation(Theme.quick) { lib.mode = lib.mode == .grid ? .loupe : .grid }
        case .escape:
            if lib.zoomed { lib.resetZoom() }
            else if lib.mode == .loupe { lib.mode = .grid }
            else { lib.clearSelection() }
        case .delete, .deleteForward: lib.requestTrashSelection()
        default:
            switch chars {
            case "p": lib.setFlag(.pick)
            case "x": lib.setFlag(.reject)
            case "u": lib.setFlag(.none)
            case "0", "1", "2", "3", "4", "5": lib.setRating(Int(chars) ?? 0)
            case "g": lib.mode = .grid
            case "e": lib.mode = .loupe
            case "z": if lib.mode == .loupe { withAnimation(Theme.spring) { lib.toggleZoom() } }
            case "+", "=": if lib.mode == .loupe { withAnimation(Theme.quick) { lib.zoomIn() } }
            case "-", "_": if lib.mode == .loupe { withAnimation(Theme.quick) { lib.zoomOut() } }
            case "i": withAnimation(Theme.spring) { lib.showInspector.toggle() }
            case "b": if let item = lib.activeItem { withAnimation(Theme.spring) { lib.toggleCollapse(item.burstID) } }
            case "k":
                if let item = lib.activeItem {
                    let n = lib.keepBest(inBurst: item.burstID)
                    if n > 0 { lib.showToast("Kept the sharpest frame · \(n) rejected", symbol: "sparkles", actionTitle: "Undo") { lib.undo() } }
                }
            case "[": lib.jumpBurst(-1)
            case "]": lib.jumpBurst(1)
            default: return .ignored
            }
        }
        return .handled
    }
}

/// Lets menu-bar commands trigger window-owned sheets.
struct MenuBridge: View {
    @Binding var showUpload: Bool
    @Binding var showExport: Bool
    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .keeperShowUpload)) { _ in showUpload = true }
            .onReceive(NotificationCenter.default.publisher(for: .keeperShowExport)) { _ in showExport = true }
    }
}

extension Notification.Name {
    static let keeperShowUpload = Notification.Name("keeper.showUpload")
    static let keeperShowExport = Notification.Name("keeper.showExport")
    static let keeperUpdateResult = Notification.Name("keeper.updateResult")
}

struct UpdateBanner: View {
    @Environment(UpdateService.self) private var updates
    let release: UpdateService.Release
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            Text("Keeper \(release.version) is available").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            if updates.state == .downloading {
                ProgressView().controlSize(.small)
            } else {
                Button("Install & Restart") { Task { await updates.install(release) } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Button("What's new") { NSWorkspace.shared.open(release.notesURL) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Button { updates.dismissBanner() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.strokeStrong))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
