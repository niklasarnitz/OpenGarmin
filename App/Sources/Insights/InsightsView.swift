import SwiftUI
import GarminModels

/// Insights computed on the phone from the retained watch history (`HealthInsights`). Stress and body battery have
/// no HealthKit type, so they are shown here first. Every card opens the detail screen of its metric.
struct InsightsView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(WorkingHours.storageKey) private var workingHoursData = Data()

    @State private var preset: ChartRangePreset = .lastWeek
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -13, to: .now) ?? .now
    @State private var customTo = Date.now

    private var data: HealthBatch { app.watch.latest }

    /// The selected range as a whole number of days.
    private var interval: DateInterval { preset.interval(now: .now, from: customFrom, to: customTo) }

    /// The daily insights of the selected range, oldest first.
    private var trend: [DayInsight] {
        HealthInsights.days(data).filter { interval.contains($0.day) }
    }

    /// The phone keeps three months; anything before that comes from the backend.
    private var reachesPastPhoneHistory: Bool {
        interval.start < Calendar.current.date(byAdding: .day, value: -90, to: Calendar.current.startOfDay(for: .now))!
    }

    private var stressByContext: StressByContext {
        StressContexts.summarize(stress: data.stress, sleep: data.sleep, interval: interval,
                                 workingHours: WorkingHours.saved(workingHoursData))
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
                        stressContext
                        trainingStatus
                        hrvStatus
                        dailyChart(.restingHeartRate)
                        dailyChart(.sleep)
                        dailyChart(.sleepScore)
                        dailyChart(.steps)
                        sleepScoreBreakdown
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Insights")
            .refreshable { await app.watch.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchStatusPill(state: app.watch.state, battery: app.watch.battery, glass: false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Range", selection: $preset) {
                            ForEach(ChartRangePreset.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label { Text(preset.title) } icon: { Image(systemName: "calendar") }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    // MARK: - Range

    private var rangePicker: some View {
        // The preset itself is chosen in the navigation bar; this shows the custom dates and the resulting days.
        VStack(alignment: .leading, spacing: 8) {
            if preset == .custom {
                DatePicker("From", selection: $customFrom, in: ...Date.now, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: ...Date.now, displayedComponents: .date)
            }
            Text(interval.start.formatted(date: .abbreviated, time: .omitted) + " – "
                 + interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if reachesPastPhoneHistory {
                Text("The phone keeps the last three months. Older data comes from your backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cards

    /// A card that opens the detail screen of its metric.
    private func card<Content: View>(_ metric: InsightMetric, @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            InsightDetailView(metric: metric, interval: interval)
        } label: {
            MetricTile(metric.title, symbol: metric.symbol, tint: metric.tint, content: content)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stress and body battery

    private var stressAndBattery: some View {
        VStack(spacing: 16) {
            card(.stress) {
                MetricFigure(value: data.stress.latest.map { Formatting.whole($0) } ?? "–", unit: "/ 100")
                SeriesChart(points: data.stress.filter { interval.contains($0.date) }, tint: Palette.amber, label: "Stress", height: 130, zeroMeansNoData: true, domain: interval)
            }
            card(.bodyBattery) {
                MetricFigure(value: data.bodyBattery.latest.map { Formatting.whole($0) } ?? "–", unit: "/ 100")
                SeriesChart(points: data.bodyBattery.filter { interval.contains($0.date) }, tint: Palette.lichen, label: "Body battery", height: 130, zeroMeansNoData: true, domain: interval)
            }
        }
    }

    private var stressContext: some View {
        NavigationLink {
            StressContextView(interval: interval)
        } label: {
            MetricTile("Stress by context", symbol: "square.grid.2x2.fill", tint: Palette.amber) {
                StressContextGrid(summary: stressByContext)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Training and HRV

    private var trainingStatus: some View {
        let load = HealthInsights.trainingLoad(data, now: .now)
        return card(.trainingStatus) {
            MetricFigure(value: load.status.title, size: 30)
            HStack(alignment: .top, spacing: 12) {
                InsightStat(title: "Acute, 7 days", value: Formatting.whole(load.acuteLoad))
                InsightStat(title: "Chronic, weekly", value: Formatting.whole(load.chronicLoad))
                InsightStat(title: "Ratio", value: load.ratio.map { String(format: "%.2f", $0) } ?? "–")
            }
        }
    }

    private var hrvStatus: some View {
        card(.hrvStatus) {
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

    // MARK: - Daily trends

    private func dailyChart(_ metric: InsightMetric) -> some View {
        let points = trend.compactMap { day in metric.dailyValue(day).map { PointSample(date: day.day, value: $0) } }
        return card(metric) {
            MetricFigure(value: points.latest.map(metric.formatted) ?? "–", unit: metric.unit, size: 34)
            DailyValueChart(points: points, interval: interval, tint: metric.tint)
        }
    }

    // MARK: - Sleep score

    private var sleepScoreBreakdown: some View {
        let session = data.sleep.max { $0.end < $1.end }
        return card(.sleepScore) {
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
