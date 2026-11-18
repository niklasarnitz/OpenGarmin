import Foundation

// Plain-language facts about the Insights metrics, worked out from the retained history with a few fixed rules. The
// app turns these into sentences; the rules live here so they can be tested without a view. Pure functions: the same
// history and the same `now` always give the same explanation.

/// The daily metrics whose detail screens explain the current value against the user's own history.
public enum InsightMetric: String, Sendable, CaseIterable, Identifiable {
    case stress, bodyBattery, trainingStatus, hrvStatus, restingHeartRate, sleep, sleepScore, steps

    public var id: Self { self }

    /// Whether a higher value is the better direction. Nil where the number alone does not say, as for training load.
    public var higherIsBetter: Bool? {
        switch self {
        case .bodyBattery, .hrvStatus, .sleep, .sleepScore, .steps: true
        case .stress, .restingHeartRate: false
        case .trainingStatus: nil
        }
    }

    /// The day's value, or nil when the day has none. Garmin writes 0 for stress, Body Battery and heart rate when it
    /// could not measure, and a day without steps or training has nothing to compare, so only positive values count.
    public func dailyValue(_ day: DayInsight) -> Double? {
        let value: Double? = switch self {
        case .stress: day.averageStress
        case .bodyBattery: day.bodyBatteryHigh
        case .hrvStatus: day.hrv
        case .restingHeartRate: day.restingHeartRate
        case .sleep: day.sleepMinutes.map { $0 / 60 }
        case .sleepScore: day.sleepScore.map(Double.init)
        case .steps: day.steps
        case .trainingStatus: day.trainingLoad
        }
        guard let value, value > 0 else { return nil }
        return value
    }
}

/// The 7-day average against the 30-day average.
public enum InsightTrend: Sendable, Equatable {
    case higher, lower, similar
}

/// Where the latest value sits against the usual range: the 30-day average plus or minus one standard deviation.
public enum InsightPosition: Sendable, Equatable {
    case below, within, above
}

public enum InsightOutlook: Sendable, Equatable {
    case better, steady, worse
}

/// Something in the recent data that plausibly moves a metric.
public enum InsightFactor: String, Sendable, Equatable, CaseIterable {
    /// Last night's sleep was under seven hours.
    case shortSleep
    /// The last week's training load is well above the four-week average.
    case recentTraining
    /// The last seven days average under 5,000 steps.
    case lowMovement
    /// The 7-day stress average is above the 30-day one.
    case highStress
}

public enum InsightEffect: Sendable, Equatable {
    case raises, lowers
}

public struct InsightDriver: Sendable, Equatable {
    public var factor: InsightFactor
    public var effect: InsightEffect

    public init(factor: InsightFactor, effect: InsightEffect) {
        self.factor = factor
        self.effect = effect
    }
}

public enum InsightSuggestion: Sendable, Equatable, CaseIterable {
    /// Not enough history yet: wear the watch so a baseline can form.
    case keepTracking
    /// The value is better than usual: carry on as before.
    case keepUp
    case protectSleep
    case easierTraining
    /// Training has dropped below the usual load: build back gradually.
    case steadyTraining
    case moveMore
    case breathe
    /// A resting value that stays off for weeks is worth a doctor's look.
    case consultDoctor
}

public struct MetricBaseline: Sendable, Equatable {
    /// The most recent value of the last seven days.
    public var latest: Double?
    public var sevenDayAverage: Double?
    public var thirtyDayAverage: Double?
    /// Sample standard deviation of the last 30 days. The usual range is the 30-day average plus or minus this.
    public var thirtyDayDeviation: Double?
    /// Days with a value in the last 30.
    public var days: Int
}

public struct InsightExplanation: Sendable, Equatable {
    public var baseline: MetricBaseline
    /// Nil until the baseline has `InsightExplanations.minimumBaselineDays` days.
    public var trend: InsightTrend?
    public var position: InsightPosition?
    public var outlook: InsightOutlook?
    /// The factors found in the data that move this metric, in the order of `InsightFactor`.
    public var drivers: [InsightDriver]
    public var suggestions: [InsightSuggestion]
    /// The watch's training status, for `.trainingStatus`.
    public var training: TrainingLoadStatus?
    /// The watch's HRV assessment, for `.hrvStatus`.
    public var hrv: HRVStatusAssessment?
}

