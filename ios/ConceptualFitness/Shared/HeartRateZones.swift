import SwiftUI

func heartRateZoneColor(_ zone: String) -> Color {
    switch zone {
    case "zone_1": return HealthTheme.color(for: .stable)
    case "zone_2": return HealthTheme.color(for: .positive)
    case "zone_3": return HealthTheme.color(for: .strain)
    case "zone_4": return HealthTheme.color(for: .risk)
    default: return .secondary
    }
}

func heartRateZoneShortLabel(_ zone: String) -> String {
    switch zone {
    case "zone_1": return "Z1"
    case "zone_2": return "Z2"
    case "zone_3": return "Z3"
    case "zone_4": return "Z4"
    default: return zone.displayTitle
    }
}
