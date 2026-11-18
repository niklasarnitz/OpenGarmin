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

private func daysAgo(_ days: Int, at hour: Int = 9) -> Date {
    let day = calendar.date(byAdding: .day, value: -days, to: now)!
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
}

private func activity(daysAgo days: Int, minutes: Double, trainingEffect: Double? = nil, averageHeartRate: Int? = nil) -> Activity {
    let start = daysAgo(days)
    return Activity(id: "\(days)", sport: .running, start: start, end: start.addingTimeInterval(minutes * 60),
                    duration: minutes * 60, averageHeartRate: averageHeartRate, trainingEffect: trainingEffect)
}

@Test func loadIsMinutesTimesTrainingEffectOrHeartRateReserve() {
    // 30 minutes at training effect 3.0.
    #expect(HealthInsights.load(of: activity(daysAgo: 0, minutes: 30, trainingEffect: 3.0)) == 90)
    // 60 minutes at an average of 150 bpm: reserve (150 - 60) / (190 - 60) = 90 / 130, times 5 per hour.
    let withoutEffect = HealthInsights.load(of: activity(daysAgo: 0, minutes: 60, averageHeartRate: 150))
    #expect(abs(withoutEffect - 60 * 90 / 130 * 5) < 1e-9)
    // No effect and no heart rate: no load.
    #expect(HealthInsights.load(of: activity(daysAgo: 0, minutes: 60)) == 0)
}

@Test func trainingLoadUsesSevenAndTwentyEightDayWindows() {
    let batch = HealthBatch.withActivities([
        activity(daysAgo: 0, minutes: 60, averageHeartRate: 150), // acute and chronic
        activity(daysAgo: 3, minutes: 30, trainingEffect: 3.0), // acute and chronic: 90
        activity(daysAgo: 10, minutes: 30, trainingEffect: 4.0), // chronic only: 120
        activity(daysAgo: 20, minutes: 40, trainingEffect: 2.0), // chronic only: 80
        activity(daysAgo: 28, minutes: 60, trainingEffect: 5.0), // outside both windows
        activity(daysAgo: 40, minutes: 60, trainingEffect: 5.0), // outside both windows
    ], heartRateFrom: 40)

    let status = HealthInsights.trainingLoad(batch, now: now, calendar: calendar)
    // Today's activity alone: 60 minutes at 150 bpm.
    let today = 60.0 * 90 / 130 * 5
    #expect(abs(status.acuteLoad - (today + 90)) < 1e-9)
    #expect(abs(status.chronicLoad - (today + 90 + 120 + 80) / 4) < 1e-9)
    #expect(abs(status.ratio! - status.acuteLoad / status.chronicLoad) < 1e-9)
    // The ratio is about 2.4, far above 1.5.
    #expect(status.status == .highRisk)
}

@Test func trainingLoadIsDetrainingWhenNothingWasDoneThisWeek() {
    let batch = HealthBatch.withActivities([
        activity(daysAgo: 10, minutes: 30, trainingEffect: 4.0),
        activity(daysAgo: 30, minutes: 30, trainingEffect: 4.0),
    ], heartRateFrom: 40)
    let status = HealthInsights.trainingLoad(batch, now: now, calendar: calendar)
    #expect(status.acuteLoad == 0)
    #expect(status.ratio == 0)
    #expect(status.status == .detraining)
}

@Test func trainingLoadNeedsTwentyEightDaysOfHistory() {
    let batch = HealthBatch.withActivities([activity(daysAgo: 2, minutes: 30, trainingEffect: 3.0)], heartRateFrom: 5)
    let status = HealthInsights.trainingLoad(batch, now: now, calendar: calendar)
    #expect(status.status == .noBaseline)
    #expect(status.ratio == nil)
    #expect(status.acuteLoad == 90)
}

private func night(daysAgo days: Int, average: Double, lower: Double = 46, upper: Double = 56, lowUpper: Double = 40) -> HRVStatusSample {
    HRVStatusSample(date: daysAgo(days, at: 6), lastNightAverage: average, baselineLowUpper: lowUpper,
                    baselineBalancedLower: lower, baselineBalancedUpper: upper)
}

