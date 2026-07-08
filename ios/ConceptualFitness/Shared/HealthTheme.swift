import SwiftUI

enum HealthMetricDomain {
    case readiness
    case sleep
    case strain
    case recovery
    case heart
    case activity
    case respiratory
    case temperature
    case energy
    case neutral
}

enum HealthStatusTone {
    case positive
    case stable
    case caution
    case risk
    case missing
}

enum HealthTheme {
    static var readiness: Color { color(for: .readiness) }
    static var sleep: Color { color(for: .sleep) }
    static var strain: Color { color(for: .strain) }
    static var hrv: Color { color(for: .recovery) }
    static var heartRate: Color { color(for: .heart) }
    static var steps: Color { color(for: .activity) }
    static var distance: Color { color(for: .activity) }
    static var respiratoryRate: Color { color(for: .respiratory) }
    static var oxygenSaturation: Color { color(for: .respiratory) }
    static var skinTemperature: Color { color(for: .temperature) }
    static var calories: Color { color(for: .energy) }
    static var vo2Max: Color { color(for: .activity) }

    static func color(for domain: HealthMetricDomain) -> Color {
        switch domain {
        case .readiness:
            return Color(red: 0.16, green: 0.58, blue: 0.35)
        case .sleep:
            return Color(red: 0.31, green: 0.36, blue: 0.78)
        case .strain:
            return Color(red: 0.86, green: 0.45, blue: 0.13)
        case .recovery:
            return Color(red: 0.10, green: 0.59, blue: 0.62)
        case .heart:
            return Color(red: 0.83, green: 0.22, blue: 0.32)
        case .activity:
            return Color(red: 0.12, green: 0.49, blue: 0.82)
        case .respiratory:
            return Color(red: 0.05, green: 0.58, blue: 0.76)
        case .temperature:
            return Color(red: 0.80, green: 0.46, blue: 0.12)
        case .energy:
            return Color(red: 0.88, green: 0.39, blue: 0.15)
        case .neutral:
            return Color(red: 0.40, green: 0.43, blue: 0.48)
        }
    }

    static func color(for tone: HealthStatusTone) -> Color {
        switch tone {
        case .positive:
            return Color(red: 0.16, green: 0.58, blue: 0.35)
        case .stable:
            return Color(red: 0.10, green: 0.59, blue: 0.62)
        case .caution:
            return Color(red: 0.86, green: 0.55, blue: 0.14)
        case .risk:
            return Color(red: 0.82, green: 0.22, blue: 0.20)
        case .missing:
            return .secondary
        }
    }
}
