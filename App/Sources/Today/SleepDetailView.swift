import SwiftUI
import Charts
import GarminModels

extension SleepStage {
    /// Vertical position in the hypnogram: awake on top, deep at the bottom.
    var level: Double {
        switch self {
        case .awake: 3
        case .rem: 2
        case .light, .unmeasurable: 1
        case .deep: 0
        }
    }

    var title: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .light: "Light"
        case .deep: "Deep"
        case .unmeasurable: "Unmeasured"
        }
    }

    var tint: Color {
        switch self {
        case .awake: Palette.amber
        case .rem: Palette.ember
        case .light: Palette.glacier
        case .deep: Palette.dusk
        case .unmeasurable: .secondary
        }
    }
}

struct SleepDetailView: View {
    let session: SleepSession

    private func seconds(_ stage: SleepStage) -> TimeInterval {
        session.intervals.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private var asleep: TimeInterval {
        session.end.timeIntervalSince(session.start) - seconds(.awake)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    MetricTile("Asleep", symbol: "moon.zzz.fill", tint: Palette.dusk) {
                        MetricFigure(value: Formatting.duration(asleep), size: 36)
                    }
                    MetricTile("Score", symbol: "star.fill", tint: Palette.amber) {
                        MetricFigure(value: session.score.map(String.init) ?? "–", size: 36)
                    }
                }
                .frame(height: 150)

                MetricTile("Hypnogram", symbol: "chart.bar.xaxis", tint: Palette.dusk) {
                    Chart(session.intervals, id: \.start) { interval in
                        RectangleMark(
                            xStart: .value("Start", interval.start),
                            xEnd: .value("End", interval.end),
                            yStart: .value("Stage", interval.stage.level - 0.4),
                            yEnd: .value("Stage", interval.stage.level + 0.4))
                        .foregroundStyle(interval.stage.tint)
                        .cornerRadius(3)
                    }
                    .chartYScale(domain: -0.6...3.6)
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .frame(height: 220)
                }

                MetricTile("Stages", symbol: "square.stack.3d.up.fill", tint: Palette.glacier) {
                    ForEach(SleepStage.allCases.filter { $0 != .unmeasurable }, id: \.self) { stage in
                        HStack {
                            Circle()
                                .fill(stage.tint)
                                .frame(width: 10, height: 10)
                            Text(stage.title)
                            Spacer()
                            Text(Formatting.duration(seconds(stage)))
                                .font(.figure(18, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }
}
