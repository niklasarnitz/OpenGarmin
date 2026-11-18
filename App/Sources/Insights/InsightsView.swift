import SwiftUI
import Charts
import GarminModels

/// Insights computed on the phone from the retained watch history (`HealthInsights`). Stress and body battery have
/// no HealthKit type, so they are shown here first.
struct InsightsView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var preset: ChartRangePreset = .lastWeek
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -13, to: .now) ?? .now
    @State private var customTo = Date.now

    private var data: HealthBatch { app.watch.latest }

    /// The selected range in whole days.
    private var interval: DateInterval { preset.interval(now: .now, from: customFrom, to: customTo) }

    private var rangeDays: Int { Int((interval.duration / 86_400).rounded()) }

    /// The daily insights of the selected range, oldest first.
    private var trend: [DayInsight] {
        HealthInsights.days(data).filter { interval.contains($0.day) }
    }

    /// The phone keeps three months; anything before that comes from the backend.
    private var reachesPastPhoneHistory: Bool {
        interval.start < Calendar.current.date(byAdding: .day, value: -90, to: Calendar.current.startOfDay(for: .now))!
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if data.isEmpty {
                    EmptyDataCard(title: "No insights yet", symbol: "chart.xyaxis.line",
                                  message: "Sync your watch to see training, recovery and trends here.")
                } else {
                    VStack(spacing: 16) {
                        rangePicker
                        stressAndBattery
                        trainingStatus
                        hrvStatus
                        dailyChart("Resting heart rate", symbol: "heart", tint: Palette.ember, unit: "bpm") { $0.restingHeartRate }
                        dailyChart("Sleep", symbol: "bed.double.fill", tint: Palette.dusk, unit: "h") { $0.sleepMinutes.map { $0 / 60 } }
                        dailyChart("Sleep score", symbol: "star.fill", tint: Palette.amber, unit: "") { $0.sleepScore.map { Double($0) } }
                        dailyChart("Steps", symbol: "figure.walk", tint: Palette.blaze, unit: "") { $0.steps }
                        sleepScoreBreakdown
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Insights")
            .refreshable { await app.watch.syncNow() }
        }
    }

    // MARK: - Range

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $preset) {
                ForEach(ChartRangePreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if preset == .custom {
                DatePicker("From", selection: $customFrom, in: ...Date.now, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: ...Date.now, displayedComponents: .date)
            }
            Text(interval.start.formatted(date: .abbreviated, time: .omitted) + " – "
                 + interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            if reachesPastPhoneHistory {
                Text("The phone keeps the last three months. Older data comes from your backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stress and body battery

    private var stressAndBattery: some View {
        VStack(spacing: 16) {
            MetricTile("Stress", symbol: "bolt.heart.fill", tint: Palette.amber) {
                MetricFigure(value: data.stress.latest.map { Formatting.whole($0) } ?? "–", unit: "/ 100")
                SeriesChart(points: data.stress.filter { interval.contains($0.date) }, tint: Palette.amber, label: "Stress", height: 130, zeroMeansNoData: true)
            }
            MetricTile("Body battery", symbol: "battery.75percent", tint: Palette.lichen) {
                MetricFigure(value: data.bodyBattery.latest.map { Formatting.whole($0) } ?? "–", unit: "/ 100")
                SeriesChart(points: data.bodyBattery.filter { interval.contains($0.date) }, tint: Palette.lichen, label: "Body battery", height: 130, zeroMeansNoData: true)
            }
        }
    }

    // MARK: - Training and HRV

    private var trainingStatus: some View {
        let load = HealthInsights.trainingLoad(data, now: .now)
        return MetricTile("Training status", symbol: "figure.run", tint: Palette.blaze) {
            MetricFigure(value: load.status.title, size: 30)
            HStack(alignment: .top, spacing: 12) {
                stat("Acute, 7 days", Formatting.whole(load.acuteLoad))
                stat("Chronic, weekly", Formatting.whole(load.chronicLoad))
                stat("Ratio", load.ratio.map { String(format: "%.2f", $0) } ?? "–")
            }
        }
    }

    private var hrvStatus: some View {
        MetricTile("HRV status", symbol: "waveform.path.ecg", tint: Palette.lichen) {
            if let hrv = HealthInsights.hrvStatus(data, now: .now) {
                MetricFigure(value: hrv.status.title, size: 30)
                Text(hrvCaption(hrv))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No HRV in the last seven days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hrvCaption(_ hrv: HRVStatusAssessment) -> String {
        let average = "7-day average \(Int(hrv.sevenDayAverage.rounded())) ms"
        guard let range = hrv.balancedRange else { return average }
        return "\(average), balanced \(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) ms"
    }

    // MARK: - Trends

    private func dailyChart(_ title: String, symbol: String, tint: Color, unit: String,
                            value: @escaping (DayInsight) -> Double?) -> some View {
        let points = trend.compactMap { day in value(day).flatMap { $0 > 0 ? PointSample(date: day.day, value: $0) : nil } }
        // Days of the range without a value (or with 0, Garmin's "not measured") are greyed.
        let calendar = Calendar.current
        let measured = Set(points.map { calendar.startOfDay(for: $0.date) })
        let missing = rangeDays <= 62
            ? stride(from: 0, to: rangeDays, by: 1).compactMap { offset -> Date? in
                let day = calendar.date(byAdding: .day, value: offset, to: interval.start)!
                return day <= .now && !measured.contains(day) ? day : nil
            }
            : []
        return MetricTile(LocalizedStringKey(title), symbol: symbol, tint: tint) {
            MetricFigure(value: points.latest.map { Formatting.whole($0) } ?? "–", unit: unit, size: 34)
            Chart {
                // Up to two months each day is a bar; longer ranges draw the 7-day mean as a line.
                ForEach(missing, id: \.self) { day in
                    RectangleMark(x: .value("Day", day, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.14))
                }
                if rangeDays <= 62 {
                    ForEach(points, id: \.date) { point in
                        BarMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                            .foregroundStyle(tint.gradient)
                            .cornerRadius(4)
                    }
                } else {
                    ForEach(ChartSmoothing.rollingMean(points, days: 7), id: \.date) { point in
                        LineMark(x: .value("Day", point.date), y: .value(title, point.value))
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                switch rangeDays {
                case ...8:
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.caption2)
                    }
                case ...62:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2)
                    }
                default:
                    AxisMarks(values: .stride(by: .month, count: rangeDays > 200 ? 2 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.caption2)
                    }
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Sleep score

    private var sleepScoreBreakdown: some View {
        let session = data.sleep.max { $0.end < $1.end }
        return MetricTile("Sleep score", symbol: "moon.stars.fill", tint: Palette.dusk) {
            if let session {
                MetricFigure(value: session.score.map(String.init) ?? "–", unit: "/ 100", size: 34)
                if let breakdown = session.scoreBreakdown {
                    let rows = breakdownRows(breakdown)
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text("\(row.score)")
                                    .font(.figure(16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(row.score), total: 100)
                                .tint(Palette.dusk)
                        }
                    }
                } else {
                    Text("The watch did not send the score components for this night.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No sleep recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func breakdownRows(_ breakdown: SleepScoreBreakdown) -> [(name: String, score: Int)] {
        let all: [(String, Int?)] = [
            ("Duration", breakdown.duration), ("Quality", breakdown.quality), ("Recovery", breakdown.recovery),
            ("Deep", breakdown.deep), ("Light", breakdown.light), ("REM", breakdown.rem),
            ("Awake time", breakdown.awakeTime), ("Interruptions", breakdown.interruptions),
            ("Restlessness", breakdown.restlessness),
        ]
        return all.compactMap { name, score in score.map { (name: name, score: $0) } }
    }

    private func stat(_ title: String, _ value: String) -> some View {
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

extension ChartRangePreset {
    var title: LocalizedStringKey {
        switch self {
        case .lastWeek: "Last week"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .thisYear: "This year"
        case .custom: "Custom range"
        }
    }
}

extension TrainingStatus {
    var title: String {
        switch self {
        case .noBaseline: "Building baseline"
        case .detraining: "Detraining"
        case .optimal: "Productive"
        case .overreaching: "Overreaching"
        case .highRisk: "High risk"
        }
    }
}

extension HRVStatus {
    var title: String {
        switch self {
        case .none: "No status"
        case .poor: "Poor"
        case .low: "Low"
        case .unbalanced: "Unbalanced"
        case .balanced: "Balanced"
        }
    }
}
