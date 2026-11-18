import EventKit
import GarminModels
import GarminSession

/// Phone-side data for the watch: the forecast for the current location and the next days of calendar events.
@MainActor
enum PhoneSync {
    private static let eventStore = EKEventStore()

    /// The forecast for the current location, or nil when no location is available.
    static func weatherReport() async throws -> WeatherReport? {
        guard let location = await LocationProvider.shared.currentLocation() else { return nil }
        return try await WeatherSync.report(for: location)
    }

    static func pushWeather(to watch: any WatchService) async throws {
        guard let report = try await weatherReport() else { return }
        try await watch.sendWeather(report)
    }

    static func calendarEvents(days: Int = 2) -> [CalendarEvent] {
        let start = Date.now
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                              location: event.location, notes: event.notes,
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
            }
    }

    static func pushCalendar(to watch: any WatchService, days: Int = 2) async throws {
        try await watch.sendCalendar(calendarEvents(days: days))
    }
}
