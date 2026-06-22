import SwiftUI

struct AppShellView: View {
    @ObservedObject var authStore: AuthStore

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
                    insightProvider: insightProvider
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
    AppShellView(authStore: AuthStore())
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
