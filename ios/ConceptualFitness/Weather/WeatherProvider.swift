import CoreLocation
import Foundation
import WeatherKit

struct WeatherProvider {
    func weather(for location: CLLocation?, locationName: String?) async -> WeatherData {
        guard let location else {
            var fallback = WeatherData.fallback
            fallback.locationName = locationName ?? "Weather preview"
            fallback.date = Date()
            return fallback
        }

        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let today = weather.dailyForecast.first { Calendar.current.isDate($0.date, inSameDayAs: current.date) }
                ?? weather.dailyForecast.first

            return WeatherData(
                weatherCode: current.condition.rawValue,
                cloudCover: current.cloudCover,
                precipitationIntensity: current.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000,
                isDay: current.isDaylight,
                sunrise: today?.sun.sunrise,
                sunset: today?.sun.sunset,
                date: current.date,
                locationName: locationName ?? current.condition.description,
                windSpeed: current.wind.speed.converted(to: .metersPerSecond).value
            )
        } catch {
            var fallback = WeatherData.fallback
            fallback.locationName = locationName ?? "Weather fallback"
            fallback.date = Date()
            return fallback
        }
    }
}
