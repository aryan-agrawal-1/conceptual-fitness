import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import UserNotifications

enum AuthState: Equatable {
    case checking
    case signedOut
    case signingIn
    case authenticated(AuthSession)
    case deletionScheduled(Date, String?)
    case failed(String)
}

enum GoogleHealthConnectionState: String, Decodable, Equatable {
    case connected
    case disconnected
    case errored
}

struct AuthSession: Decodable, Equatable {
    let user: AuthUser
    let googleHealth: GoogleHealthStatus
    let profile: AuthProfileStatus

    enum CodingKeys: String, CodingKey {
        case user
        case googleHealth = "google_health"
        case profile
    }
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
    let profile: AuthProfileStatus

    enum CodingKeys: String, CodingKey {
        case user
        case googleHealth = "google_health"
        case profile
    }

    var session: AuthSession {
        AuthSession(user: user, googleHealth: googleHealth, profile: profile)
    }
}

struct AuthUser: Decodable, Equatable {
    let id: String
    let email: String?
    let firstName: String?
    let lastName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct GoogleHealthStatus: Decodable, Equatable {
    let status: GoogleHealthConnectionState
    let connectedAt: String?
    let lastSyncAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case status
        case connectedAt = "connected_at"
        case lastSyncAt = "last_sync_at"
        case lastError = "last_error"
    }
}

struct AuthProfileStatus: Decodable, Equatable {
    let onboardingCompletedAt: String?
    let weatherEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case onboardingCompletedAt = "onboarding_completed_at"
        case weatherEnabled = "weather_enabled"
    }
}

private struct NameUpdateRequest: Encodable {
    let firstName: String
    let lastName: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

enum AuthError: Error {
    case badURL
    case badCallback
    case missingRefreshToken
    case unauthenticated
}

enum SensitiveActionError: LocalizedError {
    case cancelled
    case secureEnclaveUnavailable
    case authenticationUnavailable
    case signingKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            nil
        case .secureEnclaveUnavailable:
            "Face ID or device passcode confirmation requires a physical device with Secure Enclave support."
        case .authenticationUnavailable:
            "Face ID or device passcode is unavailable. Check your device security settings and try again."
        case .signingKeyUnavailable:
            "This device’s protected signing key is unavailable. Sign in again to reconnect this device."
        }
    }
}

private struct HTTPResponseError: Error {
    let statusCode: Int
    let code: String?
}

