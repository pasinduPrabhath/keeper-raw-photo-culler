import AppKit
import KeeperCore
import SwiftUI

struct LoupeView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.bg
                if let item = lib.activeItem { LoupeCanvas(item: item) }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            FilmstripView().frame(height: 94).background(Theme.surface)
        }
    }
}

private let loupePixels = 2880

struct LoupeCanvas: View {
    let item: PhotoItem
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var full: CGImage?
    @State private var loadingFull = false
    @State private var dragStart: CGSize?
    @State private var pinchStart: Double?
    private let backing = NSScreen.main?.backingScaleFactor ?? 2

    var body: some View {
        GeometryReader { geo in
            let shown = full ?? image
            let fit = fitSize(of: shown, in: geo.size)
            ZStack {
                // The (possibly huge) zoomed image lives in its own clipped layer so it can't push the overlays off-screen.
                ZStack {
                    if let shown {
                        Image(decorative: shown, scale: 1).resizable().interpolation(.high)
                            .frame(width: fit.width * lib.zoom, height: fit.height * lib.zoom)
                            .offset(lib.pan)
                            .saturation(item.flag == .reject ? 0.1 : 1)
                            .opacity(item.flag == .reject ? 0.5 : 1)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                overlays
                zoomControls(geo.size, fit)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .snapshotFrame("canvas")
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard lib.zoomed else { return }
                    let base = dragStart ?? lib.pan
                    dragStart = base
                    lib.pan = clamp(CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height), geo.size, fit)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let base = pinchStart ?? lib.zoom
                    pinchStart = base
                    lib.applyZoom(base * value.magnification, anchor: offsetFromCentre(value.startLocation, geo.size))
                    lib.pan = clamp(lib.pan, geo.size, fit)
                }
                .onEnded { _ in pinchStart = nil })
            .background(ScrollMonitor(onDoubleClick: { location in
                withAnimation(Theme.spring) {
                    if lib.zoomed { lib.resetZoom() }
                    else {
                        lib.applyZoom(lib.zoomFull, anchor: offsetFromCentre(location, geo.size))
                        lib.pan = clamp(lib.pan, geo.size, fit)
                    }
                }
            }) { dx, dy, flags, location in
                if flags.contains(.command) || flags.contains(.option) {
                    lib.applyZoom(lib.zoom * exp(Double(dy) * 0.012), anchor: offsetFromCentre(location, geo.size))
                    lib.pan = clamp(lib.pan, geo.size, fit)
                    return true
                }
                guard lib.zoomed else { return false }
                lib.pan = clamp(CGSize(width: lib.pan.width + dx, height: lib.pan.height + dy), geo.size, fit)
                return true
            })
            .onChange(of: fit, initial: true) { _, newFit in updateFullZoom(newFit) }
            .onChange(of: lib.zoom) { _, _ in
                lib.pan = clamp(lib.pan, geo.size, fit)
                if lib.zoomed { Task { await loadFull() } }
            }
        }
        .task(id: item.id) { await load() }
    }

    // MARK: Geometry

    private func fitSize(of image: CGImage?, in size: CGSize) -> CGSize {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let availableW = max(1, size.width - 40), availableH = max(1, size.height - 32)
        let r = min(availableW / CGFloat(image.width), availableH / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * r, height: CGFloat(image.height) * r)
    }

    /// Zoom value at which one image pixel equals one screen pixel.
    private func updateFullZoom(_ fit: CGSize) {
        let fitLong = max(fit.width, fit.height)
        guard fitLong > 1 else { return }
        let native = CGFloat(max(item.meta.pixelWidth, item.meta.pixelHeight, full?.width ?? 0, full?.height ?? 0, image?.width ?? 0, image?.height ?? 0))
        lib.zoomFull = max(1.01, Double((native / backing) / fitLong))
    }

