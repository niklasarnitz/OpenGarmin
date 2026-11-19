import XCTest
@testable import App

/// The insight engine on synthetic series whose answers are known by construction. No database needed.
final class InsightEngineTests: XCTestCase {
    let first = CivilDay.index(year: 2023, month: 1, day: 1)

    func series(_ days: Int, _ value: (Int) -> Double) -> DailySeries {
        var result: DailySeries = [:]
        for offset in 0..<days { result[first + offset] = value(offset) }
        return result
    }

    func input(days: Int, _ metrics: [String: DailySeries]) -> InsightInput {
        var input = InsightInput(range: first...(first + days - 1))
        input.series = metrics
        return input
    }

    func insight(_ insights: [Insight], _ id: String) -> Insight? {
        insights.first { $0.id == id }
    }

    // MARK: - Statistics

    func testStatisticsMatchKnownAnswers() {
        // Strictly increasing values: every pair is concordant, so tau is exactly 1.
        let trend = Stats.mannKendall((0..<20).map(Double.init))
        XCTAssertEqual(trend.tau, 1, accuracy: 1e-12)
        XCTAssertLessThan(trend.p, 0.001)

        // Theil–Sen recovers an exact line of slope 2 despite one wild value.
        var y = (0..<30).map { 2 * Double($0) + 1 }
        y[10] = 500
        XCTAssertEqual(Stats.theilSenSlope(x: (0..<30).map(Double.init), y: y), 2, accuracy: 1e-12)

        // Benjamini–Hochberg with m = 3: the sorted p-values 0.01, 0.03, 0.04 get q 0.03, 0.04, 0.04.
        let q = Stats.benjaminiHochberg([0.01, 0.04, 0.03])
        XCTAssertEqual(q[0], 0.03, accuracy: 1e-12)
        XCTAssertEqual(q[1], 0.04, accuracy: 1e-12)
        XCTAssertEqual(q[2], 0.04, accuracy: 1e-12)

        // Spearman is 1 for any monotone relation, even a non-linear one; Pearson is not.
        let x = (1...30).map(Double.init)
        XCTAssertEqual(Stats.spearman(x, x.map { $0 * $0 * $0 }), 1, accuracy: 1e-12)
        XCTAssertLessThan(Stats.pearson(x, x.map { exp($0 / 5) }), 0.99)

        XCTAssertEqual(Stats.ranks([3, 1, 3]), [2.5, 1, 2.5], "tied values share the average rank")
    }

    func testWordsFormatThousandsSeparatelyPerLanguage() {
        XCTAssertEqual(Words("en").integer(9800), "9,800")
        XCTAssertEqual(Words("de").integer(9800), "9.800")
        XCTAssertEqual(Words("de").num(1.5, 1), "1,5")
    }

    // MARK: - Source resolution

    func testOneSourcePerDayGarminThenMirrorThenTheFullestAppleSource() {
        let rows: [InsightSources.Row] = [
            .init(day: 1, metric: "steps", source: "garmin", value: 8000, count: 1),
            .init(day: 1, metric: "HKQuantityTypeIdentifierStepCount", source: "healthkit:com.apple.health", value: 9000, count: 100),
            .init(day: 2, metric: "HKQuantityTypeIdentifierStepCount", source: "healthkit:com.apple.health", value: 9000, count: 100),
            .init(day: 2, metric: "HKQuantityTypeIdentifierStepCount", source: "healthkit:garmin-mirror", value: 7000, count: 50),
            .init(day: 3, metric: "steps", source: "healthkit:garmin-mirror", value: 7000, count: 50),
            .init(day: 4, metric: "HKQuantityTypeIdentifierStepCount", source: "healthkit:com.apple.health.A", value: 2000, count: 10),
            .init(day: 4, metric: "HKQuantityTypeIdentifierStepCount", source: "healthkit:com.apple.health.B", value: 9500, count: 400),
            .init(day: 4, metric: "HKQuantityTypeIdentifierDistanceWalkingRunning", source: "healthkit:com.apple.health.B", value: 6.5, count: 400),
        ]
        let steps = InsightSources.resolve(rows)["steps"]
        XCTAssertEqual(steps?[1], 8000, "Garmin wins over Apple Health on the same day")
        XCTAssertEqual(steps?[2], 7000, "the Garmin mirror wins over Apple Health; the two are never added")
        XCTAssertEqual(steps?[3], 7000, "a day only the Garmin mirror covers is used")
        XCTAssertEqual(steps?[4], 9500, "of two Apple devices the one with more readings wins, not their sum")
        XCTAssertEqual(InsightSources.resolve(rows)["distance"]?[4], 6500, "Apple Health km become Garmin metres")
    }

