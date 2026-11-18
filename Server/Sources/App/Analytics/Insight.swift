import Foundation
import Vapor

/// One finding from GET /api/v1/insights. Titles and texts are full sentences in the requested language. They describe
/// associations and changes over time; they never claim causation.
struct Insight: Codable, Content, Sendable {
    let id: String
    let kind: String
    let title: String
    let summary: String
    let detail: String
    let metrics: [String]
    let strength: Double
    let confidence: Double
    let n: Int
    let period: Period
    /// The lag in days (0 to 3) of a correlation finding. Nil for every other kind.
    let lagDays: Int?
    let chart: InsightChart?
}

struct Period: Codable, Sendable {
    let from: String
    let to: String
}

struct InsightChart: Codable, Sendable {
    let type: String
    let series: [ChartSeries]
}

struct ChartSeries: Codable, Sendable {
    let name: String
    let points: [[Double]]
}

/// An inclusive range of day indexes.
struct DayRange {
    let first: Int
    let last: Int

    var period: Period {
        Period(from: CivilDay.string(first), to: CivilDay.string(last))
    }
}

/// Clamps to 0…1. NaN becomes 0; infinity becomes 1.
func clamp01(_ value: Double) -> Double {
    value.isNaN ? 0 : min(1, max(0, value))
}

func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}
