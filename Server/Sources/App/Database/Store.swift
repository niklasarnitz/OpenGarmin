import FluentSQL
import Foundation
import GarminModels

typealias Row = [any Encodable & Sendable]

/// `INSERT ... VALUES (...), (...)` with every value bound as a parameter, so no data is spliced into the SQL.
func bulkInsert(_ sql: any SQLDatabase, _ head: String, _ rows: [Row], tail: String = "") async throws {
    guard !rows.isEmpty else { return }
    var query = SQLQueryString(head)
    for (index, row) in rows.enumerated() {
        if index > 0 { query.appendLiteral(", ") }
        query.appendLiteral("(")
        query.appendInterpolation(binds: row)
        query.appendLiteral(")")
    }
    query.appendLiteral(tail)
    try await sql.raw(query).run()
}

func batched<T>(_ items: [T], _ size: Int) -> [ArraySlice<T>] {
    stride(from: 0, to: items.count, by: size).map { items[$0..<min($0 + size, items.count)] }
}

/// Writes a decoded Garmin batch into the indexed tables. Every write upserts or replaces the rows of its parent, so
/// writing the same batch twice leaves the tables as they were.
enum Store {
    static func write(_ batch: HealthBatch, fitFileID: UUID?, userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        // One row per metric and start time: the upsert cannot touch the same row twice in one statement.
        var unique: [String: (Metric, SamplePoint)] = [:]
        for metric in Metric.allCases {
            for point in metric.points(in: batch) {
                unique["\(metric.rawValue)|\(point.start.timeIntervalSince1970)"] = (metric, point)
            }
        }
        let samples = unique.values.sorted { $0.1.start < $1.1.start }
        try await Partitions.ensure(sql, parent: "samples", covering: samples.map { $0.1.start })
        try await Partitions.ensure(sql, parent: "activity_records", covering: batch.activities.flatMap { $0.records.map(\.date) })

        for chunk in batched(samples, 2_000) {
            try await bulkInsert(sql, "INSERT INTO samples (user_id, metric, ts, end_ts, value) VALUES ", chunk.map { entry -> Row in
                [userID, entry.0.rawValue, entry.1.start, entry.1.end, entry.1.value]
            }, tail: " ON CONFLICT (user_id, metric, ts) DO UPDATE SET end_ts = EXCLUDED.end_ts, value = EXCLUDED.value")
        }

        for session in batch.sleep {
            var breakdown: String?
            if let scores = session.scoreBreakdown {
                breakdown = String(decoding: try TimeCoding.encoder.encode(scores), as: UTF8.self)
            }
            guard let row = try await sql.raw("""
                INSERT INTO sleep_sessions (user_id, start_ts, end_ts, score, breakdown)
                VALUES (\(bind: userID), \(bind: session.start), \(bind: session.end), \(bind: session.score), \(bind: breakdown)::jsonb)
                ON CONFLICT (user_id, start_ts) DO UPDATE SET end_ts = EXCLUDED.end_ts, score = EXCLUDED.score, breakdown = EXCLUDED.breakdown
                RETURNING id
                """).first(decoding: IDRow.self) else { continue }
            try await sql.raw("DELETE FROM sleep_stages WHERE session_id = \(bind: row.id)").run()
            try await bulkInsert(sql, "INSERT INTO sleep_stages (session_id, start_ts, end_ts, stage) VALUES ",
                                 session.intervals.map { interval -> Row in [row.id, interval.start, interval.end, interval.stage.rawValue] },
                                 tail: " ON CONFLICT DO NOTHING")
        }

        for activity in batch.activities {
            guard let row = try await sql.raw("""
                INSERT INTO activities (user_id, external_id, fit_file_id, sport, sub_sport, name, start_ts, end_ts, duration, distance,
                    active_calories, avg_hr, max_hr, total_ascent, total_descent, avg_speed, avg_cadence, avg_power, training_effect)
                VALUES (\(bind: userID), \(bind: activity.id), \(bind: fitFileID), \(bind: activity.sport.rawValue), \(bind: activity.subSport),
                    \(bind: activity.name), \(bind: activity.start), \(bind: activity.end), \(bind: activity.duration), \(bind: activity.distance),
                    \(bind: activity.activeCalories), \(bind: activity.averageHeartRate), \(bind: activity.maxHeartRate),
                    \(bind: activity.totalAscent), \(bind: activity.totalDescent), \(bind: activity.averageSpeed),
                    \(bind: activity.averageCadence), \(bind: activity.averagePower), \(bind: activity.trainingEffect))
                ON CONFLICT (user_id, external_id) DO UPDATE SET
                    fit_file_id = COALESCE(EXCLUDED.fit_file_id, activities.fit_file_id), sport = EXCLUDED.sport,
                    sub_sport = EXCLUDED.sub_sport, name = COALESCE(EXCLUDED.name, activities.name),
                    start_ts = EXCLUDED.start_ts, end_ts = EXCLUDED.end_ts, duration = EXCLUDED.duration, distance = EXCLUDED.distance,
                    active_calories = EXCLUDED.active_calories, avg_hr = EXCLUDED.avg_hr, max_hr = EXCLUDED.max_hr,
                    total_ascent = EXCLUDED.total_ascent, total_descent = EXCLUDED.total_descent, avg_speed = EXCLUDED.avg_speed,
                    avg_cadence = EXCLUDED.avg_cadence, avg_power = EXCLUDED.avg_power, training_effect = EXCLUDED.training_effect
                RETURNING id
                """).first(decoding: IDRow.self) else { continue }

            try await sql.raw("DELETE FROM activity_laps WHERE activity_id = \(bind: row.id)").run()
            try await bulkInsert(sql, "INSERT INTO activity_laps (activity_id, idx, start_ts, end_ts, distance, calories, avg_hr) VALUES ",
                                 activity.laps.enumerated().map { entry -> Row in
                                     [row.id, entry.offset, entry.element.start, entry.element.end, entry.element.distance,
                                      entry.element.calories, entry.element.averageHeartRate]
                                 })

            try await sql.raw("DELETE FROM activity_records WHERE activity_id = \(bind: row.id)").run()
            for chunk in batched(activity.records, 1_000) {
                try await bulkInsert(sql, """
                    INSERT INTO activity_records (activity_id, ts, latitude, longitude, altitude, heart_rate, speed, distance, cadence, power, temperature) VALUES
                    """, chunk.map { record -> Row in
                        [row.id, record.date, record.latitude, record.longitude, record.altitude, record.heartRate,
                         record.speed, record.distance, record.cadence, record.power, record.temperature]
                    }, tail: " ON CONFLICT (activity_id, ts) DO NOTHING")
            }
        }

        let touched = samples.map { $0.1.start } + batch.sleep.map(\.start) + batch.activities.map(\.start)
        try await Summaries.recompute(over: touched, userID: userID, sql: sql, calendar: calendar)
        try await Rollup.recompute(over: touched, userID: userID, sql: sql, calendar: calendar)
    }
}

