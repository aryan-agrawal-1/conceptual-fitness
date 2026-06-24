import SwiftUI
import FoundationModels

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
        if ProcessInfo.processInfo.arguments.contains("-FoundationModelsSmokeTest") {
            FoundationModelsSmokeTestView()
        } else if let previewState = DashboardPreviewLaunchState.current {
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
private struct FoundationModelsSmokeTestView: View {
    @State private var status = "Starting FoundationModels smoke test..."

    var body: some View {
        VStack(spacing: 12) {
            Text("FoundationModels Smoke Test")
                .font(.headline)
            Text(status)
                .font(.body.monospaced())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .task {
            await run()
        }
    }

    @MainActor
    private func run() async {
        guard #available(iOS 26.0, *) else {
            status = "unavailable: iOS < 26"
            print("[FoundationModelsSmokeTest] \(status)")
            return
        }

        let model = SystemLanguageModel.default
        let availability = String(describing: model.availability)
        guard model.availability == .available else {
            status = "availability=\(availability)"
            print("[FoundationModelsSmokeTest] \(status)")
            return
        }

        do {
            let session = LanguageModelSession(model: model, instructions: "Reply with one word.")
            let response = try await session.respond(
                to: "Reply with only the word OK.",
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 8)
            )
            status = "success: \(response.content)"
            print("[FoundationModelsSmokeTest] \(status)")
        } catch {
            status = "failed: \(String(describing: error))"
            print("[FoundationModelsSmokeTest] \(status)")
        }
    }
}

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
                syncCoordinator: AppSyncCoordinator(client: DashboardAPIClient()),
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
