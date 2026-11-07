import AppKit
import KeeperCore
import SwiftUI

struct InspectorView: View {
    @Environment(Library.self) private var lib
    @Binding var showUpload: Bool
    @Binding var showExport: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                if lib.selection.count > 1 {
                    MultiPanel(showUpload: $showUpload, showExport: $showExport)
                } else if let item = lib.activeItem {
                    SinglePanel(item: item)
                } else {
                    Text("No photo selected").foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .background(Theme.surface)
    }
}

private struct SinglePanel: View {
    let item: PhotoItem
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                Text("\(item.meta.captureDate.shotDay) · \(item.meta.captureDate.shotTimePrecise)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 5) {
                    tag(item.isRaw ? item.url.pathExtension.uppercased() : "IMAGE", Theme.accent)
                    if item.companion != nil { tag("+ JPG", Theme.textSecondary) }
                    if !item.file.sidecars.isEmpty { tag("XMP", Theme.textSecondary) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Cull")
                HStack(spacing: 8) {
                    flagButton(.pick, "checkmark", Theme.pick)
                    flagButton(.reject, "xmark", Theme.reject)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(1 ... 5, id: \.self) { n in
                            Button { lib.setRating(n, on: [item]) } label: {
                                Image(systemName: n <= item.rating ? "star.fill" : "star")
                                    .foregroundStyle(n <= item.rating ? Theme.star : Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 14))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Exposure")
                InfoRow(label: "Camera", value: item.meta.cameraName ?? "—")
                InfoRow(label: "Lens", value: item.meta.lens ?? "—")
                InfoRow(label: "Focal length", value: item.meta.focalText ?? "—")
                InfoRow(label: "Aperture", value: item.meta.apertureText ?? "—")
                InfoRow(label: "Shutter", value: item.meta.shutterText ?? "—")
                InfoRow(label: "ISO", value: item.meta.iso.map(String.init) ?? "—")
            }

            let members = lib.burst(of: item)
            if members.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Burst")
                    InfoRow(label: "Frames", value: "\(members.count)")
                    Button { withAnimation(Theme.quick) { lib.enterCompare() } } label: {
                        Label("Compare all \(members.count) frames", systemImage: "square.on.square").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.burst)
                    if let s = item.sharpness, let best = members.compactMap(\.sharpness).max(), best > 0 {
                        HStack {
                            Text("Sharpness").foregroundStyle(Theme.textSecondary)
                            Spacer()
                            SharpnessMeter(value: s / best, width: 80)
                            Text("\(Int(s / best * 100))%").foregroundStyle(Theme.text).frame(width: 38, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                    }
                    if item.isBestInBurst {
                        Label("Sharpest frame in this burst", systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.burst)
                    } else if let best = members.first(where: \.isBestInBurst) {
                        Button { lib.select(best, .replace) } label: {
                            Label("Jump to sharpest (\(best.baseName))", systemImage: "arrow.turn.down.right").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "File")
                InfoRow(label: "Dimensions", value: item.meta.pixelWidth > 0 ? "\(item.meta.pixelWidth) × \(item.meta.pixelHeight)" : "—")
                InfoRow(label: "Size", value: item.file.fileSize.fileSizeText)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
    }

    private func flagButton(_ flag: Flag, _ symbol: String, _ tint: Color) -> some View {
        let on = item.flag == flag
        let title = flag == .pick ? "Pick" : "Reject"
        let shownTitle = title
        return Button { lib.setFlag(flag, on: [item], advance: false) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(shownTitle).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? .black : tint)
            .padding(.horizontal, 10).frame(height: 28).fixedSize()
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint : tint.opacity(0.14)))
        }
        .buttonStyle(PressableStyle())
        .snapshotFrame(title)
        .help(flag == .pick ? "Pick: mark as a keeper (P)" : "Reject: mark as unwanted. Nothing is deleted until you press the trash button (X)")
    }
}

private struct MultiPanel: View {
    @Environment(Library.self) private var lib
    @Binding var showUpload: Bool
    @Binding var showExport: Bool
    @State private var bytes: Int64 = 0

    var body: some View {
        let items = lib.selectedItems
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count) photos selected").font(.system(size: 15, weight: .semibold))
                Text(bytes.fileSizeText).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 8) {
                action("Pick all", "checkmark.circle", Theme.pick) { lib.setFlag(.pick, advance: false) }
                action("Reject all", "xmark.circle", Theme.reject) { lib.setFlag(.reject, advance: false) }
                action("Move to Trash…", "trash", Theme.reject) { lib.requestTrashSelection() }
                Divider().overlay(Theme.stroke)
                action("Export JPEGs…", "square.and.arrow.up", Theme.accent) { showExport = true }
                action("Upload to Google Drive…", "icloud.and.arrow.up", Theme.accent) { showUpload = true }
            }
        }
        .task(id: lib.selection) { bytes = items.reduce(0) { $0 + $1.file.fileSize } }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack { Image(systemName: symbol).foregroundStyle(tint).frame(width: 20); Text(title); Spacer() }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.elevated))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
