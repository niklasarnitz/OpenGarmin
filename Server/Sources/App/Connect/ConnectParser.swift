import Foundation
import GarminModels

/// Garmin Connect's daily responses, read into the batch shape the app uploads. Pure: no database, no network, so the
/// tests run on fixtures. Bump `version` whenever a reading changes: archived responses are parsed again at startup.
enum ConnectParser {
    static let version = 1

    static let endpoints: Set<String> = ["dailySleepData", "dailyStress", "dailySummaryChart", "usersummary", "hrv", "activityList"]

    /// The stage of each sleep level code when the DTO totals give no reason to think otherwise. Codes 0 and 1 are deep
    /// and light. 2 and 3 are awake and REM in some order; 2 awake and 3 REM is what 89 nights of a real account showed.
    static let defaultStages: [Int: SleepStage] = [0: .deep, 1: .light, 2: .awake, 3: .rem]

    /// A night agrees when the chosen mapping's minutes per stage, summed over the four stages, are within this many
    /// minutes of the DTO's totals.
    static let agreementMinutes = 5.0

    /// One night's check of the stage mapping against Garmin's own stage totals.
    struct SleepCheck: Equatable, Sendable {
        let day: String
        /// Minutes of each raw activityLevel code, codes 0 to 3.
        let minutesPerCode: [Int: Double]
        /// Garmin's totals per stage in minutes, keyed by stage name (`deep`, `light`, `rem`, `awake`).
        let dtoMinutes: [String: Double]
        /// The mapping that matches the totals best.
        let mapping: [Int: SleepStage]
        /// The residual of that mapping, in minutes, summed over the four stages.
        let errorMinutes: Double

        var agrees: Bool { errorMinutes <= ConnectParser.agreementMinutes }
    }

    struct Parsed: Sendable {
        var batch = HealthBatch()
        var sleepCheck: SleepCheck?
    }

    /// What one archived response contributes. `activityList` is archived but not parsed yet.
    static func parse(endpoint: String, day: String?, calendar: Calendar, body: Any) -> Parsed {
        var parsed = Parsed()
        switch endpoint {
        case "dailyStress":
            let json = body as? [String: Any] ?? [:]
            parsed.batch.stress = stressPoints(json["stressValuesArray"])
            parsed.batch.bodyBattery = bodyBatteryPoints(json["bodyBatteryValuesArray"])
        case "dailySleepData":
            let json = body as? [String: Any] ?? [:]
            let night = sleep(json, day: day)
            parsed.batch.sleep = night.session.map { [$0] } ?? []
            parsed.sleepCheck = night.check
        case "dailySummaryChart":
            let rows = body as? [[String: Any]] ?? []
            parsed.batch.steps = rows.compactMap { row -> IntervalSample? in
                guard let start = gmtDate(row["startGMT"] as? String), let end = gmtDate(row["endGMT"] as? String),
                      let steps = number(row["steps"]), steps > 0 else { return nil }
                return IntervalSample(start: start, end: end, value: steps)
            }
        case "usersummary":
            let json = body as? [String: Any] ?? [:]
            if let day, let start = dayStart(day, calendar: calendar), let value = number(json["restingHeartRate"]), value > 0 {
                parsed.batch.restingHeartRate = [PointSample(date: start, value: value)]
            }
        case "hrv":
            let json = body as? [String: Any] ?? [:]
            if let summary = json["hrvSummary"] as? [String: Any], let value = number(summary["lastNightAvg"]),
               let end = gmtDate(json["sleepEndTimestampGMT"] as? String) {
                parsed.batch.hrv = [PointSample(date: end, value: value)]
            }
        default:
            break
        }
        return parsed
    }

