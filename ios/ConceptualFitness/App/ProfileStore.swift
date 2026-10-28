import OSLog
import SwiftUI

private struct ProfileUnitsKey: EnvironmentKey {
    static let defaultValue = ProfileUnits.metric
}

extension EnvironmentValues {
    var profileUnits: ProfileUnits {
        get { self[ProfileUnitsKey.self] }
        set { self[ProfileUnitsKey.self] = newValue }
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: AccountProfile?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var revision = 0
    let authStore: AuthStore
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Profile")

    init(authStore: AuthStore) { self.authStore = authStore }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let startedRevision = revision
        do {
            let response: AccountProfile = try await authStore.authenticatedRequest(path: "/profile")
            guard !Task.isCancelled, startedRevision == revision else { return }
            profile = response
            loadError = nil
        } catch {
            guard !Task.isCancelled, startedRevision == revision else { return }
            loadError = "Your profile couldn’t load. Check your connection and try again."
            logFailure("load", error: error)
        }
    }

    func update(_ fields: [String: ProfileValue]) async throws {
        let response: AccountProfile = try await authStore.authenticatedJSON(path: "/profile", method: "PATCH", body: fields)
        revision += 1
        profile = response
        loadError = nil
    }

    func logFailure(_ operation: String, error: Error) {
        let status = (error as? HTTPResponseError)?.statusCode ?? 0
        logger.error("Profile \(operation, privacy: .public) failed; type=\(String(describing: type(of: error)), privacy: .public); status=\(status)")
    }
}
