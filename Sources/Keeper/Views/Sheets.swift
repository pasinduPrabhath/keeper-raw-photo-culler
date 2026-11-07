import AppKit
import KeeperCore
import SwiftUI

// MARK: - Drive upload

struct DriveUploadSheet: View {
    @Environment(Library.self) private var lib
    @Environment(DriveController.self) private var drive
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    enum Scope: String, CaseIterable, Identifiable { case selection = "Selected", picks = "Picks", visible = "Everything shown"; var id: String { rawValue } }

    @State private var scope: Scope = .picks
    @State private var content: DriveController.Content = .previews
    @State private var previewSize = 2048
    @State private var folderPath = ""
    @State private var shareLink = true

    private var items: [PhotoItem] {
        switch scope {
        case .selection: lib.selectedItems
        case .picks: lib.items.filter { $0.flag == .pick }
        case .visible: lib.visible
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Upload to Google Drive", systemImage: "icloud.and.arrow.up").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { drive.cancel(); dismiss(); drive.reset() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }

            if !drive.isSignedIn {
                notConnected
            } else if drive.isUploading || drive.finished {
                progress
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.surface)
        .onAppear {
            if lib.selection.count > 1 { scope = .selection }
            else if lib.counts.picks == 0 { scope = .visible }
            if folderPath.isEmpty { folderPath = "Keeper/\(lib.folder?.lastPathComponent ?? "Shoot")" }
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your Google account first. Keeper only ever sees the files and folders it creates.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Open Settings") { openSettings() }
                if drive.hasCredentials {
                    Button("Sign in with Google") { drive.signIn() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            if let error = drive.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.reject) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Photos") {
                Picker("", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            LabeledContent("Upload") {
                Picker("", selection: $content) { ForEach(DriveController.Content.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            if content != .originals {
                LabeledContent("Preview size") {
                    Picker("", selection: $previewSize) {
                        Text("1600 px").tag(1600); Text("2048 px").tag(2048); Text("3840 px").tag(3840); Text("Full").tag(0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                }
            }
            LabeledContent("Drive folder") {
                TextField("Keeper/My shoot", text: $folderPath).textFieldStyle(.roundedBorder).frame(width: 300)
            }
            Toggle("Anyone with the link can view the folder", isOn: $shareLink).font(.system(size: 13))

            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if let error = drive.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.reject) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Upload \(items.count) photo\(items.count == 1 ? "" : "s")") {
                    drive.upload(items: items, folderPath: folderPath, content: content,
                                 previewSize: previewSize == 0 ? nil : previewSize, shareLink: shareLink)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty || folderPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var summary: String {
        let bytes = items.reduce(Int64(0)) { $0 + $1.file.fileSize }
        let estimate = content == .previews ? "JPEG previews are typically 1–3 MB each." : "Originals total \(bytes.fileSizeText)."
        return "\(items.count) photo\(items.count == 1 ? "" : "s") · \(estimate) Files already in the folder are skipped."
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: drive.overallProgress).tint(Theme.accent)
            Text(drive.isUploading ? "Uploading \(drive.completed) of \(drive.jobs.count)…" : "Finished · \(drive.completed) of \(drive.jobs.count) files in Drive")
                .font(.system(size: 13, weight: .medium)).monospacedDigit()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(drive.jobs) { job in
                        HStack(spacing: 10) {
                            icon(job.state).frame(width: 16)
                            Text(job.name).lineLimit(1).font(.system(size: 12))
                            Spacer()
                            if case .uploading(let p) = job.state { Text("\(Int(p * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                            if case .skipped = job.state { Text("already there").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                            if case .failed(let m) = job.state { Text(m).font(.system(size: 11)).foregroundStyle(Theme.reject).lineLimit(1) }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .frame(height: 190)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))

            if let error = drive.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.reject) }

            HStack {
                if let link = drive.folderLink {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string); lib.showToast("Link copied", symbol: "link") } label: {
                        Label("Copy link", systemImage: "link")
                    }
                    Button { NSWorkspace.shared.open(link) } label: { Label("Open in Drive", systemImage: "arrow.up.right.square") }
                }
                Spacer()
                if drive.isUploading { Button("Cancel upload") { drive.cancel() } }
                else { Button("Done") { dismiss(); drive.reset() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent) }
            }
        }
    }

    @ViewBuilder private func icon(_ state: DriveController.JobState) -> some View {
        switch state {
        case .queued: Image(systemName: "circle.dotted").foregroundStyle(Theme.textTertiary)
        case .uploading: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.pick)
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(Theme.textTertiary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.reject)
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var exporter = Exporter()
    @State private var source: ExportOptions.Source = .cameraPreview
    @State private var size = 2048
    @State private var quality = 0.88

    var body: some View {
        let items = lib.targets
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Export JPEGs", systemImage: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Text("Share \(items.count) photo\(items.count == 1 ? "" : "s") without opening an editor.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)

            LabeledContent("Look") {
                Picker("", selection: $source) {
                    Text("Camera preview").tag(ExportOptions.Source.cameraPreview)
                    Text("Develop RAW").tag(ExportOptions.Source.developedRAW)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            Text(source == .cameraPreview
                 ? "Instant. Uses the JPEG your camera made, so it keeps your in-camera colour and contrast."
                 : "Slower. Develops the RAW at full resolution with Apple's RAW engine for a larger, sharper image.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)

            LabeledContent("Long edge") {
                Picker("", selection: $size) {
                    Text("1600").tag(1600); Text("2048").tag(2048); Text("3840").tag(3840); Text("Full").tag(0)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            LabeledContent("Quality") {
                HStack { Slider(value: $quality, in: 0.5 ... 1).frame(width: 220); Text("\(Int(quality * 100))").monospacedDigit().frame(width: 30) }
            }

            if exporter.isRunning || exporter.done > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: exporter.progress).tint(Theme.accent)
                    Text(exporter.isRunning ? "Exporting \(exporter.done) of \(exporter.total)…" : "Exported \(exporter.done - exporter.failures.count) photos" + (exporter.failures.isEmpty ? "" : " · \(exporter.failures.count) failed"))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }

            HStack {
                if !exporter.isRunning, exporter.done > 0, let dest = exporter.lastDestination {
                    Button("Show in Finder") { NSWorkspace.shared.open(dest) }
                }
                Spacer()
                Button(exporter.done > 0 && !exporter.isRunning ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { choose(items) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
                    .disabled(exporter.isRunning || items.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.surface)
    }

    private func choose(_ items: [PhotoItem]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"; panel.message = "Choose where to save the JPEGs."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let options = ExportOptions(source: source, maxPixel: size == 0 ? nil : size, quality: quality)
        Task { await exporter.export(items, to: folder, options: options) }
    }
}