public struct StressContextExplanation: Sendable, Equatable {
    /// Working-hours mean minus after-hours mean, in points. Nil without readings in both.
    public var workingAboveAfterHours: Double?
    /// Sleep mean minus after-hours mean, in points. Nil without readings in both.
    public var sleepAboveAfterHours: Double?
    public var suggestions: [InsightSuggestion]
}

public enum InsightExplanations {
    public static let minimumBaselineDays = 7
    /// Changes within this share of the 30-day average count as similar.
    static let similarBand = 0.05
    /// Readings this many points above the after-hours mean make working time stand out.
    static let standOutPoints = 5.0

    public static func explain(_ metric: InsightMetric, days: [DayInsight], batch: HealthBatch, now: Date,
                               calendar: Calendar = .current) -> InsightExplanation {
        let today = calendar.startOfDay(for: now)
        func age(_ day: Date) -> Int { calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0 }
        func series(_ metric: InsightMetric) -> [DayValue] {
            days.compactMap { day in
                let daysAgo = age(day.day)
                guard (0..<30).contains(daysAgo), let value = metric.dailyValue(day) else { return nil }
                return DayValue(daysAgo: daysAgo, value: value)
            }
        }

        let baseline = makeBaseline(series(metric))
        let hasBaseline = baseline.days >= minimumBaselineDays
        let trend = hasBaseline ? trendOf(baseline) : nil
        let position = hasBaseline ? positionOf(baseline) : nil
        var outlook = outlookOf(metric, position: position)
        let training = HealthInsights.trainingLoad(batch, now: now, calendar: calendar)
        let hrv = metric == .hrvStatus ? HealthInsights.hrvStatus(batch, now: now, calendar: calendar) : nil

        var factors: Set<InsightFactor> = []
        let lastNight = days.filter { age($0.day) <= 1 && $0.sleepMinutes != nil }.max { $0.day < $1.day }?.sleepMinutes
        if let lastNight, lastNight < 7 * 60 { factors.insert(.shortSleep) }
        if (training.ratio ?? 0) > 1.3 { factors.insert(.recentTraining) }
        let steps = series(.steps).filter { $0.daysAgo < 7 }
        if steps.count >= 3, steps.map(\.value).reduce(0, +) / Double(steps.count) < 5_000 { factors.insert(.lowMovement) }
        let stressBaseline = makeBaseline(series(.stress))
        if stressBaseline.days >= minimumBaselineDays, trendOf(stressBaseline) == .higher { factors.insert(.highStress) }

        var suggestions: [InsightSuggestion]
        switch metric {
        case .trainingStatus:
            (outlook, suggestions) = trainingAdvice(training.status)
        case .hrvStatus:
            outlook = hrv.flatMap { hrvOutlook($0.status) }
            suggestions = hasBaseline ? generalSuggestions(metric, outlook: outlook, factors: factors) : [.keepTracking]
        default:
            suggestions = hasBaseline ? generalSuggestions(metric, outlook: outlook, factors: factors) : [.keepTracking]
        }

        let drivers = InsightFactor.allCases.compactMap { factor -> InsightDriver? in
            guard factors.contains(factor), let effect = effect(of: factor, on: metric) else { return nil }
            return InsightDriver(factor: factor, effect: effect)
        }

        return InsightExplanation(
            baseline: baseline, trend: trend, position: position, outlook: outlook, drivers: drivers,
            suggestions: suggestions, training: metric == .trainingStatus ? training : nil, hrv: hrv
        )
    }

    /// What the stress readings of the working, after-hours, sleep and weekend contexts say against each other.
    public static func explain(_ stress: StressByContext) -> StressContextExplanation {
        func difference(_ context: StressContext, from other: StressContext) -> Double? {
            guard let a = stress.averages[context], let b = stress.averages[other] else { return nil }
            return a.mean - b.mean
        }
        let working = difference(.working, from: .afterHours)
        let sleep = difference(.sleep, from: .afterHours)
        var suggestions: [InsightSuggestion] = []
        if let working, working >= standOutPoints { suggestions.append(.breathe) }
        if let sleep, sleep > 0 { suggestions.append(.protectSleep) }
        if suggestions.isEmpty, !stress.averages.isEmpty { suggestions.append(.keepUp) }
        if stress.averages.isEmpty { suggestions = [.keepTracking] }
        return StressContextExplanation(workingAboveAfterHours: working, sleepAboveAfterHours: sleep, suggestions: suggestions)
    }

