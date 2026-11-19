import Foundation

/// A night of sleep in the user's time zone.
struct SleepNight: Sendable, Equatable {
    /// Local day index of the wake-up.
    let wakeDay: Int
    /// Minutes from 18:00 local to the start of the night, 0 ..< 1440. Keeps bedtimes after midnight in one range.
    let onset: Double
    /// Minutes asleep from start to end.
    let duration: Double

    /// The middle of the night, in the same 18:00-based minutes as `onset`.
    var midpoint: Double { onset + duration / 2 }
}

/// Everything an insight run reads. Days are `CivilDay` indexes in the user's time zone.
struct InsightInput: Sendable {
    /// The days the run covers, both ends included.
    var range: ClosedRange<Int>
    /// Weekdays that are working days, 0 = Monday … 6 = Sunday.
    var workingDays: Set<Int> = [0, 1, 2, 3, 4]
    /// Canonical metric name (the names `/api/v1/metrics` uses for Garmin) → one value per day.
    var series: [String: DailySeries] = [:]
    /// Stress averages of each day by context: `work`, `afterHours`, `free` (weekends and holidays), `sleep`.
    var stressByContext: [String: DailySeries] = [:]
    /// Minutes of recorded activities per day.
    var trainingMinutes: DailySeries = [:]
    var nights: [SleepNight] = []
}

/// Chooses one source value per metric and day, from the rollup rows.
enum InsightSources {
    /// Apple Health identifiers that stand for a Garmin metric, with the factor that converts to the Garmin unit.
    static let aliases: [String: (name: String, scale: Double)] = [
        "HKQuantityTypeIdentifierStepCount": ("steps", 1),
        "HKQuantityTypeIdentifierActiveEnergyBurned": ("activeEnergy", 1),
        "HKQuantityTypeIdentifierRestingHeartRate": ("restingHeartRate", 1),
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": ("hrv", 1),
        "HKQuantityTypeIdentifierOxygenSaturation": ("spo2", 1),
        "HKQuantityTypeIdentifierRespiratoryRate": ("respiration", 1),
        // Apple Health distance is in km (the phone's preferred unit), Garmin's in m.
        "HKQuantityTypeIdentifierDistanceWalkingRunning": ("distance", 1000),
        "HKQuantityTypeIdentifierFlightsClimbed": ("floors", 1),
    ]

    /// One rollup row: a metric's value on a day from one source.
    struct Row: Sendable {
        let day: Int
        let metric: String
        let source: String
        let value: Double
        let count: Int
    }

    /// Exactly one source per metric and day, so nothing is counted twice: Garmin, then what Garmin Connect or the app
    /// wrote into Apple Health (`healthkit:garmin-mirror`, a copy of Garmin data, so only for days Garmin itself lacks),
    /// then the Apple Health source with the most readings that day.
    static func resolve(_ rows: [Row]) -> [String: DailySeries] {
        var chosen: [String: [Int: (rank: Int, count: Int, value: Double)]] = [:]
        for row in rows {
            let rank: Int
            if row.source == "garmin" {
                rank = 3
            } else if row.source == "healthkit:garmin-mirror" {
                rank = 2
            } else if row.source.hasPrefix("healthkit:") {
                rank = 1
            } else {
                continue
            }
            let alias = aliases[row.metric]
            let name = alias?.name ?? row.metric
            let current = chosen[name]?[row.day]
            if current == nil || (rank, row.count) > (current!.rank, current!.count) {
                chosen[name, default: [:]][row.day] = (rank, row.count, row.value * (alias?.scale ?? 1))
            }
        }
        return chosen.mapValues { days in days.mapValues { $0.value } }
    }
}
