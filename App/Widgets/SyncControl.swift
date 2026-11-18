import SwiftUI
import WidgetKit

/// A Control Center control that syncs the watch.
struct SyncControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.niklasarnitz.opengarmin.sync-control") {
            ControlWidgetButton(action: SyncWatchIntent()) {
                Label("Sync watch", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .displayName("Sync watch")
        .description("Syncs your Garmin watch now.")
    }
}
