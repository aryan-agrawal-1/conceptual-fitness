import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case fitness
    case insights

    var id: String { rawValue }

    @ViewBuilder
    var label: some View {
        switch self {
        case .dashboard:
            Label("Dashboard", systemImage: "house.fill")
        case .fitness:
            Label("Fitness", systemImage: "figure.run")
        case .insights:
            Label("Insights", systemImage: "sparkles")
        }
    }
}

enum AppRoute: Hashable {
    case metric(String)
    case workout(String)
}
