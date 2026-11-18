import Foundation
import GarminModels

/// The kinds of a day's data the import keeps, each under its own key. Resting heart rate and HRV can come from the
/// sleep response, which carries both.
public enum ConnectDayKind: CaseIterable, Sendable {
    case stress, sleep, steps, restingHeartRate, hrv
}

enum ConnectDaily {
    /// Parses the kinds asked for. `fetch` returns the body of an endpoint: "dailyStress", "dailySleepData",
    /// "dailySummaryChart" (steps), "usersummary" (resting heart rate) or "hrv". The summary and HRV endpoints are asked
    /// for only when the sleep response lacks the value. A body that is empty reads as no data.
    static func resolve(_ kinds: Set<ConnectDayKind>, day: Date, calendar: Calendar,
                        fetch: @Sendable (String) async throws -> Data) async throws -> [ConnectDayKind: HealthBatch] {
        func body(_ endpoint: String, _ wanted: Bool) async throws -> Data {
            wanted ? try await fetch(endpoint) : Data()
        }
        async let stressBody = body("dailyStress", kinds.contains(.stress))
        async let stepsBody = body("dailySummaryChart", kinds.contains(.steps))
        let sleepBody = try await body("dailySleepData", kinds.contains(.sleep))
        let sleepRestingHeartRate = ConnectParsing.sleepRestingHeartRate(sleepBody)
        let sleepHRV = ConnectParsing.sleepHRV(sleepBody)
        async let summaryBody = body("usersummary", kinds.contains(.restingHeartRate) && sleepRestingHeartRate == nil)
        async let hrvBody = body("hrv", kinds.contains(.hrv) && sleepHRV == nil)

        let stress = try ConnectParsing.dailyStress(try await stressBody)
        let steps = ConnectParsing.steps(try await stepsBody)
        let summary = try await summaryBody
        let hrv = try await hrvBody

        var out: [ConnectDayKind: HealthBatch] = [:]
        if kinds.contains(.stress) {
            var batch = HealthBatch()
            batch.stress = stress.stress
            batch.bodyBattery = stress.bodyBattery
            out[.stress] = batch
        }
        if kinds.contains(.sleep) {
            var batch = HealthBatch()
            batch.sleep = ConnectParsing.sleep(sleepBody).map { [$0] } ?? []
            out[.sleep] = batch
        }
        if kinds.contains(.steps) {
            var batch = HealthBatch()
            batch.steps = steps
            out[.steps] = batch
        }
        if kinds.contains(.restingHeartRate) {
            var batch = HealthBatch()
            let value = sleepRestingHeartRate ?? ConnectParsing.restingHeartRate(summary)
            batch.restingHeartRate = value.map { [PointSample(date: calendar.startOfDay(for: day), value: $0)] } ?? []
            out[.restingHeartRate] = batch
        }
        if kinds.contains(.hrv) {
            var batch = HealthBatch()
            batch.hrv = (sleepHRV ?? ConnectParsing.hrv(hrv)).map { [$0] } ?? []
            out[.hrv] = batch
        }
        return out
    }
}
