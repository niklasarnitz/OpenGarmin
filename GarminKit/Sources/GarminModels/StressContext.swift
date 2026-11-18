import Foundation

/// When the user works. Stress readings inside these hours on these weekdays count as working time.
public struct WorkingHours: Sendable, Codable, Hashable {
    /// `Calendar` weekdays: 1 is Sunday, 2 Monday ... 7 Saturday.
    public var weekdays: Set<Int>
    /// Minutes after midnight. The window runs from `startMinute` (inclusive) to `endMinute` (exclusive).
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Monday to Friday, 9:00 to 17:00.
    public static let standard = WorkingHours(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 17 * 60)

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard weekdays.contains(calendar.component(.weekday, from: date)) else { return false }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        return minute >= startMinute && minute < endMinute
    }
}

/// The part of the day a stress reading belongs to. Each reading has exactly one context.
public enum StressContext: String, Sendable, Codable, CaseIterable {
    /// Awake inside the working hours.
    case working
    /// Awake on a weekday outside the working hours.
    case afterHours
    /// Inside one of the night's sleep sessions.
    case sleep
    /// Awake on a Saturday or Sunday outside the working hours.
    case weekend
}

public struct StressContextAverage: Sendable, Hashable {
    /// Mean of the readings, 0-100.
    public var mean: Double
    /// How many readings went into the mean.
    public var readings: Int

    public init(mean: Double, readings: Int) {
        self.mean = mean
        self.readings = readings
    }
}

public struct StressByContext: Sendable, Hashable {
    /// The contexts that have readings. A context without readings is absent.
    public var averages: [StressContext: StressContextAverage]

    public init(averages: [StressContext: StressContextAverage] = [:]) {
        self.averages = averages
    }
}

public enum StressContexts {
    /// Averages the stress readings inside `interval` per context. A reading of 0 means the watch did not measure,
    /// so it is left out, as the charts leave it out.
    public static func summarize(stress: [PointSample], sleep: [SleepSession], interval: DateInterval,
                                 workingHours: WorkingHours, calendar: Calendar = .current) -> StressByContext {
        var totals: [StressContext: (sum: Double, count: Int)] = [:]
        for reading in stress where reading.value > 0 && interval.contains(reading.date) {
            let context = context(of: reading.date, sleep: sleep, workingHours: workingHours, calendar: calendar)
            totals[context, default: (0, 0)].sum += reading.value
            totals[context, default: (0, 0)].count += 1
        }
        return StressByContext(averages: totals.mapValues { StressContextAverage(mean: $0.sum / Double($0.count), readings: $0.count) })
    }

    /// Sleep wins over everything, so a night's readings stay in the sleep context even when they fall inside the
    /// working hours of a weekday. Then working hours, then weekends; the rest is after hours.
    public static func context(of date: Date, sleep: [SleepSession], workingHours: WorkingHours,
                               calendar: Calendar = .current) -> StressContext {
        if sleep.contains(where: { $0.start <= date && date < $0.end }) { return .sleep }
        if workingHours.contains(date, calendar: calendar) { return .working }
        if calendar.isDateInWeekend(date) { return .weekend }
        return .afterHours
    }
}
