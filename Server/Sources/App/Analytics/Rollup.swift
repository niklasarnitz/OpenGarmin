import FluentSQL
import Foundation
import Vapor

/// Daily values per user, metric and source. The dashboard reads this table, so a read is a range scan rather than an
/// aggregate over years of samples. Days are the user's local days. Recomputed for the days each upload touches.
enum Rollup {
    /// Garmin metrics that add up within a day. Every other metric is a reading: averaged, with min and max.
    static let summedGarmin: Set<String> = [
        "steps", "activeEnergy", "restingEnergy", "distance", "floors", "intensityMinutes", "activityMinutes", "sleepMinutes",
        "sleepDeepMinutes", "sleepLightMinutes", "sleepRemMinutes", "sleepAwakeMinutes",
    ]

    /// Apple Health quantity types that are amounts per interval. Every other quantity type is a reading.
    static let summedHealthKit: Set<String> = [
        "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierDistanceSwimming", "HKQuantityTypeIdentifierDistanceWheelchair", "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierBasalEnergyBurned", "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierAppleStandTime", "HKQuantityTypeIdentifierTimeInDaylight", "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "HKQuantityTypeIdentifierDietaryWater", "HKQuantityTypeIdentifierPushCount", "HKQuantityTypeIdentifierSwimmingStrokeCount",
    ]

    static let garminUnits: [String: String] = [
        "steps": "count", "floors": "count", "activeEnergy": "kcal", "restingEnergy": "kcal", "distance": "m",
        "intensityMinutes": "min", "heartRate": "bpm", "restingHeartRate": "bpm", "stress": "score", "bodyBattery": "score",
        "spo2": "%", "respiration": "brpm", "hrv": "ms", "activityMinutes": "min", "sleepMinutes": "min",
        "sleepDeepMinutes": "min", "sleepLightMinutes": "min", "sleepRemMinutes": "min", "sleepAwakeMinutes": "min",
    ]

    /// SQL for the source of a Health row with `source_bundle` on `alias`.
    static func healthSource(_ alias: String) -> String {
        """
        CASE WHEN \(alias).source_bundle = 'com.niklasarnitz.opengarmin' OR \(alias).source_bundle LIKE 'com.garmin%'
             THEN 'healthkit:garmin-mirror' ELSE 'healthkit:' || \(alias).source_bundle END
        """
    }

    static func isSummed(_ metric: String) -> Bool {
        summedGarmin.contains(metric) || summedHealthKit.contains(metric)
    }

