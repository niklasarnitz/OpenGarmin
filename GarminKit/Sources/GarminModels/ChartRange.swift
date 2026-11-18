import Foundation

/// The date ranges the Insights screen offers. `custom` takes its days from the caller.
public enum ChartRangePreset: String, Sendable, CaseIterable, Identifiable {
    case lastWeek, thisMonth, lastMonth, thisYear, custom

    public var id: Self { self }

    /// The range as a half-open interval of whole local days. "Last week" is the last seven days including today;
    /// the month and year presets are calendar periods, with the current ones ending at the end of today.
    /// `custom` spans the days of `from` through `to`, in either order.
    public func interval(now: Date, from: Date = .now, to: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch self {
        case .lastWeek:
            return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: today)!, end: tomorrow)
        case .thisMonth:
            return DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: tomorrow)
        case .lastMonth:
            let previous = calendar.date(byAdding: .month, value: -1, to: now)!
            return calendar.dateInterval(of: .month, for: previous)!
        case .thisYear:
            return DateInterval(start: calendar.dateInterval(of: .year, for: now)!.start, end: tomorrow)
        case .custom:
            let first = calendar.startOfDay(for: min(from, to))
            let last = calendar.startOfDay(for: max(from, to))
            return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last)!)
        }
    }
}

/// Smoothing for charts that span several days, so minute-level readings such as stress do not draw as noise.
public enum ChartSmoothing {
    /// How wide one averaged bucket is for a chart spanning `span` seconds. Nil keeps the raw points (up to 36 hours).
    public static func bucketWidth(forSpan span: TimeInterval) -> TimeInterval? {
        switch span {
        case ...(36 * 3600): nil
        case ...(8 * 86_400): 3600
        case ...(35 * 86_400): 4 * 3600
        default: 86_400
        }
    }

    /// The points averaged into buckets sized for their own span, then each bucket averaged with its direct neighbours
    /// (a centred moving average over three buckets). Buckets without readings stay gaps: a neighbour only counts when
    /// it holds readings, so a night without data is not bridged. Each point sits at the middle of its bucket.
    public static func smoothed(_ points: [PointSample]) -> [PointSample] {
        guard let first = points.min(by: { $0.date < $1.date })?.date,
              let last = points.max(by: { $0.date < $1.date })?.date,
              let width = bucketWidth(forSpan: last.timeIntervalSince(first)) else { return points }
        let origin = (first.timeIntervalSinceReferenceDate / width).rounded(.down) * width
        var sums: [Int: (total: Double, count: Int)] = [:]
        for point in points {
            let index = Int(((point.date.timeIntervalSinceReferenceDate - origin) / width).rounded(.down))
            sums[index, default: (0, 0)].total += point.value
            sums[index, default: (0, 0)].count += 1
        }
        let means = sums.mapValues { $0.total / Double($0.count) }
        return means.keys.sorted().map { index in
            let window = [index - 1, index, index + 1].compactMap { means[$0] }
            return PointSample(date: Date(timeIntervalSinceReferenceDate: origin + (Double(index) + 0.5) * width),
                               value: window.reduce(0, +) / Double(window.count))
        }
    }

    /// The mean of each day and the up to `days - 1` days before it that have a value, for long daily trends.
    public static func rollingMean(_ points: [PointSample], days: Int, calendar: Calendar = .current) -> [PointSample] {
        let sorted = points.sorted { $0.date < $1.date }
        return sorted.map { point in
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: point.date))!
            let window = sorted.filter { $0.date >= start && $0.date <= point.date }
            return PointSample(date: point.date, value: window.map(\.value).reduce(0, +) / Double(window.count))
        }
    }
}
