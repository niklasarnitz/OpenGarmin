import Observation
import GarminSession

/// Everything the UI reads from the device stack. Views only ever see `WatchService`.
@MainActor
@Observable
final class AppEnvironment {
    let watch: any WatchService

    init(watch: any WatchService) {
        self.watch = watch
    }

    /// The one place the real device service gets wired in. Until GarminSession ships its
    /// `GarminWatchService`, the UI runs on `PreviewWatchService`.
    static func live() -> AppEnvironment {
        AppEnvironment(watch: PreviewWatchService())
    }
}
