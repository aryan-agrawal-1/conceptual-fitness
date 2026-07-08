import SwiftUI

struct HealthMetricPresentation {
    let key: String
    let title: String
    let unit: String
    let systemImage: String
    let domain: HealthMetricDomain
    let chartKind: MiniMetricChartKind
    let higherIsBetter: Bool?

    var tint: Color { HealthTheme.color(for: domain) }

    static func presentation(for key: String) -> HealthMetricPresentation {
        switch key {
        case "heart_rate_variability":
            return .init(key: key, title: "HRV", unit: "ms", systemImage: "waveform.path.ecg", domain: .recovery, chartKind: .baselineLine, higherIsBetter: true)
        case "resting_heart_rate":
            return .init(key: key, title: "Resting HR", unit: "bpm", systemImage: "heart.fill", domain: .heart, chartKind: .baselineLine, higherIsBetter: false)
        case "heart_rate":
            return .init(key: key, title: "Heart Rate", unit: "bpm", systemImage: "heart.text.square.fill", domain: .heart, chartKind: .intradayLine, higherIsBetter: nil)
        case "skin_temperature_variation":
            return .init(key: key, title: "Skin Temp", unit: "C", systemImage: "thermometer", domain: .temperature, chartKind: .baselineLine, higherIsBetter: nil)
        case "oxygen_saturation":
            return .init(key: key, title: "SpO2", unit: "%", systemImage: "lungs.fill", domain: .respiratory, chartKind: .thresholdLine, higherIsBetter: true)
        case "respiratory_rate":
            return .init(key: key, title: "Respiratory", unit: "br/min", systemImage: "wind", domain: .respiratory, chartKind: .baselineLine, higherIsBetter: false)
        case "vo2_max":
            return .init(key: key, title: "VO2 Max", unit: "ml/kg/min", systemImage: "figure.run", domain: .activity, chartKind: .rangeLine, higherIsBetter: true)
        case "sleep":
            return .init(key: key, title: "Sleep", unit: "min", systemImage: "bed.double.fill", domain: .sleep, chartKind: .sleepStages, higherIsBetter: true)
        case "steps":
            return .init(key: key, title: "Steps", unit: "", systemImage: "shoeprints.fill", domain: .activity, chartKind: .bars, higherIsBetter: true)
        case "total_calories":
            return .init(key: key, title: "Calories Burned", unit: "kcal", systemImage: "flame.fill", domain: .energy, chartKind: .bars, higherIsBetter: nil)
        case "distance":
            return .init(key: key, title: "Distance", unit: "km", systemImage: "point.topleft.down.curvedto.point.bottomright.up", domain: .activity, chartKind: .bars, higherIsBetter: true)
        default:
            return .init(key: key, title: key.displayTitle, unit: "", systemImage: "chart.xyaxis.line", domain: .neutral, chartKind: .empty, higherIsBetter: nil)
        }
    }
}
