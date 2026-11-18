import Foundation
import Testing
import GarminModels

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// A local time in November 2026; `day` defaults to Wednesday the 18th.
private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, day: Int = 18) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
}

@Test func stressReadingsAreSortedIntoWorkingHoursBoundariesIncluded() {
    // Monday to Friday 9:00 to 17:00. 9:00 is working, 17:00 is not, 8:59:59 is not.
    let hours = WorkingHours.standard
    #expect(hours.contains(at(9), calendar: calendar))
    #expect(hours.contains(at(16, 59, 59), calendar: calendar))
    #expect(!hours.contains(at(17), calendar: calendar))
    #expect(!hours.contains(at(8, 59, 59), calendar: calendar))
    // Saturday at noon is outside the working days.
    #expect(!hours.contains(at(12, day: 21), calendar: calendar))
}

@Test func stressAveragesPerContextWithExactBoundariesZerosAndSleep() {
    // Interval: Tuesday 17 to Sunday 22 November, end exclusive. The Monday 16 reading is outside it.
    let interval = DateInterval(start: at(0, day: 17), end: at(0, day: 23))
    let sleep = [SleepSession(
        // Tuesday 23:00 to Wednesday 07:00 crosses midnight.
        start: at(23, day: 17), end: at(7),
        intervals: []
    )]
    let stress: [PointSample] = [
        PointSample(date: at(9), value: 30),         // working, included at 9:00
        PointSample(date: at(12), value: 60),        // working
        PointSample(date: at(16, 59, 59), value: 21), // working, last second before 17:00
        PointSample(date: at(10), value: 0),         // not measured: left out
        PointSample(date: at(17), value: 80),        // after hours, 17:00 is outside working hours
        PointSample(date: at(8, 59, 59), value: 10), // after hours, one second before 9:00
        PointSample(date: at(23, day: 17), value: 20), // asleep, at the start of the session
        PointSample(date: at(23, 30, day: 17), value: 30), // asleep
        PointSample(date: at(2), value: 50),         // asleep, after midnight
        PointSample(date: at(6, 59, 59), value: 70), // asleep, last second of the session
        PointSample(date: at(7), value: 90),         // awake again at 7:00: after hours
        PointSample(date: at(18, day: 20), value: 100), // Friday evening: after hours
        PointSample(date: at(10, day: 21), value: 30), // Saturday: weekend
        PointSample(date: at(22, day: 22), value: 50), // Sunday: weekend
        PointSample(date: at(12, day: 16), value: 99), // Monday, before the interval
    ]

    let summary = StressContexts.summarize(stress: stress, sleep: sleep, interval: interval,
                                           workingHours: .standard, calendar: calendar)

    // Working: (30 + 60 + 21) / 3. Counting 9:00 out, 17:00 in, or the zero would change it.
    #expect(summary.averages[.working] == StressContextAverage(mean: 111.0 / 3, readings: 3))
    // Sleep: (20 + 30 + 50 + 70) / 4.
    #expect(summary.averages[.sleep] == StressContextAverage(mean: 170.0 / 4, readings: 4))
    // After hours: (10 + 80 + 90 + 100) / 4.
    #expect(summary.averages[.afterHours] == StressContextAverage(mean: 280.0 / 4, readings: 4))
    // Weekend: (30 + 50) / 2.
    #expect(summary.averages[.weekend] == StressContextAverage(mean: 80.0 / 2, readings: 2))
}

@Test func contextIsEmptyWithoutReadings() {
    let summary = StressContexts.summarize(
        stress: [PointSample(date: at(10), value: 0)], sleep: [],
        interval: DateInterval(start: at(0), end: at(0, day: 19)), workingHours: .standard, calendar: calendar
    )
    #expect(summary.averages.isEmpty)
}

@Test func explanationSaysWhatStandsOutAgainstAfterHours() {
    // Working 70 against after hours 50: 20 points more, which asks for breaks. Sleep 60: 10 points more than
    // after hours, which asks for a calmer evening.
    let stressing = StressByContext(averages: [
        .working: StressContextAverage(mean: 70, readings: 10),
        .afterHours: StressContextAverage(mean: 50, readings: 10),
        .sleep: StressContextAverage(mean: 60, readings: 5),
    ])
    let explanation = InsightExplanations.explain(stressing)
    #expect(explanation.workingAboveAfterHours == 20)
    #expect(explanation.sleepAboveAfterHours == 10)
    #expect(explanation.suggestions == [.breathe, .protectSleep])

    // Working only 3 points above after hours does not stand out, and sleep is lower: nothing to flag.
    let calm = StressByContext(averages: [
        .working: StressContextAverage(mean: 53, readings: 10),
        .afterHours: StressContextAverage(mean: 50, readings: 10),
        .sleep: StressContextAverage(mean: 30, readings: 5),
    ])
    #expect(InsightExplanations.explain(calm).suggestions == [.keepUp])
}
