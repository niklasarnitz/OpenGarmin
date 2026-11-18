import EventKit
import Foundation
import GarminModels
import GarminSession

/// Calendar events for the watch. The watch asks for them over GFDI; the phone keeps the copy the watch gets
/// current by pushing a fresh list whenever EventKit reports a change.
@MainActor
enum CalendarSync {
    /// The Device tab's toggle, and the settings it reads, are stored under these keys.
    static let enabledKey = "feature.calendar"
    static let lookaheadDaysKey = "calendar.lookaheadDays"
    static let excludedCalendarsKey = "calendar.excludedCalendars"
    static let defaultLookaheadDays = 7

    private static let store = EKEventStore()

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var lookaheadDays: Int {
        let days = UserDefaults.standard.integer(forKey: lookaheadDaysKey)
        return days > 0 ? days : defaultLookaheadDays
    }

    /// Calendars the user turned off, by identifier. Calendars added later sync until the user turns them off.
    static var excludedCalendars: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: excludedCalendarsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: excludedCalendarsKey) }
    }

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for full access, which the watch needs to read event titles and places. iOS only shows the prompt once.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func calendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    /// The events the watch can show: the calendars the user kept, from now until the chosen number of days ahead.
    /// Empty while the feature is off or access is missing, so the watch drops events it still holds.
    static func events() -> [CalendarEvent] {
        guard isEnabled, hasAccess else { return [] }
        let selected = calendars().filter { !excludedCalendars.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let start = Date.now
        let end = Calendar.current.date(byAdding: .day, value: lookaheadDays, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                              location: event.location, notes: event.notes,
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
            }
    }

    static func push(to watch: any WatchService) async throws {
        try await watch.sendCalendar(events())
    }

    /// Pushes fresh events to the watch after EventKit changes, once the changes have settled for two seconds.
    static func pushChanges(to watch: any WatchService) {
        Task {
            var pending: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    try? await push(to: watch)
                }
            }
        }
    }
}
