import AppKit
import KeeperCore
import SwiftUI

/// All frames of a burst on one screen. Zoom and pan are linked, so zooming on the bird's eye in one frame
/// shows the same spot in every frame.
struct CompareView: View {
    @Environment(Library.self) private var lib
    private let gap: CGFloat = 10

    var body: some View {
        let items = lib.compareItems
        VStack(spacing: 0) {
            header(items)
            GeometryReader { geo in
                let cols = columns(for: items.count)
                let rows = max(1, Int((Double(items.count) / Double(cols)).rounded(.up)))
                let w = (geo.size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
                let h = (geo.size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
                VStack(spacing: gap) {
                    ForEach(0 ..< rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(items[(r * cols) ..< min(items.count, (r + 1) * cols)]) { item in
                                CompareCell(item: item, active: item.id == lib.activeID, size: CGSize(width: w, height: h), all: items)
                            }
                            if (r + 1) * cols > items.count { Spacer(minLength: 0) }
                        }
                    }
                }
                .padding(gap)
            }
        }
        .background(Theme.bg)
    }

    private func columns(for n: Int) -> Int { n <= 2 ? max(n, 1) : (n <= 4 ? 2 : (n <= 9 ? 3 : 4)) }

    private func header(_ items: [PhotoItem]) -> some View {
        let percent = Int((lib.cmpZoom * 100).rounded())
        return HStack(spacing: 12) {
            Pill(tint: Theme.burst) { Image(systemName: "square.on.square"); Text("Comparing \(items.count) frames") }
            Text("Zoom any frame: all zoom together")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer()
            HStack(spacing: 2) {
                preset("Fit", active: lib.cmpZoom <= 1.01) { lib.cmpZoom = 1; lib.cmpPan = .zero }
                preset("2×", active: abs(lib.cmpZoom - 2) < 0.05) { lib.cmpZoom = 2 }
                preset("4×", active: abs(lib.cmpZoom - 4) < 0.05) { lib.cmpZoom = 4 }
                preset("8×", active: abs(lib.cmpZoom - 8) < 0.05) { lib.cmpZoom = 8 }
                if lib.cmpZoom > 1.01 { Text("\(percent)%").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 44) }
            }
            .fixedSize()
            .padding(3).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Theme.stroke))

