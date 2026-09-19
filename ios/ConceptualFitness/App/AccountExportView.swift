import OSLog
import SwiftUI

enum AccountExportCategory: String, CaseIterable, Encodable, Identifiable {
    case healthAndWorkouts = "health_and_workouts"
    case journal
    case derivedInsights = "derived_insights"
    case personalization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthAndWorkouts: "Health and workouts"
        case .journal: "Journal"
        case .derivedInsights: "Derived insights"
        case .personalization: "Personalization"
        }
    }

    var detail: String {
        switch self {
        case .healthAndWorkouts: "Imported health records, sleep, workouts, routines, and source details"
        case .journal: "Your daily context, tags, and journal entries"
        case .derivedInsights: "Scores, baselines, algorithm inputs, and daily briefs saved on this device"
        case .personalization: "Account details, goals, preferences, connections, and import coverage"
        }
    }
}

struct AccountExportView: View {
    let authStore: AuthStore
    let userID: String

    @State private var selected = Set(AccountExportCategory.allCases)
    @State private var isExporting = false
    @State private var archiveURL: URL?
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: "ConceptualFitness", category: "AccountExport")

    init(authStore: AuthStore, userID: String) {
        self.authStore = authStore
        self.userID = userID
    }

    #if DEBUG
    init(authStore: AuthStore, userID: String, previewState: AccountExportPreviewState) {
        self.authStore = authStore
        self.userID = userID
        _isExporting = State(initialValue: previewState == .loading)
        _archiveURL = State(
            initialValue: previewState == .success
                ? URL(fileURLWithPath: "/tmp/conceptual-fitness-export-preview.zip")
                : nil
        )
        _errorMessage = State(
            initialValue: previewState == .error
                ? "Your export couldn’t be created. Check your connection and try again."
                : nil
        )
    }
    #endif

    var body: some View {
        Form {
            Section {
                Text("Choose the data to include. You’ll confirm your Google account before the archive is created.")
                Text("The ZIP contains documented JSON files. Authentication credentials are never included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Include") {
                ForEach(AccountExportCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.title)
                            Text(category.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint(category.detail)
                }
            }

            Section {
                if isExporting {
                    HStack {
                        ProgressView()
                        Text("Creating export…")
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Button("Create export") { Task { await createExport() } }
                        .disabled(selected.isEmpty)
                }

                if selected.isEmpty {
                    Text("Select at least one category.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let archiveURL {
                    ShareLink(item: archiveURL) {
                        Label("Share export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("Opens sharing and save options for the ZIP archive")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                    Button("Try again") { Task { await createExport() } }
                        .disabled(selected.isEmpty || isExporting)
                }
            }
        }
        .navigationTitle("Export your data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for category: AccountExportCategory) -> Binding<Bool> {
        Binding(
            get: { selected.contains(category) },
            set: { enabled in
                if enabled { selected.insert(category) } else { selected.remove(category) }
                archiveURL = nil
                errorMessage = nil
            }
        )
    }

    @MainActor
    private func createExport() async {
        guard !selected.isEmpty, !isExporting else { return }
        isExporting = true
        archiveURL = nil
        errorMessage = nil
        defer { isExporting = false }
        do {
            let grant = try await authStore.sensitiveActionGrant(for: .export)
            let insights = selected.contains(.derivedInsights)
                ? DailyInsightProvider().exportedInsights(userID: userID)
                : []
            archiveURL = try await AccountExportClient(authStore: authStore).create(
                categories: selected,
                grant: grant,
                localInsights: insights
            )
        } catch is CancellationError {
        } catch {
            logger.error("Account export failed: \(String(describing: type(of: error)), privacy: .public)")
            errorMessage = "Your export couldn’t be created. Check your connection and try again."
        }
    }
}

#if DEBUG
enum AccountExportPreviewState: String {
    case idle, loading, error, success

    static var current: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AccountExportPreview"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    @MainActor var view: some View {
        NavigationStack {
            AccountExportView(authStore: AuthStore(), userID: "preview", previewState: self)
        }
    }
}
#endif

@MainActor
private struct AccountExportClient {
    let authStore: AuthStore

    func create(
        categories: Set<AccountExportCategory>,
        grant: String,
        localInsights: [DailyInsightExport]
    ) async throws -> URL {
        guard let url = URL(string: "/account/export", relativeTo: authStore.baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(
            ExportBody(
                categories: categories.sorted { $0.rawValue < $1.rawValue },
                sensitiveActionGrant: grant,
                deviceID: authStore.sensitiveActionDeviceID,
                localInsights: localInsights
            )
        )
        let (downloadURL, _) = try await authStore.authenticatedDownload(for: request)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("conceptual-fitness-export-\(Self.date.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadURL, to: destination)
        return destination
    }

    private struct ExportBody: Encodable {
        let categories: [AccountExportCategory]
        let sensitiveActionGrant: String
        let deviceID: String
        let localInsights: [DailyInsightExport]

        enum CodingKeys: String, CodingKey {
            case categories
            case sensitiveActionGrant = "sensitive_action_grant"
            case deviceID = "device_id"
            case localInsights = "local_insights"
        }
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

#Preview {
    NavigationStack {
        AccountExportView(authStore: AuthStore(), userID: "preview")
    }
}