    // MARK: - Rules

    private struct DayValue {
        var daysAgo: Int
        var value: Double
    }

    private static func makeBaseline(_ values: [DayValue]) -> MetricBaseline {
        let recent = values.filter { $0.daysAgo < 7 }
        let all = values.map(\.value)
        return MetricBaseline(
            latest: recent.min { $0.daysAgo < $1.daysAgo }?.value,
            sevenDayAverage: mean(recent.map(\.value)),
            thirtyDayAverage: mean(all),
            thirtyDayDeviation: deviation(all),
            days: all.count
        )
    }

    private static func trendOf(_ baseline: MetricBaseline) -> InsightTrend {
        guard let seven = baseline.sevenDayAverage, let thirty = baseline.thirtyDayAverage, thirty > 0 else { return .similar }
        let change = (seven - thirty) / thirty
        if change > similarBand { return .higher }
        if change < -similarBand { return .lower }
        return .similar
    }

    private static func positionOf(_ baseline: MetricBaseline) -> InsightPosition? {
        guard let latest = baseline.latest, let average = baseline.thirtyDayAverage,
              let deviation = baseline.thirtyDayDeviation else { return nil }
        if latest > average + deviation { return .above }
        if latest < average - deviation { return .below }
        return .within
    }

    private static func outlookOf(_ metric: InsightMetric, position: InsightPosition?) -> InsightOutlook? {
        guard let higherIsBetter = metric.higherIsBetter, let position else { return nil }
        switch position {
        case .within: return .steady
        case .above: return higherIsBetter ? .better : .worse
        case .below: return higherIsBetter ? .worse : .better
        }
    }

    /// Training status has its own bands, so it is not compared with the daily baseline.
    private static func trainingAdvice(_ status: TrainingStatus) -> (InsightOutlook?, [InsightSuggestion]) {
        switch status {
        case .noBaseline: (nil, [.keepTracking])
        case .optimal: (.better, [.keepUp])
        case .detraining: (.steady, [.steadyTraining])
        case .overreaching: (.worse, [.easierTraining, .protectSleep])
        case .highRisk: (.worse, [.easierTraining, .protectSleep])
        }
    }

    /// The watch judges HRV against its own balanced range; a low or poor night is worse, the rest is steady.
    private static func hrvOutlook(_ status: HRVStatus) -> InsightOutlook? {
        switch status {
        case .none: nil
        case .poor, .low: .worse
        case .unbalanced, .balanced: .steady
        }
    }

    private static func effect(of factor: InsightFactor, on metric: InsightMetric) -> InsightEffect? {
        switch (metric, factor) {
        case (.stress, .shortSleep), (.stress, .recentTraining), (.stress, .lowMovement),
             (.restingHeartRate, .shortSleep), (.restingHeartRate, .recentTraining), (.restingHeartRate, .highStress):
            .raises
        case (.bodyBattery, .shortSleep), (.bodyBattery, .recentTraining), (.bodyBattery, .highStress),
             (.hrvStatus, .shortSleep), (.hrvStatus, .recentTraining), (.hrvStatus, .highStress),
             (.sleep, .highStress), (.sleepScore, .highStress):
            .lowers
        default:
            nil
        }
    }

    private static func generalSuggestions(_ metric: InsightMetric, outlook: InsightOutlook?,
                                           factors: Set<InsightFactor>) -> [InsightSuggestion] {
        var suggestions: [InsightSuggestion] = []
        let worse = outlook == .worse
        if outlook == .better { suggestions.append(.keepUp) }
        let sleepMetric = metric == .sleep || metric == .sleepScore
        if factors.contains(.shortSleep) || (sleepMetric && worse) { suggestions.append(.protectSleep) }
        if worse && factors.contains(.recentTraining) { suggestions.append(.easierTraining) }
        if factors.contains(.lowMovement) && outlook != .better { suggestions.append(.moveMore) }
        if (metric == .stress && worse) || factors.contains(.highStress) { suggestions.append(.breathe) }
        if (metric == .restingHeartRate || metric == .hrvStatus) && worse { suggestions.append(.consultDoctor) }
        return suggestions
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation; nil with fewer than two values.
    private static func deviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let average = mean(values) else { return nil }
        let squares = values.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        return (squares / Double(values.count - 1)).squareRoot()
    }
}
