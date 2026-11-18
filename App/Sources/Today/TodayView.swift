import SwiftUI
import GarminModels

struct TodayView: View {
    @Environment(AppEnvironment.self) private var app

    private var data: HealthBatch { app.watch.latest }

    // The watch history covers 30 days, so the day's totals only count today's samples.
    private var steps: Double { data.steps.filter { Calendar.current.isDateInToday($0.start) }.reduce(0) { $0 + $1.value } }
    private var sleep: SleepSession? { data.sleep.max { $0.end < $1.end } }
    private var heartRateNow: Int? { data.heartRate.max { $0.date < $1.date }?.bpm }

    var body: some View {
        NavigationStack {
            ScrollView {
                SyncProgressView(state: app.watch.state, file: app.watch.fileProgress)
                    .padding(.horizontal)
                if data.isEmpty {
                    EmptyDataCard(title: "No data yet", symbol: "heart.text.square",
                                  message: "Sync your watch to see heart rate, sleep and activity here.")
                } else {
                    VStack(spacing: 16) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        hero
                        heartRate
                        grid
                        stress
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Today")
            .refreshable { await app.watch.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchStatusPill(state: app.watch.state, battery: app.watch.battery)
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 12) {
            ring(title: "Steps", symbol: "figure.walk", value: Formatting.whole(steps),
                 caption: "of 10,000", progress: steps / 10_000, tint: Palette.blaze)
            ring(title: "Body battery", symbol: "battery.75percent",
                 value: data.bodyBattery.latest.map(Formatting.whole) ?? "–",
                 caption: "of 100", progress: (data.bodyBattery.latest ?? 0) / 100, tint: Palette.lichen)
        }
        .frame(height: 230)
    }

    private func ring(title: String, symbol: String, value: String, caption: String,
                      progress: Double, tint: Color) -> some View {
        MetricTile(title, symbol: symbol, tint: tint) {
            ZStack {
                RingGauge(progress: progress, tint: tint, lineWidth: 14)
                VStack(spacing: 0) {
                    Text(value)
                        .font(.figure(30))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
        }
    }

    private var heartRate: some View {
        MetricTile("Heart rate", symbol: "heart.fill", tint: Palette.ember) {
            MetricFigure(value: heartRateNow.map(String.init) ?? "–", unit: "bpm")
            SeriesChart(points: data.heartRate.map { PointSample(date: $0.date, value: Double($0.bpm)) },
                        tint: Palette.ember, label: "Heart rate", height: 150)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            if let sleep {
                NavigationLink {
                    SleepDetailView(session: sleep)
                } label: {
                    cell("Sleep", symbol: "bed.double.fill", tint: Palette.dusk,
                         value: Formatting.duration(sleep.end.timeIntervalSince(sleep.start)),
                         caption: sleep.score.map { "Score \($0)" } ?? "Last night")
                }
                .buttonStyle(.plain)
            }
            cell("Energy", symbol: "flame.fill", tint: Palette.blaze,
                 value: Formatting.whole(data.activeEnergyKcal.filter { Calendar.current.isDateInToday($0.start) }.reduce(0) { $0 + $1.value }),
                 caption: "Active kcal")
            cell("SpO2", symbol: "lungs.fill", tint: Palette.glacier,
                 value: data.spo2.latest.map { "\(Int($0 * 100))%" } ?? "–", caption: "Blood oxygen")
            cell("HRV", symbol: "waveform.path.ecg", tint: Palette.lichen,
                 value: data.hrv.latest.map { "\(Int($0)) ms" } ?? "–", caption: "Overnight average")
            cell("Respiration", symbol: "wind", tint: Palette.amber,
                 value: data.respirationRate.latest.map { String(format: "%.1f", $0) } ?? "–",
                 caption: "Breaths per minute")
            cell("Resting HR", symbol: "heart", tint: Palette.ember,
                 value: data.restingHeartRate.latest.map { "\(Int($0))" } ?? "–", caption: "bpm")
        }
    }

    private func cell(_ title: String, symbol: String, tint: Color, value: String, caption: String) -> some View {
        MetricTile(title, symbol: symbol, tint: tint) {
            MetricFigure(value: value, size: 34)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stress: some View {
        MetricTile("Stress", symbol: "bolt.heart.fill", tint: Palette.amber) {
            SeriesChart(points: data.stress, tint: Palette.amber, label: "Stress", height: 120)
        }
    }
}

extension Array where Element == PointSample {
    var latest: Double? { self.max(by: { $0.date < $1.date })?.value }
}
