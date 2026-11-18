import Charts
import SwiftUI
import GarminModels

/// Realtime readings from the watch. The watch streams only the metric on screen, and only while this screen is open:
/// changing the metric or leaving the screen ends the stream.
struct LiveView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var metric: LiveMetric = .heartRate
    @State private var points: [PointSample] = []
    @State private var latest: LiveReading?

    private static let window = 120

    private var isConnected: Bool {
        switch app.watch.state {
        case .connected, .syncing: true
        default: false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Metric", selection: $metric) {
                    ForEach(LiveMetric.allCases, id: \.self) { metric in
                        Text(Self.title(metric)).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                MetricTile(LocalizedStringKey(Self.title(metric)), symbol: Self.symbol(metric), tint: Palette.glacier) {
                    if let text = Self.valueText(latest) {
                        MetricFigure(value: text.value, unit: text.unit, size: 52)
                    } else {
                        Text(isConnected ? "Waiting for the first reading." : "Connect the watch to see live readings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    chart
                }
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Live")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: metric) {
            points = []
            latest = nil
            var index = 0.0
            for await reading in app.watch.liveReadings([metric]) {
                latest = reading
                let now = Date.now
                for value in Self.values(reading) {
                    // Accelerometer packets carry three samples at about 38 ms apart.
                    points.append(PointSample(date: now.addingTimeInterval(index * 0.038), value: value))
                    index += 1
                }
                if points.count > Self.window { points.removeFirst(points.count - Self.window) }
            }
        }
    }

    private var chart: some View {
        Chart(points, id: \.date) { point in
            AreaMark(x: .value("Time", point.date), y: .value(Self.title(metric), point.value))
                .foregroundStyle(LinearGradient(colors: [Palette.glacier.opacity(0.32), Palette.glacier.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value(Self.title(metric), point.value))
                .foregroundStyle(Palette.glacier)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.minute().second())
                    .font(.caption2)
            }
        }
        .frame(height: 220)
        .animation(.smooth, value: points.count)
    }

    /// The numbers a reading plots. Accelerometer plots the magnitude of each of its three samples.
    private static func values(_ reading: LiveReading) -> [Double] {
        switch reading {
        case let .heartRate(bpm, _): [Double(bpm)]
        case let .steps(count, _): [Double(count)]
        case let .calories(total, _): [Double(total)]
        case let .hrv(rr): [Double(rr)]
        case let .stress(level), let .spo2(level), let .bodyBattery(level), let .respiration(level): [Double(level)]
        case let .accelerometer(samples):
            samples.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }
        }
    }

    private static func valueText(_ reading: LiveReading?) -> (value: String, unit: String)? {
        switch reading {
        case nil: nil
        case let .heartRate(bpm, resting):
            (String(bpm), resting.map { "bpm, resting \($0)" } ?? "bpm")
        case let .steps(count, goal): (count.formatted(), "of \(goal.formatted()) steps")
        case let .calories(total, active): (total.formatted(), "kcal, \(active) active")
        case let .hrv(rr): ("\(rr)", "ms RR interval")
        case let .stress(level): ("\(level)", "stress, 0 to 100")
        case let .spo2(percent): ("\(percent)", "% SpO2")
        case let .bodyBattery(level): ("\(level)", "body battery")
        case let .respiration(breaths): ("\(breaths)", "breaths per minute")
        case let .accelerometer(samples):
            (samples.last.map { String(format: "%.2f", ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot()) } ?? "–", "g")
        }
    }

    static func title(_ metric: LiveMetric) -> String {
        switch metric {
        case .heartRate: "Heart rate"
        case .steps: "Steps"
        case .calories: "Calories"
        case .hrv: "HRV"
        case .stress: "Stress"
        case .spo2: "SpO2"
        case .bodyBattery: "Body battery"
        case .respiration: "Respiration"
        case .accelerometer: "Accelerometer"
        }
    }

    private static func symbol(_ metric: LiveMetric) -> String {
        switch metric {
        case .heartRate, .hrv: "heart.fill"
        case .steps: "figure.walk"
        case .calories: "flame.fill"
        case .stress: "waveform.path"
        case .spo2: "lungs.fill"
        case .bodyBattery: "battery.75percent"
        case .respiration: "wind"
        case .accelerometer: "gyroscope"
        }
    }
}
