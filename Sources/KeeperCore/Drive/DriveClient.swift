import Foundation
import UniformTypeIdentifiers

public struct DriveFolder: Sendable, Equatable {
    public let id: String
    public let name: String
    public let webViewLink: URL?
}

/// A small Google Drive v3 client: folders, resumable uploads, link sharing.
public actor DriveClient {
    private let auth: GoogleAuth
    private let session: URLSession
    private static let api = "https://www.googleapis.com/drive/v3"
    private static let upload = "https://www.googleapis.com/upload/drive/v3/files"

    public init(auth: GoogleAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - Folders

    /// Finds or creates a nested folder path such as `"Wildlife/2026-11-07 Yala"` and returns the leaf.
    public func ensureFolder(path: String) async throws -> DriveFolder {
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var parent = "root"
        var leaf = DriveFolder(id: "root", name: "My Drive", webViewLink: nil)
        for name in parts {
            let query = "mimeType='application/vnd.google-apps.folder' and name='\(Self.escape(name))' and '\(parent)' in parents and trashed=false"
            let listing = try await json(.get, "/files", query: ["q": query, "fields": "files(id,name,webViewLink)", "pageSize": "10"])
            if let first = (listing["files"] as? [[String: Any]])?.first, let id = first["id"] as? String {
                leaf = DriveFolder(id: id, name: name, webViewLink: (first["webViewLink"] as? String).flatMap(URL.init))
            } else {
                let created = try await json(.post, "/files", query: ["fields": "id,name,webViewLink"],
                                             body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent]])
                guard let id = created["id"] as? String else { throw DriveError.invalidResponse }
                leaf = DriveFolder(id: id, name: name, webViewLink: (created["webViewLink"] as? String).flatMap(URL.init))
            }
            parent = leaf.id
        }
        return leaf
    }

    /// Names already inside a folder, so re-running an upload skips what's there.
    public func existingFileNames(in folderID: String) async throws -> Set<String> {
        var names = Set<String>()
        var token: String?
        repeat {
            var query = ["q": "'\(folderID)' in parents and trashed=false", "fields": "nextPageToken,files(name)", "pageSize": "1000"]
            if let token { query["pageToken"] = token }
            let page = try await json(.get, "/files", query: query)
            for file in page["files"] as? [[String: Any]] ?? [] { if let n = file["name"] as? String { names.insert(n) } }
            token = page["nextPageToken"] as? String
        } while token != nil
        return names
    }

    public func makeLinkShareable(id: String) async throws {
        _ = try await json(.post, "/files/\(id)/permissions", body: ["role": "reader", "type": "anyone"])
    }

    public func link(for id: String) async throws -> URL {
        let info = try await json(.get, "/files/\(id)", query: ["fields": "webViewLink"])
        guard let s = info["webViewLink"] as? String, let url = URL(string: s) else { throw DriveError.invalidResponse }
        return url
    }

    // MARK: - Upload

    /// Uploads one file with Drive's resumable protocol and reports 0…1 progress.
    @discardableResult
    public func upload(fileURL: URL, name: String, mimeType: String, folderID: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let size = (try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // 1. Start a resumable session.
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID]])
        let (_, started) = try await perform {
            var r = URLRequest(url: URL(string: "\(Self.upload)?uploadType=resumable&fields=id")!)
            r.httpMethod = "POST"
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            r.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            r.httpBody = metadata
            return r
        }
        guard let location = started.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw DriveError.invalidResponse
        }

        // 2. Send the bytes straight from disk (no memory spike for 60 MB RAWs).
        let delegate = ProgressDelegate(handler: progress)
        let (data, _) = try await perform(file: fileURL, delegate: delegate) {
            var r = URLRequest(url: sessionURL)
            r.httpMethod = "PUT"
            r.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            return r
        }
        progress(1)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String else {
            throw DriveError.invalidResponse
        }
        return id
    }

    public static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    // MARK: - Plumbing

    enum Method: String { case get = "GET", post = "POST" }

    private func json(_ method: Method, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(string: Self.api + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let url = comps.url!
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, _) = try await perform {
            var r = URLRequest(url: url)
            r.httpMethod = method.rawValue
            if let payload {
                r.httpBody = payload
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return r
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Sends a request with a bearer token; refreshes once on 401 and backs off on 429/5xx/network errors.
    private func perform(file: URL? = nil, delegate: URLSessionTaskDelegate? = nil,
                         _ make: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var request = make()
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await {
                    if let file { return try await session.upload(for: request, fromFile: file, delegate: delegate) }
                    return try await session.data(for: request, delegate: delegate)
                }()
                guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
                if http.statusCode == 401, attempt == 0 {
                    await auth.invalidateAccessToken()
                    attempt += 1
                    continue
                }
                if http.statusCode == 429 || http.statusCode >= 500, attempt < 4 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 400_000_000))
                    continue
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw DriveError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
                return (data, http)
            } catch let error as URLError where error.code != .cancelled && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 400_000_000))
            }
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(Double(totalBytesSent) / Double(max(1, totalBytesExpectedToSend)))
    }
}