    /// The night that ends on a day: the session from `dailySleepDTO`, its stages and its score. The stage of codes 2
    /// and 3 is decided by the DTO totals (see `chooseMapping`), and the night is returned as a check as well.
    static func sleep(_ json: [String: Any], day: String?) -> (session: SleepSession?, check: SleepCheck?) {
        guard let dto = json["dailySleepDTO"] as? [String: Any],
              let startMs = number(dto["sleepStartTimestampGMT"]), let endMs = number(dto["sleepEndTimestampGMT"]),
              endMs > startMs else { return (nil, nil) }

        let levels: [(start: Date, end: Date, code: Int)] = ((json["sleepLevels"] as? [[String: Any]]) ?? []).compactMap { level in
            guard let start = gmtDate(level["startGMT"] as? String), let end = gmtDate(level["endGMT"] as? String),
                  end > start, let code = number(level["activityLevel"]) else { return nil }
            return (start, end, Int(code))
        }
        var minutes: [Int: Double] = [:]
        for level in levels where defaultStages[level.code] != nil {
            minutes[level.code, default: 0] += level.end.timeIntervalSince(level.start) / 60
        }

        var check: SleepCheck?
        let mapping: [Int: SleepStage]
        if let totals = stageTotals(dto), let checkDay = day ?? (dto["calendarDate"] as? String) {
            let chosen = chooseMapping(minutes: minutes, totals: totals)
            mapping = chosen.mapping
            check = SleepCheck(
                day: checkDay,
                minutesPerCode: minutes,
                dtoMinutes: Dictionary(uniqueKeysWithValues: totals.map { ($0.key.rawValue, $0.value) }),
                mapping: chosen.mapping,
                errorMinutes: chosen.error
            )
        } else {
            mapping = defaultStages
        }

        let intervals = levels.compactMap { level -> SleepInterval? in
            guard let stage = mapping[level.code] else { return nil }
            return SleepInterval(start: level.start, end: level.end, stage: stage)
        }
        let scores = dto["sleepScores"] as? [String: Any]
        func score(_ key: String) -> Int? {
            number((scores?[key] as? [String: Any])?["value"]).map { Int($0) }
        }
        let breakdown: SleepScoreBreakdown? = scores == nil ? nil : SleepScoreBreakdown(
            duration: score("totalDuration"), deep: score("deepPercentage"), light: score("lightPercentage"),
            rem: score("remPercentage"), awakenings: score("awakeCount"), restlessness: score("restlessness"))
        let session = SleepSession(
            start: Date(timeIntervalSince1970: startMs / 1000), end: Date(timeIntervalSince1970: endMs / 1000),
            intervals: intervals, score: score("overall"), scoreBreakdown: breakdown)
        return (session, check)
    }

    /// The mapping of codes 0 to 3 to stages that best fits the DTO's totals, found by trying all 24 assignments. Ties go
    /// to the default mapping, so a night that fits the default is never reassigned.
    static func chooseMapping(minutes: [Int: Double], totals: [SleepStage: Double]) -> (mapping: [Int: SleepStage], error: Double) {
        let stages: [SleepStage] = [.deep, .light, .rem, .awake]
        let candidates = [defaultStages] + permutations(stages)
            .map { Dictionary(uniqueKeysWithValues: zip([0, 1, 2, 3], $0)) }
            .filter { $0 != defaultStages }
        var best = (mapping: defaultStages, error: Double.infinity)
        for mapping in candidates {
            let error = stages.reduce(0.0) { sum, stage in
                let code = mapping.first { $0.value == stage }!.key
                return sum + abs((minutes[code] ?? 0) - (totals[stage] ?? 0))
            }
            if error < best.error { best = (mapping, error) }
        }
        return best
    }

    // MARK: - Helpers

    private static func stageTotals(_ dto: [String: Any]) -> [SleepStage: Double]? {
        guard let deep = number(dto["deepSleepSeconds"]), let light = number(dto["lightSleepSeconds"]),
              let rem = number(dto["remSleepSeconds"]), let awake = number(dto["awakeSleepSeconds"]) else { return nil }
        return [.deep: deep / 60, .light: light / 60, .rem: rem / 60, .awake: awake / 60]
    }

    private static func stressPoints(_ value: Any?) -> [PointSample] {
        // Rows are [timestamp, stress].
        rows(value).compactMap { row -> PointSample? in
            guard row.count >= 2, let ms = number(row[0]), let level = number(row[1]), (0.0...100.0).contains(level) else { return nil }
            return PointSample(date: Date(timeIntervalSince1970: ms / 1000), value: level)
        }
    }

    private static func bodyBatteryPoints(_ value: Any?) -> [PointSample] {
        // Rows are [timestamp, status, level, version].
        rows(value).compactMap { row -> PointSample? in
            guard row.count >= 3, let ms = number(row[0]), let level = number(row[2]), (0.0...100.0).contains(level) else { return nil }
            return PointSample(date: Date(timeIntervalSince1970: ms / 1000), value: level)
        }
    }

    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    private static func rows(_ value: Any?) -> [[Any]] {
        value as? [[Any]] ?? []
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// "2026-01-08 14:10:21" or "2026-01-08T14:10:21.0" as UTC.
    static func gmtDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { " :-T.".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3], minute: parts[4], second: parts[5]))
    }

    /// Midnight of a `YYYY-MM-DD` day in the calendar's time zone.
    static func dayStart(_ text: String, calendar: Calendar) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: text)
    }
}
