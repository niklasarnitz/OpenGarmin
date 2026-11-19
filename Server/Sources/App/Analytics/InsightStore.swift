import Fluent
import FluentSQL
import Foundation
import Vapor

/// Loads what the insight engine reads, and keeps its results in `insight_runs` and `insights`. A GET serves the cached
/// run of its range and language, or computes it now. `InsightJob` computes runs again after the data changes.
enum InsightStore {
    /// Longest a GET waits for a run that is not cached. The run keeps going in the background; the next GET finds it.
    static let computeTimeout: Double = 20

    /// Insights of a range (day indexes, `to` exclusive) and language: from the cache, or computed and cached now.
    static func insights(on db: any Database, userID: UUID, from: Int, to: Int, lang: String) async throws -> [Insight] {
        if let cached = try await cached(on: db, userID, from, to, lang) { return cached }
        let fresh = try await compute(on: db, userID, from, to, lang)
        try await save(on: db, userID, from, to, lang, fresh)
        return fresh
    }

    /// Runs the GET handler's range. A run that is not cached is computed here, with a timeout.
    static func serve(_ req: Request, user: AuthenticatedUser) async throws -> [Insight] {
        let calendar = user.calendar
        let from = try dayParam(req, "from", calendar) ?? CivilDay.index(year: 1970, month: 1, day: 1)
        let to = try dayParam(req, "to", calendar) ?? today(calendar) + 1
        guard from < to else { throw Abort(.badRequest, reason: "`from` must be before `to`.") }
        let lang = req.query[String.self, at: "lang"] == "de" ? "de" : "en"
        let db = req.application.db
        let userID = user.id
        // The computation is not cancelled at the timeout: it finishes and caches, and the next GET finds the run.
        return try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            Task {
                do {
                    answer.finish(.success(try await insights(on: db, userID: userID, from: from, to: to, lang: lang)))
                } catch {
                    answer.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(computeTimeout))
                answer.finish(.failure(Abort(.gatewayTimeout, reason: "The insights are still being computed. Try again in a minute.")))
            }
        }
    }

    /// Computes the run of a range from the user's data. Reads only; `save` stores it.
    static func compute(on db: any Database, _ userID: UUID, _ from: Int, _ to: Int, _ lang: String) async throws -> [Insight] {
        let sql = try db.sql()
        guard let owner = try await sql.raw("""
            SELECT time_zone AS "timeZone", work_days AS "workDays", work_start AS "workStart", work_end AS "workEnd"
            FROM users WHERE id = \(bind: userID)
            """).first(decoding: Owner.self) else { throw Abort(.notFound) }
        let calendar = userCalendar(owner.timeZone)
        let input = try await load(sql, userID: userID, range: from...(to - 1), owner: owner, calendar: calendar)
        return InsightEngine.run(input, lang: lang)
    }

    /// Reads one user's daily rollups, sleep, activities and stress by context for the range.
    static func load(_ sql: any SQLDatabase, userID: UUID, range: ClosedRange<Int>, owner: Owner, calendar: Calendar) async throws -> InsightInput {
        let rows = try await sql.raw("""
            SELECT to_char(day, 'YYYY-MM-DD') AS "day", metric, source, value, count
            FROM metric_daily
            WHERE user_id = \(bind: userID) AND day >= \(bind: CivilDay.string(range.lowerBound))::date
                AND day <= \(bind: CivilDay.string(range.upperBound))::date
            """).all(decoding: RollupRow.self)
        var input = InsightInput(range: range, workingDays: Set(owner.workDays.map { $0 - 1 }))
        input.series = InsightSources.resolve(rows.compactMap { row in
            CivilDay.parse(row.day).map {
                InsightSources.Row(day: $0, metric: row.metric, source: row.source, value: row.value, count: row.count)
            }
        })

        let sessions = try await sql.raw("""
            SELECT start_ts AS "start", end_ts AS "end" FROM sleep_sessions
            WHERE user_id = \(bind: userID) AND end_ts >= \(bind: instant(range.lowerBound, calendar))
                AND end_ts < \(bind: instant(range.upperBound + 1, calendar))
            """).all(decoding: SessionRow.self)
        // Health nights fill the nights Garmin lacks (older years, other watches and apps).
        let lower = instant(range.lowerBound, calendar), upper = instant(range.upperBound + 1, calendar)
        let health = try await HealthSleep.nights(sql, userID: userID, from: lower.addingTimeInterval(-86_400), to: upper)
            .filter { $0.end >= lower && $0.end < upper }
            .map { SessionRow(start: $0.start, end: $0.end) }
        input.nights = (sessions + health).map { session in
            let wake = calendar.dateComponents([.year, .month, .day], from: session.end)
            let bed = calendar.dateComponents([.hour, .minute], from: session.start)
            // Bedtime in minutes after 18:00, so a night from 23:30 to 07:00 sits at 330 and never wraps.
            let onset = (bed.hour! * 60 + bed.minute! - 18 * 60 + 1440) % 1440
            return SleepNight(
                wakeDay: CivilDay.index(year: wake.year!, month: wake.month!, day: wake.day!),
                onset: Double(onset),
                duration: session.end.timeIntervalSince(session.start) / 60
            )
        }

        let activities = try await sql.raw("""
            SELECT start_ts AS "start", duration FROM activities
            WHERE user_id = \(bind: userID) AND start_ts >= \(bind: instant(range.lowerBound, calendar))
                AND start_ts < \(bind: instant(range.upperBound + 1, calendar))
            UNION ALL
            SELECT w.start_ts AS "start", w.duration FROM healthkit_workouts w
            WHERE w.user_id = \(bind: userID) AND w.start_ts >= \(bind: instant(range.lowerBound, calendar))
                AND w.start_ts < \(bind: instant(range.upperBound + 1, calendar)) AND \(unsafeRaw: HealthSleep.workoutNotOnGarmin)
            """).all(decoding: ActivityRow.self)
        var training: DailySeries = [:]
        for activity in activities {
            training[localDay(activity.start, calendar), default: 0] += activity.duration / 60
        }
        // A day without an activity is a day of no training, from the first activity on.
        if let first = training.keys.min() {
            for day in max(first, range.lowerBound)...range.upperBound where training[day] == nil { training[day] = 0 }
        }
        input.series["trainingMinutes"] = training

        // Stress by context. Working days and hours come from the user; sleep wins over everything else.
        let weekdays = owner.workDays.filter { (1...7).contains($0) }
        let days = weekdays.isEmpty ? "0" : weekdays.map(String.init).joined(separator: ",")
        let zone = calendar.timeZone.identifier
        let stress = try await sql.raw("""
            SELECT day, ctx, avg(value) AS value FROM (
              SELECT to_char((s.ts AT TIME ZONE \(bind: zone))::date, 'YYYY-MM-DD') AS day,
                CASE
                  WHEN EXISTS (SELECT 1 FROM sleep_sessions ss
                               WHERE ss.user_id = s.user_id AND s.ts >= ss.start_ts AND s.ts < ss.end_ts) THEN 'sleep'
                  WHEN EXTRACT(ISODOW FROM s.ts AT TIME ZONE \(bind: zone)) IN (\(unsafeRaw: days))
                    AND EXTRACT(HOUR FROM s.ts AT TIME ZONE \(bind: zone)) >= \(bind: owner.workStart)
                    AND EXTRACT(HOUR FROM s.ts AT TIME ZONE \(bind: zone)) < \(bind: owner.workEnd) THEN 'work'
                  WHEN EXTRACT(ISODOW FROM s.ts AT TIME ZONE \(bind: zone)) IN (\(unsafeRaw: days)) THEN 'afterHours'
                  ELSE 'free'
                END AS ctx,
                s.value AS value
              FROM samples s
              WHERE s.user_id = \(bind: userID) AND s.metric = 'stress'
                AND s.ts >= \(bind: instant(range.lowerBound, calendar)) AND s.ts < \(bind: instant(range.upperBound + 1, calendar))
            ) AS readings
            GROUP BY day, ctx
            """).all(decoding: StressRow.self)
        for row in stress {
            guard let day = CivilDay.parse(row.day) else { continue }
            input.stressByContext[row.ctx, default: [:]][day] = row.value
        }
        return input
    }

    // MARK: - Cache

    static func cached(on db: any Database, _ userID: UUID, _ from: Int, _ to: Int, _ lang: String) async throws -> [Insight]? {
        let sql = try db.sql()
        let runs = try await sql.raw("""
            SELECT count(*) AS count FROM insight_runs
            WHERE user_id = \(bind: userID) AND range_from = \(bind: from) AND range_to = \(bind: to) AND lang = \(bind: lang)
            """).first(decoding: CountRow.self)
        guard let runs, runs.count > 0 else { return nil }
        let rows = try await sql.raw("""
            SELECT body FROM insights
            WHERE user_id = \(bind: userID) AND range_from = \(bind: from) AND range_to = \(bind: to) AND lang = \(bind: lang)
            ORDER BY position
            """).all(decoding: BodyRow.self)
        return try rows.map { try JSONDecoder().decode(Insight.self, from: Data($0.body.utf8)) }
    }

    /// Replaces the stored run of a range with `found`, in one transaction.
    static func save(on db: any Database, _ userID: UUID, _ from: Int, _ to: Int, _ lang: String, _ found: [Insight]) async throws {
        try await db.transaction { tx in
            let sql = try tx.sql()
            try await sql.raw("""
                DELETE FROM insights
                WHERE user_id = \(bind: userID) AND range_from = \(bind: from) AND range_to = \(bind: to) AND lang = \(bind: lang)
                """).run()
            try await sql.raw("""
                INSERT INTO insight_runs (user_id, range_from, range_to, lang, computed_at)
                VALUES (\(bind: userID), \(bind: from), \(bind: to), \(bind: lang), now())
                ON CONFLICT (user_id, range_from, range_to, lang) DO UPDATE SET computed_at = now()
                """).run()
            for (position, insight) in found.enumerated() {
                let body = String(decoding: try JSONEncoder().encode(insight), as: UTF8.self)
                try await sql.raw("""
                    INSERT INTO insights (user_id, range_from, range_to, lang, position, body)
                    VALUES (\(bind: userID), \(bind: from), \(bind: to), \(bind: lang), \(bind: position), \(bind: body))
                    """).run()
            }
        }
    }

    /// Marks the user's insights as out of date. The job computes them again once the data has been quiet for a while.
    static func markDirty(_ sql: any SQLDatabase, userID: UUID) async throws {
        try await sql.raw("UPDATE users SET insights_dirty_at = now() WHERE id = \(bind: userID)").run()
    }

    // MARK: - Helpers

    /// `YYYY-MM-DD`, or an ISO 8601 instant read in the user's time zone.
    static func dayParam(_ req: Request, _ name: String, _ calendar: Calendar) throws -> Int? {
        guard let text = req.query[String.self, at: name] else { return nil }
        if text.count == 10, let day = CivilDay.parse(text) { return day }
        guard let date = TimeCoding.parse(text) else {
            throw Abort(.badRequest, reason: "`\(name)` must be YYYY-MM-DD or ISO 8601.")
        }
        return localDay(date, calendar)
    }

    static func localDay(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CivilDay.index(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    static func today(_ calendar: Calendar) -> Int {
        localDay(Date(), calendar)
    }

    /// Midnight at the start of a day in the calendar's time zone.
    static func instant(_ day: Int, _ calendar: Calendar) -> Date {
        let parts = CivilDay.parts(day)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
    }
}

/// Resumes a continuation once: with the computation's result, or with the timeout, whichever comes first.
private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Insight], Error>?

    init(_ continuation: CheckedContinuation<[Insight], Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<[Insight], Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// The time zone and working hours a run is computed with.
struct Owner: Decodable {
    let timeZone: String
    let workDays: [Int]
    let workStart: Int
    let workEnd: Int
}

/// Recomputes insights in the background: a user's runs after their data has been quiet for five minutes, and every
/// user's runs once a night (03:00 UTC), so the findings never fall far behind the data.
enum InsightJob {
    static func run(_ app: Application) async {
        var nightlyDay: Int?
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            do {
                let now = utc.dateComponents([.year, .month, .day, .hour], from: Date())
                let day = CivilDay.index(year: now.year!, month: now.month!, day: now.day!)
                if now.hour == 3, nightlyDay != day {
                    nightlyDay = day
                    try await app.db.sql().raw("UPDATE users SET insights_dirty_at = now()").run()
                    try await prune(app.db)
                }
                try await recomputeDue(app.db)
            } catch {
                app.logger.report(error: error)
            }
        }
    }

    /// Drops runs nobody has asked for in 30 days. The default range ends today, so every day starts a new run.
    static func prune(_ db: any Database) async throws {
        let sql = try db.sql()
        try await sql.raw("""
            DELETE FROM insights WHERE (user_id, range_from, range_to, lang) IN (
                SELECT user_id, range_from, range_to, lang FROM insight_runs WHERE computed_at < now() - interval '30 days')
            """).run()
        try await sql.raw("DELETE FROM insight_runs WHERE computed_at < now() - interval '30 days'").run()
    }

    static func recomputeDue(_ db: any Database) async throws {
        let sql = try db.sql()
        let due = try await sql.raw("""
            SELECT id, insights_dirty_at AS "dirtyAt" FROM users
            WHERE insights_dirty_at < now() - interval '5 minutes'
            """).all(decoding: DueUser.self)
        for user in due {
            let runs = try await sql.raw("""
                SELECT range_from AS "from", range_to AS "to", lang FROM insight_runs WHERE user_id = \(bind: user.id)
                """).all(decoding: RunRow.self)
            for run in runs {
                let found = try await InsightStore.compute(on: db, user.id, run.from, run.to, run.lang)
                try await InsightStore.save(on: db, user.id, run.from, run.to, run.lang, found)
            }
            // Only clears the mark if nothing changed while the runs were computed.
            try await sql.raw("""
                UPDATE users SET insights_dirty_at = NULL
                WHERE id = \(bind: user.id) AND insights_dirty_at <= \(bind: user.dirtyAt)
                """).run()
        }
    }
}

private struct RollupRow: Decodable {
    let day: String
    let metric: String
    let source: String
    let value: Double
    let count: Int
}

private struct SessionRow: Decodable {
    let start: Date
    let end: Date
}

private struct ActivityRow: Decodable {
    let start: Date
    let duration: Double
}

private struct StressRow: Decodable {
    let day: String
    let ctx: String
    let value: Double
}

private struct BodyRow: Decodable {
    let body: String
}

private struct DueUser: Decodable {
    let id: UUID
    let dirtyAt: Date
}

private struct RunRow: Decodable {
    let from: Int
    let to: Int
    let lang: String
}
