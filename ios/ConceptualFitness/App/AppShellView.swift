import SwiftUI

struct AppShellView: View {
    @ObservedObject var authStore: AuthStore
    let session: AuthSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: AppTab = .dashboard
    @State private var dashboardPath: [AppRoute] = []
    @State private var fitnessPath: [AppRoute] = []
    @State private var insightsPath: [AppRoute] = []
    @StateObject private var syncCoordinator: AppSyncCoordinator

    private let weatherProvider = WeatherProvider()
    private let locationProvider = LocationProvider()
    private let insightProvider = DailyInsightProvider()

    init(authStore: AuthStore, session: AuthSession) {
        self.authStore = authStore
        self.session = session
        _syncCoordinator = StateObject(
            wrappedValue: AppSyncCoordinator(
                client: DashboardAPIClient(authStore: authStore),
                initialLastSyncAt: session.googleHealth.lastSyncAt
            )
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $dashboardPath) {
                DashboardView(
                    client: DashboardAPIClient(authStore: authStore),
                    syncCoordinator: syncCoordinator,
                    weatherProvider: weatherProvider,
                    locationProvider: locationProvider,
                    insightProvider: insightProvider,
                    firstName: session.user.firstName,
                    weatherEnabled: session.profile.weatherEnabled
                )
                .withAppDestinations()
            }
            .tabItem { AppTab.dashboard.label }
            .tag(AppTab.dashboard)

            NavigationStack(path: $fitnessPath) {
                PlaceholderTabView(
                    title: "Fitness",
                    systemImage: "figure.run",
                    message: "Workout history, training load, and detailed fitness trends will live here."
                )
                .withAppDestinations()
            }
            .tabItem { AppTab.fitness.label }
            .tag(AppTab.fitness)

            NavigationStack(path: $insightsPath) {
                PlaceholderTabView(
                    title: "Insights",
                    systemImage: "sparkles",
                    message: "AI reports, correlations, and longer-term health explanations will live here."
                )
                .withAppDestinations()
            }
            .tabItem { AppTab.insights.label }
            .tag(AppTab.insights)
        }
        .tint(.blue)
        .task {
            await syncCoordinator.syncIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await syncCoordinator.syncIfNeeded()
            }
        }
    }
}

#Preview {
    AppShellView(authStore: AuthStore(), session: .preview)
}

extension AuthSession {
    static let preview = AuthSession(
        user: AuthUser(id: "preview", email: "preview@example.com", firstName: "Aryan", lastName: nil),
        googleHealth: GoogleHealthStatus(
            status: .connected,
            connectedAt: "2026-06-22T08:00:00Z",
            lastSyncAt: "2026-06-22T18:42:00Z",
            lastError: nil
        ),
        profile: AuthProfileStatus(onboardingCompletedAt: "2026-06-23T12:00:00Z", weatherEnabled: true)
    )
}

@MainActor
final class AppSyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var refreshToken = 0
    @Published private(set) var lastSyncAt: Date?

    private let client: DashboardAPIClient
    private var runTask: Task<Void, Never>?
    private let freshnessInterval: TimeInterval = 15 * 60
    private let pollIntervalNanoseconds: UInt64 = 5_000_000_000
    private let maxPollAttempts = 24

    init(client: DashboardAPIClient, initialLastSyncAt: String? = nil) {
        self.client = client
        self.lastSyncAt = DashboardFormatters.parseBackendDateTime(initialLastSyncAt)
    }

    func updateFromDashboard(_ data: DashboardData) {
        let newestLastSync = data.lastSyncAt
        if let newestLastSync, newestLastSync != lastSyncAt {
            lastSyncAt = newestLastSync
        }
        if data.hasRunningSyncStatus && !isSyncing {
            Task {
                await syncIfNeeded()
            }
        }
    }

    func syncIfNeeded() async {
        if let runTask {
            await runTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSyncIfNeeded()
        }
        runTask = task
        await task.value
        runTask = nil
    }

    private func performSyncIfNeeded() async {
        guard !isFresh else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let response = try await client.syncCurrent()
            apply(lastSyncAt: response.lastSyncAt)
            switch response.status {
            case .synced:
                refreshToken += 1
            case .alreadyRunning:
                await pollUntilFinished()
            case .skippedFresh:
                break
            }
        } catch {
            return
        }
    }

    private func pollUntilFinished() async {
        for _ in 0..<maxPollAttempts {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            do {
                let status = try await client.currentSyncStatus()
                apply(lastSyncAt: status.lastSyncAt)
                if !status.isRunning {
                    refreshToken += 1
                    return
                }
            } catch {
                return
            }
        }
    }

    private var isFresh: Bool {
        guard let lastSyncAt else { return false }
        return Date().timeIntervalSince(lastSyncAt) < freshnessInterval
    }

    private func apply(lastSyncAt value: String?) {
        guard let date = DashboardFormatters.parseBackendDateTime(value) else { return }
        lastSyncAt = date
    }
}

private extension View {
    func withAppDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .metric(let metric):
                PlaceholderDetailView(
                    title: metric,
                    systemImage: "chart.line.uptrend.xyaxis",
                    message: "This dashboard detail screen is reserved for trends, baselines, and explanations."
                )
            case .workout(let workoutID):
                PlaceholderDetailView(
                    title: "Workout",
                    systemImage: "figure.run.circle",
                    message: "Workout analytics for \(workoutID) will be added after the dashboard pass."
                )
            }
        }
    }
}
