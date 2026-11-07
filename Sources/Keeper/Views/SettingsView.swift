import AppKit
import KeeperCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DriveSettings().tabItem { Label("Google Drive", systemImage: "icloud") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage("writeXMP") private var writeXMP = false
    @AppStorage("presentDeveloped") private var presentDeveloped = true
    @AppStorage(UpdateService.enabledKey) private var checkUpdates = true
    @Environment(UpdateService.self) private var updates
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("Culling") {
                Toggle("Write ratings and flags to XMP sidecars", isOn: $writeXMP)
                Text("Lets Lightroom, Capture One and darktable see your stars, picks (green label) and rejects (−1). Existing sidecars are patched, never replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Presenting") {
                Toggle("Develop RAW-only photos for sharper full-screen", isOn: $presentDeveloped)
                Text("Shows the instant camera preview first, then swaps in a developed version a moment later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check GitHub for new versions", isOn: $checkUpdates)
                Text("Keeper is offline by default. This is one plain request to GitHub's public releases page, sending nothing about you or your photos. Turn it off and Keeper makes no connection at all (except Google Drive uploads you start yourself).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                }
                switch updates.state {
                case .upToDate: Text("You're up to date.").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.secondary)
                case .checking: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
            Section("Cache") {
                LabeledContent("Thumbnail cache", value: cacheSize.fileSizeText)
                Button("Clear Thumbnail Cache") {
                    Task { await ThumbnailService.shared.clearDiskCache(); cacheSize = await ThumbnailService.shared.diskCacheSize() }
                }
            }
        }
        .formStyle(.grouped)
        .task { cacheSize = await ThumbnailService.shared.diskCacheSize() }
    }
}

private struct DriveSettings: View {
    @Environment(DriveController.self) private var drive

    var body: some View {
        @Bindable var drive = drive
        Form {
            Section("Account") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(drive.isSignedIn ? Theme.pick : Color.secondary).frame(width: 8, height: 8)
                        Text(drive.isSignedIn ? "Connected" : "Not connected")
                    }
                }
                if drive.isSignedIn {
                    Button("Sign Out") { drive.signOut() }
                } else {
                    Button(drive.isSigningIn ? "Waiting for browser…" : "Sign in with Google") { drive.signIn() }
                        .disabled(!drive.hasCredentials || drive.isSigningIn)
                }
                if let error = drive.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("OAuth client") {
                TextField("Client ID", text: $drive.clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
                SecureField("Client secret", text: $drive.clientSecret, prompt: Text("Optional for Desktop clients"))
                Text("Create a free “Desktop app” OAuth client in Google Cloud Console and enable the Drive API. Keeper requests only the drive.file scope, so it can never read your other files. Step-by-step guide: docs/GOOGLE_DRIVE_SETUP.md")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
