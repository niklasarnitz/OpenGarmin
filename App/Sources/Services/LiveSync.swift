import ActivityKit
import Observation
import WidgetKit
import GarminModels
import GarminSession
import GarminShared

/// Mirrors the watch service into the home screen widgets and the sync Live Activity. Both follow the service's
/// observable state, so the session never knows they exist.
@MainActor
enum LiveSync {
    private static var watch: (any WatchService)?
    /// `Activity` is not Sendable, so it is only touched from the nonisolated helpers below, never sent between actors.
    nonisolated(unsafe) private static var activity: ActivityKit.Activity<SyncActivityAttributes>?
    /// The last queued update. Each update waits for the one before, so two quick state changes cannot both see no
    /// activity and request two (the first one would then be orphaned, stuck on "Listing activities").
    private static var lastUpdate: Task<Void, Never>?

    static func start(_ watch: any WatchService) {
        self.watch = watch
        Task { await endStaleActivities() }
        trackSnapshot()
        trackSync()
    }

    /// Writes the widget snapshot whenever the history, the paired watch or the battery changes.
    private static func trackSnapshot() {
        guard let watch else { return }
        withObservationTracking {
            let snapshot = WatchSnapshot(batch: watch.latest, watchName: watch.pairedWatch?.name,
                                         lastSync: watch.pairedWatch?.lastSync, battery: watch.battery)
            try? WatchSnapshotStore.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } onChange: {
            Task { @MainActor in trackSnapshot() }
        }
    }

    /// Shows a Live Activity for the length of a sync.
    private static func trackSync() {
        guard let watch else { return }
        withObservationTracking {
            let state = watch.state
            let watchName = watch.pairedWatch?.name ?? "Garmin watch"
            let previous = lastUpdate
            lastUpdate = Task {
                await previous?.value
                await showSync(state, watchName: watchName)
            }
        } onChange: {
            Task { @MainActor in trackSync() }
        }
    }

    nonisolated private static func showSync(_ state: WatchConnectionState, watchName: String) async {
        guard case let .syncing(progress, detail) = state else {
            activity = nil
            // Every activity of this type, so one orphaned by an earlier build or a lost race ends too.
            for ended in ActivityKit.Activity<SyncActivityAttributes>.activities {
                await ended.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(5)))
            }
            return
        }
        let content = ActivityContent(
            state: SyncActivityAttributes.ContentState(progress: progress, detail: progress >= 1 ? "Saving…" : detail),
            staleDate: nil)
        if let activity {
            await activity.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            // Fails silently when the sync runs in the background, where iOS does not allow starting an activity.
            activity = try? ActivityKit.Activity.request(attributes: SyncActivityAttributes(watchName: watchName),
                                                         content: content)
        }
    }

    /// Activities left over from an earlier launch cannot be updated any more, so they are ended.
    nonisolated private static func endStaleActivities() async {
        for stale in ActivityKit.Activity<SyncActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
    }
}
