import Foundation

/// Finds the notable parts of a user's history. Pure: `InsightStore` loads the input, and the tests run on synthetic
/// series with known answers. Every sentence is written in the requested language. None claims a cause.
enum InsightEngine {
    /// The fewest paired days a comparison needs.
    static let minimumN = 30
    static let maximumInsights = 40

    static func run(_ input: InsightInput, lang: String) -> [Insight] {
        let words = Words(lang)
        var found: [Insight] = []
        found += trends(input, words)
        found += changepoints(input, words)
        found += anomalies(input, words)
        found += records(input, words)
        found += correlations(input, words)
        found += conditions(input, words)
        found += weekdayPatterns(input, words)
        found += seasonalPatterns(input, words)
        found += sleepRegularity(input, words)
        found += socialJetlag(input, words)
        found += stressContexts(input, words)
        return Array(found.sorted { $0.strength * $0.confidence > $1.strength * $1.confidence }.prefix(maximumInsights))
    }

    // MARK: - Shared helpers

    /// The observed days of a series inside the range, in order, with their values.
    static func observed(_ series: DailySeries?, _ range: ClosedRange<Int>) -> (days: [Int], values: [Double]) {
        guard let series else { return ([], []) }
        let days = series.keys.filter { range.contains($0) }.sorted()
        return (days, days.map { series[$0]! })
    }

    static func period(_ first: Int, _ last: Int) -> Period {
        DayRange(first: first, last: last).period
    }

    /// Midnight of a day as a plain number of milliseconds, for chart x values.
    static func millis(_ day: Int) -> Double {
        Double(day) * 86_400_000
    }

    static func chart(_ type: String, _ series: [ChartSeries]) -> InsightChart {
        InsightChart(type: type, series: series)
    }

    // MARK: - Trends

    /// Monthly averages of each metric, tested for a monotonic trend. The slope is Theil–Sen, per year.
    static func trends(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for metric in ["restingHeartRate", "hrv", "stress", "bodyBattery", "sleepMinutes", "steps"] {
            let (days, values) = observed(input.series[metric], input.range)
            var sums: [Int: (total: Double, count: Int)] = [:]
            for (day, value) in zip(days, values) {
                let parts = CivilDay.parts(day)
                var entry = sums[parts.year * 12 + parts.month - 1] ?? (0, 0)
                entry.total += value
                entry.count += 1
                sums[parts.year * 12 + parts.month - 1] = entry
            }
            let months = sums.filter { $0.value.count >= 10 }.sorted { $0.key < $1.key }
            guard months.count >= 12, let first = days.first, let last = days.last else { continue }
            let x = months.map { Double($0.key) }
            let y = months.map { $0.value.total / Double($0.value.count) }
            let test = Stats.mannKendall(y)
            let perYear = Stats.theilSenSlope(x: x, y: y) * 12
            guard test.p < 0.05, abs(test.tau) >= 0.2 else { continue }

            let name = w.name(metric)
            let amount = w.quantity(abs(perYear), metric, digits: 1)
            let rising = perYear > 0
            let title = w.pick(
                "Your \(name) \(rising ? "rises" : "falls") by \(amount) per year.",
                "Der Trend von \(name) \(rising ? "steigt" : "sinkt") um \(amount) pro Jahr."
            )
            let summary = w.pick(
                "Theil–Sen slope over \(months.count) months; Mann–Kendall τ = \(w.num(test.tau, 2)), p \(w.p(test.p)).",
                "Theil-Sen-Steigung über \(months.count) Monate; Mann-Kendall τ = \(w.num(test.tau, 2)), p \(w.p(test.p))."
            )
            let firstMonth = months.first!, lastMonth = months.last!
            let detail = w.pick(
                "Monthly averages went from \(w.quantity(firstMonth.value.total / Double(firstMonth.value.count), metric)) in \(w.monthYear(firstMonth.key)) to \(w.quantity(lastMonth.value.total / Double(lastMonth.value.count), metric)) in \(w.monthYear(lastMonth.key)).",
                "Die Monatsmittel gingen von \(w.quantity(firstMonth.value.total / Double(firstMonth.value.count), metric)) im \(w.monthYear(firstMonth.key)) auf \(w.quantity(lastMonth.value.total / Double(lastMonth.value.count), metric)) im \(w.monthYear(lastMonth.key)) über."
            )
            found.append(Insight(
                id: "trend:\(metric)", kind: "trend", title: title, summary: summary, detail: detail,
                metrics: [metric], strength: abs(test.tau), confidence: 1 - test.p, n: values.count,
                period: period(first, last), lagDays: nil,
                chart: chart("line", [ChartSeries(name: name, points: zip(months, y).map { [millis(monthStart($0.0.key)), $0.1] })])
            ))
        }
        return found
    }

