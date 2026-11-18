import SwiftUI
import GarminModels

extension InsightMetric {
    var title: LocalizedStringKey {
        switch self {
        case .stress: "Stress"
        case .bodyBattery: "Body battery"
        case .trainingStatus: "Training status"
        case .hrvStatus: "HRV status"
        case .restingHeartRate: "Resting heart rate"
        case .sleep: "Sleep"
        case .sleepScore: "Sleep score"
        case .steps: "Steps"
        }
    }

    var symbol: String {
        switch self {
        case .stress: "bolt.heart.fill"
        case .bodyBattery: "battery.75percent"
        case .trainingStatus: "figure.run"
        case .hrvStatus: "waveform.path.ecg"
        case .restingHeartRate: "heart"
        case .sleep: "bed.double.fill"
        case .sleepScore: "moon.stars.fill"
        case .steps: "figure.walk"
        }
    }

    var tint: Color {
        switch self {
        case .stress, .sleepScore: Palette.amber
        case .bodyBattery, .hrvStatus: Palette.lichen
        case .trainingStatus, .steps: Palette.blaze
        case .restingHeartRate: Palette.ember
        case .sleep: Palette.dusk
        }
    }

    var unit: String {
        switch self {
        case .stress, .bodyBattery, .sleepScore: "/ 100"
        case .restingHeartRate: "bpm"
        case .sleep: "h"
        case .hrvStatus: "ms"
        case .trainingStatus, .steps: ""
        }
    }

    /// Sleep in hours with one decimal, everything else as whole numbers.
    func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(self == .sleep ? 1 : 0)))
    }

    var about: LocalizedStringKey {
        switch self {
        case .stress: "Garmin estimates stress from your heart rate variability and heart rate during the day. 0 to 25 is rest, 26 to 50 low, 51 to 75 medium and 76 to 100 high. A reading of 0 means the watch could not measure."
        case .bodyBattery: "Body Battery is a 0 to 100 estimate of your energy. It is built from heart rate variability, stress and sleep. It charges while you rest and sleep, and drains with activity and stress."
        case .trainingStatus: "Training status compares the load of the last seven days with your average over four weeks. The load of each activity comes from its duration and training effect, or from its heart rate."
        case .hrvStatus: "Heart rate variability (HRV) is the variation in time between heartbeats, measured overnight. Garmin compares your last seven nights with your own balanced range."
        case .restingHeartRate: "Your heart rate at complete rest, usually measured in the early morning. A lower value than usual often means good recovery and fitness. A sustained rise can mean stress, poor sleep or illness."
        case .sleep: "The time you spent asleep in the sleep sessions the watch recorded."
        case .sleepScore: "Garmin's 0 to 100 sleep score combines the duration, quality, recovery and interruptions of the night."
        case .steps: "The steps the watch counted during each day."
        }
    }
}

extension InsightSuggestion {
    var text: LocalizedStringKey {
        switch self {
        case .keepTracking: "Wear the watch for a few more days so a personal baseline can form."
        case .keepUp: "This is better than your usual. Keep doing what you are doing."
        case .protectSleep: "Try an earlier bedtime or a calmer evening. Sleep is the easiest lever for recovery."
        case .easierTraining: "Plan one or two lighter days. Your recent load is high compared with your usual."
        case .steadyTraining: "Your load is below your usual. Build back gradually rather than all at once."
        case .moveMore: "Your steps were low this week. A short walk each day adds up."
        case .breathe: "Short breaks, a walk or some slow breathing can bring stress down during the day."
        case .consultDoctor: "If this stays clearly off for several weeks, or you feel unwell, talk to a doctor. This is not a diagnosis."
        }
    }
}

extension InsightFactor {
    var title: LocalizedStringKey {
        switch self {
        case .shortSleep: "Short sleep last night"
        case .recentTraining: "Heavy training this week"
        case .lowMovement: "Few steps this week"
        case .highStress: "Higher stress this week"
        }
    }
}

