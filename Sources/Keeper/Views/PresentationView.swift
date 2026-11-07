import AppKit
import KeeperCore
import SwiftUI

/// Full-screen slideshow for showing RAW captures to other people: no editing, no exporting.
struct PresentationView: View {
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var showHUD = true
    @State private var hudTask: Task<Void, Never>?
    @State private var autoplay = false
    @State private var showInfo = true

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let targetPixels = 3840

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                image.swiftUIImage.resizable().interpolation(.high).scaledToFit()
                    .transition(.opacity)
            }
            if let item = lib.presentItem { hud(item) }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { lib.presentMove(1); poke() }
        .onContinuousHover { phase in if case .active = phase { poke() } }
        .task(id: lib.presentIndex) { await load() }
        .onReceive(tick) { _ in if autoplay { lib.presentMove(1) } }
        .onAppear { poke() }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .focusable()
        .focusEffectDisabled()
    }

    private func hud(_ item: PhotoItem) -> some View {
        VStack {
            HStack {
                Pill { Text("Esc"); Text("to exit").foregroundStyle(Theme.textSecondary) }
                Spacer()
                if autoplay { Pill { Image(systemName: "play.fill"); Text("Auto") } }
            }
            Spacer()
            if showInfo {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.baseName).font(.system(size: 15, weight: .semibold))
                        Text([item.meta.focalText, item.meta.apertureText, item.meta.shutterText, item.meta.iso.map { "ISO \($0)" }]
                            .compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Text("\(lib.presentIndex + 1) / \(lib.presentIDs.count)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 30).padding(.bottom, 24).padding(.top, 50)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(.top, 20).padding(.horizontal, 20)
        .foregroundStyle(.white)
        .opacity(showHUD ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showHUD)
        .allowsHitTesting(false)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape: lib.endPresentation()
        case .rightArrow, .space, .downArrow: lib.presentMove(1)
        case .leftArrow, .upArrow: lib.presentMove(-1)
        default:
            switch press.characters.lowercased() {
            case "a": autoplay.toggle()
            case "i": showInfo.toggle()
            default: return .ignored
            }
        }
        poke()
        return .handled
    }

    private func poke() {
        showHUD = true
        NSCursor.setHiddenUntilMouseMoves(false)
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            showHUD = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Loading — instant camera preview first, then a developed RAW if that gives a sharper picture.

    private func load() async {
        guard let item = lib.presentItem else { return }
        let f = item.file
        let wantsDeveloped = f.isRaw && f.companion == nil && (UserDefaults.standard.object(forKey: "presentDeveloped") as? Bool ?? true)

        if let ready = wantsDeveloped ? PreviewCache.shared.cachedDeveloped(primary: f.url, maxPixel: targetPixels) : nil {
            image = ready
        } else if let quick = await PreviewCache.shared.image(primary: f.url, companion: f.companion, maxPixel: targetPixels), !Task.isCancelled {
            image = quick
            if wantsDeveloped, let developed = await PreviewCache.shared.developed(primary: f.url, maxPixel: targetPixels), !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) { image = developed }
            }
        }
        prefetch()
    }

    private func prefetch() {
        for offset in [1, 2] {
            guard let id = lib.presentIDs[safe: (lib.presentIndex + offset) % max(1, lib.presentIDs.count)], let next = lib.item(id: id) else { continue }
            let f = next.file
            Task(priority: .utility) {
                _ = await PreviewCache.shared.image(primary: f.url, companion: f.companion, maxPixel: targetPixels)
                if f.isRaw, f.companion == nil { _ = await PreviewCache.shared.developed(primary: f.url, maxPixel: targetPixels) }
            }
        }
    }
}
