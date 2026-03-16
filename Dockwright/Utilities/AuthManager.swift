import Foundation
import CryptoKit
import AuthenticationServices
import AppKit
import Observation
import Network
import Security
import os

/// Handles OAuth sign-in flows for Claude (Anthropic) and OpenAI, plus API key fallback.
/// Claude uses OAuth 2.0 + PKCE (same flow as Claude Code CLI).
/// OpenAI uses OAuth 2.0 + PKCE with a localhost callback server (same flow as Codex CLI).
@Observable
final class AuthManager: NSObject, @unchecked Sendable {
    var isSigningIn = false
    var signInError: String?
    var oauthCodePrompt = false
    /// Bumped on every Keychain mutation so SwiftUI re-renders computed key state.
    private(set) var keychainVersion = 0

    // MARK: - OAuth Constants

    private let claudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let claudeAuthorizeURL = "https://claude.ai/oauth/authorize"
    private let claudeTokenURL = "https://console.anthropic.com/v1/oauth/token"
    private let claudeRedirectURI = "https://console.anthropic.com/oauth/code/callback"
    private let claudeScopes = "org:create_api_key user:profile user:inference"

    private let openaiClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let openaiAuthorizeURL = "https://auth.openai.com/oauth/authorize"
    private let openaiTokenURL = "https://auth.openai.com/oauth/token"
    private let openaiRedirectURI = "http://localhost:1455/auth/callback"
    private let openaiScopes = "openid profile email offline_access"
    private let openaiCallbackPort: UInt16 = 1455

    /// Maximum time (seconds) the OAuth callback listener stays alive before auto-cancelling.
    private let oauthListenerTimeout: TimeInterval = 600

    // PKCE state
    private var codeVerifier: String?
    private var oauthState: String?

    // OpenAI PKCE state
    private var openaiCodeVerifier: String?
    private var openaiOAuthState: String?
    private var callbackListener: NWListener?

    // Token exchange timeout
    private let oauthExchangeTimeout: TimeInterval = 30

    // MARK: - Token Status

    deinit {
        callbackListener?.cancel()
    }

    var isOpenAISignedIn: Bool {
        _ = keychainVersion
        return KeychainHelper.exists(key: "openai_oauth_token") || KeychainHelper.exists(key: "openai_api_key")
    }

    var isClaudeSignedIn: Bool {
        _ = keychainVersion
        return KeychainHelper.exists(key: "claude_oauth_token") || KeychainHelper.exists(key: "anthropic_api_key")
    }

    var isClaudeOAuth: Bool {
        _ = keychainVersion
        return KeychainHelper.exists(key: "claude_oauth_token")
    }

    var isOpenAIOAuth: Bool {
        _ = keychainVersion
        return KeychainHelper.exists(key: "openai_oauth_token")
    }

    var isSignedIn: Bool {
        isOpenAISignedIn || isClaudeSignedIn
    }

    // MARK: - Get Active API Key (for LLMService)

    var openaiApiKey: String {
        _ = keychainVersion
        return KeychainHelper.read(key: "openai_oauth_token")
            ?? KeychainHelper.read(key: "openai_api_key")
            ?? ""
    }

    var anthropicApiKey: String {
        _ = keychainVersion
        // 1. Prefer a real API key (sk-ant-api...)
        if let key = KeychainHelper.read(key: "anthropic_api_key"), !key.isEmpty {
            return key
        }
        // 2. Try fresh OAuth token from Claude Code's keychain
        if let freshToken = Self.readFreshClaudeCodeOAuthToken() {
            return freshToken
        }
        // 3. Fall back to previously-imported OAuth token
        if let oauth = KeychainHelper.read(key: "claude_oauth_token"), !oauth.isEmpty {
            return oauth
        }
        return ""
    }

    // MARK: - Save API Keys (manual entry)

    func saveOpenAIKey(_ key: String) {
        KeychainHelper.save(key: "openai_api_key", value: key)
        keychainVersion += 1
    }

    func saveAnthropicKey(_ key: String) {
        KeychainHelper.save(key: "anthropic_api_key", value: key)
        keychainVersion += 1
    }

    // MARK: - Import Claude Code Token