    // MARK: - Engine

    func testSteadyRiseIsReportedAsTrendWithItsDirection() {
        // Resting heart rate rises 0.02 bpm a day for 2.5 years, with no noise: a monotone monthly trend.
        let rhr = series(915) { 60 + 0.02 * Double($0) }
        let found = InsightEngine.run(input(days: 915, ["restingHeartRate": rhr]), lang: "en")
        let trend = insight(found, "trend:restingHeartRate")
        XCTAssertEqual(trend?.kind, "trend")
        XCTAssertTrue(trend?.title.contains("rises") ?? false, trend?.title ?? "missing")
        XCTAssertEqual(trend?.strength ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(trend?.period.from, "2023-01-01")
        XCTAssertEqual(trend?.period.to, CivilDay.string(first + 914))
    }

    func testEpisodeOfUnusualDaysIsOneAnomaly() {
        // Resting heart rate around 55 with ±1 noise; days 60 to 63 sit 11 bpm higher, as during an illness.
        var rng = SplitMix(seed: 1)
        let rhr = series(120) { day in
            let noise = (rng.unit() - 0.5) * 2
            return (60...63).contains(day) ? 66 + noise : 55 + noise
        }
        let found = InsightEngine.run(input(days: 120, ["restingHeartRate": rhr]), lang: "en")
        let episode = insight(found, "anomaly:restingHeartRate:\(first + 60)")
        XCTAssertEqual(episode?.kind, "anomaly")
        XCTAssertEqual(episode?.n, 4, "four consecutive unusual days form one episode")
        XCTAssertEqual(episode?.period.from, "2023-03-02")
        XCTAssertEqual(episode?.period.to, "2023-03-05")
        XCTAssertEqual(found.filter { $0.kind == "anomaly" }.count, 1)
    }

    func testStepChangeIsFoundWithBeforeAndAfterMeans() {
        // Resting heart rate is 60 for 60 days, then 70 for 60 days, with ±0.5 noise.
        var rng = SplitMix(seed: 2)
        let rhr = series(120) { day in (day < 60 ? 60 : 70) + (rng.unit() - 0.5) }
        let found = InsightEngine.run(input(days: 120, ["restingHeartRate": rhr]), lang: "en")
        let change = insight(found, "changepoint:restingHeartRate:\(first + 60)")
        XCTAssertEqual(change?.kind, "changepoint")
        XCTAssertTrue(change?.title.contains("shifted on") ?? false, change?.title ?? "missing")
        XCTAssertTrue(change?.summary.contains("60 days before") ?? false, change?.summary ?? "missing")
    }

    func testLaggedCorrelationReportsItsLag() {
        // Deep sleep tomorrow follows today's steps. Same-day values are unrelated.
        var rng = SplitMix(seed: 3)
        let steps = series(400) { _ in 5_000 + rng.unit() * 10_000 }
        var deep: DailySeries = [:]
        for (day, value) in steps where day + 1 <= first + 399 {
            deep[day + 1] = 40 + 0.004 * value + (rng.unit() - 0.5)
        }
        let found = InsightEngine.run(input(days: 400, ["steps": steps, "sleepDeepMinutes": deep]), lang: "en")
        let lagged = insight(found, "correlation:steps:sleepDeepMinutes:1")
        XCTAssertEqual(lagged?.lagDays, 1)
        XCTAssertGreaterThan(lagged?.strength ?? 0, 0.9)
        XCTAssertNil(insight(found, "correlation:steps:sleepDeepMinutes:0"), "the same-day pair is not significant")
    }

    func testLongStepStreakIsARecord() {
        // 8,000 steps a day, except six days from 10 to 15 with 12,000.
        let steps = series(30) { (10...15).contains($0) ? 12_000 : 8_000 }
        let found = InsightEngine.run(input(days: 30, ["steps": steps]), lang: "en")
        let streak = insight(found, "record:stepStreak")
        XCTAssertEqual(streak?.n, 6)
        XCTAssertEqual(streak?.period.from, "2023-01-11")
        XCTAssertEqual(streak?.period.to, "2023-01-16")
    }

    func testConditionalComparisonReadsTheNextDay() {
        // Steps alternate 12,000 and 6,000 a day. Deep sleep the day after a 12,000 day is 60 minutes, otherwise 40,
        // both with small noise. The known answer is a 50% difference.
        var rng = SplitMix(seed: 4)
        let steps = series(120) { $0 % 2 == 0 ? 12_000 : 6_000 }
        var deep: DailySeries = [:]
        for day in steps.keys.sorted() where day + 1 <= first + 119 {
            deep[day + 1] = (steps[day]! > 10_000 ? 60 : 40) + (rng.unit() - 0.5)
        }
        let found = InsightEngine.run(input(days: 120, ["steps": steps, "sleepDeepMinutes": deep]), lang: "en")
        let rule = insight(found, "condition:steps:sleepDeepMinutes:1")
        XCTAssertEqual(rule?.lagDays, 1)
        XCTAssertTrue(rule?.title.contains("50%") ?? false, rule?.title ?? "missing")
        XCTAssertTrue(rule?.title.contains("higher the next day") ?? false, rule?.title ?? "missing")
    }

    func testSocialJetlagIsTheMidpointGapBetweenFreeAndWorkNights() {
        // Workday nights sleep from 23:30 (onset 330), free-day nights from 01:30 (onset 450). Both last 8 hours, so the
        // midpoints are 120 minutes apart. Alternating ±10 minutes of noise keeps the test honest.
        var input = InsightInput(range: first...(first + 89))
        input.nights = (0..<90).map { offset in
            let day = first + offset
            let work = (0...4).contains(CivilDay.weekday(day))
            let noise: Double = offset % 2 == 0 ? 10 : -10
            return SleepNight(wakeDay: day, onset: (work ? 330 : 450) + noise, duration: 480)
        }
        let found = InsightEngine.run(input, lang: "en")
        let jetlag = insight(found, "jetlag:sleep")
        XCTAssertEqual(jetlag?.kind, "pattern")
        // The noise does not cancel exactly between the two groups, so the gap is read within a few minutes of 120.
        let title = jetlag?.title ?? "missing"
        XCTAssertTrue(title.contains("min later"), title)
        let minutes = title.components(separatedBy: " min later").first?.split(separator: " ").last.flatMap { Int($0) }
        XCTAssertNotNil(minutes)
        XCTAssertLessThanOrEqual(abs((minutes ?? 0) - 120), 3, title)
    }

    func testStressByWeekdayNamesTheHighestDay() {
        // Mondays average about 40 and every other day about 20, with a little noise, over ten weeks.
        var rng = SplitMix(seed: 5)
        let stress = series(70) { offset in
            (CivilDay.weekday(first + offset) == 0 ? 40 : 20) + rng.unit()
        }
        let found = InsightEngine.run(input(days: 70, ["stress": stress]), lang: "en")
        let pattern = insight(found, "weekday:stress")
        XCTAssertEqual(pattern?.kind, "pattern")
        XCTAssertTrue(pattern?.title.contains("highest on Monday") ?? false, pattern?.title ?? "missing")
        XCTAssertEqual(pattern?.n, 70)
    }

    func testNoDataProducesNoInsights() {
        XCTAssertTrue(InsightEngine.run(input(days: 365, [:]), lang: "de").isEmpty)
    }
}
