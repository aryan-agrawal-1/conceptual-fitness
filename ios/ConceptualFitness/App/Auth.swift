import AuthenticationServices
import Foundation
import Security
import SwiftUI
import UIKit

enum AuthState: Equatable {
    case checking
    case signedOut
    case signingIn
    case authenticated(GoogleHealthConnectionState)
    case failed(String)
}

enum GoogleHealthConnectionState: String, Decodable {
    case connected
    case disconnected
    case errored
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct AuthMeResponse: Decodable {
    let user: AuthUser
    let googleHealth: GoogleHealthStatus

    enum CodingKeys: String, CodingKey {
        case user
        case googleHealth = "google_health"
    }
}

struct AuthUser: Decodable {
    let id: String
    let email: String?
}

struct GoogleHealthStatus: Decodable {
    let status: GoogleHealthConnectionState
}

enum AuthError: Error {
    case badURL
    case badCallback
    case missingRefreshToken
    case unauthenticated
}

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var state: AuthState = .checking

    let baseURL: URL
    private let session: URLSession
    private let keychain: KeychainStore
    private let callbackScheme = "healthapp"
    private var webSession: ASWebAuthenticationSession?
    private var accessToken: String?
    private var refreshTask: Task<TokenResponse, Error>?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        session: URLSession = .shared,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.keychain = keychain
    }

    func bootstrap() async {
        guard keychain.refreshToken != nil else {
            state = .signedOut
            return
        }
        do {
            _ = try await refreshAccessToken()
            try await loadMe()
        } catch {
            keychain.clearTokens()
            accessToken = nil
            state = .signedOut
        }
    }

    func signIn() async {
        state = .signingIn
        do {
            let deviceID = keychain.deviceID
            let startURL: StartURLResponse = try await request(
                path: "/auth/google/start-url?device_id=\(Self.percentEncode(deviceID))"
            )
            guard let authURL = URL(string: startURL.authorizationURL) else {
                throw AuthError.badURL
            }
            let callbackURL = try await authenticate(with: authURL)
            let code = try authCode(from: callbackURL)
            let tokenResponse: TokenResponse = try await post(
                path: "/auth/exchange",
                body: ["code": code, "device_id": deviceID]
            )
            apply(tokenResponse)
            try await loadMe()
        } catch {
            keychain.clearTokens()
            accessToken = nil
            state = .failed("Sign in failed. Check the backend is running and try again.")
        }
    }

    func reconnectGoogleHealth() async {
        await signIn()
    }

    func signOut() async {
        let body = [
            "refresh_token": keychain.refreshToken ?? "",
            "device_id": keychain.deviceID,
        ]
        var request = try? makeRequest(path: "/auth/logout", method: "POST")
        if let accessToken {
            request?.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request?.httpBody = try? JSONEncoder().encode(body)
        request?.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let request {
            _ = try? await session.data(for: request)
        }
        keychain.clearTokens()
        accessToken = nil
        state = .signedOut
    }

    func authenticatedData(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if !Self.isUnauthorized(response) {
            try Self.validate(response)
            return data
        }

        request.setValue("Bearer \(try await refreshAccessToken().accessToken)", forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await session.data(for: request)
        try Self.validate(retryResponse)
        return retryData
    }

    private func validAccessToken() async throws -> String {
        if let accessToken {
            return accessToken
        }
        return try await refreshAccessToken().accessToken
    }

    private func refreshAccessToken() async throws -> TokenResponse {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = keychain.refreshToken else {
            throw AuthError.missingRefreshToken
        }
        let deviceID = keychain.deviceID
        let task = Task<TokenResponse, Error> {
            try await Self.postToken(
                baseURL: baseURL,
                session: session,
                path: "/auth/refresh",
                body: ["refresh_token": refreshToken, "device_id": deviceID]
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        let response = try await task.value
        apply(response)
        return response
    }

    private func apply(_ response: TokenResponse) {
        accessToken = response.accessToken
        keychain.refreshToken = response.refreshToken
    }

    private func loadMe() async throws {
        let me: AuthMeResponse = try await authenticatedRequest(path: "/auth/me")
        state = .authenticated(me.googleHealth.status)
    }

    private func authenticatedRequest<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthError.badURL
        }
        let data = try await authenticatedData(for: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthError.badURL
        }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        try await Self.postToken(baseURL: baseURL, session: session, path: path, body: body)
    }

    private static func postToken<T: Decodable>(
        baseURL: URL,
        session: URLSession,
        path: String,
        body: [String: String]
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func authenticate(with url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? AuthError.badCallback)
                }
            }
            session.presentationContextProvider = WebAuthPresentationContextProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            session.start()
        }
    }

    private func authCode(from callbackURL: URL) throws -> String {
        guard callbackURL.scheme == callbackScheme,
              callbackURL.host == "auth",
              callbackURL.path == "/callback",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw AuthError.badCallback
        }
        return code
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func isUnauthorized(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 401
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

struct StartURLResponse: Decodable {
    let authorizationURL: String

    enum CodingKeys: String, CodingKey {
        case authorizationURL = "authorization_url"
    }
}

struct AuthGateView: View {
    @ObservedObject var authStore: AuthStore

    var body: some View {
        switch authStore.state {
        case .checking:
            ProgressView()
                .task { await authStore.bootstrap() }
        case .signedOut, .failed:
            signInView
        case .signingIn:
            ProgressView("Signing in")
        case .authenticated(.connected):
            AppShellView(authStore: authStore)
        case .authenticated(.disconnected), .authenticated(.errored):
            reconnectView
        }
    }

    private var signInView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.blue)
            Text("Conceptual Fitness")
                .font(.largeTitle.weight(.bold))
            Text("Sign in to sync your Google Health data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await authStore.signIn() }
            } label: {
                Label("Continue with Google", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
        .padding(28)
    }

    private var reconnectView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.blue)
            Text("Reconnect Google Health")
                .font(.title2.weight(.bold))
            Text("Your app session is active, but Google Health is disconnected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await authStore.reconnectGoogleHealth() }
            } label: {
                Label("Reconnect Google", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Sign out") {
                Task { await authStore.signOut() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(28)
    }
}

final class WebAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

final class KeychainStore {
    private let service = "com.conceptualfitness.auth"
    private let refreshAccount = "refresh-token"
    private let deviceAccount = "device-id"

    var refreshToken: String? {
        get { read(account: refreshAccount) }
        set {
            if let newValue {
                save(newValue, account: refreshAccount)
            } else {
                delete(account: refreshAccount)
            }
        }
    }

    var deviceID: String {
        if let existing = read(account: deviceAccount) {
            return existing
        }
        let next = UUID().uuidString + "-" + UUID().uuidString
        save(next, account: deviceAccount)
        return next
    }

    func clearTokens() {
        delete(account: refreshAccount)
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
