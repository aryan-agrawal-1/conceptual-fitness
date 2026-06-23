import SwiftUI

struct AppShellView: View {
    @ObservedObject var authStore: AuthStore
    let session: AuthSession

    @State private var selectedTab: AppTab = .dashboard
    @State private var dashboardPath: [AppRoute] = []
    @State private var fitnessPath: [AppRoute] = []
    @State private var insightsPath: [AppRoute] = []

    private let weatherProvider = WeatherProvider()
    private let locationProvider = LocationProvider()
    private let insightProvider = DailyInsightProvider()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $dashboardPath) {
                DashboardView(
                    client: DashboardAPIClient(authStore: authStore),
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
    }
}

#Preview {
    AppShellView(authStore: AuthStore(), session: .preview)
}

extension AuthSession {
    static let preview = AuthSession(
        user: AuthUser(id: "preview", email: "preview@example.com", firstName: "Aryan", lastName: nil),
        googleHealth: GoogleHealthStatus(status: .connected),
        profile: AuthProfileStatus(onboardingCompletedAt: "2026-06-23T12:00:00Z", weatherEnabled: true)
    )
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
