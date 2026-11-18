import Foundation

// Insights computed on the phone from the retained history. Pure functions: the same history and the same `now`
// always give the same numbers, so they can be tested without a watch or a store.

/// One calendar day of the retained history. Values are nil when the watch sent nothing for that day.
public struct DayInsight: Sendable, Codable, Hashable, Identifiable {
    public var day: Date
    /// bpm
    public var restingHeartRate: Double?
    /// 0-100
    public var averageStress: Double?
    /// Overnight HRV (RMSSD) in ms, the mean of the day's readings.
    public var hrv: Double?
    /// Lowest and highest body battery reading of the day, 0-100.
    public var bodyBatteryLow: Double?
    public var bodyBatteryHigh: Double?
    public var sleepMinutes: Double?
    public var sleepScore: Int?
    public var steps: Double
    /// Sum of the loads of the day's activities, see `HealthInsights.load(of:)`.
    public var trainingLoad: Double

    public var id: Date { day }
}

public enum TrainingStatus: String, Sendable, Codable, CaseIterable {
    /// Not enough history for a 28-day baseline yet.
    case noBaseline
    /// Acute load well below the chronic load.
    case detraining
    /// Acute load close to the chronic load.
    case optimal
    /// Acute load clearly above the chronic load.
    case overreaching
    /// Acute load far above the chronic load.
    case highRisk
}

public struct TrainingLoadStatus: Sendable, Codable, Hashable {
    /// Load of the last seven days, as a weekly total.
    public var acuteLoad: Double
    /// Average weekly load over the last 28 days.
    public var chronicLoad: Double
    /// `acuteLoad / chronicLoad`, nil without a chronic load.
    public var ratio: Double?
    public var status: TrainingStatus
}

public struct HRVStatusAssessment: Sendable, Codable, Hashable {
    /// Average RMSSD (ms) of the last seven nights.
    public var sevenDayAverage: Double
    /// The balanced range the watch set from its baseline, in ms.
    public var balancedRange: ClosedRange<Double>?
    public var status: HRVStatus
}

public enum HealthInsights {
    /// Load of one activity: minutes times its training effect (0 to 5). An activity without a training effect uses
    /// its average heart rate instead: the share of heart rate reserve it used, times 5, so it lands on the same scale.
    public static func load(of activity: Activity, restingHeartRate: Int = 60, maxHeartRate: Int = 190) -> Double {
        let minutes = activity.duration / 60
        if let effect = activity.trainingEffect {
            return minutes * effect
        }
        guard let average = activity.averageHeartRate, maxHeartRate > restingHeartRate else { return 0 }
        let reserve = Double(average - restingHeartRate) / Double(maxHeartRate - restingHeartRate)
        return minutes * min(max(reserve, 0), 1) * 5
    }

