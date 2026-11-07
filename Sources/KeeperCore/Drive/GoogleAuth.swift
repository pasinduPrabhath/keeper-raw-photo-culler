import Foundation

public struct GoogleCredentials: Sendable, Equatable {
    public var clientID: String
    /// Google issues a "secret" for Desktop OAuth clients, but it is not confidential for installed apps.
    public var clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date
}

public enum DriveError: LocalizedError {
    case missingClientID
    case notSignedIn
    case authorizationFailed(String)
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Google OAuth client ID in Settings → Google Drive first."
        case .notSignedIn: "You're not signed in to Google Drive."
        case .authorizationFailed(let m): "Google sign-in failed: \(m)"
        case .http(let code, let body): "Google Drive returned HTTP \(code). \(Self.summary(body))"
        case .invalidResponse: "Google Drive sent a response Keeper couldn't understand."
        }
    }

    private static func summary(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], let message = error["message"] as? String else { return "" }
        return message
    }
}

/// OAuth 2.0 for installed apps: system browser + loopback redirect + PKCE.
/// Only the `drive.file` scope is requested, so Keeper can never see files it didn't create.
public actor GoogleAuth {
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let tokenAccount = "google-oauth-tokens"

    private var credentials: GoogleCredentials
    private var tokens: OAuthTokens?
    private let session: URLSession

    public init(credentials: GoogleCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        if let data = Keychain.get(account: Self.tokenAccount) {
            self.tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
        }
    }

    public var isSignedIn: Bool { tokens?.refreshToken != nil || (tokens?.expiry ?? .distantPast) > Date() }

    public func updateCredentials(_ new: GoogleCredentials) { credentials = new }

    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard !credentials.clientID.trimmingCharacters(in: .whitespaces).isEmpty else { throw DriveError.missingClientID }

        let server = try LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirect = "http://127.0.0.1:\(port)"
        let verifier = PKCE.randomVerifier()
        let state = PKCE.randomVerifier(length: 24)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        let params = try await server.nextRequest()
        if let error = params["error"] { throw DriveError.authorizationFailed(error) }
        guard params["state"] == state, let code = params["code"] else { throw DriveError.authorizationFailed("state mismatch") }

        var form = [
            "code": code, "client_id": credentials.clientID, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ]
        if let secret = credentials.clientSecret, !secret.isEmpty { form["client_secret"] = secret }
        let response = try await tokenRequest(form)
        guard let access = response["access_token"] as? String, let lifetime = response["expires_in"] as? Double else {
            throw DriveError.authorizationFailed((response["error_description"] as? String) ?? "no access token")
        }
        store(OAuthTokens(accessToken: access, refreshToken: response["refresh_token"] as? String, expiry: Date().addingTimeInterval(lifetime - 60)))
    }

    public func accessToken() async throws -> String {
        guard var current = tokens else { throw DriveError.notSignedIn }
        if current.expiry > Date() { return current.accessToken }
        guard let refresh = current.refreshToken else { throw DriveError.notSignedIn }

        var form = ["refresh_token": refresh, "client_id": credentials.clientID, "grant_type": "refresh_token"]
        if let secret = credentials.clientSecret, !secret.isEmpty { form["client_secret"] = secret }
        let response = try await tokenRequest(form)
        guard let access = response["access_token"] as? String, let lifetime = response["expires_in"] as? Double else {
            throw DriveError.authorizationFailed((response["error_description"] as? String) ?? "refresh failed")
        }
        current.accessToken = access
        current.expiry = Date().addingTimeInterval(lifetime - 60)
        store(current)
        return access
    }

    /// Forces the next `accessToken()` call to refresh (used after a 401).
    public func invalidateAccessToken() {
        guard var current = tokens else { return }
        current.expiry = .distantPast
        tokens = current
    }

    public func signOut() {
        tokens = nil
        Keychain.delete(account: Self.tokenAccount)
    }

    // MARK: -

    private func store(_ new: OAuthTokens) {
        var merged = new
        if merged.refreshToken == nil { merged.refreshToken = tokens?.refreshToken }   // refresh responses omit it
        tokens = merged
        if let data = try? JSONEncoder().encode(merged) { Keychain.set(data, account: Self.tokenAccount) }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DriveError.invalidResponse }
        return json
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
}
