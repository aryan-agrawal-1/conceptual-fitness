import SwiftUI

func heartRateZoneColor(_ zone: String) -> Color {
    switch zone {
    case "zone_1": return .teal
    case "zone_2": return .green
    case "zone_3": return .orange
    case "zone_4": return .red
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