    /// The first day of a month, from the year-times-12 month key used above.
    static func monthStart(_ key: Int) -> Int {
        CivilDay.index(year: key / 12, month: key % 12 + 1, day: 1)
    }

    // MARK: - Changepoints

    /// Level shifts in the daily values of a metric, found by binary segmentation.
    static func changepoints(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for metric in ["restingHeartRate", "hrv", "stress", "sleepMinutes"] {
            let (days, values) = observed(input.series[metric], input.range)
            guard values.count >= 60 else { continue }
            let splits = Stats.changepoints(values).sorted { $0.index < $1.index }
            let bounds = [0] + splits.map(\.index) + [values.count]
            for split in splits {
                let left = bounds.filter { $0 < split.index }.max() ?? 0
                let right = bounds.filter { $0 > split.index }.min() ?? values.count
                let before = Array(values[left..<split.index]), after = Array(values[split.index..<right])
                let test = Stats.welch(after, before)
                let day = days[split.index]
                let name = w.name(metric)
                let beforeMean = Stats.mean(before), afterMean = Stats.mean(after)
                let rose = afterMean > beforeMean
                found.append(Insight(
                    id: "changepoint:\(metric):\(day)", kind: "changepoint",
                    title: w.pick(
                        "\(capitalized(name)) shifted on \(w.date(day)): \(w.quantity(beforeMean, metric)) before, \(w.quantity(afterMean, metric)) after.",
                        "\(capitalized(name)) verschob sich am \(w.date(day)): vorher \(w.quantity(beforeMean, metric)), danach \(w.quantity(afterMean, metric))."
                    ),
                    summary: w.pick(
                        "The level \(rose ? "rose" : "fell") from \(before.count) days before to \(after.count) days after the change.",
                        "Das Niveau \(rose ? "stieg" : "fiel") von \(before.count) Tagen davor auf \(after.count) Tage danach."
                    ),
                    detail: w.pick(
                        "Binary segmentation of daily values, minimum segment 14 days, F = \(w.num(split.f, 1)).",
                        "Binäre Segmentierung der Tageswerte, mindestens 14 Tage pro Abschnitt, F = \(w.num(split.f, 1))."
                    ),
                    metrics: [metric],
                    strength: min(1, abs(test.d) / 2),
                    confidence: 1 - test.p,
                    n: values.count,
                    period: period(days.first!, days.last!),
                    lagDays: nil,
                    chart: nil
                ))
            }
        }
        return found
    }

    // MARK: - Anomalies

    /// Days far from the 28 days before them, in the direction that is unusual for the metric. `direction` is +1 when a
    /// rise is unusual and -1 when a fall is. `minimum` is the smallest change that counts, in the metric's unit.
    static let anomalySpecs: [(metric: String, direction: Double, minimum: Double)] = [
        ("restingHeartRate", 1, 5), ("stress", 1, 10), ("hrv", -1, 10), ("bodyBattery", -1, 15), ("sleepMinutes", -1, 60),
    ]

