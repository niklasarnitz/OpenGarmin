import Foundation

/// Correlations, conditional comparisons and patterns. Every pairwise test is corrected for multiple testing, needs a
/// minimum sample and an effect size, and is reported as an association only.
extension InsightEngine {
    /// Daily series that pairwise correlations are computed for.
    static let correlated = [
        "steps", "activeEnergy", "intensityMinutes", "trainingMinutes", "restingHeartRate", "hrv", "stress", "bodyBattery",
        "sleepMinutes", "sleepDeepMinutes",
    ]

    /// A rule "after days with X, Y is higher or lower": X on day d against Y on day d + lag.
    struct Rule {
        let x: String
        let threshold: Double
        let above: Bool
        let y: String
        let lag: Int
        let en: String
        let de: String
    }

    static let conditionRules: [Rule] = [
        Rule(x: "steps", threshold: 10_000, above: true, y: "sleepDeepMinutes", lag: 1,
             en: "with more than 10,000 steps", de: "mit mehr als 10.000 Schritten"),
        Rule(x: "sleepMinutes", threshold: 390, above: false, y: "stress", lag: 1,
             en: "with less than 6.5 hours of sleep", de: "mit weniger als 6,5 Stunden Schlaf"),
        Rule(x: "sleepMinutes", threshold: 390, above: false, y: "restingHeartRate", lag: 1,
             en: "with less than 6.5 hours of sleep", de: "mit weniger als 6,5 Stunden Schlaf"),
        Rule(x: "trainingMinutes", threshold: 45, above: true, y: "hrv", lag: 1,
             en: "with more than 45 minutes of training", de: "mit mehr als 45 Minuten Training"),
        Rule(x: "trainingMinutes", threshold: 45, above: true, y: "restingHeartRate", lag: 1,
             en: "with more than 45 minutes of training", de: "mit mehr als 45 Minuten Training"),
    ]

    static let contexts: [(key: String, en: String, de: String)] = [
        ("work", "during working hours", "in der Arbeitszeit"),
        ("afterHours", "on workdays after hours", "an Werktagen nach Feierabend"),
        ("free", "on free days", "an freien Tagen"),
        ("sleep", "while asleep", "im Schlaf"),
    ]

    /// Days where `x` on day d and `y` on day d + lag both exist, in order.
    static func pairs(_ x: DailySeries?, _ y: DailySeries?, lag: Int, _ range: ClosedRange<Int>)
        -> (x: [Double], y: [Double], days: [Int]) {
        var result: (x: [Double], y: [Double], days: [Int]) = ([], [], [])
        guard let x, let y else { return result }
        for day in x.keys.sorted() where range.contains(day) && range.contains(day + lag) {
            guard let xValue = x[day], let yValue = y[day + lag] else { continue }
            result.x.append(xValue)
            result.y.append(yValue)
            result.days.append(day)
        }
        return result
    }

    /// Up to about 400 points, for a scatter chart.
    static func scatter(_ x: [Double], _ y: [Double]) -> [[Double]] {
        let step = max(1, x.count / 400)
        return stride(from: 0, to: x.count, by: step).map { [x[$0], y[$0]] }
    }

    // MARK: - Correlations

    struct Candidate {
        let x: String
        let y: String
        let lag: Int
        let rho: Double
        let p: Double
        let data: (x: [Double], y: [Double], days: [Int])
    }

