import AppKit
import CryptoKit
import Foundation

/// Optional update checker. The ONLY thing it does online is a plain GET of GitHub's public
/// "latest release" endpoint and, if you click Install, a download of the release's .zip.
/// It sends no identifiers, no analytics, nothing about your photos. Turn it off in Settings.
@MainActor @Observable
final class UpdateService {
    static let repo = "pasinduPrabhath/keeper-raw-photo-culler"
    static let enabledKey = "checkForUpdates"

    struct Release: Equatable {
        let version: String
        let notesURL: URL
        let zipURL: URL?
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case failed(String)
    }

    var state: State = .idle
    private var dismissed: String?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// The release to show in the banner (nil once dismissed).
    var banner: Release? {
        if case .available(let r) = state, r.version != dismissed { return r }
        return nil
    }

    func dismissBanner() { if case .available(let r) = state { dismissed = r.version } }

    /// Once per launch, quietly, if enabled and at least 6 hours since the last check.
    func checkOnLaunch() async {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Keeper", forHTTPHeaderField: "User-Agent")   // GitHub requires some UA; no version or machine info
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                state = userInitiated ? .failed("No release information found.") : .idle
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: currentVersion) else { state = userInitiated ? .upToDate : .idle; return }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            var sha: String?
            if let digest = zip?["digest"] as? String, digest.hasPrefix("sha256:") { sha = String(digest.dropFirst(7)) }
            let notes = (json["html_url"] as? String).flatMap(URL.init) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
            let zipURL = (zip?["browser_download_url"] as? String).flatMap(URL.init)
            dismissed = userInitiated ? nil : dismissed
            state = .available(Release(version: version, notesURL: notes, zipURL: zipURL, sha256: sha))
        } catch {
            state = userInitiated ? .failed("Couldn't reach GitHub. You may be offline.") : .idle
        }
    }

    /// Downloads the release, replaces this app and relaunches. Falls back to the release page when it can't.
    func install(_ release: Release) async {
        let appURL = Bundle.main.bundleURL
        guard let zipURL = release.zipURL, appURL.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.notesURL); return
        }
        state = .downloading
        do {
            let (tmp, response) = try await URLSession.shared.download(from: zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
            if let expected = release.sha256 {
                let actual = try Self.sha256(of: tmp)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw UpdateError("Checksum mismatch. Update aborted.") }
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipPath = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zipPath)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path])
            let newApp = work.appendingPathComponent("Keeper.app")
            guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The downloaded app didn't look right. Update aborted.")
            }
            // Swap after this process exits, then relaunch.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(appURL.path)" && cp -R "\(newApp.path)" "\(appURL.path)" && xattr -dr com.apple.quarantine "\(appURL.path)"
            open "\(appURL.path)"
            rm -rf "\(work.path)"
            """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0 ..< max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the update.") }
    }
}
