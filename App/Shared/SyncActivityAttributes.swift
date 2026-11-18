import ActivityKit

/// The sync Live Activity. The app starts and updates it; the widget extension draws it.
struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0...1 of the sync.
        var progress: Double
        var detail: String
    }

    var watchName: String
}
