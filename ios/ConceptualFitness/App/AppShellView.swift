import SwiftUI
import OSLog
import UserNotifications
import BackgroundTasks

struct AppShellView: View {
    @ObservedObject var authStore: AuthStore
    let session: AuthSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: AppTab = .dashboard
    @State private var dashboardPath: [AppRoute] = []
    @State private var fitnessPath: [AppRoute] = []
    @State private var insightsPath: [AppRoute] = []
    @StateObject private var syncCoordinator: AppSyncCoordinator
    @StateObject private var profileStore: ProfileStore
    @StateObject private var journalStore: JournalStore
    @StateObject private var journalReminders: JournalReminders
    @ObservedObject private var notificationRouter = JournalNotificationRouter.shared
    @State private var checkIn: JournalCheckInSelection?

    private let weatherProvider = WeatherProvider()
    private let locationProvider = LocationProvider()
    private let insightProvider = DailyInsightProvider()

    init(authStore: AuthStore, session: AuthSession) {
        self.authStore = authStore
        self.session = session
        _profileStore = StateObject(wrappedValue: ProfileStore(authStore: authStore))
        _journalStore = StateObject(wrappedValue: JournalStore(authStore: authStore, userID: session.user.id))
        _journalReminders = StateObject(wrappedValue: JournalReminders(userID: session.user.id))
        #if DEBUG
        _selectedTab = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("-OpenInsightsTab")
                ? .insights
                : ProcessInfo.processInfo.arguments.contains("-OpenFitnessTab")
                ? .fitness
                : .dashboard
        )
        #endif
        _syncCoordinator = StateObject(
            wrappedValue: AppSyncCoordinator(
                client: DashboardAPIClient(authStore: authStore),
                initialLastSyncAt: session.googleHealth.lastSyncAt
            )
        )
    }

    var body: some View {
        let appClient = DashboardAPIClient(authStore: authStore, userID: session.user.id)

        TabView(selection: $selectedTab) {
            NavigationStack(path: $dashboardPath) {
                DashboardView(
                    client: appClient,
                    syncCoordinator: syncCoordinator,
                    weatherProvider: weatherProvider,
                    locationProvider: locationProvider,
                    insightProvider: insightProvider,
                    firstName: session.user.firstName,
                    weatherEnabled: profileStore.profile?.weatherEnabled ?? session.profile.weatherEnabled,
                    profileStore: profileStore,
                    journalReminders: journalReminders
                )
                .withAppDestinations(client: appClient)
            }
            .tabItem { AppTab.dashboard.label }
            .tag(AppTab.dashboard)

            NavigationStack(path: $fitnessPath) {
                FitnessView(authStore: authStore, userID: session.user.id)
                .withAppDestinations(client: appClient)
            }
            .tabItem { AppTab.fitness.label }
            .tag(AppTab.fitness)

            NavigationStack(path: $insightsPath) {
                JournalView(store: journalStore, reminders: journalReminders, onboardedAt: onboardedAt)
                .withAppDestinations(client: appClient)
            }
            .tabItem { AppTab.insights.label }
            .tag(AppTab.insights)
        }
        .tint(HealthTheme.color(for: .activity))
        .environment(\.profileUnits, profileStore.profile?.unitSystem ?? .metric)
        .sheet(item: $checkIn) {
            JournalCheckInView(store: journalStore, reminders: journalReminders, day: $0.day)
        }
        .task { await profileStore.load() }
        .task {
            if UIApplication.shared.applicationState == .active { await journalStore.synchronize() }
            journalReminders.refresh(journalStore.snapshot)
            presentCheckInIfNeeded()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if UIApplication.shared.applicationState == .active, journalStore.needsRetry {
                    await journalStore.synchronize()
                }
            }
        }
        .onDisappear {
            journalStore.stop()
            journalReminders.stop()
        }
        .onChange(of: reminderInputs) { _, _ in journalReminders.refresh(journalStore.snapshot) }
        .onChange(of: notificationRouter.openRequested) { _, _ in presentCheckInIfNeeded() }
        .onChange(of: selectedTab) { _, _ in presentCheckInIfNeeded() }
        .onChange(of: profileStore.revision) { _, _ in syncCoordinator.profileDidChange() }
        .task {
            await syncCoordinator.syncIfNeeded()
        }
        .task { await syncCoordinator.monitorHistory() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { syncCoordinator.scheduleHistoryCheck() }
            guard phase == .active else { return }
            Task {
                await journalStore.synchronize()
                journalReminders.refresh(journalStore.snapshot)
                presentCheckInIfNeeded()
                await syncCoordinator.checkHistory()
                await syncCoordinator.syncIfNeeded()
            }
        }
    }

    private var onboardedAt: Date? {
        DashboardFormatters.parseBackendDateTime(session.profile.onboardingCompletedAt)
    }

    // Reminders only need rescheduling when completed days or the timezone change.
    private var reminderInputs: [String] {
        journalStore.snapshot.completions.filter(\.completed).map(\.journalDate).sorted()
            + [journalStore.snapshot.timezone ?? ""]
    }

    // A workout in progress or an open editor must never be interrupted, so this waits for
    // the next chance rather than using up the day's prompt.
    private var isPresentingElsewhere: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?
            .rootViewController?.presentedViewController != nil
    }

    private func presentCheckInIfNeeded() {
        let snapshot = journalStore.snapshot
        guard checkIn == nil, snapshot.catalogue != nil, snapshot.timezone != nil, !isPresentingElsewhere else { return }
        if notificationRouter.openRequested {
            notificationRouter.openRequested = false
            checkIn = JournalCheckInSelection(day: JournalCheckIn.reminderTarget(snapshot, today: journalStore.today))
            return
        }
        let key = "journalPrompted.\(session.user.id)"
        guard JournalCheckIn.shouldPrompt(snapshot, onboardedAt: onboardedAt,
                                          lastPromptDay: UserDefaults.standard.string(forKey: key)) else { return }
        UserDefaults.standard.set(journalStore.today, forKey: key)
        checkIn = JournalCheckInSelection(day: JournalDay.previous(journalStore.today))
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
    @Published private(set) var failureMessage: String?
    @Published private(set) var history: HistoricalBackfillStatus?
    @Published private(set) var historyError: String?
    @Published private(set) var historyLoaded = false
    @Published private(set) var currentScoresAvailable = false
    @Published private(set) var retryingSource: String?
    @Published private(set) var notifyOnCompletion = false
    @Published private(set) var notificationMessage: String?
    private var accountID: String?
    private var historyRequestRevision = 0

    #if DEBUG
    static func historyPreview(_ state: HistoryPreviewState) -> AppSyncCoordinator {
        let coordinator = AppSyncCoordinator(client: DashboardAPIClient())
        coordinator.historyLoaded = state != .loading
        coordinator.currentScoresAvailable = state != .empty
        if state == .offline { coordinator.historyError = "Import progress couldn’t update. Check your connection and try again." }
        guard state != .loading && state != .waiting else { return coordinator }
        let complete = state == .complete || state == .empty
        let sources = ["steps", "sleep", "heart-rate"].enumerated().map { index, name in
            HistoricalBackfillSource(
                dataType: name, status: complete || index == 0 ? "succeeded" : state == .failed ? "failed" : "running",
                coverageStart: "2026-06-14", coverageEnd: complete || index == 0 ? "2026-09-11" : "2026-07-05",
                pageInProgress: !complete && index != 0, completedAt: nil
            )
        }
        coordinator.history = HistoricalBackfillStatus(
            status: complete ? "complete" : state == .failed ? "failed" : "running",
            completedSources: complete ? 3 : 1, totalSources: 3,
            rangeStart: "2026-06-14", rangeEnd: "2026-09-11",
            calibrationState: complete ? "complete" : "calibrating", checkpointAt: nil, sources: sources
        )
        return coordinator
    }
    #endif

    func monitorHistory() async {
        while !Task.isCancelled {
            await checkHistory()
            if history?.status == "complete" { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }

    func checkHistory() async {
        historyRequestRevision += 1
        let revision = historyRequestRevision
        do {
            let status = try await client.currentSyncStatus()
            guard !Task.isCancelled, revision == historyRequestRevision else { return }
            let previousCheckpoint = history?.checkpointAt
            accountID = status.accountID
            notifyOnCompletion = UserDefaults.standard.bool(forKey: "historyNotify.\(status.accountID)")
            currentScoresAvailable = status.currentScoresAvailable ?? false
            history = status.historicalBackfill
            historyLoaded = true
            historyError = nil
            if let checkpoint = history?.checkpointAt, checkpoint != previousCheckpoint {
                refreshToken += 1
            }
            await notifyIfCompletedWhileInactive()
            if UIApplication.shared.applicationState == .active {
                UserDefaults.standard.removeObject(forKey: "historyInactive.\(status.accountID)")
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, revision == historyRequestRevision else { return }
            historyError = "Import progress couldn’t update. Check your connection and try again."
            logger.error("Historical progress request failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func retryHistory(source: String) async {
        guard retryingSource == nil else { return }
        retryingSource = source
        defer { retryingSource = nil }
        do {
            _ = try await client.retryHistoricalBackfill(source: source)
            await checkHistory()
        } catch {
            historyError = "This source couldn’t restart. Check your connection and try again."
            logger.error("Historical retry failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func setCompletionNotification(_ enabled: Bool) async {
        guard let accountID else { return }
        notificationMessage = nil
        do {
            let allowed = enabled ? try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) : false
            notifyOnCompletion = allowed
            UserDefaults.standard.set(allowed, forKey: "historyNotify.\(accountID)")
            if !allowed {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.conceptualfitness.history")
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["historyComplete.\(accountID)"])
            }
            if enabled && !allowed { notificationMessage = "Notifications are disabled. You can enable them in Settings." }
        } catch {
            notificationMessage = "Notification permission couldn’t be checked. Try again."
        }
    }

    func scheduleHistoryCheck() {
        guard let accountID, history?.status != "complete" else { return }
        UserDefaults.standard.set(Date(), forKey: "historyInactive.\(accountID)")
        guard notifyOnCompletion else { return }
        let request = BGAppRefreshTaskRequest(identifier: "com.conceptualfitness.history")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.error("Historical background check could not be scheduled") }
    }

    private func notifyIfCompletedWhileInactive() async {
        guard let accountID, notifyOnCompletion, let history, history.status == "complete",
              let inactive = UserDefaults.standard.object(forKey: "historyInactive.\(accountID)") as? Date,
              let completed = DashboardFormatters.parseBackendDateTime(history.checkpointAt),
              completed >= inactive,
              UserDefaults.standard.string(forKey: "historyNotified.\(accountID)") != history.rangeEnd else { return }
        let content = UNMutableNotificationContent()
        content.title = "Import complete"
        content.body = "Your history is ready to view."
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "historyComplete.\(accountID)", content: content, trigger: nil
            ))
            UserDefaults.standard.set(history.rangeEnd, forKey: "historyNotified.\(accountID)")
        } catch {
            logger.error("Historical completion notification could not be scheduled")
        }
    }


    private let client: DashboardAPIClient
    private var runTask: Task<Void, Never>?
    private let pollIntervalNanoseconds: UInt64 = 5_000_000_000
    private let maxPollAttempts = 120
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Sync")

    init(client: DashboardAPIClient, initialLastSyncAt: String? = nil) {
        self.client = client
        self.lastSyncAt = DashboardFormatters.parseBackendDateTime(initialLastSyncAt)
    }

    func updateFromDashboard(_ data: DashboardData) {
        if let date = data.lastSyncAt, date > (lastSyncAt ?? .distantPast) {
            lastSyncAt = date
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
        isSyncing = true
        failureMessage = nil
        defer { isSyncing = false }

        do {
            let current = try await client.currentSyncStatus()
            if apply(lastSyncAt: current.lastSyncAt) {
                refreshToken += 1
            }
            if current.isRunning {
                await pollUntilFinished()
                return
            }
            if current.isFresh && !current.hasFailure {
                return
            }
            let response = try await client.syncCurrent()
            apply(lastSyncAt: response.lastSyncAt)
            switch response.status {
            case .synced, .skippedFresh:
                let status = try await client.currentSyncStatus()
                apply(lastSyncAt: status.lastSyncAt)
                refreshToken += 1
                failureMessage = status.hasFailure ? "Health data refresh failed. Try again." : nil
            case .alreadyRunning:
                await pollUntilFinished()
            }
        } catch let error as URLError where error.code == .timedOut {
            // The server may still be importing after the request times out.
            await pollUntilFinished()
        } catch {
            logger.error("Sync request failed: \(String(describing: type(of: error)), privacy: .public)")
            failureMessage = "Health data couldn’t refresh. Check your connection and try again."
        }
    }

    func retry() async {
        await syncIfNeeded()
    }

    func profileDidChange() { refreshToken += 1 }

    private func pollUntilFinished() async {
        for _ in 0..<maxPollAttempts {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            do {
                let status = try await client.currentSyncStatus()
                apply(lastSyncAt: status.lastSyncAt)
                if !status.isRunning {
                    refreshToken += 1
                    if status.hasFailure {
                        failureMessage = "Health data refresh failed. Try again."
                        return
                    }
                    failureMessage = nil
                    return
                }
            } catch {
                logger.error("Sync polling failed: \(String(describing: type(of: error)), privacy: .public)")
                failureMessage = "Health data couldn’t refresh. Check your connection and try again."
                return
            }
        }
        logger.error("Sync polling timed out")
        failureMessage = "Health data is still syncing. Try again to check its progress."
    }

    @discardableResult
    private func apply(lastSyncAt value: String?) -> Bool {
        guard let date = DashboardFormatters.parseBackendDateTime(value), date != lastSyncAt else {
            return false
        }
        lastSyncAt = date
        return true
    }
}

private extension View {
    func withAppDestinations(client: DashboardAPIClient) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .metric(let metric):
                if metric == "strain" {
                    StrainDetailView(client: client)
                } else if metric == "readiness" {
                    ReadinessDetailView(client: client)
                } else if metric == "sleep" {
                    SleepDetailView(client: client)
                } else if metric == "heart_rate_variability" {
                    HRVDetailView(client: client)
                } else if metric == "resting_heart_rate" {
                    RestingHeartRateDetailView(client: client)
                } else if metric == "skin_temperature_variation" {
                    SkinTemperatureVariationDetailView(client: client)
                } else if metric == "oxygen_saturation" {
                    OxygenSaturationDetailView(client: client)
                } else if metric == "respiratory_rate" {
                    RespiratoryRateDetailView(client: client)
                } else if metric == "vo2_max" {
                    VO2MaxDetailView(client: client)
                } else if metric == "heart_rate" {
                    HeartRateDetailView(client: client)
                } else if metric == "steps" {
                    StepsDetailView(client: client)
                } else if metric == "total_calories" {
                    CaloriesBurnedDetailView(client: client)
                } else if metric == "distance" {
                    DistanceDetailView(client: client)
                } else {
                    PlaceholderDetailView(
                        title: metric,
                        systemImage: "chart.line.uptrend.xyaxis",
                        message: "This dashboard detail screen is reserved for trends, baselines, and explanations."
                    )
                }
            case .workout(let workoutID):
                WorkoutDetailView(workoutID: workoutID, client: client)
            }
        }
    }
}
