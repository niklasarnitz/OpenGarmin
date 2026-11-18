import SwiftUI
import Charts
import GarminModels
import GarminSession

/// A titled content surface with an icon. Every dashboard and detail screen is built from these.
struct MetricTile<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let content: Content

    init(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
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

struct MetricFigure: View {
    let value: String
    var unit: String?
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.figure(size))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
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
    }
}

extension WatchConnectionState {
    var label: String {
        switch self {
        case .noWatchPaired: "No watch"
        case .searching: "Searching"
        case .connecting: "Connecting"
        case .pairing: "Pairing"
        case .connected: "Connected"
        case .syncing(let progress, _): "Syncing \(Int(progress * 100))%"
        case .disconnected: "Offline"
        case .failed: "Error"
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
    }
}

/// Shown in place of content that has not synced yet.
struct EmptyDataCard: View {
    let title: String
    let symbol: String
    let message: String

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