    private func clamp(_ pan: CGSize, _ view: CGSize, _ fit: CGSize) -> CGSize {
        let maxX = max(0, (fit.width * lib.zoom - view.width) / 2)
        let maxY = max(0, (fit.height * lib.zoom - view.height) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func offsetFromCentre(_ point: CGPoint, _ size: CGSize) -> CGSize {
        CGSize(width: point.x - size.width / 2, height: point.y - size.height / 2)
    }

    // MARK: Overlays

    @ViewBuilder private var overlays: some View {
        VStack {
            HStack(alignment: .top) {
                Pill { Text(item.name).fontWeight(.semibold); Text(item.meta.captureDate.shotTimePrecise).foregroundStyle(Theme.textSecondary) }
                Spacer()
                HStack(spacing: 8) {
                    if item.rating > 0 { Pill { StarsView(rating: item.rating, size: 11) } }
                    FlagBadge(flag: item.flag, size: 26)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                exifChips
                Spacer()
                burstChip
            }
        }
        .padding(16)
        .allowsHitTesting(false)

        if loadingFull && full == nil {
            Pill { ProgressView().controlSize(.small); Text("Loading full resolution…") }
        }
    }

    private func zoomControls(_ size: CGSize, _ fit: CGSize) -> some View {
        let percent = Int((lib.zoom / max(lib.zoomFull, 0.01) * 100).rounded())
        return VStack {
            Spacer()
            HStack(spacing: 2) {
                zoomButton("minus", help: "Zoom out (−)") { lib.zoomOut() }
                zoomPreset("Fit", active: !lib.zoomed) { lib.resetZoom() }
                zoomPreset("100%", active: lib.zoomed && abs(percent - 100) <= 2) { lib.zoomTo(actualPixels: 1) }
                zoomPreset("200%", active: abs(percent - 200) <= 2) { lib.zoomTo(actualPixels: 2) }
                zoomButton("plus", help: "Zoom in (+)") { lib.zoomIn() }
                if lib.zoomed {
                    Text("\(percent)%").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary).frame(width: 46)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .padding(.bottom, 14)
        }
    }

    private func zoomButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.quick) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle()).foregroundStyle(Theme.text).help(help)
    }

    private func zoomPreset(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.spring) { action() } } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.9) : .clear))
                .foregroundStyle(active ? Color.black : Theme.text)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var exifChips: some View {
        HStack(spacing: 6) {
            ForEach([item.meta.focalText, item.meta.apertureText, item.meta.shutterText, item.meta.iso.map { "ISO \($0)" }].compactMap { $0 }, id: \.self) { text in
                Pill { Text(text) }
            }
        }
    }

    @ViewBuilder private var burstChip: some View {
        let members = lib.burst(of: item)
        HStack(spacing: 8) {
            if let s = item.sharpness, let best = members.compactMap(\.sharpness).max(), best > 0 {
                Pill { Text("Sharpness"); SharpnessMeter(value: s / best, width: 54) }
            }
            if members.count > 1, let index = members.firstIndex(where: { $0 === item }) {
                Pill(tint: Theme.burst) {
                    Image(systemName: "square.stack.3d.down.right.fill")
                    Text("Frame \(index + 1) of \(members.count)")
                    if item.isBestInBurst { Image(systemName: "sparkles") }
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        full = nil
        loadingFull = false
        let f = item.file
        if let cached = PreviewCache.shared.cached(f.url, maxPixel: loupePixels) {
            image = cached
        } else {
            if let thumb = await lib.thumbnail(for: item), !Task.isCancelled { image = thumb }
            if let big = await PreviewCache.shared.image(primary: f.url, companion: f.companion, maxPixel: loupePixels), !Task.isCancelled {
                image = big
            }
        }
        prefetchNeighbours()
    }

    private func loadFull() async {
        guard full == nil, !loadingFull else { return }
        let f = item.file
        loadingFull = true
        let result = await Task.detached(priority: .userInitiated) { PreviewDecoder.fullResolution(primary: f.url, companion: f.companion) }.value
        guard !Task.isCancelled else { return }
        full = result
        loadingFull = false
    }

    private func prefetchNeighbours() {
        guard let index = lib.visible.firstIndex(where: { $0.id == item.id }) else { return }
        for offset in [1, -1, 2, -2, 3] {
            guard let neighbour = lib.visible[safe: index + offset] else { continue }
            let f = neighbour.file
            Task(priority: .utility) { _ = await PreviewCache.shared.image(primary: f.url, companion: f.companion, maxPixel: loupePixels) }
        }
    }
}

/// Receives trackpad / mouse-wheel scrolling over its area without interfering with clicks.
struct ScrollMonitor: NSViewRepresentable {
    var onDoubleClick: ((CGPoint) -> Void)?
    let handler: (_ dx: CGFloat, _ dy: CGFloat, _ flags: NSEvent.ModifierFlags, _ location: CGPoint) -> Bool

    func makeNSView(context: Context) -> MonitorView { let v = MonitorView(); v.handler = handler; v.onDoubleClick = onDoubleClick; return v }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler; view.onDoubleClick = onDoubleClick }

    final class MonitorView: NSView {
        var handler: ((CGFloat, CGFloat, NSEvent.ModifierFlags, CGPoint) -> Bool)?
        var onDoubleClick: ((CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, event.window == self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let location = CGPoint(x: p.x, y: self.bounds.height - p.y)
                if event.type == .leftMouseDown {
                    if event.clickCount == 2 { self.onDoubleClick?(location) }
                    return event
                }
                let handled = self.handler?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags, location) ?? false
                return handled ? nil : event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Filmstrip

struct FilmstripView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(lib.visible) { item in
                        FilmCell(item: item).id(item.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: lib.activeID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct FilmCell: View {
    let item: PhotoItem
    @Environment(Library.self) private var lib
    @State private var image: CGImage?

    var body: some View {
        let active = lib.activeID == item.id
        let selected = lib.selection.contains(item.id)
        Color.clear
            .frame(width: 84, height: 56)
            .background(Theme.cell)
            .overlay {
                if let image { image.swiftUIImage.resizable().scaledToFit().opacity(item.flag == .reject ? 0.35 : 1) }
            }
            .overlay(alignment: .topTrailing) { FlagBadge(flag: item.flag, size: 14).padding(3) }
            .overlay(alignment: .bottom) {
                if item.flag == .pick { Rectangle().fill(Theme.pick).frame(height: 2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Theme.accent : (selected ? Theme.accent.opacity(0.5) : Theme.stroke), lineWidth: active ? 2 : 1)
            }
            .scaleEffect(active ? 1.04 : 1)
            .animation(Theme.quick, value: active)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                lib.select(item, flags.contains(.shift) ? .extend : (flags.contains(.command) ? .toggle : .replace))
            }
            .task(id: item.id) { image = await lib.thumbnail(for: item) }
    }
}
