import SwiftUI
import GarminModels

extension WorkingHours {
    /// The working hours are saved as JSON under this key. Monday to Friday, 9 to 5, until the user changes them.
    static let storageKey = "insights.workingHours"

    static func saved(_ data: Data) -> WorkingHours {
        (try? JSONDecoder().decode(WorkingHours.self, from: data)) ?? .standard
    }

    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

extension StressContext {
    var title: LocalizedStringKey {
        switch self {
        case .working: "Working hours"
        case .afterHours: "After hours"
        case .sleep: "Asleep"
        case .weekend: "Weekends"
        }
    }
}

/// The four mean stress values in a two-column grid. Used by the Insights card and the detail screen.
struct StressContextGrid: View {
    let summary: StressByContext
    var showsReadings = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 14) {
            ForEach(StressContext.allCases, id: \.self) { context in
                let average = summary.averages[context]
                VStack(alignment: .leading, spacing: 2) {
                    Text(average.map { Formatting.whole($0.mean) } ?? "–")
                        .font(.figure(28, weight: .semibold))
                        .monospacedDigit()
                    Text(context.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsReadings {
                        Group {
                            if let average {
                                Text("\(average.readings) readings")
                            } else {
                                Text("No readings")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Mean stress while working, after hours, asleep and at weekends: the selected range and today. The working hours
/// are editable here and saved on the phone.
struct StressContextView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(WorkingHours.storageKey) private var workingHoursData = Data()
    let interval: DateInterval

    private var workingHours: WorkingHours { .saved(workingHoursData) }

    private var rangeSummary: StressByContext { summary(interval) }

    private var todaySummary: StressByContext {
        summary(Calendar.current.dateInterval(of: .day, for: .now)!)
    }

    private func summary(_ interval: DateInterval) -> StressByContext {
        let data = app.watch.latest
        return StressContexts.summarize(stress: data.stress, sleep: data.sleep, interval: interval, workingHours: workingHours)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MetricTile("Selected range", symbol: "calendar", tint: Palette.amber) {
                    StressContextGrid(summary: rangeSummary, showsReadings: true)
                }
                MetricTile("Today", symbol: "sun.max.fill", tint: Palette.amber) {
                    StressContextGrid(summary: todaySummary, showsReadings: true)
                }
                explanation
                about
                workingHoursEditor
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Stress by context")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var explanation: some View {
        let explanation = InsightExplanations.explain(rangeSummary)
        return MetricTile("What stands out", symbol: "lightbulb.fill", tint: Palette.amber) {
            if rangeSummary.averages.isEmpty {
                Text("No stress readings in this range yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let working = explanation.workingAboveAfterHours {
                Text(Self.workingSentence(working))
            }
            if let sleep = explanation.sleepAboveAfterHours {
                Text(Self.sleepSentence(sleep))
            }
            ForEach(explanation.suggestions, id: \.self) { suggestion in
                Label(suggestion.text, systemImage: "checkmark.circle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    private var about: some View {
        MetricTile("About this", symbol: "info.circle.fill", tint: .secondary) {
            Text("Each stress reading is filed under one context. Sleep comes first: readings inside a night's sleep count as asleep. Weekends are awake time on Saturday and Sunday outside working hours. Readings of 0 were not measured and are left out.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var workingHoursEditor: some View {
        MetricTile("Working hours", symbol: "briefcase.fill", tint: Palette.dusk) {
            Text("Working days")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in dayButton(weekday) }
            }
            DatePicker("Start", selection: startBinding, displayedComponents: .hourAndMinute)
            DatePicker("End", selection: endBinding, displayedComponents: .hourAndMinute)
            if workingHours.endMinute <= workingHours.startMinute {
                Text("End must be after the start. Until then, no reading counts as working time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayButton(_ weekday: Int) -> some View {
        let selected = workingHours.weekdays.contains(weekday)
        return Button {
            update { hours in
                if selected { hours.weekdays.remove(weekday) } else { hours.weekdays.insert(weekday) }
            }
        } label: {
            Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(selected ? Palette.dusk : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var startBinding: Binding<Date> {
        Binding(get: { Self.date(minute: workingHours.startMinute) },
                set: { date in update { $0.startMinute = Self.minute(of: date) } })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { Self.date(minute: workingHours.endMinute) },
                set: { date in update { $0.endMinute = Self.minute(of: date) } })
    }

    private func update(_ change: (inout WorkingHours) -> Void) {
        var hours = workingHours
        change(&hours)
        workingHoursData = hours.encoded
    }

    private static func date(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    private static func minute(of date: Date) -> Int {
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (time.hour ?? 0) * 60 + (time.minute ?? 0)
    }

    private static func workingSentence(_ points: Double) -> LocalizedStringKey {
        if abs(points) < 1 { return "Working hours and after hours are about the same." }
        let amount = Formatting.whole(abs(points))
        return points > 0
            ? "Working hours are \(amount) points higher than after hours."
            : "Working hours are \(amount) points lower than after hours."
    }

    private static func sleepSentence(_ points: Double) -> LocalizedStringKey {
        if abs(points) < 1 { return "Stress while asleep is about the same as after hours." }
        let amount = Formatting.whole(abs(points))
        return points > 0
            ? "Stress while asleep is \(amount) points higher than after hours."
            : "Stress while asleep is \(amount) points lower than after hours."
    }
}
