import CoreLocation
import MapKit
import WeatherKit
import GarminModels

/// Turns WeatherKit's current conditions and forecast into the watch's weather payload.
enum WeatherSync {
    static func report(for location: CLLocation) async throws -> WeatherReport {
        let weather = try await WeatherKit.WeatherService.shared.weather(for: location)
        let now = weather.currentWeather
        let today = weather.dailyForecast.forecast.first
        var locality: String?
        if let request = MKReverseGeocodingRequest(location: location),
           let items = try? await request.mapItems {
            locality = items.first?.addressRepresentations?.cityName
        }
        let nowCelsius = now.temperature.converted(to: .celsius).value

        return WeatherReport(
            date: now.date,
            locationName: locality ?? "Current location",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            temperatureCelsius: nowCelsius,
            feelsLikeCelsius: now.apparentTemperature.converted(to: .celsius).value,
            lowCelsius: today?.lowTemperature.converted(to: .celsius).value ?? nowCelsius,
            highCelsius: today?.highTemperature.converted(to: .celsius).value ?? nowCelsius,
            condition: condition(now.condition),
            humidity: Int(now.humidity * 100),
            windSpeedMps: now.wind.speed.converted(to: .metersPerSecond).value,
            windDirectionDegrees: Int(now.wind.direction.converted(to: .degrees).value),
            precipitationChance: Int((today?.precipitationChance ?? 0) * 100),
            uvIndex: Double(now.uvIndex.value),
            hourly: weather.hourlyForecast.forecast.prefix(24).map { hour in
                WeatherForecastHour(
                    date: hour.date,
                    temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                    condition: condition(hour.condition),
                    precipitationChance: Int(hour.precipitationChance * 100))
            },
            daily: weather.dailyForecast.forecast.prefix(7).map { day in
                WeatherForecastDay(
                    date: day.date,
                    lowCelsius: day.lowTemperature.converted(to: .celsius).value,
                    highCelsius: day.highTemperature.converted(to: .celsius).value,
                    condition: condition(day.condition),
                    precipitationChance: Int(day.precipitationChance * 100))
            })
    }

    private static func condition(_ value: WeatherKit.WeatherCondition) -> GarminModels.WeatherCondition {
        switch value {
        case .clear, .mostlyClear: .clear
        case .partlyCloudy: .partlyCloudy
        case .mostlyCloudy: .mostlyCloudy
        case .cloudy: .cloudy
        case .drizzle: .lightRain
        case .rain, .sunShowers: .rain
        case .heavyRain: .heavyRain
        case .snow, .flurries, .sunFlurries: .snow
        case .heavySnow, .blizzard: .heavySnow
        case .sleet, .freezingRain, .wintryMix: .sleet
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms: .thunderstorm
        case .foggy: .fog
        case .haze, .smoky: .haze
        case .windy, .breezy: .windy
        case .hail: .hail
        default: .unknown
        }
    }
}
