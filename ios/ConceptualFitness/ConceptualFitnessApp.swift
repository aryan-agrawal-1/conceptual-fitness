import SwiftUI

@main
struct ConceptualFitnessApp: App {
    @StateObject private var authStore = AuthStore()

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let previewState = DashboardPreviewLaunchState.current {
            previewState.view
        } else {
            AuthGateView(authStore: authStore)
        }
        #else
        AuthGateView(authStore: authStore)
        #endif
    }
}

#if DEBUG
@MainActor
private enum DashboardPreviewLaunchState: String {
    case ai
    case noAI
    case noAINoLocation

    static var current: DashboardPreviewLaunchState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DashboardPreviewState"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return DashboardPreviewLaunchState(rawValue: arguments[index + 1])
    }

    var view: some View {
        NavigationStack {
            DashboardView(
                client: DashboardAPIClient(),
                weatherProvider: WeatherProvider(),
                locationProvider: LocationProvider(),
                insightProvider: DailyInsightProvider(),
                firstName: "Aryan",
                weatherEnabled: weatherEnabled,
                previewLoadState: .loaded(data),
                greetingOverride: "Good evening, Aryan"
            )
        }
    }

    private var data: DashboardData {
        switch self {
        case .ai:
            return .sample
        case .noAI, .noAINoLocation:
            return .previewWithoutInsights()
        }
    }

    private var weatherEnabled: Bool {
        self != .noAINoLocation
    }
}
#endif