    /// Spearman correlations for every pair of correlated series and lags 0 to 3. Lag 0 is tested once per pair. The
    /// p-values come from Fisher's z, and Benjamini–Hochberg decides which findings are reported.
    static func correlations(_ input: InsightInput, _ w: Words) -> [Insight] {
        var candidates: [Candidate] = []
        for x in correlated {
            for y in correlated where x != y {
                for lag in 0...3 where lag > 0 || x < y {
                    let data = pairs(input.series[x], input.series[y], lag: lag, input.range)
                    guard data.x.count >= minimumN else { continue }
                    let rho = Stats.spearman(data.x, data.y)
                    let clamped = min(max(rho, -0.999), 0.999)
                    let z = atanh(clamped) * (Double(data.x.count) - 3).squareRoot()
                    candidates.append(Candidate(x: x, y: y, lag: lag, rho: rho, p: Stats.twoSidedP(z), data: data))
                }
            }
        }
        let q = Stats.benjaminiHochberg(candidates.map(\.p))
        var found: [Insight] = []
        for (candidate, qValue) in zip(candidates, q) where qValue < 0.05 && abs(candidate.rho) >= 0.2 {
            let d = candidate.data
            let ci = Stats.bootstrapCI(count: d.x.count, iterations: 200) { idx in
                Stats.spearman(idx.map { d.x[$0] }, idx.map { d.y[$0] })
            }
            let xName = w.name(candidate.x), yName = w.name(candidate.y)
            let positive = candidate.rho > 0
            let lagEn = candidate.lag == 0 ? " on the same day" : w.lagPhrase(candidate.lag)
            let lagDe = candidate.lag == 0 ? " am selben Tag" : w.lagPhrase(candidate.lag)
            found.append(Insight(
                id: "correlation:\(candidate.x):\(candidate.y):\(candidate.lag)", kind: "correlation",
                title: w.pick(
                    "Higher \(xName) tends to go with \(positive ? "higher" : "lower") \(yName)\(lagEn).",
                    "Ein höherer Wert bei \(xName) geht tendenziell mit einem \(positive ? "höheren" : "niedrigeren") Wert bei \(yName) einher\(lagDe)."
                ),
                summary: w.pick(
                    "Spearman ρ = \(w.num(candidate.rho, 2)), 95% interval \(w.num(ci.low, 2)) to \(w.num(ci.high, 2)), over \(d.x.count) days. FDR-adjusted q = \(w.p(qValue)).",
                    "Spearman ρ = \(w.num(candidate.rho, 2)), 95-%-Intervall \(w.num(ci.low, 2)) bis \(w.num(ci.high, 2)), über \(d.x.count) Tage. FDR-korrigiertes q = \(w.p(qValue))."
                ),
                detail: w.pick(
                    "An association only: the two series move together. That does not show that one causes the other.",
                    "Nur ein Zusammenhang: Beide Reihen bewegen sich gemeinsam. Daraus folgt keine Ursache."
                ),
                metrics: [candidate.x, candidate.y], strength: abs(candidate.rho), confidence: 1 - qValue,
                n: d.x.count, period: period(d.days.first!, d.days.last!), lagDays: candidate.lag,
                chart: chart("scatter", [ChartSeries(name: "\(xName) / \(yName)", points: scatter(d.x, d.y))])
            ))
        }
        return found
    }

    // MARK: - Conditional comparisons

