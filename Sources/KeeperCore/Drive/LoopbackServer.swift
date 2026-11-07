import Foundation
import Network

/// A one-shot HTTP server on 127.0.0.1 that catches Google's OAuth redirect.
public final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.keeper.loopback")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var requestContinuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port the OS picked.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port?.rawValue { self.readyContinuation?.resume(returning: port) }
                        self.readyContinuation = nil
                    case .failed(let error):
                        self.readyContinuation?.resume(throwing: error)
                        self.readyContinuation = nil
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the browser to hit the redirect URL and returns its query parameters.
    public func nextRequest(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pending {
                    self.pending = nil
                    continuation.resume(with: pending)
                    return
                }
                self.requestContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        }
    }

    public func stop() { queue.async { self.listener.cancel() } }

    private func finish(_ result: Result<[String: String], Error>) {
        if let continuation = requestContinuation {
            requestContinuation = nil
            continuation.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            // Ignore stray requests such as /favicon.ico.
            guard params["code"] != nil || params["error"] != nil else {
                self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            let ok = params["error"] == nil
            self.respond(connection, status: "200 OK", body: Self.page(success: ok))
            self.finish(.success(params))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're connected" : "Sign-in was cancelled"
        let text = success ? "Keeper can now upload to your Google Drive. You can close this tab." : "Nothing was changed. You can close this tab and try again."
        return """
        <!doctype html><meta charset="utf-8"><title>Keeper</title>
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#0e0f12;color:#f2f3f5;font:16px -apple-system,BlinkMacSystemFont,sans-serif">
        <div style="text-align:center"><div style="font-size:44px">\(success ? "✓" : "–")</div>
        <h1 style="font-weight:600;margin:.4em 0 .2em">\(title)</h1><p style="color:#9aa0aa">\(text)</p></div></body>
        """
    }
}
