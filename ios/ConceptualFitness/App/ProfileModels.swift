import Foundation

enum ProfileUnits: String, Codable, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric" : "Imperial" }
    var massSymbol: String { self == .metric ? "kg" : "lb" }
    var heightSymbol: String { self == .metric ? "cm" : "in" }
    var distanceSymbol: String { self == .metric ? "km" : "mi" }
    var shortDistanceSymbol: String { self == .metric ? "m" : "ft" }
    var temperatureSymbol: String { self == .metric ? "°C" : "°F" }
    var temperatureName: String { self == .metric ? "Celsius" : "Fahrenheit" }
    func temperatureVariation(_ celsius: Double) -> Double { self == .metric ? celsius : celsius * 1.8 }

    func temperatureVariationText(_ celsius: Double?) -> String? {
        guard let celsius else { return nil }
        let value = temperatureVariation(celsius)
        if abs(value) < 0.05 { return "0.0" }
        return "\(value > 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))"
    }

    func mass(_ kg: Double) -> Double { self == .metric ? kg : kg / 0.45359237 }
    func kilograms(_ value: Double) -> Double { self == .metric ? value : value * 0.45359237 }
    func height(_ cm: Double) -> Double { self == .metric ? cm : cm / 2.54 }
    func centimeters(_ value: Double) -> Double { self == .metric ? value : value * 2.54 }
    func shortDistance(_ meters: Double) -> Double { self == .metric ? meters : meters / 0.3048 }
    func meters(_ value: Double) -> Double { self == .metric ? value : value * 0.3048 }

    func distanceText(_ meters: Double, compact: Bool = false) -> String {
        let divisor = self == .metric ? 1000.0 : 1609.344
        let separator = compact ? "" : " "
        if abs(meters) < divisor {
            return "\(Int(shortDistance(meters).rounded()))\(separator)\(shortDistanceSymbol)"
        }
        return "\((meters / divisor).formatted(.number.precision(.fractionLength(0...1))))\(separator)\(distanceSymbol)"
    }

    func distanceText(_ meters: Double?) -> String {
        meters.map { distanceText($0) } ?? "--"
    }

    func massText(_ kg: Double) -> String {
        "\(mass(kg).formatted(.number.precision(.fractionLength(0...1)))) \(massSymbol)"
    }
}

struct ProfileConstraints: Codable, Equatable {
    var schedule: [String] = []
    var equipment: [String] = []
    var injuries: [String] = []
    var dietaryPreferences: [String] = []
    var sleepSchedule: String?

    enum CodingKeys: String, CodingKey {
        case schedule, equipment, injuries
        case dietaryPreferences = "dietary_preferences"
        case sleepSchedule = "sleep_schedule"
    }
}

struct ProfileProvenance: Decodable, Equatable {
    let preference: String
    let activeSource: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case preference
        case activeSource = "active_source"
        case updatedAt = "updated_at"
    }
}

struct AccountProfile: Decodable, Equatable {
    let timezone: String
    let dateOfBirth: String?
    let birthYear: Int?
    let sex: String?
    let heightCm: Double?
    let weightKg: Double?
    let weatherEnabled: Bool
    let primaryGoal: String?
    let secondaryGoals: [String]
    let constraints: ProfileConstraints
    let unitSystem: ProfileUnits
    let heightProvenance: ProfileProvenance
    let weightProvenance: ProfileProvenance
    let sleepTargetMinutes: Int

    enum CodingKeys: String, CodingKey {
        case timezone, sex, constraints
        case dateOfBirth = "date_of_birth"
        case birthYear = "birth_year"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case weatherEnabled = "weather_enabled"
        case primaryGoal = "primary_goal"
        case secondaryGoals = "secondary_goals"
        case unitSystem = "unit_system"
        case heightProvenance = "height_provenance"
        case weightProvenance = "weight_provenance"
        case sleepTargetMinutes = "sleep_target_minutes"
    }
}

// PATCH distinguishes an explicit clear from an omitted field.
enum ProfileValue: Encodable {
    case text(String), number(Double), bool(Bool), list([String]), object([String: ProfileValue]), null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func optionalText(_ text: String) -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .null : .text(value)
    }
}

enum ProfileInput {
    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !result.contains(value) { result.append(value) }
        }
        return result
    }

    static func validLines(_ text: String, count: Int, length: Int = 160) -> Bool {
        let values = lines(text)
        return values.count <= count && values.allSatisfy { $0.count <= length }
    }

    static func decimal(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned.replacingOccurrences(of: formatter.decimalSeparator, with: ".")),
              value.isFinite else { return nil }
        return value
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...4)))
    }
}
