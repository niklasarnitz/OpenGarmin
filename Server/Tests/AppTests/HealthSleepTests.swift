import XCTest
@testable import App

/// Health sleep samples become nights, one per span of time, below Garmin. No database needed.
final class HealthSleepTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func sample(_ fromHour: Double, _ toHour: Double, _ value: Int, _ bundle: String) -> HealthSleep.Sample {
        HealthSleep.Sample(start: t0.addingTimeInterval(fromHour * 3600), end: t0.addingTimeInterval(toHour * 3600), value: value, bundle: bundle)
    }

    func testSamplesMoreThanTwoHoursApartAreSeparateNightsAndInBedIsNotSleep() {
        let nights = HealthSleep.group([
            sample(0, 3, 4, "com.google.android.apps.fitness"),
            sample(4.5, 7, 5, "com.google.android.apps.fitness"), // 1.5 h gap: same night
            sample(24, 30, 0, "com.google.android.apps.fitness"), // in bed only
            sample(31, 32, 1, "com.google.android.apps.fitness"),
        ]).sorted { $0.start < $1.start }
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].end, t0.addingTimeInterval(7 * 3600))
        XCTAssertEqual(nights[0].stages.map(\.stage), ["deep", "rem"])
        XCTAssertEqual(nights[1].stages.map(\.stage), ["asleep"])
        XCTAssertEqual(nights[1].source, "healthkit:com.google.android.apps.fitness")
    }

    func testGarminWinsThenTheMirrorThenTheNightWithMoreSleep() {
        let candidates = HealthSleep.group([
            // Night 1: Garmin has it, so neither Health night counts.
            sample(0, 7, 3, "com.apple.health.WATCH"),
            // Night 2: the mirror wins over a longer Apple night.
            sample(24, 30, 3, "com.garmin.connect.mobile"),
            sample(23, 31, 3, "com.apple.health.WATCH"),
            // Night 3: the watch has more sleep than the phone.
            sample(48, 49, 1, "com.apple.health.PHONE"),
            sample(47, 54, 3, "com.apple.health.WATCH"),
            // Night 4: awake only, not a night.
            sample(72, 80, 2, "com.apple.health.WATCH"),
        ])
        let garmin = [HealthSleep.Span(start: t0.addingTimeInterval(-1800), end: t0.addingTimeInterval(6 * 3600))]
        let chosen = HealthSleep.select(candidates, garmin: garmin)
        XCTAssertEqual(chosen.map(\.source), ["healthkit:garmin-mirror", "healthkit:com.apple.health.WATCH"])
        XCTAssertEqual(chosen.map(\.start), [t0.addingTimeInterval(24 * 3600), t0.addingTimeInterval(47 * 3600)])
    }
}