    /// Compares `y` on the days after (or the same day as) the rule holds, against the other days.
    static func conditions(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for rule in conditionRules {
            let data = pairs(input.series[rule.x], input.series[rule.y], lag: rule.lag, input.range)
            guard data.x.count >= minimumN else { continue }
            let holds = data.x.map { rule.above ? $0 > rule.threshold : $0 < rule.threshold }
            let yes = data.y.indices.filter { holds[$0] }.map { data.y[$0] }
            let no = data.y.indices.filter { !holds[$0] }.map { data.y[$0] }
            guard yes.count >= 10, no.count >= 10 else { continue }
            let test = Stats.welch(yes, no)
            let meanYes = Stats.mean(yes), meanNo = Stats.mean(no)
            guard test.p < 0.05, abs(test.d) >= 0.2, meanNo != 0 else { continue }
            let change = (meanYes / meanNo - 1) * 100
            let ci = Stats.bootstrapCI(count: data.x.count, iterations: 300) { idx in
                var sumYes = 0.0, countYes = 0.0, sumNo = 0.0, countNo = 0.0
                for i in idx {
                    if holds[i] { sumYes += data.y[i]; countYes += 1 } else { sumNo += data.y[i]; countNo += 1 }
                }
                return countYes > 0 && countNo > 0 ? sumYes / countYes - sumNo / countNo : 0
            }
            let yName = w.name(rule.y)
            let higher = change >= 0
            found.append(Insight(
                id: "condition:\(rule.x):\(rule.y):\(rule.lag)", kind: "correlation",
                title: w.pick(
                    "After days \(rule.en), \(yName) is \(w.pct(abs(change))) \(higher ? "higher" : "lower")\(w.lagPhrase(rule.lag)).",
                    "Nach Tagen \(rule.de) ist \(yName) \(w.pct(abs(change))) \(higher ? "höher" : "niedriger")\(w.lagPhrase(rule.lag))."
                ),
                summary: w.pick(
                    "\(w.quantity(meanYes, rule.y)) after those days, against \(w.quantity(meanNo, rule.y)) otherwise (\(yes.count) vs. \(no.count) days). 95% bootstrap interval of the difference: \(w.num(ci.low, 1)) to \(w.num(ci.high, 1)).",
                    "\(w.quantity(meanYes, rule.y)) nach diesen Tagen, sonst \(w.quantity(meanNo, rule.y)) (\(yes.count) gegen \(no.count) Tage). 95-%-Intervall der Differenz: \(w.num(ci.low, 1)) bis \(w.num(ci.high, 1))."
                ),
                detail: w.pick(
                    "Welch's test of the two groups, effect size d = \(w.num(test.d, 2)). An association only.",
                    "Welch-Test der beiden Gruppen, Effektstärke d = \(w.num(test.d, 2)). Nur ein Zusammenhang."
                ),
                metrics: [rule.x, rule.y], strength: min(1, abs(test.d)), confidence: 1 - test.p, n: data.x.count,
                period: period(data.days.first!, data.days.last!), lagDays: rule.lag, chart: nil
            ))
        }
        return found
    }

    // MARK: - Patterns

    /// Kruskal–Wallis H with its chi-square p-value, and the epsilon-squared effect size. Ties are not corrected.
    static func kruskalWallis(_ groups: [[Double]]) -> (h: Double, p: Double, effect: Double) {
        let all = groups.flatMap { $0 }
        let n = Double(all.count), k = Double(groups.count)
        let ranks = Stats.ranks(all)
        var start = 0
        var sum = 0.0
        for group in groups {
            let rankSum = ranks[start..<(start + group.count)].reduce(0, +)
            sum += rankSum * rankSum / Double(group.count)
            start += group.count
        }
        let h = 12 / (n * (n + 1)) * sum - 3 * (n + 1)
        return (h, Stats.chiSquareSurvival(h, df: k - 1), max(0, (h - k + 1) / (n - k)))
    }

    /// A metric that differs by weekday, such as stress: the highest and lowest weekday.
    static func weekdayPatterns(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for metric in ["stress", "restingHeartRate", "sleepMinutes", "steps"] {
            let (days, values) = observed(input.series[metric], input.range)
            var groups = Array(repeating: [Double](), count: 7)
            for (day, value) in zip(days, values) { groups[CivilDay.weekday(day)].append(value) }
            guard groups.allSatisfy({ $0.count >= 4 }) else { continue }
            let test = kruskalWallis(groups)
            guard test.p < 0.01 else { continue }
            let means = groups.map(Stats.mean)
            let high = means.indices.max { means[$0] < means[$1] }!
            let low = means.indices.min { means[$0] < means[$1] }!
            let name = w.name(metric)
            let listed = means.map { w.integer($0) }.joined(separator: ", ")
            found.append(Insight(
                id: "weekday:\(metric)", kind: "pattern",
                title: w.pick(
                    "\(capitalized(name)) is highest on \(w.weekday(high)) and lowest on \(w.weekday(low)).",
                    "\(capitalized(name)) ist am \(w.weekday(high)) am höchsten und am \(w.weekday(low)) am niedrigsten."
                ),
                summary: w.pick(
                    "Averages Monday to Sunday: \(listed). Kruskal–Wallis p \(w.p(test.p)).",
                    "Mittelwerte Montag bis Sonntag: \(listed). Kruskal-Wallis p \(w.p(test.p))."
                ),
                detail: w.pick(
                    "Kruskal–Wallis test across the seven weekdays, effect size ε² = \(w.num(test.effect, 3)).",
                    "Kruskal-Wallis-Test über die sieben Wochentage, Effektstärke ε² = \(w.num(test.effect, 3))."
                ),
                metrics: [metric], strength: min(1, test.effect / 0.2), confidence: 1 - test.p, n: values.count,
                period: period(days.first!, days.last!), lagDays: nil,
                chart: chart("bar", [ChartSeries(name: name, points: means.indices.map { [Double($0), means[$0]] })])
            ))
        }
        return found
    }