@Test func hrvAveragesSevenNightsAgainstTheBalancedRange() throws {
    var batch = HealthBatch()
    // Seven nights in the window: average 360 / 7. The night eight days ago is outside it.
    let averages: [Double] = [50, 52, 48, 55, 45, 50, 60]
    batch.hrvStatus = averages.enumerated().map { night(daysAgo: $0.offset, average: $0.element) }
        + [night(daysAgo: 8, average: 90)]

    let assessment = try #require(HealthInsights.hrvStatus(batch, now: now, calendar: calendar))
    #expect(abs(assessment.sevenDayAverage - 360.0 / 7) < 1e-9)
    #expect(assessment.balancedRange == 46...56)
    #expect(assessment.status == .balanced)
}

@Test func hrvBelowTheBalancedRangeIsLowOrPoor() throws {
    var batch = HealthBatch()
    // Average 42.5: below the balanced range (46) but above the low-upper limit (40).
    batch.hrvStatus = [night(daysAgo: 0, average: 40), night(daysAgo: 1, average: 45)]
    #expect(try #require(HealthInsights.hrvStatus(batch, now: now, calendar: calendar)).status == .low)

    // Average 35: below the low-upper limit.
    batch.hrvStatus = [night(daysAgo: 0, average: 30), night(daysAgo: 1, average: 40)]
    #expect(try #require(HealthInsights.hrvStatus(batch, now: now, calendar: calendar)).status == .poor)

    // Average 58: above the balanced range.
    batch.hrvStatus = [night(daysAgo: 0, average: 60), night(daysAgo: 1, average: 56)]
    #expect(try #require(HealthInsights.hrvStatus(batch, now: now, calendar: calendar)).status == .unbalanced)
}

@Test func dailyInsightsGroupEachSourceByItsDay() throws {
    var batch = HealthBatch()
    batch.restingHeartRate = [PointSample(date: daysAgo(1, at: 7), value: 52), PointSample(date: daysAgo(1, at: 20), value: 49)]
    batch.stress = [PointSample(date: daysAgo(1, at: 8), value: 20), PointSample(date: daysAgo(1, at: 9), value: 40),
                    PointSample(date: daysAgo(1, at: 10), value: 90)]
    batch.bodyBattery = [PointSample(date: daysAgo(1, at: 8), value: 80), PointSample(date: daysAgo(1, at: 18), value: 35)]
    batch.sleep = [SleepSession(start: daysAgo(1, at: 23), end: daysAgo(1, at: 23).addingTimeInterval(7 * 3600 + 30 * 60),
                                intervals: [], score: 81)]

    let days = HealthInsights.days(batch, calendar: calendar)
    let day = try #require(days.first)
    #expect(days.count == 1)
    #expect(day.restingHeartRate == 49) // the later reading
    #expect(day.averageStress == 50)
    #expect(day.bodyBatteryLow == 35)
    #expect(day.bodyBatteryHigh == 80)
    #expect(day.sleepMinutes == 450)
    #expect(day.sleepScore == 81)
}

extension HealthBatch {
    /// A batch holding `activities`, and a heart rate sample `heartRateFrom` days ago so the history has a span.
    static func withActivities(_ activities: [Activity], heartRateFrom days: Int) -> HealthBatch {
        var batch = HealthBatch()
        batch.activities = activities
        batch.heartRate = [HeartRateSample(date: daysAgo(days), bpm: 60)]
        return batch
    }
}

@Test func trainingPlanRepeatsTheWeeklyTemplateAndFindsTheNextWorkout() throws {
    func workout(_ name: String) -> WorkoutPlan { WorkoutPlan(name: name, sport: .running, steps: []) }
    // Monday, Wednesday and Friday, for two weeks from a Tuesday.
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 8))!
    let plan = TrainingPlan(name: "Base", start: start, weeks: 2, weekdays: [2: workout("A"), 4: workout("B"), 6: workout("C")],
                            calendar: calendar)

    #expect(plan.sessions.map(\.workout.name) == ["B", "C", "A", "B", "C", "A"])

    // Wednesday at 10:00 is B's own day, so it is the next workout.
    let wednesday = try #require(plan.nextSession(from: now, calendar: calendar))
    #expect(wednesday.workout.name == "B")
    #expect(calendar.component(.day, from: wednesday.day) == 18)

    // After Wednesday, the next is Friday.
    let thursday = calendar.date(byAdding: .day, value: 1, to: now)!
    #expect(plan.nextSession(from: thursday, calendar: calendar)?.workout.name == "C")
}
