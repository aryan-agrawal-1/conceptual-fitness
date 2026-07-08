import SwiftUI

enum WorkoutActivityFamily {
    case walking
    case running
    case cycling
    case swimming
    case strength
    case mobility
    case mixed
}

struct WorkoutPresentation {
    let displayName: String
    let symbolName: String
    let family: WorkoutActivityFamily
    let activityAccent: Color
    let strainAccent: Color
    let intensityLabel: String?
}

enum WorkoutPresentationFactory {
    static func make(type: String?, intensity: String?, strainLoadPoints: Double?) -> WorkoutPresentation {
        let displayName = normalizedName(type)
        let family = activityFamily(for: type)
        return WorkoutPresentation(
            displayName: displayName,
            symbolName: symbolName(for: family),
            family: family,
            activityAccent: activityAccent(for: family),
            strainAccent: strainAccent(for: intensity, strainLoadPoints: strainLoadPoints),
            intensityLabel: normalizedIntensity(intensity)
        )
    }

    static func normalizedName(_ type: String?) -> String {
        guard let type else { return "Workout" }
        let normalized = type
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Workout" }
        return normalized
            .lowercased()
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func normalizedIntensity(_ intensity: String?) -> String? {
        guard let intensity, !intensity.isEmpty, intensity != "unknown" else { return nil }
        return intensity.displayTitle
    }

    private static func activityFamily(for type: String?) -> WorkoutActivityFamily {
        let type = type?.lowercased() ?? ""
        if type.contains("run") { return .running }
        if type.contains("cycl") || type.contains("bike") { return .cycling }
        if type.contains("walk") { return .walking }
        if type.contains("swim") { return .swimming }
        if type.contains("strength") || type.contains("weight") { return .strength }
        if type.contains("yoga") || type.contains("mobility") || type.contains("stretch") { return .mobility }
        return .mixed
    }

    private static func symbolName(for family: WorkoutActivityFamily) -> String {
        switch family {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .swimming: return "figure.pool.swim"
        case .strength: return "dumbbell.fill"
        case .mobility: return "figure.cooldown"
        case .mixed: return "figure.mixed.cardio"
        }
    }

    private static func activityAccent(for family: WorkoutActivityFamily) -> Color {
        switch family {
        case .walking: return Color(red: 0.10, green: 0.55, blue: 0.64)
        case .running: return Color(red: 0.82, green: 0.22, blue: 0.28)
        case .cycling: return Color(red: 0.08, green: 0.50, blue: 0.78)
        case .swimming: return Color(red: 0.05, green: 0.58, blue: 0.76)
        case .strength: return Color(red: 0.39, green: 0.37, blue: 0.46)
        case .mobility: return Color(red: 0.10, green: 0.55, blue: 0.42)
        case .mixed: return HealthTheme.color(for: .activity)
        }
    }

    private static func strainAccent(for intensity: String?, strainLoadPoints: Double?) -> Color {
        switch intensity?.lowercased() {
        case "peak":
            return HealthTheme.color(for: .risk)
        case "vigorous", "high":
            return HealthTheme.color(for: .strain)
        case "moderate":
            return HealthTheme.color(for: .stable)
        case "light", "low":
            return HealthTheme.color(for: .positive)
        default:
            if let strainLoadPoints {
                if strainLoadPoints >= 80 { return HealthTheme.color(for: .risk) }
                if strainLoadPoints >= 45 { return HealthTheme.color(for: .strain) }
                if strainLoadPoints >= 18 { return HealthTheme.color(for: .stable) }
            }
            return HealthTheme.color(for: .missing)
        }
    }
}