/// A figure with its caption, for the comparison rows.
struct InsightStat: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.figure(20, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Insights metric in plain language: what it is, where the latest value sits against the user's own history,
/// what moves it, the trend and the day-by-day values. The sentences follow from `InsightExplanations`.
struct InsightDetailView: View {
    @Environment(AppEnvironment.self) private var app
    let metric: InsightMetric
    let interval: DateInterval

    private var data: HealthBatch { app.watch.latest }

    private var explanation: InsightExplanation {
        InsightExplanations.explain(metric, days: HealthInsights.days(data), batch: data, now: .now)
    }

    private var points: [PointSample] {
        HealthInsights.days(data).filter { interval.contains($0.day) }
            .compactMap { day in metric.dailyValue(day).map { PointSample(date: day.day, value: $0) } }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                current
                comparison
                if !explanation.drivers.isEmpty { drivers }
                suggestions
                MetricTile("Trend", symbol: "chart.xyaxis.line", tint: metric.tint) {
                    DailyValueChart(points: points, interval: interval, tint: metric.tint, height: 220)
                }
                dayByDay
                about
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Current value

    private var current: some View {
        MetricTile(metric.title, symbol: metric.symbol, tint: metric.tint) {
            figure
            Text(headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var figure: some View {
        switch metric {
        case .trainingStatus:
            MetricFigure(value: explanation.training?.status.title ?? "–", size: 30)
        case .hrvStatus:
            MetricFigure(value: explanation.hrv?.status.title ?? "–", size: 30)
        default:
            MetricFigure(value: explanation.baseline.latest.map(metric.formatted) ?? "–", unit: metric.unit)
        }
    }

    private var headline: LocalizedStringKey {
        switch explanation.outlook {
        case .better?: "Better than your usual."
        case .steady?: "In line with your usual."
        case .worse?: "Worse than your usual."
        case nil: "Not enough data yet to compare with your usual."
        }
    }

    // MARK: - Comparison

    private var comparison: some View {
        MetricTile("Compared with your usual", symbol: "scale.3d", tint: metric.tint) {
            switch metric {
            case .trainingStatus:
                if let training = explanation.training {
                    HStack(alignment: .top, spacing: 12) {
                        InsightStat(title: "Acute, 7 days", value: Formatting.whole(training.acuteLoad))
                        InsightStat(title: "Chronic, weekly", value: Formatting.whole(training.chronicLoad))
                        InsightStat(title: "Ratio", value: training.ratio.map { String(format: "%.2f", $0) } ?? "–")
                    }
                }
            case .hrvStatus:
                if let hrv = explanation.hrv {
                    HStack(alignment: .top, spacing: 12) {
                        InsightStat(title: "7-day average", value: "\(Int(hrv.sevenDayAverage.rounded())) ms")
                        InsightStat(title: "Balanced range", value: hrv.balancedRange.map {
                            "\(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded()))"
                        } ?? "–")
                    }
                }
            default:
                baselineComparison
            }
        }
    }

    @ViewBuilder
    private var baselineComparison: some View {
        if explanation.baseline.days < InsightExplanations.minimumBaselineDays {
            Text("Garmin needs \(InsightExplanations.minimumBaselineDays) days of data to tell what is usual for you. So far there are \(explanation.baseline.days).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 12) {
                InsightStat(title: "7-day average", value: explanation.baseline.sevenDayAverage.map(metric.formatted) ?? "–")
                InsightStat(title: "30-day average", value: explanation.baseline.thirtyDayAverage.map(metric.formatted) ?? "–")
                InsightStat(title: "Usual range", value: usualRange)
            }
            Text(trendSentence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(positionSentence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// The 30-day average plus or minus one standard deviation.
    private var usualRange: String {
        guard let average = explanation.baseline.thirtyDayAverage,
              let deviation = explanation.baseline.thirtyDayDeviation else { return "–" }
        return "\(metric.formatted(max(average - deviation, 0)))–\(metric.formatted(average + deviation))"
    }

    private var trendSentence: LocalizedStringKey {
        switch explanation.trend {
        case .higher?: "Your 7-day average is higher than your 30-day average."
        case .lower?: "Your 7-day average is lower than your 30-day average."
        case .similar?, nil: "Your 7-day average is close to your 30-day average."
        }
    }

    private var positionSentence: LocalizedStringKey {
        switch explanation.position {
        case .above?: "The latest value is above your usual range."
        case .below?: "The latest value is below your usual range."
        case .within?, nil: "The latest value is within your usual range."
        }
    }

    // MARK: - Drivers and suggestions

    private var drivers: some View {
        MetricTile("What moves it", symbol: "arrow.up.arrow.down", tint: metric.tint) {
            ForEach(explanation.drivers, id: \.factor) { driver in
                HStack {
                    Text(driver.factor.title)
                    Spacer()
                    Text(driver.effect == .raises ? "Raises" : "Lowers")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var suggestions: some View {
        MetricTile("Suggestions", symbol: "lightbulb.fill", tint: Palette.glacier) {
            ForEach(explanation.suggestions, id: \.self) { suggestion in
                Label(suggestion.text, systemImage: "checkmark.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            Text("These are general ideas, not medical advice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Day by day and about

    private var dayByDay: some View {
        MetricTile("Day by day", symbol: "calendar", tint: .secondary) {
            if points.isEmpty {
                Text("No values in this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(points.reversed(), id: \.date) { point in
                    LabeledContent(point.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                                   value: metric.formatted(point.value))
                }
            }
        }
    }

    private var about: some View {
        MetricTile("About this metric", symbol: "info.circle.fill", tint: .secondary) {
            Text(metric.about)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