    /// Summer (June to August) against winter (December to February).
    static func seasonalPatterns(_ input: InsightInput, _ w: Words) -> [Insight] {
        var found: [Insight] = []
        for metric in ["sleepMinutes", "restingHeartRate", "hrv", "steps"] {
            let (days, values) = observed(input.series[metric], input.range)
            var summer: [Double] = [], winter: [Double] = []
            for (day, value) in zip(days, values) {
                switch CivilDay.parts(day).month {
                case 6, 7, 8: summer.append(value)
                case 12, 1, 2: winter.append(value)
                default: break
                }
            }
            guard summer.count >= minimumN, winter.count >= minimumN else { continue }
            let test = Stats.welch(summer, winter)
            guard test.p < 0.01, abs(test.d) >= 0.2 else { continue }
            let name = w.name(metric)
            let amount = w.quantity(abs(test.diff), metric, digits: 1)
            let higher = test.diff > 0
            found.append(Insight(
                id: "season:\(metric)", kind: "pattern",
                title: w.pick(
                    "Your \(name) is \(amount) \(higher ? "higher" : "lower") in summer than in winter.",
                    "Dein Wert für \(name) liegt im Sommer \(amount) \(higher ? "höher" : "niedriger") als im Winter."
                ),
                summary: w.pick(
                    "Summer (June to August) against winter (December to February): \(summer.count) and \(winter.count) days. Welch p \(w.p(test.p)).",
                    "Sommer (Juni bis August) gegen Winter (Dezember bis Februar): \(summer.count) und \(winter.count) Tage. Welch-p \(w.p(test.p))."
                ),
                detail: "",
                metrics: [metric], strength: min(1, abs(test.d)), confidence: 1 - test.p, n: values.count,
                period: period(days.first!, days.last!), lagDays: nil, chart: nil
            ))
        }
        return found
    }

    /// How much bedtime and wake-up time move from night to night.
    static func sleepRegularity(_ input: InsightInput, _ w: Words) -> [Insight] {
        let nights = input.nights
        guard nights.count >= minimumN else { return [] }
        let bedSD = Stats.standardDeviation(nights.map(\.onset))
        let wakeSD = Stats.standardDeviation(nights.map { $0.onset + $0.duration })
        let wakeDays = nights.map(\.wakeDay)
        return [Insight(
            id: "regularity:sleep", kind: "pattern",
            title: w.pick(
                "Your bedtime varies by about \(w.integer(bedSD)) min and your wake-up time by about \(w.integer(wakeSD)) min.",
                "Deine Schlafenszeit schwankt um etwa \(w.integer(bedSD)) Min., deine Aufwachzeit um etwa \(w.integer(wakeSD)) Min."
            ),
            summary: w.pick(
                "Standard deviation over \(nights.count) nights. A smaller value means a more regular rhythm.",
                "Standardabweichung über \(nights.count) Nächte. Ein kleinerer Wert bedeutet einen regelmäßigeren Rhythmus."
            ),
            detail: "",
            metrics: ["sleepMinutes"], strength: min(1, bedSD / 90), confidence: min(1, Double(nights.count) / 90),
            n: nights.count, period: period(wakeDays.min()!, wakeDays.max()!), lagDays: nil, chart: nil
        )]
    }

