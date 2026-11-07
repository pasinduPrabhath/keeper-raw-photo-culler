import AppKit
import KeeperCore
import SwiftUI

struct GridView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 10, pad: CGFloat = 18
            let cols = max(1, Int((geo.size.width - pad * 2 + spacing) / (lib.thumbSize + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(lib.sections) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: spacing) {
                                    ForEach(section.items) { item in
                                        ThumbnailCell(item: item).id(item.id)
                                    }
                                }
                                .padding(.horizontal, pad)
                            } header: {
                                SectionHeaderView(section: section)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.automatic)
                .onChange(of: lib.activeID) { _, id in
                    guard let id else { return }
                    withAnimation(Theme.quick) { proxy.scrollTo(id) }
                }
                .onChange(of: cols, initial: true) { _, new in lib.gridColumns = new }
            }
        }
    }
}

// MARK: - Cell

struct ThumbnailCell: View {
    let item: PhotoItem
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        let selected = lib.selection.contains(item.id)
        let active = lib.activeID == item.id
        let rejected = item.flag == .reject

        Color.clear
            .aspectRatio(1.5, contentMode: .fit)
            .background(Theme.cell)
            .overlay {
                if let image {
                    image.swiftUIImage.resizable().scaledToFit()
                        .saturation(rejected ? 0.05 : 1)
                        .opacity(rejected ? 0.4 : 1)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { bottomBar(selected: selected) }
            .overlay(alignment: .bottom) {
                if item.flag == .pick { Rectangle().fill(Theme.pick).frame(height: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : (active ? Color.white.opacity(0.5) : Theme.stroke), lineWidth: selected ? 2.5 : (active ? 1.5 : 1))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                lib.select(item, flags.contains(.shift) ? .extend : (flags.contains(.command) ? .toggle : .replace))
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { lib.select(item, .replace); lib.mode = .loupe })
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .contextMenu { ItemContextMenu(item: item) }
            .animation(Theme.quick, value: selected)
            .task(id: item.id) {
                let loaded = await lib.thumbnail(for: item)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }

    @ViewBuilder private var topBar: some View {
        HStack(alignment: .top) {
            if item.isBestInBurst {
                Pill(tint: Theme.burst) { Image(systemName: "sparkles"); Text("Best") }
            }
            Spacer()
            if hovering && item.flag == .none {
                HStack(spacing: 5) {
                    quickButton("checkmark", Theme.pick) { lib.setFlag(.pick, on: [item], advance: false) }
                    quickButton("xmark", Theme.reject) { lib.setFlag(.reject, on: [item], advance: false) }
                }
                .transition(.opacity)
            } else {
                FlagBadge(flag: item.flag)
            }
        }
        .padding(7)
    }

    private func quickButton(_ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .black)).foregroundStyle(tint)
                .frame(width: 20, height: 20).background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.strokeStrong))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func bottomBar(selected: Bool) -> some View {
        if hovering || selected || item.rating > 0 {
            HStack(spacing: 6) {
                if hovering || selected {
                    Text(item.baseName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.rating > 0 { StarsView(rating: item.rating, size: 9) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.bottom, item.flag == .pick ? 8 : 6).padding(.top, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
    }
}

struct ItemContextMenu: View {
    let item: PhotoItem
    @Environment(Library.self) private var lib
    @Environment(DriveController.self) private var drive

    var body: some View {
        let targets = lib.selection.contains(item.id) ? lib.selectedItems : [item]
        Button("Pick", systemImage: "checkmark.circle") { lib.setFlag(.pick, on: targets, advance: false) }
        Button("Reject", systemImage: "xmark.circle") { lib.setFlag(.reject, on: targets, advance: false) }
        Button("Clear Flag", systemImage: "circle.dashed") { lib.setFlag(.none, on: targets, advance: false) }
        Menu("Rating", systemImage: "star") {
            ForEach(0 ... 5, id: \.self) { n in
                Button(n == 0 ? "No Rating" : String(repeating: "★", count: n)) { lib.setRating(n, on: targets) }
            }
        }
        Divider()
        Button("Reveal in Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Button("Move to Trash", systemImage: "trash") { lib.select(item, .replace); lib.pendingTrash = targets }
    }
}

// MARK: - Section header

struct SectionHeaderView: View {
    let section: GridSection
    @Environment(Library.self) private var lib

    var body: some View {
        HStack(spacing: 10) {
            if let burstID = section.burstID, let first = section.items.first {
                let members = lib.burst(of: first)
                let span = (members.last?.meta.captureDate.timeIntervalSince(members.first?.meta.captureDate ?? .now)) ?? 0
                let collapsed = lib.collapsedBursts.contains(burstID)

                Button { withAnimation(Theme.spring) { lib.toggleCollapse(burstID) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? -90 : 0)).foregroundStyle(Theme.textTertiary)
                        Image(systemName: "square.stack.3d.down.right.fill").foregroundStyle(Theme.burst)
                        Text("Burst").fontWeight(.semibold)
                        Text("\(section.totalCount) frames").foregroundStyle(Theme.textSecondary)
                        Text("·  \(members.first?.meta.captureDate.shotTime ?? "")  ·  \(String(format: "%.1f", span)) s")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                let ready = members.contains { $0.isBestInBurst }
                Button {
                    let n = lib.keepBest(inBurst: burstID)
                    if n > 0 { lib.showToast("Kept the sharpest frame · \(n) rejected", symbol: "sparkles", actionTitle: "Undo") { lib.undo() } }
                } label: {
                    Label("Keep best", systemImage: "sparkles").font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.burst)
                .disabled(!ready)
                .help(ready ? "Pick the sharpest frame and reject the rest of this burst" : "Analysing sharpness…")
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.textTertiary)
                Text("Single shots").fontWeight(.semibold)
                Text("\(section.totalCount)").foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}
