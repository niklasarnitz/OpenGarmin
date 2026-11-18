import FluentSQL
import Foundation
import GarminModels
import Vapor

/// One bucket of an aggregated series. `avg`, `min` and `max` apply to readings; `sum` applies to intervals.
struct SampleBucket: Content {
    let start: Date
    let count: Int
    let avg: Double?
    let min: Double?
    let max: Double?
    let sum: Double?
}

struct SamplePage: Content {
    let items: [SamplePoint]
    let nextCursor: String?
}

struct DaySummary: Content {
    let day: String
    let steps: Double
    let activeEnergy: Double
    let restingHeartRate: Double?
    let averageStress: Double?
    let sleepMinutes: Double
    let activityCount: Int
}

struct ActivitySummary: Content {
    let id: UUID
    let externalId: String
    let sport: Int
    let subSport: Int?
    let name: String?
    let start: Date
    let end: Date
    let duration: Double
    let distance: Double?
    let activeCalories: Double?
    let averageHeartRate: Int?
    let maxHeartRate: Int?
    let totalAscent: Double?
    let totalDescent: Double?
    let averageSpeed: Double?
    let averageCadence: Int?
    let averagePower: Int?
    let trainingEffect: Double?
}

struct ActivityPage: Content {
    let items: [ActivitySummary]
    let nextCursor: String?
}

struct LapRow: Content {
    let start: Date
    let end: Date
    let distance: Double?
    let calories: Double?
    let averageHeartRate: Int?
}

struct RecordRow: Content {
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let heartRate: Int?
    let speed: Double?
    let distance: Double?
    let cadence: Int?
    let power: Int?
    let temperature: Double?
}

struct ActivityDetail: Content {
    let activity: ActivitySummary
    let laps: [LapRow]
    let records: [RecordRow]
}

struct SleepSessionDTO: Content {
    let start: Date
    let end: Date
    let score: Int?
    let breakdown: SleepScoreBreakdown?
    let stages: [SleepStageDTO]
}

struct SleepStageDTO: Content {
    let start: Date
    let end: Date
    let stage: SleepStage
}

/// The read side of the API. Ranges are `from` (inclusive) and `to` (exclusive), ISO 8601.
enum Reads {
    struct Window {
        var from: Date
        var to: Date
    }

    struct FileRef: Decodable {
        let storageKey: String
        let externalId: String
    }

    static func window(_ req: Request) throws -> Window {
        let from = try date(req, "from") ?? Date(timeIntervalSince1970: 0)
        let to = try date(req, "to") ?? Date().addingTimeInterval(366 * 86_400)
        guard from <= to else { throw Abort(.badRequest, reason: "`from` must not be after `to`.") }
        return Window(from: from, to: to)
    }

    static func date(_ req: Request, _ name: String) throws -> Date? {
        guard let text = req.query[String.self, at: name] else { return nil }
        guard let parsed = TimeCoding.parse(text) else {
            throw Abort(.badRequest, reason: "`\(name)` must be an ISO 8601 date.")
        }
        return parsed
    }

    /// Raw points, or buckets with `resolution=minute|hour|day`. Buckets carry every statistic; a client picks the one
    /// that fits the metric (`sum` for steps and energy, `avg` for readings).
    static func samples(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        guard let metric = Metric(rawValue: req.parameters.get("metric") ?? "") else {
            throw Abort(.notFound, reason: "Unknown metric.")
        }
        let window = try window(req)
        let sql = try req.sql
        let resolution = req.query[String.self, at: "resolution"] ?? "raw"
        if resolution == "raw" {
            // Full resolution, one page at a time. `nextCursor` is the first point not returned yet (inclusive).
            let limit = min(max(Int(req.query[String.self, at: "limit"] ?? "") ?? 50_000, 1), 50_000)
            let from = try date(req, "cursor") ?? window.from
            let rows = try await sql.raw("""
                SELECT ts AS "start", end_ts AS "end", value FROM samples
                WHERE user_id = \(bind: user.id) AND metric = \(bind: metric.rawValue) AND ts >= \(bind: from) AND ts < \(bind: window.to)
                ORDER BY ts LIMIT \(bind: limit + 1)
                """).all(decoding: SamplePoint.self)
            let next = rows.count > limit ? TimeCoding.string(rows[limit].start) : nil
            return try Response.json(SamplePage(items: Array(rows.prefix(limit)), nextCursor: next))
        }
        guard ["minute", "hour", "day"].contains(resolution) else {
            throw Abort(.badRequest, reason: "`resolution` must be raw, minute, hour or day.")
        }
        let zone = user.timeZone
        let bucket = "date_trunc('\(resolution)', ts AT TIME ZONE '\(zone)') AT TIME ZONE '\(zone)'"
        let buckets = try await sql.raw("""
            SELECT \(unsafeRaw: bucket) AS "start", count(*) AS count, avg(value) AS avg, min(value) AS min, max(value) AS max, sum(value) AS sum
            FROM samples
            WHERE user_id = \(bind: user.id) AND metric = \(bind: metric.rawValue) AND ts >= \(bind: window.from) AND ts < \(bind: window.to)
            GROUP BY 1 ORDER BY 1
            """).all(decoding: SampleBucket.self)
        return try Response.json(buckets)
    }

