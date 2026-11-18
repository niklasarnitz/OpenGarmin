import SwiftUI
import Charts
import GarminModels
import GarminSession

/// A titled content surface with an icon. Every dashboard and detail screen is built from these.
struct MetricTile<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let content: Content

    init(_ title: LocalizedStringKey, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.tileTitle)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .tile()
    }
}

/// A big rounded number. The size follows Dynamic Type and shrinks rather than clipping when it gets too wide.
struct MetricFigure: View {
    let value: String
    var unit: String?
    var size: CGFloat
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    init(value: String, unit: String? = nil, size: CGFloat = 44) {
        self.value = value
        self.unit = unit
        self.size = size
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.figure(size * scale))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// Activity-ring style gauge. The same motif as the app icon.
struct RingGauge: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth(duration: 1.1), value: progress)
        .accessibilityHidden(true)
    }
}

/// Floating status capsule on Liquid Glass. Shows connection state and watch battery.
struct WatchStatusPill: View {
    let state: WatchConnectionState
    let battery: BatteryStatus?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.tint)
                .frame(width: 8, height: 8)
            Text(state.label)
            if let battery {
                Text("\(battery.percent)%")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

extension WatchConnectionState {
    var label: String {
        switch self {
        case .noWatchPaired: String(localized: "No watch")
        case .searching: String(localized: "Searching")
        case .connecting: String(localized: "Connecting")
        case .pairing: String(localized: "Pairing")
        case .connected: String(localized: "Connected")
        case .syncing(let progress, _): String(localized: "Syncing \(Int(progress * 100))%")
        case .disconnected: String(localized: "Offline")
        case .failed: String(localized: "Error")
        }
    }

    var tint: Color {
        switch self {
        case .connected: Palette.lichen
        case .searching, .connecting, .pairing, .syncing: Palette.glacier
        case .failed: Palette.ember
        case .disconnected, .noWatchPaired: .secondary
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

/// A line or area series over time, used for heart rate, stress, pace and altitude.
struct SeriesChart: View {
    let points: [PointSample]
    let tint: Color
    let label: String
    var height: CGFloat = 120
    var showsAxis = true

    var body: some View {
        if points.isEmpty {
            Text("No samples yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart(points, id: \.date) { point in
            AreaMark(x: .value("Time", point.date), y: .value(label, point.value))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value(label, point.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
            }
        }
        .chartYAxis(showsAxis ? .automatic : .hidden)
        .frame(height: height)
        .accessibilityLabel(Text(label))
    }
}

/// Shown in place of content that has not synced yet.
struct EmptyDataCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