/// Daily totals for every day an upload touches. Reads use the same day boundaries, so the two always agree.
enum Summaries {
    static func recompute(over dates: [Date], userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        guard let first = dates.min(), let last = dates.max() else { return }
        let zone = calendar.timeZone.identifier
        let dayFormat = ISO8601DateFormatter()
        dayFormat.formatOptions = [.withFullDate]
        dayFormat.timeZone = calendar.timeZone
        try await sql.raw("""
            INSERT INTO daily_summaries (user_id, day, steps, active_energy, resting_heart_rate, average_stress, sleep_minutes, activity_count)
            SELECT \(bind: userID), d.day,
              (SELECT COALESCE(sum(value), 0) FROM samples WHERE user_id = \(bind: userID) AND metric = 'steps' AND ts >= d.starts AND ts < d.ends),
              (SELECT COALESCE(sum(value), 0) FROM samples WHERE user_id = \(bind: userID) AND metric = 'activeEnergy' AND ts >= d.starts AND ts < d.ends),
              (SELECT avg(value) FROM samples WHERE user_id = \(bind: userID) AND metric = 'restingHeartRate' AND ts >= d.starts AND ts < d.ends),
              (SELECT avg(value) FROM samples WHERE user_id = \(bind: userID) AND metric = 'stress' AND ts >= d.starts AND ts < d.ends),
              (SELECT COALESCE(sum(extract(epoch FROM end_ts - start_ts)) / 60, 0) FROM sleep_sessions
                 WHERE user_id = \(bind: userID) AND start_ts >= d.starts AND start_ts < d.ends),
              (SELECT count(*) FROM activities WHERE user_id = \(bind: userID) AND start_ts >= d.starts AND start_ts < d.ends)
            FROM (
              SELECT g::date AS day, g AT TIME ZONE \(bind: zone)::text AS starts, (g + interval '1 day') AT TIME ZONE \(bind: zone)::text AS ends
              FROM generate_series(\(bind: dayFormat.string(from: first))::date::timestamp,
                                   \(bind: dayFormat.string(from: last))::date::timestamp, interval '1 day') AS g
            ) AS d
            ON CONFLICT (user_id, day) DO UPDATE SET
              steps = EXCLUDED.steps, active_energy = EXCLUDED.active_energy, resting_heart_rate = EXCLUDED.resting_heart_rate,
              average_stress = EXCLUDED.average_stress, sleep_minutes = EXCLUDED.sleep_minutes, activity_count = EXCLUDED.activity_count
            """).run()
    }
}
