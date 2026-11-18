import Foundation
import GarminModels

/// One row of Garmin's activity list.
public struct ConnectActivity: Sendable, Equatable {
    public var id: Int64
    public var start: Date
}

/// Garmin's responses, read into the app's models. Pure, so the tests run on responses shaped like the recorded ones.
enum ConnectParsing {
    /// The SSO answer to a login or an MFA code.
    enum SSOStep: Equatable {
        case ticket(String)
        /// Garmin sent a code by `method` ("email", "sms" or the like).
        case mfaRequired(method: String)
        /// Any other answer, with Garmin's status type such as INVALID_USERNAME_PASSWORD.
        case rejected(type: String)
    }

    static func sso(_ data: Data) throws -> SSOStep {
        let json = try jsonObject(data)
        let type = (json["responseStatus"] as? [String: Any])?["type"] as? String ?? "UNKNOWN"
        switch type {
        case "SUCCESSFUL":
            guard let ticket = json["serviceTicketId"] as? String else { throw GarminConnectError.malformedResponse }
            return .ticket(ticket)
        case "MFA_REQUIRED":
            let method = (json["customerMfaInfo"] as? [String: Any])?["mfaLastMethodUsed"] as? String
            return .mfaRequired(method: method ?? "email")
        default:
            return .rejected(type: type)
        }
    }

    /// The `name=value&...` body of the preauthorized call.
    static func oauth1Token(_ data: Data) throws -> ConnectOAuth1Token {
        let fields = OAuth1Signer.formFields(String(decoding: data, as: UTF8.self))
        guard let token = fields["oauth_token"], let secret = fields["oauth_token_secret"] else {
            throw GarminConnectError.malformedResponse
        }
        return ConnectOAuth1Token(token: token, secret: secret, mfaToken: fields["mfa_token"].flatMap { $0.isEmpty ? nil : $0 })
    }

