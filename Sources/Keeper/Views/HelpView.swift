import SwiftUI

/// In-app help: what everything does, shortcuts, and privacy. Opens from the toolbar "?" button, Help menu, or the `?` key.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var topic: Topic = .start

    enum Topic: String, CaseIterable, Identifiable {
        case start = "Getting started", cull = "Culling", compare = "Compare bursts", zoom = "Zoom", share = "Share & upload"
        case keys = "Shortcuts", privacy = "Privacy & updates", faq = "Troubleshooting"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .start: "play.circle"; case .cull: "checkmark.circle"; case .compare: "square.on.square"; case .zoom: "plus.magnifyingglass"
            case .share: "square.and.arrow.up"; case .keys: "keyboard"; case .privacy: "lock.shield"; case .faq: "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Help").font(.system(size: 18, weight: .bold)).padding(.bottom, 10)
                ForEach(Topic.allCases) { t in
                    Button { topic = t } label: {
                        Label(t.rawValue, systemImage: t.symbol).font(.system(size: 13, weight: topic == t ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(topic == t ? Theme.accent.opacity(0.18) : .clear))
                            .foregroundStyle(topic == t ? Theme.accent : Theme.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Link("Report a problem or star the repo", destination: URL(string: "https://github.com/pasinduPrabhath/keeper-raw-photo-culler")!)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            }
            .padding(16).frame(width: 190).background(Theme.surface)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                Divider()
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
            }
        }
        .frame(width: 760, height: 540)
        .background(Theme.bg)
    }

    @ViewBuilder private var content: some View {
        switch topic {
        case .start:
            title("Getting started")
            para("Keeper shows the full-size preview your camera already saved inside every RAW file, so photos appear instantly instead of taking 2–3 seconds to load.")
            step("1", "Open your photos", "Press ⌘O (or click Open Folders) and choose one or more folders. ⌘-click to pick several, or drag folders onto the window. Add Folder merges more into the same view.")
            step("2", "Look through bursts", "Frames shot within about a second of each other are grouped as a burst. The ✦ Best badge marks the sharpest frame in each one.")
            step("3", "Mark keepers and rejects", "Press P to Pick or X to Reject (or click ✓ / ✗ on a photo). Nothing is deleted yet.")
            step("4", "Delete the rejects", "Click the trash button in the toolbar. You'll see how many photos and how much space, then they go to the macOS Trash. ⌘Z undoes it.")
            para("Tip: **Auto-cull** (✨ in the toolbar) keeps the sharpest frame of every burst and rejects the rest in one click. Review it, then undo if you disagree.")
        case .cull:
            title("Culling")
            para("**Pick** (green ✓, key P) means keeper. **Reject** (red ✗, key X) means unwanted. **Stars** (keys 1–5) rate photos. U clears a flag. Pressing the same flag again removes it.")
            para("Marking a reject never deletes anything. Rejects only move to the Trash when you press the trash button and confirm. Every flag change and every trash can be undone with ⌘Z.")
            para("Select many photos with ⌘-click, ⇧-click, or ⌘A, then press P or X to flag them all. Use the filter chips in the sidebar to see only Picks, Rejects, Unflagged or the Best of each burst.")
            para("RAW+JPEG pairs are treated as one photo: rejecting and trashing removes both files.")
        case .compare:
            title("Compare bursts")
            para("Select any photo that's part of a burst and press **C** (or click Compare in the toolbar). Every frame of the burst appears on one screen.")
            para("**Zoom is linked.** Pinch, ⌘/⌥ + scroll, or double-click on the bird's eye in one frame, and every frame zooms to that same spot, so you can see which one is actually sharp. Drag (or two-finger scroll) to pan them all together.")
            para("Click a frame to select it (blue outline). Use ✓ / ✗ on a frame, or P / X on the selected one. **Keep selected, reject others** picks that frame and rejects the rest of the burst in one go. ← → move between frames. Esc or Done goes back.")
            para("Bursts bigger than 12 frames show the 12 around the selected photo; use ← → to slide along.")
        case .zoom:
            title("Zoom")
            para("In the loupe (Space or double-click a photo), pinch on the trackpad with the pointer where you want to look. It zooms toward the pointer, not the middle.")
            para("Other ways: ⌘ or ⌥ + scroll, + and − keys, double-click to jump to 100% at that spot, Z to toggle 100%, ⌘0 Fit, ⌘1 100%, ⌘2 200%. Drag or two-finger scroll to pan. Esc returns to Fit.")
            para("100% uses the full-size JPEG the camera embedded in the RAW, so it's instant. It's the camera's own preview, not the raw sensor data, which is perfect for checking focus.")
        case .share:
            title("Share & upload")
            para("**Present** (⌘↩) is a full-screen slideshow straight from your RAW files. Arrow keys to navigate, Esc to exit. Show people your captures without converting anything.")
            para("**Export JPEGs** (⌘E) writes JPEG copies of the selection, sized 1600 px up to full resolution. **Share** opens the macOS share sheet. **Copy Image** (⌘C) copies the current photo.")
            para("**Google Drive** (⌘U) uploads originals or JPEG previews to a Drive folder and can copy a share link. Set it up once in Settings → Google Drive (see docs/GOOGLE_DRIVE_SETUP.md in the repo). It's the only feature that uploads anything, and only when you press Upload.")
        case .keys:
            title("Shortcuts")
            keys([("Space / Return", "Grid ⇄ Loupe"), ("← → ↑ ↓", "Move between photos"), ("P / X / U", "Pick / Reject / Clear flag"), ("1–5, 0", "Star rating, clear"),
                  ("C", "Compare this burst"), ("K", "Keep the sharpest of this burst"), ("[ ]", "Previous / next burst"), ("B", "Collapse or expand burst"),
                  ("⌘A", "Select all"), ("⌘⌫", "Move selection to Trash"), ("⌘Z", "Undo"), ("⌘O / ⇧⌘O", "Open / Add folder"), ("⌘↩", "Present"),
                  ("+ −  ⌘0 ⌘1 ⌘2", "Zoom"), ("I", "Toggle inspector"), ("?", "This help")])
        case .privacy:
            title("Privacy & updates")
            para("Your photos stay on your Mac. Keeper has no accounts, analytics or telemetry. Thumbnails are cached in ~/Library/Caches/Keeper and your flags in ~/Library/Application Support/Keeper.")
            para("Two optional features use the internet: **Google Drive upload** (only when you connect and press Upload) and **update checks** (one plain request to GitHub's public releases page, sending nothing about you). Turn updates off in Settings → General → Updates and Keeper makes no connections at all.")
            para("When a new version is out you'll see a banner with **Install & Restart**. The download is checked against GitHub's SHA-256 before it replaces the app.")
        case .faq:
            title("Troubleshooting")
            para("**A photo looks black or sideways.** Some cameras store previews differently. Please open an issue on GitHub with your camera model.")
            para("**macOS says Keeper is damaged or from an unidentified developer.** Right-click Keeper → Open → Open. Or run `xattr -dr com.apple.quarantine /Applications/Keeper.app` in Terminal. Keeper isn't notarized because that needs a paid Apple account.")
            para("**Buttons seem to do nothing.** The ✓ / ✗ flash a big stamp and update the badge on the photo. Check the filter in the sidebar isn't hiding the result.")
            para("**Where did my deleted photos go?** The macOS Trash. Undo with ⌘Z right away, or use Put Back in the Trash.")
        }
    }

    private func title(_ t: String) -> some View { Text(t).font(.system(size: 22, weight: .bold)) }
    private func para(_ t: String) -> some View {
        Text(.init(t)).font(.system(size: 13.5)).foregroundStyle(Theme.text.opacity(0.9)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    private func step(_ n: String, _ head: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.system(size: 13, weight: .bold)).frame(width: 24, height: 24).background(Circle().fill(Theme.accent.opacity(0.25))).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(head).font(.system(size: 14, weight: .semibold))
                Text(body).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func keys(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack { Text(row.0).font(.system(size: 12.5, weight: .semibold, design: .rounded)).frame(width: 150, alignment: .leading); Text(row.1).font(.system(size: 13)).foregroundStyle(Theme.textSecondary); Spacer() }
                    .padding(.vertical, 7)
                if i < rows.count - 1 { Divider().opacity(0.4) }
            }
        }
    }
}
