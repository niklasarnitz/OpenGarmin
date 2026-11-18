import EventKit
import SwiftUI

/// Which calendars sync to the watch, and how many days ahead they reach.
struct CalendarSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(CalendarSync.lookaheadDaysKey) private var lookaheadDays = CalendarSync.defaultLookaheadDays
    @State private var calendars: [EKCalendar] = []
    @State private var excluded = CalendarSync.excludedCalendars
    @State private var hasAccess = CalendarSync.hasAccess

    var body: some View {
        Form {
            Section {
                Picker("Show events", selection: $lookaheadDays) {
                    ForEach([1, 2, 3, 7, 14, 30], id: \.self) { days in
                        Text(days == 1 ? "1 day ahead" : "\(days) days ahead").tag(days)
                    }
                }
            } footer: {
                Text("The watch shows events from now until this far ahead.")
            }

            Section("Calendars") {
                if hasAccess {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            HStack(spacing: 12) {
                                Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calendar.title)
                                    Text(calendar.source.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("OpenGarmin needs full access to your calendars. Allow it in Settings, Privacy and Security, Calendars.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Calendars")
        .task {
            hasAccess = await CalendarSync.requestAccess()
            calendars = CalendarSync.calendars().sorted { $0.title < $1.title }
        }
        .onChange(of: lookaheadDays) { _, _ in push() }
    }

    private func binding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(calendar.calendarIdentifier) },
            set: { included in
                if included { excluded.remove(calendar.calendarIdentifier) } else { excluded.insert(calendar.calendarIdentifier) }
                CalendarSync.excludedCalendars = excluded
                push()
            }
        )
    }

    private func push() {
        Task { try? await CalendarSync.push(to: app.watch) }
    }
}
