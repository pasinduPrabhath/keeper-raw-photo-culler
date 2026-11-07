import KeeperCore
import SwiftUI

struct EmptyStateView: View {
    @Environment(Library.self) private var lib
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.35), startRadius: 20, endRadius: 520)
            VStack(spacing: 26) {
                if case .scanning(let done, let total) = lib.phase {
                    scanning(done: done, total: total)
                } else if let folder = lib.folder {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textSecondary)
                        Text("No photos in “\(folder.lastPathComponent)”").font(.system(size: 18, weight: .semibold))
                        Text("Keeper looks for RAW files (ARW, CR3, NEF, DNG…) and JPEG/HEIC images. Try turning on “Include subfolders”.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        Button("Open Another Folder…") { lib.chooseFolder() }
                    }
                } else {
                    welcome
                }
            }
            .padding(40)
            .frame(maxWidth: 560)

            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                    .background(Theme.accent.opacity(0.06))
                    .padding(24)
                    .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            lib.openExternal(urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.elevated)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.strokeStrong))
                Image(systemName: "camera.aperture").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
            }
            .frame(width: 84, height: 84)
            .shadow(color: Theme.accent.opacity(0.25), radius: 30)

            VStack(spacing: 8) {
                Text("Cull a shoot in minutes").font(.system(size: 26, weight: .semibold))
                Text("Open a folder of RAW photos. Keeper reads the preview your camera already embedded, so thousands of frames browse instantly.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }

            Button { lib.chooseFolder() } label: {
                Label("Open Folders…", systemImage: "folder").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
            .keyboardShortcut("o")

            Text("or drop one or more folders here").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)

            HStack(spacing: 22) {
                feature("bolt.fill", "Instant previews")
                feature("square.stack.3d.down.right.fill", "Burst grouping")
                feature("sparkles", "Sharpest frame")
                feature("icloud.and.arrow.up", "Drive upload")
            }
            .padding(.top, 6)

            let recents = RecentFolders.all
            if !recents.isEmpty {
                VStack(spacing: 6) {
                    SectionLabel(text: "Recent")
                    if RecentFolders.session.count > 1 {
                        Button { lib.open(folders: RecentFolders.session) } label: {
                            Label("Reopen last session (\(RecentFolders.session.count) folders)", systemImage: "arrow.counterclockwise").font(.system(size: 12.5, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }
                    ForEach(recents.prefix(3), id: \.self) { url in
                        Button { lib.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "clock.arrow.circlepath").font(.system(size: 12.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func scanning(done: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: total > 0 ? Double(done) / Double(total) : nil).frame(width: 240).tint(Theme.accent)
            Text(total > 0 ? "Reading \(done) of \(total) photos…" : "Looking for photos…")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 100)
    }
}
