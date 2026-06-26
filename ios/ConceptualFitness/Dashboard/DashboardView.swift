import SwiftUI

struct DashboardView: View {
    let client: DashboardAPIClient
    @ObservedObject var syncCoordinator: AppSyncCoordinator
    let weatherProvider: WeatherProvider
    @ObservedObject var locationProvider: LocationProvider
    let insightProvider: DailyInsightProvider
    let firstName: String?
    let weatherEnabled: Bool
    private let loadsLiveData: Bool
    private let greetingOverride: String?

    @State private var loadState: DashboardLoadState = .loading
    @State private var weather = WeatherData.fallback
    @State private var weatherStatus = "Weather preview"
    @State private var showsLocation = false
    #if DEBUG
    @State private var showsWeatherLab = false
    #endif

    init(
        client: DashboardAPIClient,
        syncCoordinator: AppSyncCoordinator,
        weatherProvider: WeatherProvider,
        locationProvider: LocationProvider,
        insightProvider: DailyInsightProvider,
        firstName: String?,
        weatherEnabled: Bool,
        previewLoadState: DashboardLoadState? = nil,
        previewWeather: WeatherData = .fallback,
        greetingOverride: String? = nil
    ) {
        self.client = client
        self.syncCoordinator = syncCoordinator
        self.weatherProvider = weatherProvider
        self.locationProvider = locationProvider
        self.insightProvider = insightProvider
        self.firstName = firstName
        self.weatherEnabled = weatherEnabled
        self.loadsLiveData = previewLoadState == nil
        self.greetingOverride = greetingOverride
        _loadState = State(initialValue: previewLoadState ?? .loading)
        _weather = State(initialValue: previewWeather)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                LazyVStack(spacing: 24) {
                    hero
                    content
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                if loadsLiveData {
                    await syncCoordinator.syncIfNeeded()
                    await reload()
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if syncCoordinator.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(lastSyncedTitle)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsWeatherLab = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Weather Lab")
            }
            #endif
        }
        #if DEBUG
        .sheet(isPresented: $showsWeatherLab) {
            NavigationStack {
                WeatherBackgroundDebugControlsView()
                    .navigationTitle("Weather Lab")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showsWeatherLab = false
                            }
                        }
                    }
            }
        }
        #endif
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            guard loadsLiveData else { return }
            if weatherEnabled {
                locationProvider.requestLocation()
            }
            await reload()
            if weatherEnabled {
                await reloadWeather()
            }
        }
        .task(id: locationProvider.revision) {
            if loadsLiveData && weatherEnabled {
                await reloadWeather()
            }
        }
        .onChange(of: syncCoordinator.refreshToken) { _, _ in
            guard loadsLiveData else { return }
            Task {
                await reload()
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            if usesWeatherBackground {
                WeatherBackgroundView(weather: weather)
                    .frame(height: heroHeight)
            } else {
                Color.clear
                    .frame(height: heroHeight)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text(greeting)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(heroTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    if usesWeatherBackground {
                        WeatherStatusChip(
                            title: weather.locationName ?? weatherStatus,
                            systemImage: locationProvider.location == nil ? "location.slash" : "location.fill",
                            isPresented: $showsLocation
                        )
                    }
                }
                .padding(.top, 54)

                if let heroBriefText {
                    Text(heroBriefText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(heroTextColor.opacity(0.78))
                        .lineLimit(9)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 28)

                switch loadState {
                case .loaded(let data):
                    DailyBriefCard(data: data)
                case .loading:
                    DailyBriefSkeleton()
                case .failed:
                    DailyBriefCard(data: previewData)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("Using preview data")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 20)
            .padding(.horizontal, 20)

            dashboardSections(data: previewData)
        case .loaded(let data):
            dashboardSections(data: data)
        }
    }

    private var previewData: DashboardData {
        DashboardData.preview(
            dailyBrief: insightProvider.previewDailyBrief(),
            insight: insightProvider.previewShortInsight()
        )
    }

    private var heroBriefText: String? {
        switch loadState {
        case .loaded(let data):
            return data.dailyBrief?.nonEmptyDashboardText
        case .loading:
            return insightProvider.cachedDailyBriefForCurrentSlot()?.nonEmptyDashboardText
        case .failed:
            return previewData.dailyBrief?.nonEmptyDashboardText
        }
    }

    private var heroHeight: CGFloat {
        switch loadState {
        case .loaded(let data) where !data.hasDailyInsightText:
            if usesWeatherBackground {
                return data.dateContext == .yesterday ? 358 : 330
            }
            return data.dateContext == .yesterday ? 318 : 290
        case .loaded(let data) where data.dateContext == .yesterday:
            return 580
        default:
            return 560
        }
    }

    private func dashboardSections(data: DashboardData) -> some View {
        VStack(spacing: 28) {
            RecentWorkoutsSection(workouts: data.workouts)
            HealthMetricsSection(items: MetricCardItem.items(from: data))
        }
        .padding(.horizontal, 20)
    }

    private var greeting: String {
        if let greetingOverride {
            return greetingOverride
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        if hour >= 4 && hour < 12 {
            base = "Good morning"
        } else if hour >= 12 && hour < 18 {
            base = "Good afternoon"
        } else {
            base = "Good evening"
        }
        guard let firstName = firstName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstName.isEmpty
        else {
            return base
        }
        return "\(base), \(firstName)"
    }

    private var heroTextColor: Color {
        guard usesWeatherBackground else { return .black.opacity(0.84) }
        return weather.isDay || weather.scene == .sunrise || weather.scene == .sunset ? Color.black.opacity(0.84) : Color.white
    }

    private var usesWeatherBackground: Bool {
        weatherEnabled
            && locationProvider.authorizationStatus != .denied
            && locationProvider.authorizationStatus != .restricted
    }

    @MainActor
    private func reload() async {
        let hadLoadedData: Bool
        if case .loaded = loadState {
            hadLoadedData = true
        } else {
            hadLoadedData = false
            loadState = .loading
        }

        do {
            let now = Date()
            let displayBundle = try await client.loadDashboard(now: now)
            let bundle = displayBundle.bundle
            let dailyBrief = await insightProvider.dailyBrief(for: bundle, now: now)
            let insight = await insightProvider.shortInsight(for: bundle, now: now)
            let aiDebugStatus = dailyBrief == nil && insight == nil
                ? "AI unavailable: FoundationModels generation failed. Check [DailyInsightProvider] logs."
                : nil
            loadState = .loaded(
                DashboardData(
                    snapshot: bundle.snapshot,
                    metricSummaries: bundle.metricSummaries,
                    workouts: bundle.recentWorkouts,
                    vo2Max: bundle.vo2Max,
                    connections: bundle.connections,
                    syncStatus: bundle.syncStatus,
                    dateContext: displayBundle.dateContext,
                    dailyBrief: dailyBrief,
                    insight: insight,
                    aiDebugStatus: aiDebugStatus
                )
            )
            if case .loaded(let data) = loadState {
                syncCoordinator.updateFromDashboard(data)
            }
        } catch {
            if !hadLoadedData {
                loadState = .failed("The backend was unavailable at \(client.baseURL.absoluteString). Start the FastAPI server to load live dashboard data.")
            }
        }
    }

    @MainActor
    private func reloadWeather() async {
        let next = await weatherProvider.weather(for: locationProvider.location, locationName: locationProvider.locationName)
        weather = next
        weatherStatus = next.locationName ?? "Weather preview"
    }

    private var lastSyncedTitle: String {
        if syncCoordinator.isSyncing {
            return "Syncing..."
        }
        return "Last Synced: \(lastSyncedTime ?? "--:--")"
    }

    private var lastSyncedTime: String? {
        displayedLastSyncAt.map(DashboardFormatters.lastSyncedTime.string)
    }

    private var displayedLastSyncAt: Date? {
        switch loadState {
        case .loaded(let data):
            return data.lastSyncAt ?? syncCoordinator.lastSyncAt
        case .loading:
            return syncCoordinator.lastSyncAt
        case .failed:
            return previewData.lastSyncAt ?? syncCoordinator.lastSyncAt
        }
    }
}

enum DashboardLoadState {
    case loading
    case loaded(DashboardData)
    case failed(String)
}

private extension DashboardData {
    var hasDailyInsightText: Bool {
        dailyBrief?.nonEmptyDashboardText != nil || insight?.nonEmptyDashboardText != nil
    }
}

#Preview {
    NavigationStack {
        DashboardView(
            client: DashboardAPIClient(),
            syncCoordinator: AppSyncCoordinator(client: DashboardAPIClient()),
            weatherProvider: WeatherProvider(),
            locationProvider: LocationProvider(),
            insightProvider: DailyInsightProvider(),
            firstName: "Aryan",
            weatherEnabled: true
        )
    }
}

#Preview("Dashboard - AI insights") {
    NavigationStack {
        DashboardView(
            client: DashboardAPIClient(),
            syncCoordinator: AppSyncCoordinator(client: DashboardAPIClient()),
            weatherProvider: WeatherProvider(),
            locationProvider: LocationProvider(),
            insightProvider: DailyInsightProvider(),
            firstName: "Aryan",
            weatherEnabled: true,
            previewLoadState: .loaded(.sample),
            greetingOverride: "Good evening, Aryan"
        )
    }
}

#Preview("Dashboard - no AI") {
    NavigationStack {
        DashboardView(
            client: DashboardAPIClient(),
            syncCoordinator: AppSyncCoordinator(client: DashboardAPIClient()),
            weatherProvider: WeatherProvider(),
            locationProvider: LocationProvider(),
            insightProvider: DailyInsightProvider(),
            firstName: "Aryan",
            weatherEnabled: true,
            previewLoadState: .loaded(.previewWithoutInsights()),
            greetingOverride: "Good evening, Aryan"
        )
    }
}

#Preview("Dashboard - no AI, no location") {
    NavigationStack {
        DashboardView(
            client: DashboardAPIClient(),
            syncCoordinator: AppSyncCoordinator(client: DashboardAPIClient()),
            weatherProvider: WeatherProvider(),
            locationProvider: LocationProvider(),
            insightProvider: DailyInsightProvider(),
            firstName: "Aryan",
            weatherEnabled: false,
            previewLoadState: .loaded(.previewWithoutInsights()),
            greetingOverride: "Good evening, Aryan"
        )
    }
}
