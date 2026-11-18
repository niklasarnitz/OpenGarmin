import SwiftUI
import MapKit
import GarminModels

struct ActivityDetailView: View {
    @Environment(AppEnvironment.self) private var app
    let activity: Activity
    @State private var shareFiles: [URL] = []

    private var route: [CLLocationCoordinate2D] {
        activity.records.compactMap { record in
            guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if route.count > 1 { routeMap }
                summary
                if activity.records.contains(where: { $0.heartRate != nil }) {
                    MetricTile("Heart rate", symbol: "heart.fill", tint: Palette.ember) {
                        SeriesChart(points: series { $0.heartRate.map(Double.init) },
                                    tint: Palette.ember, label: "bpm", height: 150, zeroMeansNoData: true)
                    }
                }
                if activity.records.contains(where: { $0.speed != nil }) {
                    MetricTile("Speed", symbol: "speedometer", tint: activity.sport.tint) {
                        SeriesChart(points: series { $0.speed.map { $0 * 3.6 } },
                                    tint: activity.sport.tint, label: "km/h", height: 130)
                    }
                }
                if activity.records.contains(where: { $0.altitude != nil }) {
                    MetricTile("Elevation", symbol: "mountain.2.fill", tint: Palette.lichen) {
                        SeriesChart(points: series { $0.altitude }, tint: Palette.lichen, label: "m", height: 120)
                    }
                }
                if !activity.laps.isEmpty { laps }
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle(activity.name ?? activity.sport.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: activity.id) { await prepareShare() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: shareFiles) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(shareFiles.isEmpty)
            }
        }
    }

    /// The GPX track is written at once. The raw FIT file is searched for off the main thread, since it decodes
    /// every stored file until it finds this activity.
    private func prepareShare() async {
        let activity = activity
        let unitNumber = app.watch.pairedWatch?.info?.unitNumber
        var files: [URL] = []
        if let gpx = try? ActivityExport.gpxFile(for: activity) { files.append(gpx) }
        if let fit = await Task.detached(operation: { ActivityExport.fitFile(for: activity, unitNumber: unitNumber) }).value {
            files.insert(fit, at: 0)
        }
        shareFiles = files
    }

    private func series(_ value: (ActivityRecord) -> Double?) -> [PointSample] {
        activity.records.compactMap { record in
            value(record).map { PointSample(date: record.date, value: $0) }
        }
    }

    private var routeMap: some View {
        Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: route)
                .stroke(activity.sport.tint, lineWidth: 5)
            if let start = route.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start).tint(.green)
            }
            if let finish = route.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: finish).tint(Palette.blaze)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .frame(height: 300)
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .accessibilityLabel("Route map")
    }

    private var region: MKCoordinateRegion {
        let latitudes = route.map(\.latitude)
        let longitudes = route.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            return MKCoordinateRegion()
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.35 + 0.002,
                                   longitudeDelta: (maxLon - minLon) * 1.35 + 0.002))
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            stat("Distance", value: activity.distance.map { Formatting.distance($0) } ?? "–", unit: "km",
                 symbol: "point.topleft.down.to.point.bottomright.curvepath")
            stat("Time", value: Formatting.duration(activity.duration), unit: nil, symbol: "timer")
            stat(activity.sport.usesPace ? "Avg pace" : "Avg speed", value: speed.value, unit: speed.unit,
                 symbol: "speedometer")
            stat("Avg heart rate", value: activity.averageHeartRate.map(String.init) ?? "–", unit: "bpm",
                 symbol: "heart.fill")
            stat("Calories", value: activity.activeCalories.map(Formatting.whole) ?? "–", unit: "kcal",
                 symbol: "flame.fill")
            stat("Ascent", value: activity.totalAscent.map(Formatting.whole) ?? "–", unit: "m",
                 symbol: "arrow.up.right")
        }
    }

    private var speed: (value: String, unit: String) {
        guard let metresPerSecond = activity.averageSpeed, metresPerSecond > 0 else { return ("–", "") }
        if activity.sport.usesPace {
            return (Formatting.pace(secondsPerKilometre: 1000 / metresPerSecond), "/km")
        }
        return ((metresPerSecond * 3.6).formatted(.number.precision(.fractionLength(1))), "km/h")
    }

    private func stat(_ title: LocalizedStringKey, value: String, unit: String?, symbol: String) -> some View {
        MetricTile(title, symbol: symbol, tint: activity.sport.tint) {
            MetricFigure(value: value, unit: unit, size: 34)
        }
        .accessibilityElement(children: .combine)
    }

    private var laps: some View {
        MetricTile("Laps", symbol: "flag.2.crossed.fill", tint: Palette.amber) {
            ForEach(Array(activity.laps.enumerated()), id: \.offset) { index, lap in
                HStack {
                    Text("\(index + 1)")
                        .font(.figure(16))
                        .frame(width: 28, alignment: .leading)
                    Text(Formatting.duration(lap.end.timeIntervalSince(lap.start)))
                    Spacer()
                    if let distance = lap.distance {
                        Text("\(Formatting.distance(distance)) km")
                    }
                    if let heartRate = lap.averageHeartRate {
                        Text("\(heartRate) bpm")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