    /// Social jetlag: the sleep midpoint on nights that end on a free day, against nights that end on a workday.
    static func socialJetlag(_ input: InsightInput, _ w: Words) -> [Insight] {
        let work = input.nights.filter { input.workingDays.contains(CivilDay.weekday($0.wakeDay)) }
        let free = input.nights.filter { !input.workingDays.contains(CivilDay.weekday($0.wakeDay)) }
        guard work.count >= 10, free.count >= 10 else { return [] }
        let test = Stats.welch(free.map(\.midpoint), work.map(\.midpoint))
        guard abs(test.diff) >= 30, test.p < 0.05 else { return [] }
        let minutes = w.integer(abs(test.diff))
        let later = test.diff > 0
        let wakeDays = input.nights.map(\.wakeDay)
        return [Insight(
            id: "jetlag:sleep", kind: "pattern",
            title: w.pick(
                "On free days your sleep midpoint is \(minutes) min \(later ? "later" : "earlier") than on workdays.",
                "An freien Tagen liegt deine Schlafmitte \(minutes) Min. \(later ? "später" : "früher") als an Arbeitstagen."
            ),
            summary: w.pick(
                "Social jetlag over \(free.count) free-day and \(work.count) workday nights. Welch p \(w.p(test.p)).",
                "Sozialer Jetlag aus \(free.count) freien Nächten und \(work.count) Arbeitsnächten. Welch-p \(w.p(test.p))."
            ),
            detail: "",
            metrics: ["sleepMinutes"], strength: min(1, abs(test.diff) / 120), confidence: 1 - test.p,
            n: free.count + work.count, period: period(wakeDays.min()!, wakeDays.max()!), lagDays: nil, chart: nil
        )]
    }

    /// Stress averages by context: working hours, workday evenings, free days, and sleep.
    static func stressContexts(_ input: InsightInput, _ w: Words) -> [Insight] {
        var rated: [(entry: (key: String, en: String, de: String), mean: Double, days: Int)] = []
        for entry in contexts {
            let values = (input.stressByContext[entry.key] ?? [:]).filter { input.range.contains($0.key) }.map { $0.value }
            guard values.count >= 20 else { continue }
            rated.append((entry, Stats.mean(values), values.count))
        }
        guard rated.count >= 2, let high = rated.max(by: { $0.mean < $1.mean }),
              let low = rated.min(by: { $0.mean < $1.mean }), high.mean - low.mean >= 5 else { return [] }
        return [Insight(
            id: "stress:contexts", kind: "pattern",
            title: w.pick(
                "Your stress is highest \(high.entry.en) (\(w.integer(high.mean))) and lowest \(low.entry.en) (\(w.integer(low.mean))).",
                "Dein Stress ist am höchsten \(high.entry.de) (\(w.integer(high.mean))) und am niedrigsten \(low.entry.de) (\(w.integer(low.mean)))."
            ),
            summary: w.pick(
                "Averages of each day's stress readings, by time of day and week. Working hours come from your profile.",
                "Mittelwerte der Stressmesswerte jedes Tages, nach Tageszeit und Wochentag. Die Arbeitszeit steht in deinem Profil."
            ),
            detail: "",
            metrics: ["stress"], strength: min(1, (high.mean - low.mean) / 30),
            confidence: min(1, Double(rated.map { $0.days }.reduce(0, +)) / 120),
            n: rated.map { $0.days }.reduce(0, +), period: period(input.range.lowerBound, input.range.upperBound), lagDays: nil,
            chart: chart("bar", [ChartSeries(name: "stress", points: rated.indices.map { [Double($0), rated[$0].mean] })])
        )]
    }
}
