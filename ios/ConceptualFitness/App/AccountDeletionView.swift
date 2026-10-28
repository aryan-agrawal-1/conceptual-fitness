import OSLog
import SwiftUI

struct AccountDeletionView: View {
    @ObservedObject var authStore: AuthStore
    let userID: String

    @State private var confirmation = ""
    @State private var isScheduling = false
    @State private var showFinalConfirmation = false
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: "ConceptualFitness", category: "AccountDeletion")

    init(authStore: AuthStore, userID: String) {
        self.authStore = authStore
        self.userID = userID
    }

    #if DEBUG
    init(authStore: AuthStore, userID: String, previewState: AccountDeletionPreviewState) {
        self.authStore = authStore
        self.userID = userID
        _confirmation = State(initialValue: previewState == .idle ? "" : "DELETE")
        _isScheduling = State(initialValue: previewState == .loading)
        let previewError: String? = switch previewState {
            case .error: "Account deletion couldn’t be scheduled. Check your connection and try again."
            case .hardwareUnavailable: "Face ID or device passcode confirmation requires a physical device with Secure Enclave support."
            default: nil
        }
        _errorMessage = State(initialValue: previewError)
    }
    #endif

    var body: some View {
        Form {
            Section {
                Label("14-day recovery period", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text("Scheduling deletion signs you out on every device and stops Google Health syncing immediately. During the next 14 days, your account stays suspended and inaccessible.")
                Text("You can restore it during that period by choosing Restore account and authenticating with the same Google account on any device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("What will be deleted") {
                Text("At the deadline, all data currently stored for your account is permanently erased from the app: imported health records, workouts, journal and tags, scores and baselines, profile and preferences, sessions, and Google connection credentials.")
                Text("The app has no retention exceptions. Infrastructure backups are managed separately and their retention policy is not available in the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Confirm deletion") {
                TextField("Type DELETE", text: $confirmation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Deletion confirmation")
                    .accessibilityHint("Enter the word DELETE in capital letters")

                if isScheduling {
                    HStack {
                        ProgressView()
                        Text("Confirming with Face ID or device passcode…")
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Button("Schedule account deletion", role: .destructive) {
                        showFinalConfirmation = true
                    }
                    .disabled(confirmation != "DELETE")
                    .accessibilityHint("Opens the final account deletion confirmation")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Deletion error: \(errorMessage)")
                    Button("Try again") { showFinalConfirmation = true }
                        .disabled(confirmation != "DELETE" || isScheduling)
                }
            }
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Schedule permanent deletion?",
            isPresented: $showFinalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account in 14 days", role: .destructive) {
                Task { await scheduleDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Confirm with Face ID or your device passcode. You will be signed out immediately, and can restore the account for 14 days with the same Google account.")
        }
    }

    @MainActor
    private func scheduleDeletion() async {
        guard confirmation == "DELETE", !isScheduling else { return }
        isScheduling = true
        errorMessage = nil
        defer { isScheduling = false }

        do {
            let grant = try await authStore.sensitiveActionGrant(for: .deleteAccount)
            let response: DeletionStatusResponse = try await authStore.authenticatedJSON(
                path: "/account/deletion",
                method: "POST",
                body: ScheduleDeletionBody(
                    confirmation: confirmation,
                    sensitiveActionGrant: grant,
                    deviceID: authStore.sensitiveActionDeviceID
                )
            )
            guard let scheduledFor = response.scheduledDate else {
                throw URLError(.cannotParseResponse)
            }
            authStore.completeDeletionScheduling(userID: userID, scheduledFor: scheduledFor)
        } catch {
            guard let message = AuthStore.sensitiveActionMessage(
                for: error,
                fallback: "Account deletion couldn’t be scheduled. Check your connection and try again."
            ) else { return }
            logger.error("Account deletion scheduling failed: \(String(describing: type(of: error)), privacy: .public)")
            errorMessage = message
        }
    }
}

private struct ScheduleDeletionBody: Encodable {
    let confirmation: String
    let sensitiveActionGrant: String
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case confirmation
        case sensitiveActionGrant = "sensitive_action_grant"
        case deviceID = "device_id"
    }
}

private struct DeletionStatusResponse: Decodable {
    let scheduledFor: String?

    enum CodingKeys: String, CodingKey {
        case scheduledFor = "scheduled_for"
    }

    var scheduledDate: Date? {
        guard let scheduledFor else { return nil }
        if let date = ISO8601DateFormatter().date(from: scheduledFor) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: scheduledFor)
    }
}

#if DEBUG
enum AccountDeletionPreviewState: String {
    case idle, loading, error, hardwareUnavailable, scheduled, expired

    static var current: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AccountDeletionPreview"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    @MainActor var view: AnyView {
        let authStore = AuthStore()
        switch self {
        case .idle, .loading, .error, .hardwareUnavailable:
            return AnyView(
                NavigationStack {
                    AccountDeletionView(authStore: authStore, userID: "preview", previewState: self)
                }
            )
        case .scheduled:
            authStore.setDeletionPreview(deadline: Date().addingTimeInterval(7 * 24 * 60 * 60))
            return AnyView(AuthGateView(authStore: authStore))
        case .expired:
            authStore.setDeletionPreview(deadline: Date().addingTimeInterval(-60))
            return AnyView(AuthGateView(authStore: authStore))
        }
    }
}
#endif

#Preview {
    NavigationStack {
        AccountDeletionView(authStore: AuthStore(), userID: "preview")
    }
}
