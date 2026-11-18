import EventKit
import GarminModels
import GarminSession

/// Pushes phone-side data to the watch: forecast for the current location and the next days of calendar events.
@MainActor
enum PhoneSync {
    private static let eventStore = EKEventStore()

    static func pushWeather(to watch: any WatchService) async throws {
        guard let location = await LocationProvider.shared.currentLocation() else { return }
        try await watch.sendWeather(try await WeatherSync.report(for: location))
    }

    static func pushCalendar(to watch: any WatchService, days: Int = 2) async throws {
        let start = Date.now
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                              location: event.location, notes: event.notes,
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
            }
        try await watch.sendCalendar(events)
    }
}
