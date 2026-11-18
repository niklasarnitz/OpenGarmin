import FluentSQL
import Foundation

/// Monthly partitions of the time-series tables, created when data first lands in a month. Must run inside
/// `Ingest.lock`, so two uploads never create the same partition at once.
enum Partitions {
    static func ensure(_ sql: any SQLDatabase, parent: String, covering dates: some Sequence<Date>) async throws {
        guard let span = dates.dateSpan() else { return }
        var month = startOfMonth(span.lowerBound)
        while month <= span.upperBound {
            let next = utc.date(byAdding: .month, value: 1, to: month)!
            let name = "\(parent)_\(monthFormat.string(from: month))"
            // Partition bounds must be constant, so they are written into the statement, not bound.
            try await sql.raw(SQLQueryString(
                "CREATE TABLE IF NOT EXISTS \(name) PARTITION OF \(parent) FOR VALUES FROM ('\(bound(month))') TO ('\(bound(next))')"
            )).run()
            month = next
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let monthFormat: DateFormatter = formatter("yyyy_MM")
    private static let boundFormat: DateFormatter = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static func startOfMonth(_ date: Date) -> Date {
        utc.dateInterval(of: .month, for: date)!.start
    }

    private static func bound(_ date: Date) -> String {
        boundFormat.string(from: date)
    }
}

extension Sequence where Element == Date {
    /// The earliest and latest date, or nil when the sequence is empty.
    func dateSpan() -> ClosedRange<Date>? {
        var result: ClosedRange<Date>?
        for date in self {
            if let range = result {
                result = Swift.min(range.lowerBound, date)...Swift.max(range.upperBound, date)
            } else {
                result = date...date
            }
        }
        return result
    }
}
