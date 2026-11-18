import Foundation

/// Statistics for the insight engine. Pure functions over arrays; nothing here touches the database.
enum Stats {
    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Median absolute deviation around `center`, scaled by 1.4826 to estimate a standard deviation for normal data.
    static func scaledMAD(_ values: [Double], center: Double) -> Double {
        1.4826 * median(values.map { abs($0 - center) })
    }

    /// Average ranks; tied values share the mean of their ranks.
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = Array(repeating: 0.0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count, values[order[end + 1]] == values[order[start]] { end += 1 }
            let rank = Double(start + end) / 2 + 1
            for k in start...end { result[order[k]] = rank }
            start = end + 1
        }
        return result
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }

    static func spearman(_ x: [Double], _ y: [Double]) -> Double {
        pearson(ranks(x), ranks(y))
    }

    static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        return values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        variance(values).squareRoot()
    }

    /// Welch's two-sample test of `a` against `b`: the difference of means, the two-sided p-value of its normal
    /// approximation, and Cohen's d with the pooled standard deviation.
    static func welch(_ a: [Double], _ b: [Double]) -> (diff: Double, p: Double, d: Double) {
        let va = variance(a), vb = variance(b)
        let na = Double(a.count), nb = Double(b.count)
        let diff = mean(a) - mean(b)
        let se = (va / na + vb / nb).squareRoot()
        let p = se > 0 ? twoSidedP(diff / se) : 1
        let pooled = ((na - 1) * va + (nb - 1) * vb) / (na + nb - 2)
        let d = pooled > 0 ? diff / pooled.squareRoot() : 0
        return (diff, p, d)
    }

    /// Upper tail of a chi-square distribution, by the Wilson–Hilferty cube-root approximation.
    static func chiSquareSurvival(_ x: Double, df k: Double) -> Double {
        guard x > 0 else { return 1 }
        let z = (pow(x / k, 1.0 / 3.0) - (1 - 2 / (9 * k))) / (2 / (9 * k)).squareRoot()
        return 0.5 * erfc(z / 2.0.squareRoot())
    }

    /// Two-sided p-value of a standard normal statistic.
    static func twoSidedP(_ z: Double) -> Double {
        erfc(abs(z) / 2.0.squareRoot())
    }

    /// Mann–Kendall trend test with the tie correction. Returns Kendall's tau (−1…1) and the two-sided p-value.
    static func mannKendall(_ y: [Double]) -> (tau: Double, p: Double) {
        let n = y.count
        guard n >= 3 else { return (0, 1) }
        var s = 0.0
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                if y[j] > y[i] { s += 1 } else if y[j] < y[i] { s -= 1 }
            }
        }
        var counts: [Double: Int] = [:]
        for value in y { counts[value, default: 0] += 1 }
        var tieTerm = 0.0
        for count in counts.values where count > 1 {
            let t = Double(count)
            tieTerm += t * (t - 1) * (2 * t + 5)
        }
        let nd = Double(n)
        let variance = (nd * (nd - 1) * (2 * nd + 5) - tieTerm) / 18
        let z: Double
        if s > 0 {
            z = (s - 1) / variance.squareRoot()
        } else if s < 0 {
            z = (s + 1) / variance.squareRoot()
        } else {
            z = 0
        }
        return (s / (nd * (nd - 1) / 2), twoSidedP(z))
    }

    /// Theil–Sen estimator: the median of all pairwise slopes. Robust to outliers. Long series are thinned so the
    /// number of pairs stays bounded.
    static func theilSenSlope(x: [Double], y: [Double]) -> Double {
        let step = max(1, x.count / 1_500)
        let idx = Array(stride(from: 0, to: x.count, by: step))
        var slopes: [Double] = []
        for a in idx.indices {
            for b in (a + 1)..<idx.count {
                let i = idx[a], j = idx[b]
                if x[j] != x[i] { slopes.append((y[j] - y[i]) / (x[j] - x[i])) }
            }
        }
        return median(slopes)
    }

    /// Benjamini–Hochberg adjusted p-values (q-values), in the input order.
    static func benjaminiHochberg(_ p: [Double]) -> [Double] {
        let m = Double(p.count)
        let descending = p.indices.sorted { p[$0] > p[$1] }
        var q = Array(repeating: 1.0, count: p.count)
        var running = 1.0
        for (k, i) in descending.enumerated() {
            let rank = m - Double(k)
            running = min(running, p[i] * m / rank)
            q[i] = running
        }
        return q
    }

    /// Percentile bootstrap interval of a statistic over resampled indices 0..<n. Deterministic for a given seed.
    static func bootstrapCI(count n: Int, iterations: Int = 500, seed: UInt64 = 7,
                            statistic: ([Int]) -> Double) -> (low: Double, high: Double) {
        var rng = SplitMix(seed: seed)
        var values = (0..<iterations).map { _ in
            statistic((0..<n).map { _ in rng.index(n) })
        }
        values.sort()
        let last = Double(iterations - 1)
        return (values[Int((0.025 * last).rounded())], values[Int((0.975 * last).rounded())])
    }

    struct Split {
        let index: Int
        let f: Double
    }

    /// Mean-shift changepoints by binary segmentation. Each split maximises the drop in squared error and is kept when
    /// its F statistic reaches `threshold`; segments are at least `minSegment` points and the search goes `depth` deep.
    static func changepoints(_ y: [Double], minSegment: Int = 14, threshold: Double = 25, depth: Int = 2) -> [Split] {
        var found: [Split] = []
        func search(_ lo: Int, _ hi: Int, _ level: Int) {
            guard level < depth, hi - lo >= 2 * minSegment else { return }
            let n = hi - lo
            var sums = [0.0], squares = [0.0]
            for value in y[lo..<hi] {
                sums.append(sums[sums.count - 1] + value)
                squares.append(squares[squares.count - 1] + value * value)
            }
            func sse(_ a: Int, _ b: Int) -> Double {
                let s = sums[b] - sums[a], q = squares[b] - squares[a]
                return q - s * s / Double(b - a)
            }
            let total = sse(0, n)
            var best: (index: Int, f: Double)?
            for k in minSegment...(n - minSegment) {
                let rss = sse(0, k) + sse(k, n)
                let reduction = total - rss
                let variance = rss / Double(n - 2)
                let f = variance > 1e-12 ? reduction / variance : (reduction > 1e-9 ? Double.infinity : 0)
                if best == nil || f > best!.f { best = (k, f) }
            }
            guard let winner = best, winner.f >= threshold else { return }
            let split = lo + winner.index
            found.append(Split(index: split, f: winner.f))
            search(lo, split, level + 1)
            search(split, hi, level + 1)
        }
        search(0, y.count, 0)
        return found
    }
}

/// SplitMix64: a small deterministic generator, so bootstrap intervals and tests are reproducible.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func index(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
