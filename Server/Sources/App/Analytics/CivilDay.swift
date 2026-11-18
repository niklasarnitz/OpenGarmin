import Foundation

/// One value per local day, keyed by day index (see `CivilDay`).
typealias DailySeries = [Int: Double]

/// Days as integers since 1970-01-01, so day arithmetic is plain integer math. Howard Hinnant's civil-date algorithms.
enum CivilDay {
    static func index(year y0: Int, month m: Int, day d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func parts(_ index: Int) -> (year: Int, month: Int, day: Int) {
        let z = index + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// `YYYY-MM-DD`.
    static func string(_ index: Int) -> String {
        let p = parts(index)
        return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
    }

    static func parse(_ text: String) -> Int? {
        let numbers = text.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
        return index(year: numbers[0], month: numbers[1], day: numbers[2])
    }

    /// Monday = 0 … Sunday = 6. 1970-01-01 was a Thursday.
    static func weekday(_ index: Int) -> Int {
        ((index + 3) % 7 + 7) % 7
    }
}
