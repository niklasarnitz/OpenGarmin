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

    static func isSummed(_ metric: String) -> Bool {
        summedGarmin.contains(metric) || summedHealthKit.contains(metric)
    }

    /// Recomputes the days that contain `dates`, in whole days, so every recomputed day is complete.
    static func recompute(over dates: [Date], userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        guard let first = dates.min(), let last = dates.max() else { return }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
        var cursor = calendar.startOfDay(for: first)
        // A year at a time, so one statement never covers a whole imported history.
        while cursor < end {
            let next = min(calendar.date(byAdding: .day, value: 366, to: cursor)!, end)
            try await aggregate(from: cursor, to: next, userID: userID, sql: sql, calendar: calendar)
            cursor = next
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
            SELECT to_char(day, 'YYYY-MM-DD') AS day, metric, source, value, min, max FROM metric_daily
            WHERE user_id = \(bind: user.id)
              AND day >= (\(bind: window.from)::timestamptz AT TIME ZONE \(bind: zone)::text)::date
              AND day < (\(bind: window.to)::timestamptz AT TIME ZONE \(bind: zone)::text)::date
              AND (cardinality(\(bind: metrics)::text[]) = 0 OR metric = ANY(\(bind: metrics)::text[]))
            ORDER BY day, metric, source
            """).all(decoding: DailyRow.self)
        return rows.map { row in
            let reading = !isSummed(row.metric)
            return MetricDay(day: row.day, metric: row.metric, source: row.source, value: row.value,
                             min: reading ? row.min : nil, max: reading ? row.max : nil)
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
}
