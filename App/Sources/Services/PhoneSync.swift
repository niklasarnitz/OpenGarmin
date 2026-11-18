import GarminModels
import GarminSession

/// Phone-side data for the watch: the forecast for the current location.
@MainActor
enum PhoneSync {
    /// The forecast for the current location, or nil when no location is available.
    static func weatherReport() async throws -> WeatherReport? {
        guard let location = await LocationProvider.shared.currentLocation() else { return nil }
        return try await WeatherSync.report(for: location)
    }

    static func pushWeather(to watch: any WatchService) async throws {
        guard let report = try await weatherReport() else { return }
        try await watch.sendWeather(report)
    }
}
