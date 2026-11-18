import Foundation
import Testing
@testable import GarminModels

private var berlin: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
    berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

@Test func presetsCoverWholeLocalDays() {
    // 2026-03-15 10:00 in Berlin; last month is February, which has 28 days in 2026.
    let now = day(2026, 3, 15, 10)
    #expect(ChartRangePreset.lastWeek.interval(now: now, calendar: berlin) == DateInterval(start: day(2026, 3, 9), end: day(2026, 3, 16)))
    #expect(ChartRangePreset.thisMonth.interval(now: now, calendar: berlin) == DateInterval(start: day(2026, 3, 1), end: day(2026, 3, 16)))
    #expect(ChartRangePreset.lastMonth.interval(now: now, calendar: berlin) == DateInterval(start: day(2026, 2, 1), end: day(2026, 3, 1)))
    #expect(ChartRangePreset.thisYear.interval(now: now, calendar: berlin) == DateInterval(start: day(2026, 1, 1), end: day(2026, 3, 16)))
    // A custom range picked backwards still covers both end days in full.
    #expect(ChartRangePreset.custom.interval(now: now, from: day(2026, 3, 4, 18), to: day(2026, 3, 2, 7), calendar: berlin)
        == DateInterval(start: day(2026, 3, 2), end: day(2026, 3, 5)))
}

@Test func lastMonthInJanuaryIsDecemberOfTheYearBefore() {
    #expect(ChartRangePreset.lastMonth.interval(now: day(2026, 1, 10, 12), calendar: berlin)
        == DateInterval(start: day(2025, 12, 1), end: day(2026, 1, 1)))
}

@Test func smoothingKeepsOneDayRawAndAveragesLongerSpansWithoutBridgingGaps() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let oneDay = (0..<10).map { PointSample(date: start.addingTimeInterval(Double($0) * 3600), value: Double($0 % 2) * 100) }
    #expect(ChartSmoothing.smoothed(oneDay) == oneDay)

    // Three days: hourly buckets. Hours 0 and 1 hold readings (10 and 30, and 50), hour 2 is empty, hour 3 holds 90,
    // and a last reading 70 hours in stretches the span past 36 hours.
    let points = [
        PointSample(date: start, value: 10), PointSample(date: start.addingTimeInterval(600), value: 30),
        PointSample(date: start.addingTimeInterval(3600), value: 50),
        PointSample(date: start.addingTimeInterval(3 * 3600), value: 90),
        PointSample(date: start.addingTimeInterval(70 * 3600), value: 0),
    ]
    let smoothed = ChartSmoothing.smoothed(points)
    // Bucket means: 20, 50, –, 90, …, 0. Hour 0 averages with hour 1 only; hour 3 has no readings next to it.
    #expect(smoothed.map(\.value) == [35, 35, 90, 0])
    #expect(smoothed.first?.date == start.addingTimeInterval(1800))
}

@Test func rollingMeanAveragesOnlyDaysThatHaveValues() {
    let points = [day(2026, 3, 1, 12), day(2026, 3, 2, 12), day(2026, 3, 9, 12)].enumerated().map {
        PointSample(date: $0.element, value: [10, 20, 60][$0.offset])
    }
    // 9 March: the 7-day window starts on 3 March, so only its own value counts.
    #expect(ChartSmoothing.rollingMean(points, days: 7, calendar: berlin).map(\.value) == [10, 15, 60])
}