    /// Runs of at least two unusual days, merged across a one-day gap, each reported as one episode.
    static func anomalies(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for spec in anomalySpecs {
            guard let series = input.series[spec.metric] else { continue }
            let (days, values) = observed(series, input.range)
            var flagged: [(day: Int, z: Double, delta: Double)] = []
            for (day, value) in zip(days, values) {
                let baseline = (day - 28..<day).compactMap { series[$0] }
                guard baseline.count >= 14 else { continue }
                let center = Stats.median(baseline)
                let scale = Stats.scaledMAD(baseline, center: center)
                guard scale > 0 else { continue }
                let delta = spec.direction * (value - center)
                if delta / scale >= 3, delta >= spec.minimum {
                    flagged.append((day, delta / scale, delta))
                }
            }
            var episodes: [[(day: Int, z: Double, delta: Double)]] = []
            for item in flagged {
                if let last = episodes.last?.last, item.day - last.day <= 2 {
                    episodes[episodes.count - 1].append(item)
                } else {
                    episodes.append([item])
                }
            }
            let name = w.name(spec.metric)
            let high = spec.direction > 0
            for episode in episodes where episode.count >= 2 {
                let first = episode.first!.day, last = episode.last!.day
                let meanDelta = Stats.mean(episode.map(\.delta))
                let meanZ = Stats.mean(episode.map(\.z))
                let amount = w.quantity(meanDelta, spec.metric, digits: 1)
                found.append(Insight(
                    id: "anomaly:\(spec.metric):\(first)", kind: "anomaly",
                    title: w.pick(
                        "\(capitalized(name)) was unusually \(high ? "high" : "low") from \(w.date(first)) to \(w.date(last)).",
                        "\(capitalized(name)) war ungewöhnlich \(high ? "hoch" : "niedrig") vom \(w.date(first)) bis \(w.date(last))."
                    ),
                    summary: w.pick(
                        "On \(episode.count) days it sat \(amount) \(high ? "above" : "below") its 28-day baseline. Illness, stress or a hard day can do that.",
                        "An \(episode.count) Tagen lag er \(amount) \(high ? "über" : "unter") seinem 28-Tage-Mittel. Krankheit, Stress oder ein harter Tag können das erklären."
                    ),
                    detail: w.pick(
                        "Robust z-score against the median and MAD of the previous 28 days, mean z = \(w.num(meanZ, 1)).",
                        "Robuster z-Wert gegen Median und MAD der vorigen 28 Tage, mittleres z = \(w.num(meanZ, 1))."
                    ),
                    metrics: [spec.metric], strength: min(1, meanZ / 6),
                    confidence: 1 - exp(-Double(episode.count) / 3), n: episode.count,
                    period: period(first, last), lagDays: nil, chart: nil
                ))
            }
        }
        return found
    }

    // MARK: - Records

    /// Personal bests and the longest run of days with at least 10,000 steps.
    static func records(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        let bests: [(metric: String, highest: Bool)] = [
            ("steps", true), ("sleepMinutes", true), ("hrv", true), ("restingHeartRate", false),
        ]
        for best in bests {
            let (days, values) = observed(input.series[best.metric], input.range)
            guard let index = best.highest ? values.indices.max(by: { values[$0] < values[$1] })
                : values.indices.min(by: { values[$0] < values[$1] }) else { continue }
            let name = w.name(best.metric)
            let value = w.quantity(values[index], best.metric)
            found.append(Insight(
                id: "record:\(best.metric):\(best.highest ? "max" : "min")", kind: "record",
                title: w.pick(
                    "Your \(best.highest ? "highest" : "lowest") \(name) was \(value) on \(w.date(days[index])).",
                    "Dein \(best.highest ? "höchster" : "niedrigster") Wert für \(name) war \(value) am \(w.date(days[index]))."
                ),
                summary: w.pick(
                    "The best of \(values.count) days with data in this period.",
                    "Der beste von \(values.count) Tagen mit Daten in diesem Zeitraum."
                ),
                detail: "",
                metrics: [best.metric], strength: 0.5, confidence: 1, n: values.count,
                period: period(days.first!, days.last!), lagDays: nil, chart: nil
            ))
        }

        let (days, steps) = observed(input.series["steps"], input.range)
        var best: (start: Int, end: Int, length: Int)?
        var run: (start: Int, end: Int, length: Int)?
        for (day, value) in zip(days, steps) {
            guard value >= 10_000 else { run = nil; continue }
            if let current = run, current.end + 1 == day {
                run = (current.start, day, current.length + 1)
            } else {
                run = (day, day, 1)
            }
            if run!.length > (best?.length ?? 0) { best = run }
        }
        if let streak = best, streak.length >= 5 {
            found.append(Insight(
                id: "record:stepStreak", kind: "record",
                title: w.pick(
                    "Your longest run of days with at least 10,000 steps is \(streak.length) days, ending on \(w.date(streak.end)).",
                    "Deine längste Serie mit mindestens 10.000 Schritten ist \(streak.length) Tage lang und endet am \(w.date(streak.end))."
                ),
                summary: w.pick(
                    "Every day in the run reached 10,000 steps, in order and with no gap.",
                    "Jeder Tag der Serie hatte mindestens 10.000 Schritten, ohne Lücke."
                ),
                detail: "",
                metrics: ["steps"], strength: 0.5, confidence: 1, n: streak.length,
                period: period(streak.start, streak.end), lagDays: nil, chart: nil
            ))
        }
        return found
    }
}
