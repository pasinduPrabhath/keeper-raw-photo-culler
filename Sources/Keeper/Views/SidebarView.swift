import KeeperCore
import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var lib
    @Environment(DriveController.self) private var drive
    @Binding var showUpload: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var lib = lib
        List {
            Section {
                Button { lib.chooseFolder() } label: {
                    Label("Open Folders…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

                if lib.hasFolder {
                    ForEach(lib.folders, id: \.self) { folder in
                        FolderRow(folder: folder, count: lib.folderCounts[folder] ?? 0, canRemove: lib.folders.count > 1) {
                            withAnimation(Theme.quick) { lib.removeFolder(folder) }
                        }
                    }
                    Button { lib.chooseFolder(add: true) } label: {
                        Label("Add Folder…", systemImage: "plus.circle").font(.system(size: 12.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    Text(lib.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            } header: { SectionLabel(text: lib.folders.count > 1 ? "Folders" : "Shoot") }

            if lib.hasFolder {
                Section {
                    ForEach(LibraryFilter.allCases) { filter in
                        FilterRow(filter: filter, count: count(for: filter), selected: lib.filter == filter) {
                            withAnimation(Theme.quick) { lib.filter = filter }
                        }
                    }
                } header: { SectionLabel(text: "Show") }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Burst gap").font(.system(size: 12))
                            Spacer()
                            Text(String(format: "%.1f s", lib.burstGap)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        }
                        Slider(value: $lib.burstGap, in: 0.2 ... 5)
                            .controlSize(.small)
                        Text("Frames closer together than this are grouped into one burst.")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 2)

                    Toggle("Include subfolders", isOn: Binding(
                        get: { lib.includeSubfolders },
                        set: { lib.includeSubfolders = $0; if lib.hasFolder { lib.open(folders: lib.folders) } }
                    ))
                    .font(.system(size: 12))
                    .toggleStyle(.switch).controlSize(.small)
                } header: { SectionLabel(text: "Bursts") }
            }

            Section {
                Button {
                    if drive.isSignedIn && lib.hasFolder { showUpload = true } else { openSettings() }
                } label: {
                    HStack {
                        Label("Google Drive", systemImage: "icloud.and.arrow.up")
                        Spacer()
                        Circle().fill(drive.isSignedIn ? Theme.pick : Theme.textTertiary).frame(width: 7, height: 7)
                    }
                }
                .buttonStyle(.plain)
                Text(drive.isSignedIn ? "Connected" : "Not connected · set up in Settings")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            } header: { SectionLabel(text: "Cloud") }

            let recents = RecentFolders.all.filter { !lib.folders.contains($0) }
            if !recents.isEmpty {
                Section {
                    ForEach(recents.prefix(5), id: \.self) { url in
                        Button { lib.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "clock.arrow.circlepath").lineLimit(1)
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).font(.system(size: 12))
                    }
                } header: { SectionLabel(text: "Recent") }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .font(.system(size: 13))
    }

    private func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: lib.counts.all
        case .picks: lib.counts.picks
        case .unflagged: lib.counts.unflagged
        case .rejects: lib.counts.rejects
        case .best: lib.counts.best
        }
    }
}

private struct FilterRow: View {
    let filter: LibraryFilter
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: filter.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? tint : Theme.textSecondary)
                Text(filter.rawValue).fontWeight(selected ? .semibold : .regular)
                Spacer()
                Text("\(count)").font(.system(size: 11.5, design: .rounded).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.white.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private var tint: Color {
        switch filter {
        case .picks: Theme.pick
        case .rejects: Theme.reject
        case .best: Theme.burst
        default: Theme.accent
        }
    }
}

private struct FolderRow: View {
    let folder: URL
    let count: Int
    let canRemove: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.textSecondary)
            Text(folder.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if canRemove && hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).help("Remove this folder from the library (files are not touched)")
            } else {
                Text("\(count)").font(.system(size: 11.5, design: .rounded).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(folder.path)
    }
}