    func importClaudeCodeTokenIfNeeded() {
        if KeychainHelper.exists(key: "claude_oauth_token") {
            AppLog.security.debug("Claude OAuth token already in keychain -- skipping import")
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let rawStr = String(data: data, encoding: .utf8) else {
            AppLog.security.debug("No Claude Code credentials found in keychain (status: \(status))")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(rawStr.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              accessToken.hasPrefix("sk-ant-oat") else {
            AppLog.security.warning("Claude Code credentials exist but couldn't parse OAuth token")
            return
        }

        KeychainHelper.save(key: "claude_oauth_token", value: accessToken)
        if let refreshToken = oauth["refreshToken"] as? String {
            KeychainHelper.save(key: "claude_refresh_token", value: refreshToken)
        }
        if let expiresAtMs = oauth["expiresAt"] as? Double {
            let expiresAtSec = Int(expiresAtMs / 1000)
            KeychainHelper.save(key: "claude_token_expires", value: "\(expiresAtSec)")
        }
        keychainVersion += 1
        AppLog.security.info("Imported Claude OAuth token from Claude Code keychain")
    }

    /// Reads the current OAuth access token directly from Claude Code's keychain.
    /// Cached for 120s to avoid blocking on SecItemCopyMatching.
    private static let _oauthCacheLock = NSLock()
    private static nonisolated(unsafe) var _cachedOAuthToken: String?
    private static nonisolated(unsafe) var _cachedOAuthExpiry: Date = .distantPast
    private static nonisolated(unsafe) var _oauthFetchInProgress = false

    static func readFreshClaudeCodeOAuthToken() -> String? {
        let now = Date()
        let cached = _oauthCacheLock.withLock { () -> String? in
            if now.timeIntervalSince(_cachedOAuthExpiry) < 120, let t = _cachedOAuthToken {
                return t
            }
            return nil
        }
        if let cached { return cached }

        let shouldFetch = _oauthCacheLock.withLock { () -> Bool in
            if _oauthFetchInProgress { return false }
            _oauthFetchInProgress = true
            return true
        }
        guard shouldFetch else {
            return _oauthCacheLock.withLock { _cachedOAuthToken }
        }
        defer { _oauthCacheLock.withLock { _oauthFetchInProgress = false } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        guard let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawStr.isEmpty else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(rawStr.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
              accessToken.hasPrefix("sk-ant-oat") else {
            return nil
        }
        // Check expiry
        if let expiresAtMs = oauth["expiresAt"] as? Double {
            let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            if expiresAt < Date() {
                Self.triggerBackgroundTokenRefresh()
                return nil
            }
        }
        _oauthCacheLock.withLock {
            _cachedOAuthToken = accessToken
            _cachedOAuthExpiry = now
        }
        return accessToken
    }

    static func invalidateOAuthCache() {
        _oauthCacheLock.withLock { _cachedOAuthToken = nil; _cachedOAuthExpiry = .distantPast }
    }

    // MARK: - Proactive Token Sync

    private static let _refreshLock = NSLock()
    private static nonisolated(unsafe) var _tokenSyncTimer: Timer?
    private static let tokenSyncInterval: TimeInterval = 300  // 5 minutes

    @MainActor static func startProactiveTokenSync() {
        _refreshLock.withLock {
            _tokenSyncTimer?.invalidate()
            _tokenSyncTimer = Timer.scheduledTimer(withTimeInterval: tokenSyncInterval, repeats: true) { _ in
                Self.syncTokenFromKeychain()
            }
        }
        DispatchQueue.global(qos: .utility).async { Self.syncTokenFromKeychain() }
    }

    static func stopProactiveTokenSync() {
        _refreshLock.withLock { _tokenSyncTimer?.invalidate(); _tokenSyncTimer = nil }
    }

    private static func syncTokenFromKeychain() {
        let currentKey = KeychainHelper.read(key: "anthropic_api_key") ?? ""
        if !currentKey.isEmpty && !currentKey.hasPrefix("sk-ant-oat") {
            return  // User has a real API key, don't overwrite
        }
        invalidateOAuthCache()
        guard let freshToken = readFreshClaudeCodeOAuthToken() else { return }
        KeychainHelper.save(key: "anthropic_api_key", value: freshToken)
        AppLog.security.info("[OAuth] Token sync: imported token from Claude Code")
    }

    private static func triggerBackgroundTokenRefresh() {
        DispatchQueue.global(qos: .utility).async { syncTokenFromKeychain() }
    }

    // MARK: - Claude OAuth Sign In (Step 1: Open Browser)

    func signInWithClaude() {
        signInError = nil

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        self.codeVerifier = verifier
        self.oauthState = state

        guard var components = URLComponents(string: claudeAuthorizeURL) else {
            signInError = "Invalid Claude authorization URL"
            return
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: claudeClientId),
            URLQueryItem(name: "redirect_uri", value: claudeRedirectURI),
            URLQueryItem(name: "scope", value: claudeScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code", value: "true"),
        ]

        guard let url = components.url else {
            signInError = "Failed to build authorization URL"
            return
        }

        NSWorkspace.shared.open(url)
        oauthCodePrompt = true
    }

    // MARK: - Claude OAuth Sign In (Step 2: Exchange Code)

    func exchangeClaudeCode(_ code: String) async {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            signInError = "Please paste the authorization code"
            return
        }

        guard let verifier = codeVerifier else {
            signInError = "OAuth session expired. Please start sign-in again."
            return
        }

        let parts = trimmedCode.split(separator: "#", maxSplits: 1)
        guard let firstPart = parts.first else {
            signInError = "Invalid authorization code format"
            return
        }
        let authCode = String(firstPart)
        let returnedState = parts.count > 1 ? String(parts[1]) : nil

        isSigningIn = true
        signInError = nil

        do {
            var params: [(String, String)] = [
                ("grant_type", "authorization_code"),
                ("code", authCode),
                ("client_id", claudeClientId),
                ("redirect_uri", claudeRedirectURI),
                ("code_verifier", verifier),
            ]
            if let state = returnedState {
                params.append(("state", state))
            }

            let formBody = params
                .map { "\($0.0)=\(formURLEncode($0.1))" }
                .joined(separator: "&")

            guard let tokenURL = URL(string: claudeTokenURL) else {
                throw DockwrightOAuthError.tokenExchangeFailed("Invalid token URL")
            }
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody.data(using: .utf8)
            request.timeoutInterval = oauthExchangeTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DockwrightOAuthError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw DockwrightOAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(errorBody.prefix(200)))")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DockwrightOAuthError.invalidResponse
            }
            guard let accessToken = json["access_token"] as? String else {
                let errMsg = (json["error_description"] ?? json["error"] ?? "No access token") as? String ?? "Token exchange failed"
                throw DockwrightOAuthError.tokenExchangeFailed(errMsg)
            }

            let refreshToken = json["refresh_token"] as? String
            let expiresIn = json["expires_in"] as? Int ?? 28800

            KeychainHelper.save(key: "claude_oauth_token", value: accessToken)
            if let refresh = refreshToken {
                KeychainHelper.save(key: "claude_refresh_token", value: refresh)
            }
            let expiresAt = Date().addingTimeInterval(Double(expiresIn))
            KeychainHelper.save(key: "claude_token_expires", value: "\(Int(expiresAt.timeIntervalSince1970))")
            keychainVersion += 1

            codeVerifier = nil
            oauthState = nil
            oauthCodePrompt = false
            isSigningIn = false

        } catch {
            isSigningIn = false
            signInError = error.localizedDescription
        }
    }

    // MARK: - Token Refresh

    private func refreshToken(provider: String, refreshToken: String, tokenURL: String, clientId: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        let params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
        ]

        let formBody = params
            .map { "\($0.0)=\(formURLEncode($0.1))" }
            .joined(separator: "&")

        guard let url = URL(string: tokenURL) else {
            throw DockwrightOAuthError.refreshFailed("Invalid \(provider) token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody.data(using: .utf8)
        request.timeoutInterval = oauthExchangeTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpStatus == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw DockwrightOAuthError.refreshFailed("\(provider) token refresh failed -- HTTP \(httpStatus): \(body)")
        }

        return (
            accessToken: newAccessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: json["expires_in"] as? Int
        )
    }

    @discardableResult
    func refreshClaudeTokenIfNeeded() async -> Bool {
        guard let expiresStr = KeychainHelper.read(key: "claude_token_expires"),
              let expiresEpoch = Int(expiresStr),
              let storedRefreshToken = KeychainHelper.read(key: "claude_refresh_token") else {
            return false
        }

        let expiresAt = Date(timeIntervalSince1970: Double(expiresEpoch))
        let buffer: TimeInterval = 600

        guard Date().addingTimeInterval(buffer) >= expiresAt else {
            return true
        }

        do {
            let result = try await refreshToken(
                provider: "Claude",
                refreshToken: storedRefreshToken,
                tokenURL: claudeTokenURL,
                clientId: claudeClientId
            )

            KeychainHelper.save(key: "claude_oauth_token", value: result.accessToken)
            if let newRefresh = result.refreshToken {
                KeychainHelper.save(key: "claude_refresh_token", value: newRefresh)
            }
            let newExpiresIn = result.expiresIn ?? 28800
            let newExpiresAt = Date().addingTimeInterval(Double(newExpiresIn))
            KeychainHelper.save(key: "claude_token_expires", value: "\(Int(newExpiresAt.timeIntervalSince1970))")
            keychainVersion += 1
            return true
        } catch {
            return false
        }
    }

    // MARK: - OpenAI OAuth Sign In

    func signInWithOpenAI() {
        signInError = nil

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        openaiCodeVerifier = verifier
        openaiOAuthState = state

        startCallbackServer()

        guard var components = URLComponents(string: openaiAuthorizeURL) else {
            signInError = "Invalid OpenAI authorization URL"
            stopCallbackServer()
            return
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: openaiClientId),
            URLQueryItem(name: "redirect_uri", value: openaiRedirectURI),
            URLQueryItem(name: "scope", value: openaiScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components.url else {
            signInError = "Failed to build OpenAI authorization URL"
            stopCallbackServer()
            return
        }

        isSigningIn = true
        NSWorkspace.shared.open(url)
    }

    // MARK: - OpenAI Localhost Callback Server

    private func startCallbackServer() {
        stopCallbackServer()

        do {
            guard let port = NWEndpoint.Port(rawValue: openaiCallbackPort) else {
                signInError = "Invalid callback port \(openaiCallbackPort)"
                isSigningIn = false
                return
            }
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        self?.signInError = "Callback server failed: \(error.localizedDescription)"
                        self?.isSigningIn = false
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleCallbackConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.callbackListener = listener

            DispatchQueue.main.asyncAfter(deadline: .now() + oauthListenerTimeout) { [weak self] in
                guard let self, self.callbackListener != nil, self.isSigningIn else { return }
                self.stopCallbackServer()
                self.isSigningIn = false
                self.signInError = "OAuth sign-in timed out. Please try again."
            }
        } catch {
            signInError = "Could not start callback server on port \(openaiCallbackPort): \(error.localizedDescription)"
            isSigningIn = false
        }
    }

    private func stopCallbackServer() {
        callbackListener?.cancel()
        callbackListener = nil
    }

    private func handleCallbackConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self,
                  let data = data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            guard let firstLine = request.components(separatedBy: "\r\n").first,
                  let path = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: String(path)),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                let errorHtml = "<html><body><h2>Error</h2><p>No authorization code received.</p></body></html>"
                self.sendHTTPResponse(connection: connection, html: errorHtml)
                return
            }

            if let receivedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
               receivedState != self.openaiOAuthState {
                let errorHtml = "<html><body><h2>Error</h2><p>Invalid state parameter. Please try again.</p></body></html>"
                self.sendHTTPResponse(connection: connection, html: errorHtml)
                return
            }

            let successHtml = """
            <html><head><style>
            body { font-family: -apple-system, system-ui; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #0a0a0a; color: #fff; }
            .card { text-align: center; padding: 40px; border-radius: 16px; background: #1a1a2e; }
            h2 { color: #10B981; margin-bottom: 8px; }
            p { color: #888; }
            </style></head><body>
            <div class="card">
            <h2>Connected to Dockwright!</h2>
            <p>You can close this tab and return to the app.</p>
            </div>
            </body></html>
            """
            self.sendHTTPResponse(connection: connection, html: successHtml)

            DispatchQueue.main.async { [weak self] in
                self?.stopCallbackServer()
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { [weak self] in
                        await self?.exchangeOpenAICode(code)
                    }
                }
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, html: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - OpenAI Token Exchange

    func exchangeOpenAICode(_ code: String) async {
        guard let verifier = openaiCodeVerifier else {
            signInError = "OpenAI OAuth session expired. Please try again."
            isSigningIn = false
            return
        }

        do {
            let params: [(String, String)] = [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", openaiClientId),
                ("redirect_uri", openaiRedirectURI),
                ("code_verifier", verifier),
            ]

            let formBody = params
                .map { "\($0.0)=\(formURLEncode($0.1))" }
                .joined(separator: "&")

            guard let tokenURL = URL(string: openaiTokenURL) else {
                throw DockwrightOAuthError.tokenExchangeFailed("Invalid token URL")
            }
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody.data(using: .utf8)
            request.timeoutInterval = oauthExchangeTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DockwrightOAuthError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw DockwrightOAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(errorBody.prefix(300)))")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DockwrightOAuthError.invalidResponse
            }
            guard let accessToken = json["access_token"] as? String else {
                let errMsg = (json["error_description"] ?? json["error"] ?? "No access token") as? String ?? "Token exchange failed"
                throw DockwrightOAuthError.tokenExchangeFailed(errMsg)
            }

            let refreshToken = json["refresh_token"] as? String
            let expiresIn = json["expires_in"] as? Int ?? 3600

            KeychainHelper.save(key: "openai_oauth_token", value: accessToken)
            if let refresh = refreshToken {
                KeychainHelper.save(key: "openai_refresh_token", value: refresh)
            }
            let expiresAt = Date().addingTimeInterval(Double(expiresIn))
            KeychainHelper.save(key: "openai_token_expires", value: "\(Int(expiresAt.timeIntervalSince1970))")
            keychainVersion += 1

            openaiCodeVerifier = nil
            openaiOAuthState = nil
            isSigningIn = false

        } catch {
            isSigningIn = false
            signInError = error.localizedDescription
        }
    }

    // MARK: - OpenAI Token Refresh

    @discardableResult
    func refreshOpenAITokenIfNeeded() async -> Bool {
        guard let expiresStr = KeychainHelper.read(key: "openai_token_expires"),
              let expiresEpoch = Int(expiresStr),
              let storedRefreshToken = KeychainHelper.read(key: "openai_refresh_token") else {
            return false
        }

        let expiresAt = Date(timeIntervalSince1970: Double(expiresEpoch))
        let buffer: TimeInterval = 300

        guard Date().addingTimeInterval(buffer) >= expiresAt else {
            return true
        }

        do {
            let result = try await refreshToken(
                provider: "OpenAI",
                refreshToken: storedRefreshToken,
                tokenURL: openaiTokenURL,
                clientId: openaiClientId
            )

            KeychainHelper.save(key: "openai_oauth_token", value: result.accessToken)
            if let newRefresh = result.refreshToken {
                KeychainHelper.save(key: "openai_refresh_token", value: newRefresh)
            }
            let newExpiresIn = result.expiresIn ?? 3600
            let newExpiresAt = Date().addingTimeInterval(Double(newExpiresIn))
            KeychainHelper.save(key: "openai_token_expires", value: "\(Int(newExpiresAt.timeIntervalSince1970))")
            keychainVersion += 1
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sign Out

    func signOutOpenAI() {
        KeychainHelper.delete(key: "openai_oauth_token")
        KeychainHelper.delete(key: "openai_refresh_token")
        KeychainHelper.delete(key: "openai_token_expires")
        KeychainHelper.delete(key: "openai_api_key")
        stopCallbackServer()
        keychainVersion += 1
    }

    func signOutClaude() {
        KeychainHelper.delete(key: "claude_oauth_token")
        KeychainHelper.delete(key: "claude_refresh_token")
        KeychainHelper.delete(key: "claude_token_expires")
        KeychainHelper.delete(key: "anthropic_api_key")
        codeVerifier = nil
        oauthState = nil
        oauthCodePrompt = false
        keychainVersion += 1
    }

    func signOutAll() {
        signOutOpenAI()
        signOutClaude()
    }

    // MARK: - Form URL Encoding

    private func formURLEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Base64URL Encoding

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth Errors

enum DockwrightOAuthError: Error, LocalizedError {
    case invalidResponse
    case tokenExchangeFailed(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from authorization server"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed(let msg): return "Token refresh failed: \(msg)"
        }
    }
}