    static func accessToken(_ data: Data, now: Date) throws -> ConnectAccessToken {
        struct Response: Decodable {
            var accessToken: String
            var tokenType: String
            var expiresIn: Double

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case tokenType = "token_type"
                case expiresIn = "expires_in"
            }
        }
        let response = try decode(Response.self, data)
        return ConnectAccessToken(value: response.accessToken, type: response.tokenType,
                                  expiresAt: now.addingTimeInterval(response.expiresIn))
    }

    static func consumer(_ data: Data) throws -> ConnectConsumer {
        try decode(ConnectConsumer.self, data)
    }

    /// The activities of one page. `startTimeGMT` is UTC without a zone, e.g. "2026-01-08 14:10:21". A row without a
    /// readable start fails the page, so a caller that pages by row count never stops early.
    static func activities(_ data: Data) throws -> [ConnectActivity] {
        struct Item: Decodable {
            var activityId: Int64
            var startTimeGMT: String
        }
        var activities: [ConnectActivity] = []
        for item in try decode([Item].self, data) {
            guard let start = gmtDate(item.startTimeGMT) else { throw GarminConnectError.malformedResponse }
            activities.append(ConnectActivity(id: item.activityId, start: start))
        }
        return activities
    }

    /// Stress and Body Battery points of one day. Values outside 0...100 are dropped. A day without data is answered
    /// with `null`, which reads as no points, as garth reads it.
    static func dailyStress(_ data: Data) throws -> (stress: [PointSample], bodyBattery: [PointSample]) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], []) }
        let stress = rows(json["stressValuesArray"]).compactMap { row -> PointSample? in
            guard row.count >= 2, let ms = number(row[0]), let value = number(row[1]), (0.0...100.0).contains(value)
            else { return nil }
            return PointSample(date: date(milliseconds: ms), value: value)
        }
        // Rows are [timestamp, status, level, version].
        let battery = rows(json["bodyBatteryValuesArray"]).compactMap { row -> PointSample? in
            guard row.count >= 3, let ms = number(row[0]), let level = number(row[2]), (0.0...100.0).contains(level)
            else { return nil }
            return PointSample(date: date(milliseconds: ms), value: level)
        }
        return (stress, battery)
    }

    /// The night that ends on a day: the session from `dailySleepDTO`, its stages from `sleepLevels` and its score.
    /// Nil when the day has no sleep. Garmin's stage codes are 0 deep, 1 light, 2 REM and 3 awake.
    static func sleep(_ data: Data) -> SleepSession? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dto = json["dailySleepDTO"] as? [String: Any],
              let startMs = number(dto["sleepStartTimestampGMT"]), let endMs = number(dto["sleepEndTimestampGMT"]),
              endMs > startMs else { return nil }
        let intervals = ((json["sleepLevels"] as? [[String: Any]]) ?? []).compactMap { level -> SleepInterval? in
            guard let start = (level["startGMT"] as? String).flatMap({ gmtDate($0) }),
                  let end = (level["endGMT"] as? String).flatMap({ gmtDate($0) }), end > start,
                  let code = number(level["activityLevel"]), let stage = sleepStage(code) else { return nil }
            return SleepInterval(start: start, end: end, stage: stage)
        }
        let scores = dto["sleepScores"] as? [String: Any]
        func score(_ key: String) -> Int? {
            number((scores?[key] as? [String: Any])?["value"]).map { Int($0) }
        }
        let breakdown: SleepScoreBreakdown? = scores == nil ? nil : SleepScoreBreakdown(
            duration: score("totalDuration"), deep: score("deepPercentage"), light: score("lightPercentage"),
            rem: score("remPercentage"), awakenings: score("awakeCount"), restlessness: score("restlessness"))
        return SleepSession(start: date(milliseconds: startMs), end: date(milliseconds: endMs), intervals: intervals,
                            score: score("overall"), scoreBreakdown: breakdown)
    }

    private static func sleepStage(_ code: Double) -> SleepStage? {
        switch Int(code) {
        case 0: .deep
        case 1: .light
        case 2: .rem
        case 3: .awake
        default: nil
        }
    }

    /// The steps of each 15-minute interval of a day. Intervals without steps are left out.
    static func steps(_ data: Data) -> [IntervalSample] {
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return rows.compactMap { row -> IntervalSample? in
            guard let start = (row["startGMT"] as? String).flatMap({ gmtDate($0) }),
                  let end = (row["endGMT"] as? String).flatMap({ gmtDate($0) }),
                  let steps = number(row["steps"]), steps > 0 else { return nil }
            return IntervalSample(start: start, end: end, value: steps)
        }
    }

    /// The resting heart rate of a day from its daily summary. Nil when the summary has none.
    static func restingHeartRate(_ data: Data) -> Double? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = number(json["restingHeartRate"]), value > 0 else { return nil }
        return value
    }

    /// The HRV of a night: its average, dated at the end of the sleep. Nil when HRV has no value for the day.
    static func hrv(_ data: Data) -> PointSample? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = json["hrvSummary"] as? [String: Any],
              let value = number(summary["lastNightAvg"]),
              let end = (json["sleepEndTimestampGMT"] as? String).flatMap({ gmtDate($0) }) else { return nil }
        return PointSample(date: end, value: value)
    }

    /// The display name of the signed-in account, which the per-user paths are built from.
    static func displayName(_ data: Data) throws -> String {
        let json = try jsonObject(data)
        guard let name = json["displayName"] as? String else { throw GarminConnectError.malformedResponse }
        return name
    }

    /// "2026-01-08 14:10:21" or "2026-01-08T14:10:21.0" as UTC.
    static func gmtDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { " :-T.".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3], minute: parts[4], second: parts[5]))
    }

    // MARK: - JSON

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GarminConnectError.malformedResponse
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GarminConnectError.malformedResponse
        }
        return object
    }

    private static func rows(_ value: Any?) -> [[Any]] {
        value as? [[Any]] ?? []
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func date(milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
