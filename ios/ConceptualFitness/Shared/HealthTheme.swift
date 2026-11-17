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

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

enum HealthTheme {
    static let page = Color(light: 0xF5F3EE, dark: 0x0D0E11)
    static let card = Color(light: 0xFFFFFF, dark: 0x17191E)
    static let track = Color(light: 0xE9E6DF, dark: 0x24272E)
    static let raised = Color(light: 0xFFFFFF, dark: 0x3A3E47)
    static let ink = Color(light: 0x15171C, dark: 0xF2F3F5)
    static let secondaryInk = Color(light: 0x5B606B, dark: 0xA4A9B4)
    static let inverseInk = Color(light: 0xFFFFFF, dark: 0x0D0E11)
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.08)
    })

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
        case .readiness: Color(light: 0x299459, dark: 0x4CC98A)
        case .sleep: Color(light: 0x4F5CC7, dark: 0x8E9BFF)
        case .strain: Color(light: 0xD9661A, dark: 0xE07A2E)
        case .recovery: Color(light: 0x12878C, dark: 0x4FC8CC)
        case .heart: Color(light: 0xD43852, dark: 0xFF6B81)
        case .activity: Color(light: 0x1F7DD1, dark: 0x5AA9F0)
        case .respiratory: Color(light: 0x0D94C2, dark: 0x45BFE0)
        case .temperature: Color(light: 0xCC751F, dark: 0xE69A45)
        case .energy: Color(light: 0xE06326, dark: 0xF08A4B)
        case .neutral: Color(light: 0x666E7A, dark: 0xA4A9B4)
        }
    }

    static func color(for tone: HealthStatusTone) -> Color {
        switch tone {
        case .positive: Color(light: 0x299459, dark: 0x4CC98A)
        case .stable: Color(light: 0x12878C, dark: 0x4FC8CC)
        case .caution: Color(light: 0xC27A12, dark: 0xF0A840)
        case .risk: Color(light: 0xC2392B, dark: 0xFF6B5E)
        case .missing: secondaryInk
        }
    }
}
