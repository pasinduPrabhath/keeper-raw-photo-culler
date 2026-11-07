import AppKit
import KeeperCore
import SwiftUI

@main
struct KeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = Library()
    @State private var drive = DriveController()
    @State private var updates = UpdateService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(drive)
                .environment(updates)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { library.openExternal($0) }
        }
        .defaultSize(width: 1480, height: 940)
        .windowToolbarStyle(.unified)
        .commands { KeeperCommands(library: library, updates: updates) }

        Settings {
            SettingsView()
                .environment(library)
                .environment(drive)
                .environment(updates)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct KeeperCommands: Commands {
    let library: Library
    let updates: UpdateService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await updates.check(userInitiated: true); NotificationCenter.default.post(name: .keeperUpdateResult, object: nil) } }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Folders…") { library.chooseFolder() }.keyboardShortcut("o")
            Button("Add Folder to Library…") { library.chooseFolder(add: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Open Recent") {
                ForEach(RecentFolders.all, id: \.self) { url in
                    Button(url.lastPathComponent) { library.open(url) }
                }
            }
        }

        CommandMenu("Photo") {
            Button("Pick  (P)") { library.setFlag(.pick) }
            Button("Reject  (X)") { library.setFlag(.reject) }
            Button("Compare Burst  (C)") { library.enterCompare() }
            Button("Clear Flag  (U)") { library.setFlag(.none) }
            Divider()
            Button("Auto-Cull Bursts") { library.autoCull() }.keyboardShortcut("k")
            Button("Keep Best of This Burst  (K)") {
                if let item = library.activeItem { library.keepBest(inBurst: item.burstID) }
            }
            Divider()
            Button("Move Selection to Trash…  (⌘⌫)") { library.requestTrashSelection() }
            Button("Move All Rejects to Trash…") { library.requestTrashRejects() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            Button("Undo Last Change  (⌘Z)") { library.undo() }.disabled(!library.canUndo)
        }

        CommandMenu("Share") {
            Button("Start Presentation") { library.startPresentation() }.keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Export JPEGs…") { NotificationCenter.default.post(name: .keeperShowExport, object: nil) }.keyboardShortcut("e")
            Button("Upload to Google Drive…") { NotificationCenter.default.post(name: .keeperShowUpload, object: nil) }.keyboardShortcut("u")
        }

        CommandGroup(replacing: .help) {
            Button("Keeper Help") { NotificationCenter.default.post(name: .keeperShowHelp, object: nil) }.keyboardShortcut("?")
        }

        CommandMenu("Zoom") {
            Button("Zoom In") { library.zoomIn() }.keyboardShortcut("=")
            Button("Zoom Out") { library.zoomOut() }.keyboardShortcut("-")
            Button("Fit on Screen") { library.resetZoom() }.keyboardShortcut("0")
            Button("Actual Size (100%)") { library.zoomTo(actualPixels: 1) }.keyboardShortcut("1")
            Button("200%") { library.zoomTo(actualPixels: 2) }.keyboardShortcut("2")
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Inspector") { library.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
