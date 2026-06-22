import SwiftUI

struct DashboardView: View {
    let client: DashboardAPIClient
    let weatherProvider: WeatherProvider
    @ObservedObject var locationProvider: LocationProvider
    let insightProvider: DailyInsightProvider

    @State private var loadState: DashboardLoadState = .loading
    @State private var weather = WeatherData.fallback
    @State private var weatherStatus = "Weather preview"
    @State private var showsLocation = false
    #if DEBUG
    @State private var showsWeatherLab = false
    #endif

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
                await reload()
            }
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsWeatherLab = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Weather Lab")
            }
        }
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
            locationProvider.requestLocation()
            await reload()
            await reloadWeather()
        }
        .task(id: locationProvider.revision) {
            await reloadWeather()
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            WeatherBackgroundView(weather: weather)
                .frame(height: 560)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text(greeting)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(heroTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    WeatherStatusChip(
                        title: weather.locationName ?? weatherStatus,
                        systemImage: locationProvider.location == nil ? "location.slash" : "location.fill",
                        isPresented: $showsLocation
                    )
                }
                .padding(.top, 54)

                Text(heroBriefText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(heroTextColor.opacity(0.78))
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(height: 560)
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
            dailyBrief: insightProvider.fallbackDailyBrief(for: .sample),
            insight: insightProvider.shortInsight(for: .sample)
        )
    }

    private var heroBriefText: String {
        switch loadState {
        case .loaded(let data):
            return data.dailyBrief
        case .loading:
            return "Preparing your daily brief..."
        case .failed:
            return previewData.dailyBrief
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
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var heroTextColor: Color {
        weather.isDay || weather.scene == .sunrise || weather.scene == .sunset ? .black.opacity(0.84) : .white
    }

    @MainActor
    private func reload() async {
        loadState = .loading
        do {
            let bundle = try await client.loadDashboard()
            let dailyBrief = await insightProvider.dailyBrief(for: bundle.snapshot)
            let insight = insightProvider.shortInsight(for: bundle.snapshot)
            loadState = .loaded(
                DashboardData(
                    snapshot: bundle.snapshot,
                    metricSummaries: bundle.metricSummaries,
                    workouts: bundle.recentWorkouts,
                    vo2Max: bundle.vo2Max,
                    dailyBrief: dailyBrief,
                    insight: insight
                )
            )
        } catch {
            loadState = .failed("The backend was unavailable at \(client.baseURL.absoluteString). Start the FastAPI server to load live dashboard data.")
        }
    }

    @MainActor
    private func reloadWeather() async {
        let next = await weatherProvider.weather(for: locationProvider.location, locationName: locationProvider.locationName)
        weather = next
        weatherStatus = next.locationName ?? "Weather preview"
    }
}

enum DashboardLoadState {
    case loading
    case loaded(DashboardData)
    case failed(String)
}

#Preview {
    NavigationStack {
        DashboardView(
            client: DashboardAPIClient(),
            weatherProvider: WeatherProvider(),
            locationProvider: LocationProvider(),
            insightProvider: DailyInsightProvider()
        )
    }
}