    /// Acute load is the last seven days' load. Chronic load is the last 28 days' load divided by four. The ratio of
    /// the two tells whether the body is taking on more than it has been used to. It is `optimal` between 0.8 and 1.3,
    /// `overreaching` below 1.5, and `highRisk` above that; below 0.8 it is `detraining`.
    public static func trainingLoad(_ batch: HealthBatch, now: Date, calendar: Calendar = .current) -> TrainingLoadStatus {
        let today = calendar.startOfDay(for: now)
        var acute = 0.0
        var chronic = 0.0
        for activity in batch.activities {
            let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: activity.start), to: today).day ?? 0
            guard (0..<28).contains(daysAgo) else { continue }
            let load = load(of: activity)
            chronic += load
            if daysAgo < 7 { acute += load }
        }
        let chronicWeekly = chronic / 4

        // The chronic load needs 28 days of history before it means anything.
        let earliest = (batch.heartRate.map(\.date) + batch.activities.map(\.start)).min()
        let hasBaseline = earliest.map { $0 <= today.addingTimeInterval(-27 * 24 * 3600) } ?? false
        guard hasBaseline, chronicWeekly > 0 else {
            return TrainingLoadStatus(acuteLoad: acute, chronicLoad: chronicWeekly, ratio: nil, status: .noBaseline)
        }
        let ratio = acute / chronicWeekly
        let status: TrainingStatus = switch ratio {
        case ..<0.8: .detraining
        case 0.8...1.3: .optimal
        case ..<1.5: .overreaching
        default: .highRisk
        }
        return TrainingLoadStatus(acuteLoad: acute, chronicLoad: chronicWeekly, ratio: ratio, status: status)
    }

    /// The HRV of the last seven nights against the watch's baseline. Below the baseline's lower limit of poor it is
    /// `poor`, below the balanced range `low`, above the balanced range `unbalanced`, and otherwise `balanced`. Without
    /// a baseline the watch's own status is used. Nil when there is no HRV in the last seven days.
    public static func hrvStatus(_ batch: HealthBatch, now: Date, calendar: Calendar = .current) -> HRVStatusAssessment? {
        let today = calendar.startOfDay(for: now)
        func isRecent(_ date: Date) -> Bool {
            let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            return (0..<7).contains(daysAgo)
        }
        let nights = batch.hrvStatus.filter { isRecent($0.date) }.compactMap(\.lastNightAverage)
        let values = nights.isEmpty ? batch.hrv.filter { isRecent($0.date) }.map(\.value) : nights
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Double(values.count)

        let latest = batch.hrvStatus.max { $0.date < $1.date }
        guard let lower = latest?.baselineBalancedLower, let upper = latest?.baselineBalancedUpper,
              let lowUpper = latest?.baselineLowUpper else {
            return HRVStatusAssessment(sevenDayAverage: average, balancedRange: nil, status: latest?.status ?? HRVStatus.none)
        }
        let status: HRVStatus = if average < lowUpper {
            .poor
        } else if average < lower {
            .low
        } else if average > upper {
            .unbalanced
        } else {
            .balanced
        }
        return HRVStatusAssessment(sevenDayAverage: average, balancedRange: lower...upper, status: status)
    }

    /// One entry per calendar day that has any data, oldest first.
    public static func days(_ batch: HealthBatch, calendar: Calendar = .current) -> [DayInsight] {
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

        let resting = Dictionary(batch.restingHeartRate.sorted { $0.date < $1.date }.map { (day($0.date), $0.value) },
                                 uniquingKeysWith: { _, later in later })
        let stress = Dictionary(grouping: batch.stress) { day($0.date) }
        let hrv = Dictionary(grouping: batch.hrv) { day($0.date) }
        let battery = Dictionary(grouping: batch.bodyBattery) { day($0.date) }
        let steps = Dictionary(grouping: batch.steps) { day($0.start) }
        let sleep = Dictionary(grouping: batch.sleep) { day($0.start) }
        let activities = Dictionary(grouping: batch.activities) { day($0.start) }

        let days = Set(resting.keys)
            .union(stress.keys).union(hrv.keys).union(battery.keys).union(steps.keys).union(sleep.keys)
            .union(activities.keys)
        return days.sorted().map { day in
            let levels = battery[day]?.map(\.value) ?? []
            return DayInsight(
                day: day,
                restingHeartRate: resting[day],
                averageStress: mean(stress[day]?.map(\.value) ?? []),
                hrv: mean(hrv[day]?.map(\.value) ?? []),
                bodyBatteryLow: levels.min(),
                bodyBatteryHigh: levels.max(),
                sleepMinutes: sleep[day].map { sessions in
                    sessions.reduce(0) { total, session in total + session.end.timeIntervalSince(session.start) / 60 }
                },
                sleepScore: sleep[day]?.max { $0.start < $1.start }?.score,
                steps: steps[day]?.reduce(0) { $0 + $1.value } ?? 0,
                trainingLoad: activities[day]?.reduce(0) { $0 + load(of: $1) } ?? 0
            )
        }
    }
}
