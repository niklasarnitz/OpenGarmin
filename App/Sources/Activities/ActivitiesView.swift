import SwiftUI
import GarminModels

struct ActivitiesView: View {
    @Environment(AppEnvironment.self) private var app

    private var activities: [Activity] {
        app.watch.latest.activities.sorted { $0.start > $1.start }
    }

    var body: some View {
        NavigationStack {
            Group {
                if activities.isEmpty {
                    ContentUnavailableView("No activities yet", systemImage: "figure.run",
                                           description: Text("Runs, rides and workouts recorded on the watch appear here."))
                } else {
                    List(activities) { activity in
                        NavigationLink(value: activity) {
                            ActivityRow(activity: activity)
                        }
                    }
                }
            }
            .navigationTitle("Activities")
            .navigationDestination(for: Activity.self) { ActivityDetailView(activity: $0) }
            .refreshable { await app.watch.syncNow() }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.sport.symbol)
                .font(.title3)
                .foregroundStyle(activity.sport.tint)
                .frame(width: 44, height: 44)
                .background(activity.sport.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.name ?? activity.sport.title)
                    .font(.headline)
                Text(activity.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let distance = activity.distance {
                    Text("\(Formatting.distance(distance)) km")
                        .font(.figure(18, weight: .semibold))
                }
                Text(Formatting.duration(activity.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
