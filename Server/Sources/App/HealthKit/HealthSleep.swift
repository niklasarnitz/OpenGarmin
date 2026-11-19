import FluentSQL
import Foundation

/// Nights and workouts from Apple Health (including what Google Fit and other apps wrote there), shaped like Garmin's
/// sleep sessions and activities, for the days Garmin has none. Garmin always wins where both exist, so nothing is
/// counted twice.
enum HealthSleep {
    static let type = "HKCategoryTypeIdentifierSleepAnalysis"
    /// Samples of one source further apart than this are separate nights.
    static let nightGap: TimeInterval = 2 * 3600

    /// HKCategoryValueSleepAnalysis → stage name. 0 (in bed) is not sleep and is left out.
    static func stage(_ value: Int) -> String? {
        switch value {
        case 1: "asleep"
        case 2: "awake"
        case 3: "light"
        case 4: "deep"
        case 5: "rem"
        default: nil
        }
    }

    /// The source a Health sample is reported under: Garmin's copy in Health, or the writing app.
    static func source(_ bundle: String) -> String {
        bundle == "com.niklasarnitz.opengarmin" || bundle.hasPrefix("com.garmin") ? "healthkit:garmin-mirror" : "healthkit:\(bundle)"
    }

    /// SQL condition on `w` (healthkit_workouts): the workout does not overlap a Garmin activity of the user.
    static let workoutNotOnGarmin = """
        NOT EXISTS (SELECT 1 FROM activities a WHERE a.user_id = w.user_id AND a.start_ts < w.end_ts AND w.start_ts < a.end_ts)
        """

    struct Sample: Decodable, Sendable {
        let start: Date
        let end: Date
        let value: Int
        let bundle: String
    }

    struct Night: Sendable, Equatable {
        var start: Date
        var end: Date
        var source: String
        var stages: [SleepStageDTO]

        var asleepSeconds: TimeInterval {
            stages.filter { $0.stage != "awake" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }
    }

    /// Health nights that start in [from, to) and overlap no Garmin session. Where several apps recorded the same night,
    /// Garmin's copy in Health wins, then the one with the most sleep.
    static func nights(_ sql: any SQLDatabase, userID: UUID, from: Date, to: Date) async throws -> [Night] {
        let samples = try await sql.raw("""
            SELECT start, end_ts AS "end", category_value AS "value", source_bundle AS "bundle" FROM healthkit_samples
            WHERE user_id = \(bind: userID) AND type = \(bind: type) AND category_value BETWEEN 1 AND 5
              AND start >= \(bind: from.addingTimeInterval(-nightGap)) AND start < \(bind: to.addingTimeInterval(18 * 3600))
            ORDER BY start
            """).all(decoding: Sample.self)
        guard !samples.isEmpty else { return [] }
        let garmin = try await sql.raw("""
            SELECT start_ts AS "start", end_ts AS "end" FROM sleep_sessions
            WHERE user_id = \(bind: userID) AND end_ts > \(bind: from.addingTimeInterval(-nightGap))
              AND start_ts < \(bind: to.addingTimeInterval(18 * 3600))
            """).all(decoding: Span.self)
        return select(group(samples), garmin: garmin).filter { $0.start >= from && $0.start < to }
    }

    struct Span: Decodable, Sendable {
        let start: Date
        let end: Date
    }

    /// Samples of one source, in order, become nights wherever they are more than `nightGap` apart.
    static func group(_ samples: [Sample]) -> [Night] {
        var nights: [Night] = []
        for (bundle, rows) in Dictionary(grouping: samples, by: \.bundle) {
            var current: Night?
            for row in rows.sorted(by: { $0.start < $1.start }) {
                guard let stage = stage(row.value) else { continue }
                let dto = SleepStageDTO(start: row.start, end: row.end, stage: stage)
                if var night = current, row.start.timeIntervalSince(night.end) <= nightGap {
                    night.end = max(night.end, row.end)
                    night.stages.append(dto)
                    current = night
                } else {
                    if let night = current { nights.append(night) }
                    current = Night(start: row.start, end: row.end, source: source(bundle), stages: [dto])
                }
            }
            if let night = current { nights.append(night) }
        }
        return nights
    }

    /// One night per span of time: no night that overlaps Garmin, and of overlapping Health nights the mirror first,
    /// then the one with the most sleep. Nights without any sleep are dropped.
    static func select(_ candidates: [Night], garmin: [Span]) -> [Night] {
        func overlaps(_ a: (Date, Date), _ b: (Date, Date)) -> Bool { a.0 < b.1 && b.0 < a.1 }
        let ordered = candidates.filter { $0.asleepSeconds > 0 }.sorted {
            let (ra, rb) = ($0.source == "healthkit:garmin-mirror" ? 1 : 0, $1.source == "healthkit:garmin-mirror" ? 1 : 0)
            return ra != rb ? ra > rb : $0.asleepSeconds > $1.asleepSeconds
        }
        var taken = garmin.map { ($0.start, $0.end) }
        var chosen: [Night] = []
        for night in ordered where !taken.contains(where: { overlaps($0, (night.start, night.end)) }) {
            chosen.append(night)
            taken.append((night.start, night.end))
        }
        return chosen.sorted { $0.start < $1.start }
    }
}
