import AppKit
import KeeperCore
import SwiftUI

/// UI-facing wrapper around `GoogleAuth` + `DriveClient`: credentials, sign-in state and the upload queue.
@MainActor @Observable
final class DriveController {
    enum Content: String, CaseIterable, Identifiable {
        case originals = "Original files", previews = "JPEG previews", both = "Both"
        var id: String { rawValue }
    }

    enum JobState: Equatable {
        case queued, uploading(Double), done, skipped, failed(String)
    }

    struct Job: Identifiable {
        let id = UUID()
        var name: String
        var state: JobState
    }

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "googleClientID"); pushCredentials() }
    }
    var clientSecret: String {
        didSet { Keychain.setString(clientSecret, account: "google-client-secret"); pushCredentials() }
    }

    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    private(set) var isUploading = false
    private(set) var jobs: [Job] = []
    private(set) var folderLink: URL?
    private(set) var finished = false
    var error: String?

    private let auth: GoogleAuth
    private let client: DriveClient
    private var uploadTask: Task<Void, Never>?

    init() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "KeeperGoogleClientID") as? String ?? ""
        let id = UserDefaults.standard.string(forKey: "googleClientID") ?? bundled
        let secret = Keychain.getString(account: "google-client-secret") ?? ""
        clientID = id
        clientSecret = secret
        let auth = GoogleAuth(credentials: GoogleCredentials(clientID: id, clientSecret: secret))
        self.auth = auth
        client = DriveClient(auth: auth)
        Task { isSignedIn = await auth.isSignedIn }
    }

    var hasCredentials: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty }
    var completed: Int { jobs.filter { [.done, .skipped].contains($0.state) }.count }
    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let sum = jobs.reduce(0.0) { acc, job in
            switch job.state {
            case .done, .skipped, .failed: acc + 1
            case .uploading(let p): acc + p
            case .queued: acc
            }
        }
        return sum / Double(jobs.count)
    }

    private func pushCredentials() {
        let creds = GoogleCredentials(clientID: clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret)
        Task { await auth.updateCredentials(creds) }
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await auth.signIn { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                isSignedIn = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func signOut() {
        Task { await auth.signOut(); isSignedIn = false }
    }

    func reset() { jobs = []; folderLink = nil; finished = false; error = nil }

    func cancel() { uploadTask?.cancel() }

    // MARK: - Upload

    private enum Source: Sendable {
        case file(URL)
        case preview(primary: URL, companion: URL?, maxPixel: Int?)
    }
    private struct Plan: Sendable { let id: UUID; let name: String; let source: Source }

    func upload(items: [PhotoItem], folderPath: String, content: Content, previewSize: Int?, shareLink: Bool) {
        guard !isUploading else { return }
        let inputs = items.map { (url: $0.url, companion: $0.companion, base: $0.baseName) }
        uploadTask = Task { await run(inputs, folderPath, content, previewSize, shareLink) }
    }

    private func run(_ inputs: [(url: URL, companion: URL?, base: String)], _ folderPath: String, _ content: Content,
                     _ previewSize: Int?, _ shareLink: Bool) async {
        isUploading = true; finished = false; error = nil; folderLink = nil; jobs = []
        defer { isUploading = false; finished = true }

        do {
            let folder = try await client.ensureFolder(path: folderPath)
            let existing = try await client.existingFileNames(in: folder.id)

            var plans: [Plan] = []
            for input in inputs {
                if content != .previews {
                    plans.append(Plan(id: UUID(), name: input.url.lastPathComponent, source: .file(input.url)))
                    if let c = input.companion { plans.append(Plan(id: UUID(), name: c.lastPathComponent, source: .file(c))) }
                }
                if content != .originals {
                    let suffix = content == .both ? "-preview" : ""
                    plans.append(Plan(id: UUID(), name: input.base + suffix + ".jpg", source: .preview(primary: input.url, companion: input.companion, maxPixel: previewSize)))
                }
            }
            // Two folders can contain the same file name (camera counters roll over): keep every name unique.
            var used = Set<String>()
            plans = plans.map { plan in
                var name = plan.name, n = 2
                let ext = (plan.name as NSString).pathExtension, stem = (plan.name as NSString).deletingPathExtension
                while !used.insert(name).inserted { name = "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"); n += 1 }
                return Plan(id: plan.id, name: name, source: plan.source)
            }
            jobs = plans.map { Job(name: $0.name, state: existing.contains($0.name) ? .skipped : .queued) }
            let todo = plans.enumerated().filter { !existing.contains($0.element.name) }

            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Keeper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }

            let client = self.client
            await withTaskGroup(of: (Int, JobState).self) { group in
                var iterator = todo.makeIterator()
                func start(_ index: Int, _ plan: Plan, _ group: inout TaskGroup<(Int, JobState)>) {
                    group.addTask { [weak self] in
                        if Task.isCancelled { return (index, .failed("Cancelled")) }
                        do {
                            var fileURL: URL
                            switch plan.source {
                            case .file(let url): fileURL = url
                            case .preview(let primary, let companion, let maxPixel):
                                fileURL = temp.appendingPathComponent(plan.name)
                                try JPEGExporter.export(primary: primary, companion: companion, to: fileURL, options: ExportOptions(source: .cameraPreview, maxPixel: maxPixel))
                            }
                            await self?.setState(index, .uploading(0))
                            let last = ProgressBox()
                            try await client.upload(fileURL: fileURL, name: plan.name, mimeType: DriveClient.mimeType(for: fileURL), folderID: folder.id) { p in
                                guard last.shouldReport(p) else { return }
                                Task { @MainActor in self?.setState(index, .uploading(p)) }
                            }
                            if case .preview = plan.source { try? FileManager.default.removeItem(at: fileURL) }
                            return (index, .done)
                        } catch {
                            return (index, .failed(error.localizedDescription))
                        }
                    }
                }
                for _ in 0 ..< 3 { if let next = iterator.next() { start(next.offset, next.element, &group) } }
                for await (index, state) in group {
                    setState(index, state)
                    if let next = iterator.next() { start(next.offset, next.element, &group) }
                }
            }

            if shareLink, !Task.isCancelled {
                try await client.makeLinkShareable(id: folder.id)
            }
            if let link = folder.webViewLink { folderLink = link } else { folderLink = try? await client.link(for: folder.id) }
            let failures = jobs.filter { if case .failed = $0.state { true } else { false } }.count
            if failures > 0 { error = "\(failures) file\(failures == 1 ? "" : "s") didn't upload. Run it again to retry only those." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setState(_ index: Int, _ state: JobState) {
        guard jobs.indices.contains(index) else { return }
        jobs[index].state = state
    }
}

/// Throttles progress callbacks to roughly every 2%.
private final class ProgressBox: @unchecked Sendable {
    private var last = -1.0
    private let lock = NSLock()
    func shouldReport(_ p: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if p - last >= 0.02 || p >= 1 { last = p; return true }
        return false
    }
}