    static func days(_ req: Request, user: AuthenticatedUser, window: Window) async throws -> [DaySummary] {
        try await req.sql.raw("""
            SELECT to_char(day, 'YYYY-MM-DD') AS day, steps, active_energy AS "activeEnergy", resting_heart_rate AS "restingHeartRate",
                   average_stress AS "averageStress", sleep_minutes AS "sleepMinutes", activity_count AS "activityCount"
            FROM daily_summaries
            WHERE user_id = \(bind: user.id)
              AND day >= (\(bind: window.from)::timestamptz AT TIME ZONE \(bind: user.timeZone)::text)::date
              AND day < (\(bind: window.to)::timestamptz AT TIME ZONE \(bind: user.timeZone)::text)::date
            ORDER BY day
            """).all(decoding: DaySummary.self)
    }

    static func sleep(_ req: Request, user: AuthenticatedUser, window: Window) async throws -> [SleepSessionDTO] {
        struct SessionRow: Decodable {
            let id: UUID
            let start: Date
            let end: Date
            let score: Int?
            let breakdown: String?
        }
        struct StageRow: Decodable {
            let sessionID: UUID
            let start: Date
            let end: Date
            let stage: SleepStage
        }
        let sql = try req.sql
        let sessions = try await sql.raw("""
            SELECT id, start_ts AS "start", end_ts AS "end", score, breakdown::text AS "breakdown"
            FROM sleep_sessions
            WHERE user_id = \(bind: user.id) AND start_ts >= \(bind: window.from) AND start_ts < \(bind: window.to)
            ORDER BY start_ts
            """).all(decoding: SessionRow.self)
        let stages = try await sql.raw("""
            SELECT session_id AS "sessionID", start_ts AS "start", end_ts AS "end", stage FROM sleep_stages
            WHERE session_id IN (SELECT id FROM sleep_sessions
                                 WHERE user_id = \(bind: user.id) AND start_ts >= \(bind: window.from) AND start_ts < \(bind: window.to))
            ORDER BY start_ts
            """).all(decoding: StageRow.self)
        let bySession = Dictionary(grouping: stages, by: \.sessionID)
        return sessions.map { session in
            let breakdown = session.breakdown.flatMap { try? JSONDecoder().decode(SleepScoreBreakdown.self, from: Data($0.utf8)) }
            let rows = (bySession[session.id] ?? []).map { SleepStageDTO(start: $0.start, end: $0.end, stage: $0.stage) }
            return SleepSessionDTO(start: session.start, end: session.end, score: session.score, breakdown: breakdown, stages: rows)
        }
    }

    static let activityColumns = """
        id, external_id AS "externalId", sport, sub_sport AS "subSport", name, start_ts AS "start", end_ts AS "end",
        duration, distance, active_calories AS "activeCalories", avg_hr AS "averageHeartRate", max_hr AS "maxHeartRate",
        total_ascent AS "totalAscent", total_descent AS "totalDescent", avg_speed AS "averageSpeed",
        avg_cadence AS "averageCadence", avg_power AS "averagePower", training_effect AS "trainingEffect"
        """