    /// Recomputes the days that contain `dates`, in whole days, so every recomputed day is complete.
    static func recompute(over dates: [Date], userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        guard let first = dates.min(), let last = dates.max() else { return }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
        // A day earlier too: Health sleep after midnight belongs to the night that started the evening before.
        var cursor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: first))!
        // A year at a time, so one statement never covers a whole imported history.
        while cursor < end {
            let next = min(calendar.date(byAdding: .day, value: 366, to: cursor)!, end)
            try await aggregate(from: cursor, to: next, userID: userID, sql: sql, calendar: calendar)
            cursor = next
        }
    }

    /// Bumped when the rules change in a way that adds daily values from data already stored. 2: Health sleep and
    /// Health workouts.
    static let version = 2

    /// Computes every user's daily values again whose rollups predate `version`. Rows are upserted, never dropped, so
    /// the dashboard keeps working meanwhile, and uploads that arrive during the run recompute their own days.
    static func upgradeOutdated(_ app: Application) async {
        struct UserRow: Decodable { let id: UUID; let timeZone: String }
        do {
            let sql = try app.db.sql()
            let users = try await sql.raw("""
                SELECT id, time_zone AS "timeZone" FROM users WHERE rollup_version < \(bind: version)
                """).all(decoding: UserRow.self)
            for user in users {
                app.logger.info("Recomputing daily values of user \(user.id) for rollup version \(version)")
                let bounds = try await sql.raw("""
                    SELECT least((SELECT min(ts) FROM samples WHERE user_id = \(bind: user.id)),
                                 (SELECT min(start) FROM healthkit_samples WHERE user_id = \(bind: user.id)),
                                 (SELECT min(start_ts) FROM healthkit_workouts WHERE user_id = \(bind: user.id)),
                                 (SELECT min(start_ts) FROM sleep_sessions WHERE user_id = \(bind: user.id))) AS "first",
                           now() AS "last"
                    """).first(decoding: Bounds.self)
                if let first = bounds?.first, let last = bounds?.last {
                    try await recompute(over: [first, last], userID: user.id, sql: sql, calendar: userCalendar(user.timeZone))
                }
                try await sql.raw("""
                    UPDATE users SET rollup_version = \(bind: version), insights_dirty_at = now() WHERE id = \(bind: user.id)
                    """).run()
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Drops every rollup of the user and computes them again from the raw tables, for a new time zone.
    static func rebuild(userID: UUID, calendar: Calendar, sql: any SQLDatabase) async throws {
        try await sql.raw("DELETE FROM metric_daily WHERE user_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM daily_summaries WHERE user_id = \(bind: userID)").run()
        let bounds = [
            try await sql.raw("SELECT min(ts) AS \"first\", max(ts) AS \"last\" FROM samples WHERE user_id = \(bind: userID)").first(decoding: Bounds.self),
            try await sql.raw("SELECT min(start) AS \"first\", max(start) AS \"last\" FROM healthkit_samples WHERE user_id = \(bind: userID)").first(decoding: Bounds.self),
            try await sql.raw("SELECT min(start_ts) AS \"first\", max(start_ts) AS \"last\" FROM sleep_sessions WHERE user_id = \(bind: userID)").first(decoding: Bounds.self),
            try await sql.raw("SELECT min(start_ts) AS \"first\", max(start_ts) AS \"last\" FROM activities WHERE user_id = \(bind: userID)").first(decoding: Bounds.self),
            try await sql.raw("SELECT min(start_ts) AS \"first\", max(start_ts) AS \"last\" FROM healthkit_workouts WHERE user_id = \(bind: userID)").first(decoding: Bounds.self),
        ]
        let dates = bounds.compactMap { $0 }.flatMap { [$0.first, $0.last] }.compactMap { $0 }
        guard !dates.isEmpty else { return }
        try await Summaries.recompute(over: dates, userID: userID, sql: sql, calendar: calendar)
        try await recompute(over: dates, userID: userID, sql: sql, calendar: calendar)
    }

    private static func aggregate(from start: Date, to end: Date, userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        let zone = calendar.timeZone.identifier
        let units = garminUnits.sorted { $0.key < $1.key }.map { "WHEN '\($0.key)' THEN '\($0.value)'" }.joined(separator: " ")
        let summed = Array(summedGarmin.union(summedHealthKit)).sorted()
        try await sql.raw("""
            INSERT INTO metric_daily (user_id, day, metric, source, unit, value, min, max, count)
            SELECT \(bind: userID), x.day, x.metric, x.source, max(x.unit),
                   CASE WHEN x.metric = ANY(\(bind: summed)::text[]) THEN sum(x.value) ELSE avg(x.value) END,
                   min(x.value), max(x.value), count(*)
            FROM (
              SELECT (s.ts AT TIME ZONE \(bind: zone)::text)::date AS day, s.metric AS metric, 'garmin' AS source,
                     CASE s.metric \(unsafeRaw: units) ELSE NULL END AS unit, s.value AS value
              FROM samples s
              WHERE s.user_id = \(bind: userID) AND s.ts >= \(bind: start) AND s.ts < \(bind: end)
              UNION ALL
              SELECT (ss.start_ts AT TIME ZONE \(bind: zone)::text)::date, 'sleepMinutes', 'garmin', 'min',
                     extract(epoch FROM ss.end_ts - ss.start_ts)::double precision / 60
              FROM sleep_sessions ss
              WHERE ss.user_id = \(bind: userID) AND ss.start_ts >= \(bind: start) AND ss.start_ts < \(bind: end)
              UNION ALL
              SELECT (st.start_ts AT TIME ZONE \(bind: zone)::text)::date,
                     CASE st.stage WHEN 'deep' THEN 'sleepDeepMinutes' WHEN 'light' THEN 'sleepLightMinutes'
                                   WHEN 'rem' THEN 'sleepRemMinutes' ELSE 'sleepAwakeMinutes' END, 'garmin', 'min',
                     extract(epoch FROM st.end_ts - st.start_ts)::double precision / 60
              FROM sleep_stages st JOIN sleep_sessions ss ON ss.id = st.session_id
              WHERE ss.user_id = \(bind: userID) AND st.start_ts >= \(bind: start) AND st.start_ts < \(bind: end)
                AND st.stage IN ('deep', 'light', 'rem', 'awake')
              UNION ALL
              SELECT (a.start_ts AT TIME ZONE \(bind: zone)::text)::date, 'activityMinutes', 'garmin', 'min', a.duration / 60
              FROM activities a
              WHERE a.user_id = \(bind: userID) AND a.start_ts >= \(bind: start) AND a.start_ts < \(bind: end)
              UNION ALL
              -- Health workouts that no Garmin activity covers.
              SELECT (w.start_ts AT TIME ZONE \(bind: zone)::text)::date, 'activityMinutes', \(unsafeRaw: healthSource("w")), 'min',
                     w.duration / 60
              FROM healthkit_workouts w
              WHERE w.user_id = \(bind: userID) AND w.start_ts >= \(bind: start) AND w.start_ts < \(bind: end)
                AND \(unsafeRaw: HealthSleep.workoutNotOnGarmin)
              UNION ALL
              -- Health sleep, by night: a sample belongs to the day 12 hours before it, like a night that starts that
              -- evening. Each sample counts once in total sleep (awake excluded) and once in its stage.
              SELECT ((hs.start AT TIME ZONE \(bind: zone)::text) - interval '12 hours')::date, m.metric, \(unsafeRaw: healthSource("hs")),
                     'min', extract(epoch FROM hs.end_ts - hs.start)::double precision / 60
              FROM healthkit_samples hs
              CROSS JOIN LATERAL (VALUES
                (CASE WHEN hs.category_value IN (1, 3, 4, 5) THEN 'sleepMinutes' END),
                (CASE hs.category_value WHEN 2 THEN 'sleepAwakeMinutes' WHEN 3 THEN 'sleepLightMinutes'
                                        WHEN 4 THEN 'sleepDeepMinutes' WHEN 5 THEN 'sleepRemMinutes' END)
              ) AS m(metric)
              WHERE hs.user_id = \(bind: userID) AND hs.type = 'HKCategoryTypeIdentifierSleepAnalysis' AND m.metric IS NOT NULL
                AND hs.start >= \(bind: start.addingTimeInterval(12 * 3600)) AND hs.start < \(bind: end.addingTimeInterval(12 * 3600))
              UNION ALL
              SELECT (h.start AT TIME ZONE \(bind: zone)::text)::date, h.type,
                     CASE WHEN h.source_bundle = 'com.niklasarnitz.opengarmin' OR h.source_bundle LIKE 'com.garmin%'
                          THEN 'healthkit:garmin-mirror' ELSE 'healthkit:' || h.source_bundle END,
                     h.unit, h.value
              FROM healthkit_samples h
              WHERE h.user_id = \(bind: userID) AND h.start >= \(bind: start) AND h.start < \(bind: end)
                AND h.value IS NOT NULL AND h.type LIKE 'HKQuantityType%'
            ) AS x
            GROUP BY x.day, x.metric, x.source
            ON CONFLICT (user_id, day, metric, source) DO UPDATE SET
              unit = EXCLUDED.unit, value = EXCLUDED.value, min = EXCLUDED.min, max = EXCLUDED.max, count = EXCLUDED.count
            """).run()
    }

    // MARK: - Reads

    static func metrics(_ req: Request, user: AuthenticatedUser) async throws -> [MetricInfo] {
        let rows = try await req.sql.raw("""
            SELECT metric, source, max(unit) AS unit, to_char(min(day), 'YYYY-MM-DD') AS "first",
                   to_char(max(day), 'YYYY-MM-DD') AS "last", sum(count) AS count
            FROM metric_daily WHERE user_id = \(bind: user.id)
            GROUP BY metric, source ORDER BY metric, source
            """).all(decoding: MetricRow.self)
        return rows.map { row in
            MetricInfo(
                metric: row.metric, source: row.source, unit: row.unit,
                aggregation: isSummed(row.metric) ? "sum" : "avg",
                first: row.first, last: row.last, count: row.count
            )
        }
    }

    /// The daily values in the range, for the named metrics (all of them when `metrics` is empty).
    static func daily(_ req: Request, user: AuthenticatedUser, window: Reads.Window, metrics: [String]) async throws -> [MetricDay] {
        let zone = user.timeZone
        let rows = try await req.sql.raw("""
            SELECT to_char(day, 'YYYY-MM-DD') AS day, metric, source, value, min, max, count FROM metric_daily
            WHERE user_id = \(bind: user.id)
              AND day >= (\(bind: window.from)::timestamptz AT TIME ZONE \(bind: zone)::text)::date
              AND day < (\(bind: window.to)::timestamptz AT TIME ZONE \(bind: zone)::text)::date
              AND (cardinality(\(bind: metrics)::text[]) = 0 OR metric = ANY(\(bind: metrics)::text[]))
            ORDER BY day, metric, source
            """).all(decoding: DailyRow.self)
        return rows.map { row in
            let reading = !isSummed(row.metric)
            return MetricDay(day: row.day, metric: row.metric, source: row.source, value: row.value,
                             min: reading ? row.min : nil, max: reading ? row.max : nil, count: row.count)
        }
    }
}

struct MetricInfo: Content {
    let metric: String
    let source: String
    let unit: String?
    /// "sum" for amounts per day, "avg" for readings (with min and max in `/metrics/daily`).
    let aggregation: String
    let first: String
    let last: String
    /// Number of underlying samples.
    let count: Int
}

struct MetricDay: Content {
    let day: String
    let metric: String
    let source: String
    let value: Double
    let min: Double?
    let max: Double?
    /// Number of underlying samples, so a client can pick the fullest of several sources on a day.
    let count: Int
}

private struct Bounds: Decodable {
    let first: Date?
    let last: Date?
}

private struct MetricRow: Decodable {
    let metric: String
    let source: String
    let unit: String?
    let first: String
    let last: String
    let count: Int
}

private struct DailyRow: Decodable {
    let day: String
    let metric: String
    let source: String
    let value: Double
    let min: Double?
    let max: Double?
    let count: Int
}
