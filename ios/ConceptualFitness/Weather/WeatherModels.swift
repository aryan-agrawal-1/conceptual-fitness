import Foundation

enum WeatherScene: String, CaseIterable {
    case clearDay
    case clearNight
    case cloudyDay
    case cloudyNight
    case rain
    case snow
    case fog
    case sunrise
    case sunset
    case thunderstorm
}

struct WeatherData: Equatable {
    var weatherCode: String
    var cloudCover: Double
    var precipitationIntensity: Double
    var isDay: Bool
    var sunrise: Date?
    var sunset: Date?
    var date: Date
    var locationName: String?
    var windSpeed: Double?

    var scene: WeatherScene {
        let code = weatherCode.lowercased()
        if minutes(from: sunrise).map({ abs($0) < 75 }) == true { return .sunrise }
        if minutes(from: sunset).map({ abs($0) < 75 }) == true { return .sunset }
        if code.contains("thunder") || code.contains("storm") || code.contains("hurricane") { return .thunderstorm }
        if code.contains("snow") || code.contains("sleet") || code.contains("flurr") || code.contains("wintry") { return .snow }
        if code.contains("rain") || code.contains("drizzle") || code.contains("shower") || precipitationIntensity > 0.08 { return .rain }
        if code.contains("fog") || code.contains("haze") || code.contains("smok") || code.contains("dust") { return .fog }
        if cloudCover > 0.58 || code.contains("cloud") { return isDay ? .cloudyDay : .cloudyNight }
        return isDay ? .clearDay : .clearNight
    }

    var daylightBlend: Double {
        guard let sunrise, let sunset else { return isDay ? 1 : 0 }
        let dayStart = sunrise.timeIntervalSinceReferenceDate
        let dayEnd = sunset.timeIntervalSinceReferenceDate
        let now = date.timeIntervalSinceReferenceDate
        let fade: TimeInterval = 90 * 60
        let sunriseBlend = ((now - (dayStart - fade)) / (fade * 2)).clamped(to: 0...1)
        let sunsetBlend = (1 - ((now - (dayEnd - fade)) / (fade * 2))).clamped(to: 0...1)
        return min(sunriseBlend, sunsetBlend)
    }

    static var fallback: WeatherData {
        let now = Date()
        let sunrise = Calendar.current.date(bySettingHour: 5, minute: 12, second: 0, of: now)
        let sunset = Calendar.current.date(bySettingHour: 21, minute: 8, second: 0, of: now)
        let isDay = sunrise.map { now >= $0 } == true && sunset.map { now <= $0 } == true
        return WeatherData(
            weatherCode: "partlyCloudy",
            cloudCover: 0.34,
            precipitationIntensity: 0,
            isDay: isDay,
            sunrise: sunrise,
            sunset: sunset,
            date: now,
            locationName: "Local weather",
            windSpeed: 2.8
        )
    }

    private func minutes(from event: Date?) -> Double? {
        guard let event else { return nil }
        return date.timeIntervalSince(event) / 60
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
