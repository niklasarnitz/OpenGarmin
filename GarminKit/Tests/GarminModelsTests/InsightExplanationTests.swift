import Foundation
import Testing
import GarminModels

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// Wednesday 2026-11-18 at 10:00 in Berlin.
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10))!

/// The given local hour, the given number of days before today.
private func daysAgo(_ days: Int, hour: Int = 8) -> Date {
    let day = calendar.date(byAdding: .day, value: -days, to: now)!
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
}

@Test func lowerRestingHeartRateThanUsualIsBetter() {
    // Seven days at 50 bpm, then 23 days at 60 bpm.
    var batch = HealthBatch()
    batch.restingHeartRate = (0..<30).map { PointSample(date: daysAgo($0), value: $0 < 7 ? 50 : 60) }
    let days = HealthInsights.days(batch, calendar: calendar)

    let explanation = InsightExplanations.explain(.restingHeartRate, days: days, batch: batch, now: now, calendar: calendar)

    // The 30-day mean is (7 * 50 + 23 * 60) / 30. The sample deviation is the root of the squares over 29.
    let mean = (7 * 50.0 + 23 * 60.0) / 30
    let squares = 7 * (50 - mean) * (50 - mean) + 23 * (60 - mean) * (60 - mean)
    #expect(explanation.baseline.days == 30)
    #expect(explanation.baseline.latest == 50)
    #expect(explanation.baseline.sevenDayAverage == 50)
    #expect(abs(explanation.baseline.thirtyDayAverage! - mean) < 1e-9)
    #expect(abs(explanation.baseline.thirtyDayDeviation! - (squares / 29).squareRoot()) < 1e-9)
    // 50 is 13% under the 30-day mean, and below its usual range of about 53 to 62 bpm.
    #expect(explanation.trend == .lower)
    #expect(explanation.position == .below)
    // For resting heart rate, below usual is the good direction.
    #expect(explanation.outlook == .better)
    #expect(explanation.drivers.isEmpty)
    #expect(explanation.suggestions == [.keepUp])
}

@Test func bodyBatteryBelowUsualWithShortSleepNamesSleepAsTheDriver() {
    // Body Battery peaks at 80 every day except today, which peaked at 50.
    var batch = HealthBatch()
    batch.bodyBattery = (0..<30).map { PointSample(date: daysAgo($0, hour: $0 == 0 ? 8 : 12), value: $0 == 0 ? 50 : 80) }

    for (hours, expectsShortSleep) in [(6.0, true), (8.0, false)] {
        // Last night: from 23:00 yesterday until 5:00 today (6 hours), or until 7:00 (8 hours).
        batch.sleep = [SleepSession(start: daysAgo(1, hour: 23),
                                    end: daysAgo(0, hour: 5).addingTimeInterval(hours >= 8 ? 7_200 : 0),
                                    intervals: [])]
        let days = HealthInsights.days(batch, calendar: calendar)
        let explanation = InsightExplanations.explain(.bodyBattery, days: days, batch: batch, now: now, calendar: calendar)

        // The 7-day mean is (50 + 6 * 80) / 7. The 30-day mean is (50 + 29 * 80) / 30 = 79. The deviation is root 30.
        #expect(explanation.baseline.latest == 50)
        #expect(abs(explanation.baseline.sevenDayAverage! - 530.0 / 7) < 1e-9)
        #expect(abs(explanation.baseline.thirtyDayAverage! - 79) < 1e-9)
        #expect(abs(explanation.baseline.thirtyDayDeviation! - 30.0.squareRoot()) < 1e-9)
        // 7-day is 4% under 30-day: inside the 5% band, so it is similar.
        #expect(explanation.trend == .similar)
        // 50 is below 79 minus 5.5, and for Body Battery below usual is worse.
        #expect(explanation.position == .below)
        #expect(explanation.outlook == .worse)
        if expectsShortSleep {
            #expect(explanation.drivers == [InsightDriver(factor: .shortSleep, effect: .lowers)])
            #expect(explanation.suggestions == [.protectSleep])
        } else {
            // Seven hours or more is not short, so nothing in the data explains the drop.
            #expect(explanation.drivers.isEmpty)
            #expect(explanation.suggestions.isEmpty)
        }
    }
}

@Test func fewerThanSevenDaysGiveNoComparisonYet() {
    var batch = HealthBatch()
    batch.restingHeartRate = (0..<5).map { PointSample(date: daysAgo($0), value: 55) }
    let days = HealthInsights.days(batch, calendar: calendar)

    let explanation = InsightExplanations.explain(.restingHeartRate, days: days, batch: batch, now: now, calendar: calendar)

    #expect(explanation.baseline.days == 5)
    #expect(explanation.trend == nil)
    #expect(explanation.position == nil)
    #expect(explanation.outlook == nil)
    #expect(explanation.suggestions == [.keepTracking])
}

@Test func trainingStatusWithoutHistoryAsksForMoreTracking() {
    let explanation = InsightExplanations.explain(.trainingStatus, days: [], batch: HealthBatch(), now: now, calendar: calendar)

    #expect(explanation.training?.status == .noBaseline)
    #expect(explanation.outlook == nil)
    #expect(explanation.suggestions == [.keepTracking])
}