    /// Newest first. `limit` rows are returned; `nextCursor` is the start of the last one when more exist.
    static func activityPage(_ req: Request, user: AuthenticatedUser, window: Window, limit: Int) async throws -> ActivityPage {
        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: activityColumns) FROM activities
            WHERE user_id = \(bind: user.id) AND start_ts >= \(bind: window.from) AND start_ts < \(bind: window.to)
            ORDER BY start_ts DESC LIMIT \(bind: limit + 1)
            """).all(decoding: ActivitySummary.self)
        let items = Array(rows.prefix(limit))
        let next: String? = rows.count > limit ? items.last.map { TimeCoding.string($0.start) } : nil
        return ActivityPage(items: items, nextCursor: next)
    }

    static func activityDetail(_ req: Request, user: AuthenticatedUser, id: UUID) async throws -> ActivityDetail? {
        let sql = try req.sql
        guard let summary = try await sql.raw("""
            SELECT \(unsafeRaw: activityColumns) FROM activities WHERE id = \(bind: id) AND user_id = \(bind: user.id)
            """).first(decoding: ActivitySummary.self) else { return nil }
        let laps = try await lapRows(sql, activity: id)
        let records = try await recordRows(sql, activity: id)
        return ActivityDetail(activity: summary, laps: laps, records: records)
    }

    static func fitFile(_ req: Request, user: AuthenticatedUser, id: UUID) async throws -> FileRef? {
        try await req.sql.raw("""
            SELECT f.storage_key AS "storageKey", a.external_id AS "externalId"
            FROM activities a JOIN fit_files f ON f.id = a.fit_file_id
            WHERE a.id = \(bind: id) AND a.user_id = \(bind: user.id) AND f.storage_key IS NOT NULL
            """).first(decoding: FileRef.self)
    }

    /// Everything stored for the range, shaped as a `HealthBatch`, so the app can restore after a reinstall.
    static func history(_ req: Request, user: AuthenticatedUser, window: Window) async throws -> HealthBatch {
        let sql = try req.sql
        var batch = HealthBatch()
        for metric in Metric.allCases {
            let points = try await sql.raw("""
                SELECT ts AS "start", end_ts AS "end", value FROM samples
                WHERE user_id = \(bind: user.id) AND metric = \(bind: metric.rawValue) AND ts >= \(bind: window.from) AND ts < \(bind: window.to)
                ORDER BY ts
                """).all(decoding: SamplePoint.self)
            metric.fill(&batch, points)
        }
        let sessions = try await sleep(req, user: user, window: window)
        batch.sleep = sessions.map { session in
            SleepSession(
                start: session.start, end: session.end,
                intervals: session.stages.map { SleepInterval(start: $0.start, end: $0.end, stage: $0.stage) },
                score: session.score, scoreBreakdown: session.breakdown
            )
        }
        let summaries = try await activityPage(req, user: user, window: window, limit: 1_000_000).items
        for summary in summaries {
            let laps = try await lapRows(sql, activity: summary.id)
            let records = try await recordRows(sql, activity: summary.id)
            batch.activities.append(Activity(
                id: summary.externalId, sport: Sport(rawValue: summary.sport) ?? .generic, subSport: summary.subSport,
                name: summary.name, start: summary.start, end: summary.end, duration: summary.duration,
                distance: summary.distance, activeCalories: summary.activeCalories,
                averageHeartRate: summary.averageHeartRate, maxHeartRate: summary.maxHeartRate,
                totalAscent: summary.totalAscent, totalDescent: summary.totalDescent,
                averageSpeed: summary.averageSpeed, averageCadence: summary.averageCadence,
                averagePower: summary.averagePower, trainingEffect: summary.trainingEffect,
                laps: laps.map { ActivityLap(start: $0.start, end: $0.end, distance: $0.distance, calories: $0.calories, averageHeartRate: $0.averageHeartRate) },
                records: records.map {
                    ActivityRecord(date: $0.date, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude,
                                   heartRate: $0.heartRate, speed: $0.speed, distance: $0.distance, cadence: $0.cadence,
                                   power: $0.power, temperature: $0.temperature)
                }
            ))
        }
        return batch
    }

    private static func lapRows(_ sql: any SQLDatabase, activity: UUID) async throws -> [LapRow] {
        try await sql.raw("""
            SELECT start_ts AS "start", end_ts AS "end", distance, calories, avg_hr AS "averageHeartRate"
            FROM activity_laps WHERE activity_id = \(bind: activity) ORDER BY idx
            """).all(decoding: LapRow.self)
    }

    private static func recordRows(_ sql: any SQLDatabase, activity: UUID) async throws -> [RecordRow] {
        try await sql.raw("""
            SELECT ts AS "date", latitude, longitude, altitude, heart_rate AS "heartRate", speed, distance, cadence, power, temperature
            FROM activity_records WHERE activity_id = \(bind: activity) ORDER BY ts
            """).all(decoding: RecordRow.self)
    }
}