enum SensitiveActionPurpose: String {
    case export
    case deleteAccount = "delete_account"
    case recoverDeletion = "recover_deletion"
    case enrollDevice = "enroll_device"
}

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var state: AuthState = .checking

    let baseURL: URL
    var sensitiveActionDeviceID: String { keychain.deviceID }
    private let session: URLSession
    private let keychain: KeychainStore
    private let signingKeys: DeviceSigningKeyStore
    private let callbackScheme = "healthapp"
    private var webSession: ASWebAuthenticationSession?
    private var accessToken: String?
    private var refreshTask: Task<TokenResponse, Error>?
    private static let deletionDeadlineKey = "accountDeletion.scheduledFor"

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        session: URLSession = .shared,
        keychain: KeychainStore = KeychainStore(),
        signingKeys: DeviceSigningKeyStore = DeviceSigningKeyStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.keychain = keychain
        self.signingKeys = signingKeys
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-FitnessTestSession") {
            accessToken = ProcessInfo.processInfo.environment["FITNESS_TEST_ACCESS_TOKEN"]
        }
        #endif
    }

    func bootstrap() async {
        if let deadline = UserDefaults.standard.object(forKey: Self.deletionDeadlineKey) as? Date {
            state = .deletionScheduled(deadline, nil)
            return
        }
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
        let previousState = state
        let hadSession = keychain.refreshToken != nil
        if !hadSession { state = .signingIn }
        do {
            let deviceID = keychain.deviceID
            let canEnrollDevice = signingKeys.enrollmentAvailabilityError() == nil
            var query = ["device_id": deviceID]
            if canEnrollDevice {
                query["device_public_key"] = try signingKeys.publicKeyBase64()
            }
            let startURL: StartURLResponse = try await request(
                path: try Self.path(
                    "/auth/google/start-url",
                    query: query
                )
            )
            guard let authURL = URL(string: startURL.authorizationURL) else {
                throw AuthError.badURL
            }
            let callbackURL = try await authenticate(with: authURL)
            let code = try authCode(from: callbackURL)
            var body = ["code": code, "device_id": deviceID]
            if canEnrollDevice {
                body["signature"] = try await signingKeys.signatureBase64(
                    for: Self.transcript("auth-code-exchange", code, deviceID),
                    reason: "Confirm signing in to Conceptual Fitness"
                )
            }
            let tokenResponse: TokenResponse = try await post(
                path: "/auth/exchange",
                body: body
            )
            apply(tokenResponse)
            try await loadMe()
        } catch {
            if hadSession {
                state = previousState
            } else if Self.isCancellation(error) {
                state = .signedOut
            } else {
                state = .failed(Self.message(for: error, fallback: "Sign in failed. Check the backend is running and try again."))
            }
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
        let request = URLRequest(url: url)
        return try await authenticatedData(for: request)
    }

    func authenticatedData(for request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if !Self.isUnauthorized(response) {
            try Self.validate(response, data: data)
            return data
        }

        request.setValue("Bearer \(try await refreshAccessToken().accessToken)", forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await session.data(for: request)
        try Self.validate(retryResponse, data: retryData)
        return retryData
    }

    func authenticatedDownload(for request: URLRequest) async throws -> (URL, URLResponse) {
        var request = request
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (url, response) = try await session.download(for: request)
        if !Self.isUnauthorized(response) {
            try Self.validate(response)
            return (url, response)
        }

        request.setValue("Bearer \(try await refreshAccessToken().accessToken)", forHTTPHeaderField: "Authorization")
        let (retryURL, retryResponse) = try await session.download(for: request)
        try Self.validate(retryResponse)
        return (retryURL, retryResponse)
    }

    func authenticatedRequest<T: Decodable>(path: String) async throws -> T {
        var request = try makeRequest(path: path, method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await authenticatedData(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func authenticatedJSON<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> T {
        var request = try makeRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await authenticatedData(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func refreshSession() async throws -> AuthSession {
        try await loadMe()
    }

    func updateName(firstName: String, lastName: String?) async throws {
        let response: AuthMeResponse = try await authenticatedJSON(
            path: "/auth/me",
            method: "PATCH",
            body: NameUpdateRequest(firstName: firstName, lastName: lastName)
        )
        state = .authenticated(response.session)
    }

    func sensitiveActionGrant(for purpose: SensitiveActionPurpose) async throws -> String {
        guard purpose == .export || purpose == .deleteAccount else {
            throw AuthError.badCallback
        }
        do {
            return try await authorizeSensitiveAction(purpose)
        } catch let error as HTTPResponseError
            where error.statusCode == 409 && error.code == "device_key_enrollment_required" {
            try await enrollCurrentDevice()
            return try await authorizeSensitiveAction(purpose)
        } catch {
            if Self.isCancellation(error) { throw SensitiveActionError.cancelled }
            throw error
        }
    }

    func completeDeletionScheduling(userID: String, scheduledFor: Date) {
        clearLocalData(userID: userID)
        keychain.clearTokens()
        signingKeys.deleteKey()
        accessToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        UserDefaults.standard.set(scheduledFor, forKey: Self.deletionDeadlineKey)
        state = .deletionScheduled(scheduledFor, nil)
    }

    func restoreDeletedAccount() async {
        let savedDeadline = UserDefaults.standard.object(forKey: Self.deletionDeadlineKey) as? Date
        state = .signingIn
        do {
            if let error = signingKeys.enrollmentAvailabilityError() { throw error }
            let deviceID = keychain.deviceID
            let publicKey = try signingKeys.replaceKeyAndGetPublicKeyBase64()
            let path = try Self.path(
                "/auth/google/sensitive-start-url",
                query: [
                    "device_id": deviceID,
                    "purpose": SensitiveActionPurpose.recoverDeletion.rawValue,
                    "device_public_key": publicKey,
                ]
            )
            let start: StartURLResponse = try await request(path: path)
            guard let authURL = URL(string: start.authorizationURL) else { throw AuthError.badURL }
            let callbackURL = try await authenticate(with: authURL)
            let grant = try sensitiveActionGrant(from: callbackURL, purpose: .recoverDeletion)
            let signature = try await signingKeys.signatureBase64(
                for: Self.transcript("account-recovery", grant, deviceID),
                reason: "Confirm restoring your Conceptual Fitness account"
            )
            let response: TokenResponse = try await post(
                path: "/account/deletion/recover",
                body: [
                    "sensitive_action_grant": grant,
                    "device_id": deviceID,
                    "signature": signature,
                ]
            )
            apply(response)
            UserDefaults.standard.removeObject(forKey: Self.deletionDeadlineKey)
            try await loadMe()
        } catch {
            let message = Self.isCancellation(error)
                ? nil
                : Self.message(for: error, fallback: "Account restoration is unavailable. Confirm the same Google account was used, or the recovery period may have ended.")
            if let savedDeadline {
                state = .deletionScheduled(savedDeadline, message)
            } else {
                state = .failed(message ?? "No recoverable account was found for that Google account.")
            }
        }
    }

    private func enrollCurrentDevice() async throws {
        if let error = signingKeys.enrollmentAvailabilityError() { throw error }
        let deviceID = keychain.deviceID
        let publicKey = try signingKeys.publicKeyBase64()
        let path = try Self.path(
            "/auth/google/sensitive-start-url",
            query: [
                "device_id": deviceID,
                "purpose": SensitiveActionPurpose.enrollDevice.rawValue,
                "device_public_key": publicKey,
            ]
        )
        let start: StartURLResponse = try await authenticatedRequest(path: path)
        guard let authURL = URL(string: start.authorizationURL) else { throw AuthError.badURL }
        let callbackURL = try await authenticate(with: authURL)
        let code = try authCode(from: callbackURL)
        let signature = try await signingKeys.signatureBase64(
            for: Self.transcript("auth-code-exchange", code, deviceID),
            reason: "Confirm linking this device to your Conceptual Fitness account"
        )
        let response: TokenResponse = try await post(
            path: "/auth/exchange",
            body: ["code": code, "device_id": deviceID, "signature": signature]
        )
        apply(response)
    }

    private func authorizeSensitiveAction(_ purpose: SensitiveActionPurpose) async throws -> String {
        let challenge: DeviceChallengeResponse = try await authenticatedJSON(
            path: "/auth/device/challenge",
            method: "POST",
            body: DeviceChallengeRequest(purpose: purpose.rawValue)
        )
        let signature = try await signingKeys.signatureBase64(
            for: Self.transcript("sensitive-action", purpose.rawValue, challenge.sessionID, challenge.challenge),
            reason: purpose == .export
                ? "Confirm exporting your Conceptual Fitness data"
                : "Confirm scheduling deletion of your Conceptual Fitness account"
        )
        let authorization: DeviceAuthorizationResponse = try await authenticatedJSON(
            path: "/auth/device/authorize",
            method: "POST",
            body: DeviceAuthorizationRequest(
                purpose: purpose.rawValue,
                challenge: challenge.challenge,
                signature: signature
            )
        )
        return authorization.sensitiveActionGrant
    }

    private func clearLocalData(userID: String) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("dailyInsight.v10.") || key.hasPrefix("history") {
            defaults.removeObject(forKey: key)
        }
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let draft = applicationSupport
                .appendingPathComponent("FitnessDrafts", isDirectory: true)
                .appendingPathComponent("\(userID).json")
            try? FileManager.default.removeItem(at: draft)
        }
        if let temporaryItems = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) {
            for item in temporaryItems
                where item.lastPathComponent.hasPrefix("conceptual-fitness-export-")
                    && item.pathExtension == "zip" {
                try? FileManager.default.removeItem(at: item)
            }
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func continueAfterRecoveryPeriod() {
        UserDefaults.standard.removeObject(forKey: Self.deletionDeadlineKey)
        state = .signedOut
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

    @discardableResult
    private func loadMe() async throws -> AuthSession {
        let me: AuthMeResponse = try await authenticatedRequest(path: "/auth/me")
        state = .authenticated(me.session)
        return me.session
    }

    private func request<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthError.badURL
        }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
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
        try validate(response, data: data)
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

    private func sensitiveActionGrant(
        from callbackURL: URL,
        purpose: SensitiveActionPurpose
    ) throws -> String {
        guard callbackURL.scheme == callbackScheme,
              callbackURL.host == "auth",
              callbackURL.path == "/callback",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "status" })?.value == "authorized",
              components.queryItems?.first(where: { $0.name == "purpose" })?.value == purpose.rawValue,
              let grant = components.queryItems?.first(where: { $0.name == "grant" })?.value,
              !grant.isEmpty
        else {
            throw AuthError.badCallback
        }
        return grant
    }

    private static func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = data.flatMap { body -> String? in
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let detail = json["detail"] as? [String: Any]
                else { return nil }
                return detail["code"] as? String
            }
            throw HTTPResponseError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                code: code
            )
        }
    }

    private static func isUnauthorized(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 401
    }

    private static func path(_ path: String, query: [String: String]) throws -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let result = components.string else { throw AuthError.badURL }
        return result
    }

    private static func transcript(_ fields: String...) -> Data {
        let allFields = ["conceptual-fitness/device-proof/v1"] + fields
        return allFields.reduce(into: Data()) { result, field in
            let data = Data(field.utf8)
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(data)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if case SensitiveActionError.cancelled = error { return true }
        let error = error as NSError
        if error.domain == ASWebAuthenticationSessionError.errorDomain,
           error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            return true
        }
        return error.domain == LAError.errorDomain && [
            LAError.userCancel.rawValue,
            LAError.appCancel.rawValue,
            LAError.systemCancel.rawValue,
        ].contains(error.code)
    }

    static func sensitiveActionMessage(for error: Error, fallback: String) -> String? {
        if isCancellation(error) { return nil }
        return message(for: error, fallback: fallback)
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? SensitiveActionError)?.errorDescription ?? fallback
    }

    #if DEBUG
    func setDeletionPreview(deadline: Date) {
        state = .deletionScheduled(deadline, nil)
    }
    #endif
}

