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
    /// Off in a toolbar, which already gives its items a glass capsule; a second one drew a double border.
    var glass = true

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
        .padding(.horizontal, glass ? 12 : 4)
        .padding(.vertical, glass ? 8 : 0)
        .glassEffect(glass ? .regular : .identity, in: .capsule)
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
    /// Garmin writes 0 when it could not measure (stress, Body Battery, heart rate). Those stretches are drawn as
    /// greyed "no data" ranges and the line breaks there. Off for series where 0 is a real value, such as speed.
    var zeroMeansNoData = false
    /// The time the chart covers, such as today or the selected Insights range. With `zeroMeansNoData`, the stretch
    /// before the first and after the last reading is greyed too (up to now), and the x axis spans the whole range.
    var domain: DateInterval?

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

    private var span: TimeInterval {
        guard let first = points.map(\.date).min(), let last = points.map(\.date).max() else { return 0 }
        return last.timeIntervalSince(first)
    }

    private var spansDays: Bool { (domain?.duration ?? span) > 36 * 3600 }

    /// The line's pieces and the greyed ranges between them. Gaps shorter than ten minutes, or than one smoothing
    /// bucket on multi-day charts, are left out so single dropped readings do not hatch the chart.
    private var layout: (segments: [[PointSample]], gaps: [DateInterval]) {
        guard zeroMeansNoData else { return ([ChartSmoothing.smoothed(points)], []) }
        let bucket = ChartSmoothing.bucketWidth(forSpan: span) ?? 0
        let whole = domain?.duration ?? span
        // Stress and Body Battery come every few minutes; half an hour without any reading (power saving, watch
        // off) is a gap, as is anything longer than two smoothing buckets on multi-day charts. An activity of an
        // hour records every second, so its limits shrink with its length: a 72-second hole, a 36-second stop.
        let spacing = max(min(1800, whole / 50), 2 * bucket)
        let split = ChartGaps.split(points, maxSpacing: spacing)
        let shortest = max(min(600, whole / 100), bucket)
        var gaps = split.gaps.filter { $0.duration >= shortest }
        let readings = split.segments.joined().map(\.date)
        if let domain {
            let end = min(domain.end, .now)
            if let first = readings.min(), first.timeIntervalSince(domain.start) > shortest {
                gaps.append(DateInterval(start: domain.start, end: first))
            }
            if let last = readings.max(), end.timeIntervalSince(last) > spacing {
                gaps.append(DateInterval(start: last, end: end))
            }
            if readings.isEmpty, end > domain.start { gaps.append(DateInterval(start: domain.start, end: end)) }
        }
        // Readings on both sides of a dropped short gap rejoin one piece, so smoothing runs across it.
        var segments: [[PointSample]] = []
        for point in split.segments.joined() {
            if let last = segments.last?.last,
               gaps.contains(where: { $0.start >= last.date && $0.end <= point.date && $0.duration > 0 }) {
                segments.append([point])
            } else if segments.isEmpty {
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }
        return (segments.map(ChartSmoothing.smoothed), gaps)
    }

    /// The y range of the drawn values with a tenth of their spread above and below, so a ride between 210 and 260 m
    /// fills the chart instead of sitting on a zero baseline.
    private func yDomain(_ segments: [[PointSample]]) -> ClosedRange<Double> {
        let values = segments.joined().map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = high > low ? (high - low) * 0.1 : max(abs(high) * 0.05, 1)
        return (low - pad)...(high + pad)
    }

    private var chart: some View {
        let layout = layout
        let yRange = yDomain(layout.segments)
        return Chart {
            ForEach(layout.gaps.indices, id: \.self) { index in
                let gap = layout.gaps[index]
                RectangleMark(xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                    .annotation(position: .overlay, alignment: .center) {
                        // Only wide gaps have room for the label.
                        if span > 0, gap.duration / span > 0.12 {
                            Text("No data")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            ForEach(layout.segments.indices, id: \.self) { segment in
                ForEach(layout.segments[segment], id: \.date) { point in
                    // The area starts at the bottom of the scaled range, not at zero.
                    AreaMark(x: .value("Time", point.date), yStart: .value(label, yRange.lowerBound),
                             yEnd: .value(label, point.value), series: .value("Segment", segment))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value(label, point.value),
                             series: .value("Segment", segment))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    if layout.segments[segment].count == 1 {
                        PointMark(x: .value("Time", point.date), y: .value(label, point.value))
                            .foregroundStyle(tint)
                            .symbolSize(20)
                    }
                }
            }
        }
        .chartYScale(domain: yRange)
        .chartXScale(domain: (domain?.start ?? points.map(\.date).min()!)...(domain?.end ?? points.map(\.date).max()!))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: spansDays ? .dateTime.day().month(.abbreviated) : .dateTime.hour().minute())
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
