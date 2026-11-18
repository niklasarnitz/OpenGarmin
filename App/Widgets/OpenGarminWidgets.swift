import SwiftUI
import WidgetKit
import GarminShared

@main
struct OpenGarminWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        SyncLiveActivity()
        SyncControl()
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // The app reloads the timelines whenever the watch data changes; this refresh only covers the day rolling over.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    private var entry: TodayEntry {
        TodayEntry(date: .now, snapshot: WatchSnapshotStore.read())
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Steps, heart rate, sleep, body battery and your watch.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WatchSnapshot? { entry.snapshot }

    // The steps only count for today: a snapshot from an earlier day shows a dash until the app syncs again.
    private var steps: String {
        guard let snapshot, Calendar.current.isDateInToday(snapshot.date) else { return "–" }
        return snapshot.steps.formatted()
    }
    private var heartRate: String { snapshot?.heartRate.map { "\($0)" } ?? "–" }
    private var sleep: String { snapshot?.sleepMinutes.map { Formatting.duration(TimeInterval($0 * 60)) } ?? "–" }
    private var bodyBattery: String { snapshot?.bodyBattery.map { "\($0)" } ?? "–" }
    private var stress: String { snapshot?.stress.map { "\($0)" } ?? "–" }
    private var watchBattery: String { snapshot?.watchBattery.map { "\($0)%" } ?? "–" }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
                    ? Color.clear : Color.canvas
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            Metric(title: "Steps", symbol: "figure.walk", tint: Palette.blaze, value: steps)
            Spacer(minLength: 0)
            HStack {
                Label(heartRate, systemImage: "heart.fill").foregroundStyle(Palette.ember)
                Spacer()
                Label(watchBattery, systemImage: "applewatch").foregroundStyle(Palette.lichen)
            }
            .font(.caption.weight(.semibold))
        }
    }

    private var medium: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                Metric(title: "Steps", symbol: "figure.walk", tint: Palette.blaze, value: steps)
                Metric(title: "Heart rate", symbol: "heart.fill", tint: Palette.ember, value: heartRate)
            }
            HStack(alignment: .top) {
                Metric(title: "Sleep", symbol: "bed.double.fill", tint: Palette.dusk, value: sleep)
                Metric(title: "Body battery", symbol: "battery.75percent", tint: Palette.lichen, value: bodyBattery)
            }
            footer
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                Metric(title: "Steps", symbol: "figure.walk", tint: Palette.blaze, value: steps)
                Metric(title: "Heart rate", symbol: "heart.fill", tint: Palette.ember, value: heartRate)
                Metric(title: "Sleep", symbol: "bed.double.fill", tint: Palette.dusk, value: sleep)
                Metric(title: "Body battery", symbol: "battery.75percent", tint: Palette.lichen, value: bodyBattery)
                Metric(title: "Stress", symbol: "bolt.heart.fill", tint: Palette.amber, value: stress)
                Metric(title: "Watch", symbol: "applewatch", tint: Palette.glacier, value: watchBattery)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let lastSync = snapshot?.lastSync {
                Text("Synced")
                Text(lastSync, style: .relative)
            } else {
                Text("Not synced yet")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var circular: some View {
        Gauge(value: Double(snapshot?.bodyBattery ?? 0), in: 0...100) {
            Image(systemName: "battery.75percent")
        } currentValueLabel: {
            Text(bodyBattery)
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(steps) steps", systemImage: "figure.walk")
            Label("\(heartRate) bpm", systemImage: "heart.fill")
            Label(sleep, systemImage: "bed.double.fill")
        }
        .font(.caption.weight(.semibold))
    }

    private var inline: some View {
        Label("\(steps) steps · \(heartRate) bpm", systemImage: "figure.walk")
    }
}

/// One number with its label, in the large figures of the app.
private struct Metric: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.figure(30))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