struct StartURLResponse: Decodable {
    let authorizationURL: String

    enum CodingKeys: String, CodingKey {
        case authorizationURL = "authorization_url"
    }
}

private struct DeviceChallengeRequest: Encodable {
    let purpose: String
}

private struct DeviceChallengeResponse: Decodable {
    let challenge: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case challenge
        case sessionID = "session_id"
    }
}

private struct DeviceAuthorizationRequest: Encodable {
    let purpose: String
    let challenge: String
    let signature: String
}

private struct DeviceAuthorizationResponse: Decodable {
    let sensitiveActionGrant: String

    enum CodingKeys: String, CodingKey {
        case sensitiveActionGrant = "sensitive_action_grant"
    }
}

struct AuthGateView: View {
    @ObservedObject var authStore: AuthStore

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-FitnessTestSession"),
           let userID = ProcessInfo.processInfo.environment["FITNESS_TEST_USER_ID"] {
            AppShellView(authStore: authStore, session: .fitnessTest(userID: userID))
        } else if ProcessInfo.processInfo.arguments.contains("-skipAuthForWeatherDebug") {
            AppShellView(authStore: authStore, session: .preview)
        } else {
            authContent
        }
        #else
        authContent
        #endif
    }

    @ViewBuilder
    private var authContent: some View {
        switch authStore.state {
        case .checking:
            ProgressView()
                .task { await authStore.bootstrap() }
        case .signedOut:
            signInView(errorMessage: nil)
        case .failed(let message):
            signInView(errorMessage: message)
        case .signingIn:
            ProgressView("Signing in")
        case .deletionScheduled(let deadline, let message):
            deletionScheduledView(deadline: deadline, message: message)
        case .authenticated(let session):
            if session.profile.onboardingCompletedAt != nil {
                AppShellView(authStore: authStore, session: session)
                    .id(session.user.id)
            } else if session.googleHealth.status == .connected {
                OnboardingView(authStore: authStore, session: session)
            } else {
                reconnectView
            }
        }
    }

    private func signInView(errorMessage: String?) -> some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 28) {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(.blue)
                        .symbolRenderingMode(.hierarchical)

                    Text("Conceptual Fitness")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Connect Google Health to turn your recovery, sleep, and training data into a daily dashboard.")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel("Sign-in error: \(errorMessage)")
                    }

                    Button {
                        Task { await authStore.signIn() }
                    } label: {
                        Label("Continue with Google", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Restore an account scheduled for deletion") {
                        Task { await authStore.restoreDeletedAccount() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Signs in with Google and restores the account if it is still within the 14-day recovery period")

                    Text("Your health data stays tied to your authenticated app session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(28)
        }
    }

    private func deletionScheduledView(deadline: Date, message: String?) -> some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 20) {
                Spacer()
                Image(systemName: deadline > Date() ? "clock.badge.exclamationmark" : "trash.slash")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(deadline > Date() ? .orange : .secondary)
                    .symbolRenderingMode(.hierarchical)

                Text("Account deletion scheduled")
                    .font(.title.bold())

                Text(deadline > Date()
                     ? "Your account is suspended and its app data is scheduled for permanent deletion on \(deadline.formatted(date: .long, time: .shortened))."
                     : "The scheduled deletion time has arrived. Ask the server to confirm whether restoration is still available.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Restoration error: \(message)")
                }

                Button {
                    Task { await authStore.restoreDeletedAccount() }
                } label: {
                    Label("Restore account", systemImage: "arrow.uturn.backward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Authenticate with the same Google account and ask the server to cancel deletion")

                if deadline <= Date() {
                    Button("Return to sign in") {
                        authStore.continueAfterRecoveryPeriod()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Returns to the sign-in screen to start a new account")
                }

                Spacer()
            }
            .padding(28)
        }
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

#if DEBUG
private extension AuthSession {
    static func fitnessTest(userID: String) -> AuthSession {
        AuthSession(
            user: AuthUser(
                id: userID,
                email: "fitness-test@local.invalid",
                firstName: "Test",
                lastName: "User"
            ),
            googleHealth: GoogleHealthStatus(
                status: .connected,
                connectedAt: nil,
                lastSyncAt: nil,
                lastError: nil
            ),
            profile: AuthProfileStatus(
                onboardingCompletedAt: FitnessDate.string(Date()),
                weatherEnabled: false
            )
        )
    }
}
#endif

final class WebAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

final class DeviceSigningKeyStore {
    private let tag = Data("com.conceptualfitness.device-signing-key.v1".utf8)

    func enrollmentAvailabilityError() -> SensitiveActionError? {
        guard Self.secureEnclaveAvailable else {
            return .secureEnclaveUnavailable
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .authenticationUnavailable
        }
        return nil
    }

    func publicKeyBase64() throws -> String {
        let key = try privateKey()
        guard let publicKey = SecKeyCopyPublicKey(key),
              let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              representation.count == 65,
              representation.first == 0x04
        else {
            throw SensitiveActionError.signingKeyUnavailable
        }
        return representation.base64EncodedString()
    }

    func replaceKeyAndGetPublicKeyBase64() throws -> String {
        deleteKey()
        return try publicKeyBase64()
    }

    func signatureBase64(for message: Data, reason: String) async throws -> String {
        guard Self.secureEnclaveAvailable else {
            throw SensitiveActionError.secureEnclaveUnavailable
        }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw policyError ?? SensitiveActionError.authenticationUnavailable
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw error
        }
        let key = try existingPrivateKey(authenticationContext: context)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw SensitiveActionError.signingKeyUnavailable
        }
        return signature.base64EncodedString()
    }

    func deleteKey() {
        SecItemDelete(keyQuery() as CFDictionary)
    }

    private func privateKey() throws -> SecKey {
        if let key = try? existingPrivateKey(authenticationContext: nil) {
            return key
        }
        guard Self.secureEnclaveAvailable else {
            throw SensitiveActionError.secureEnclaveUnavailable
        }
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else {
            if let accessError { throw accessError.takeRetainedValue() }
            throw SensitiveActionError.signingKeyUnavailable
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: accessControl,
            ],
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
            if let keyError { throw keyError.takeRetainedValue() }
            throw SensitiveActionError.signingKeyUnavailable
        }
        return key
    }

    private func existingPrivateKey(authenticationContext: LAContext?) throws -> SecKey {
        var query = keyQuery()
        query[kSecReturnRef as String] = true
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let key = result as! SecKey?
        else {
            throw SensitiveActionError.signingKeyUnavailable
        }
        return key
    }

    private func keyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag,
        ]
    }

    private static var secureEnclaveAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
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