            Button {
                if let keeper = lib.activeItem { lib.keepOnly(keeper, among: lib.burst(of: keeper)) }
            } label: {
                Label("Keep selected, reject others", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Theme.pick)).foregroundStyle(Color.black)
            }
            .buttonStyle(PressableStyle())
            .help("Pick the selected frame and reject every other frame in this burst (undoable)")

            Button { withAnimation(Theme.quick) { lib.exitCompare() } } label: {
                Text("Done").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.1))).foregroundStyle(Theme.text)
            }
            .buttonStyle(PressableStyle())
            .help("Back to the grid (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func preset(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.spring) { action() } } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.9) : .clear))
                .foregroundStyle(active ? Color.black : Theme.text).contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct CompareCell: View {
    let item: PhotoItem
    let active: Bool
    let size: CGSize
    let all: [PhotoItem]
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var dragStart: CGSize?
    @State private var pinchStart: Double?

    private let maxZoom = 8.0

    var body: some View {
        let fit = fitSize
        let pan = clamped(CGSize(width: lib.cmpPan.width * size.width, height: lib.cmpPan.height * size.height), fit)
        ZStack {
            Theme.cell
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: fit.width * lib.cmpZoom, height: fit.height * lib.cmpZoom)
                        .offset(pan)
                        .opacity(item.flag == .reject ? 0.45 : 1)
                        .saturation(item.flag == .reject ? 0.15 : 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size.width, height: size.height).clipped()

            overlay
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(active ? Theme.accent : Theme.stroke, lineWidth: active ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { lib.select(item, .replace) }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard lib.cmpZoom > 1.01 else { return }
                let base = dragStart ?? CGSize(width: lib.cmpPan.width * size.width, height: lib.cmpPan.height * size.height)
                dragStart = base
                setPan(CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height), fit)
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let base = pinchStart ?? lib.cmpZoom
                pinchStart = base
                zoom(to: base * value.magnification, at: value.startLocation, fit)
            }
            .onEnded { _ in pinchStart = nil })
        .background(ScrollMonitor(onDoubleClick: { location in
            withAnimation(Theme.spring) {
                if lib.cmpZoom > 1.01 { lib.cmpZoom = 1; lib.cmpPan = .zero } else { zoom(to: 3, at: location, fit) }
            }
        }) { dx, dy, flags, location in
            if flags.contains(.command) || flags.contains(.option) {
                zoom(to: lib.cmpZoom * exp(Double(dy) * 0.012), at: location, fit)
                return true
            }
            guard lib.cmpZoom > 1.01 else { return false }
            let current = CGSize(width: lib.cmpPan.width * size.width, height: lib.cmpPan.height * size.height)
            setPan(CGSize(width: current.width + dx, height: current.height + dy), fit)
            return true
        })
        .task(id: item.id) { await load() }
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                Pill { Text(item.baseName).fontWeight(.semibold); if item.isBestInBurst { Image(systemName: "sparkles").foregroundStyle(Theme.burst) } }
                Spacer()
                if item.rating > 0 { Pill { StarsView(rating: item.rating, size: 10) } }
                FlagBadge(flag: item.flag, size: 22)
            }
            Spacer()
            HStack(alignment: .bottom) {
                if let s = item.sharpness, let best = all.compactMap(\.sharpness).max(), best > 0 {
                    Pill { Text("Sharp \(Int(s / best * 100))%"); SharpnessMeter(value: s / best, width: 40) }
                }
                Spacer()
                HStack(spacing: 6) {
                    cellButton("checkmark", Theme.pick, on: item.flag == .pick) { lib.select(item, .replace); lib.setFlag(.pick, on: [item], advance: false) }
                    cellButton("xmark", Theme.reject, on: item.flag == .reject) { lib.select(item, .replace); lib.setFlag(.reject, on: [item], advance: false) }
                }
            }
        }
        .padding(8)
    }

    private func cellButton(_ symbol: String, _ tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? Color.black : tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? tint : Color.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(tint.opacity(0.8), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(symbol == "checkmark" ? "Pick this frame (P)" : "Reject this frame (X)")
    }

    // MARK: Geometry and zoom

    private var fitSize: CGSize {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let r = min(max(1, size.width - 8) / CGFloat(image.width), max(1, size.height - 8) / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * r, height: CGFloat(image.height) * r)
    }

    private func clamped(_ pan: CGSize, _ fit: CGSize) -> CGSize {
        let maxX = max(0, (fit.width * lib.cmpZoom - size.width) / 2)
        let maxY = max(0, (fit.height * lib.cmpZoom - size.height) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func setPan(_ pan: CGSize, _ fit: CGSize) {
        let c = clamped(pan, fit)
        lib.cmpPan = CGSize(width: c.width / size.width, height: c.height / size.height)
    }

    /// Zoom keeping the point under the cursor fixed, in every frame at once.
    private func zoom(to requested: Double, at point: CGPoint, _ fit: CGSize) {
        let z = min(max(requested, 1), maxZoom)
        let f = z / lib.cmpZoom
        let a = CGSize(width: point.x - size.width / 2, height: point.y - size.height / 2)
        let current = CGSize(width: lib.cmpPan.width * size.width, height: lib.cmpPan.height * size.height)
        lib.cmpZoom = z
        if z <= 1.01 { lib.cmpZoom = 1; lib.cmpPan = .zero; return }
        setPan(CGSize(width: (current.width - a.width) * f + a.width, height: (current.height - a.height) * f + a.height), fit)
    }

    private func load() async {
        let f = item.file
        if let cached = PreviewCache.shared.cached(f.url, maxPixel: 2880) { image = cached; return }
        if let thumb = await lib.thumbnail(for: item), !Task.isCancelled, image == nil { image = thumb }
        if let big = await PreviewCache.shared.image(primary: f.url, companion: f.companion, maxPixel: 2880), !Task.isCancelled { image = big }
    }
}
