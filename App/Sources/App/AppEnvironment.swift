import Foundation
import Observation
import GarminHealth
import GarminSession
import GarminTransport

/// Everything the UI reads from the device stack. Views only ever see `WatchService`.
@MainActor
@Observable
final class AppEnvironment {
    let watch: any WatchService

    init(watch: any WatchService) {
        self.watch = watch
    }

    /// The one place the real device service gets wired in. Launching with `-preview` runs the UI on
    /// `PreviewWatchService` instead, without hardware.
    static func live() -> AppEnvironment {
        if ProcessInfo.processInfo.arguments.contains("-preview") {
            return AppEnvironment(watch: PreviewWatchService())
        }
        // Application Support is always available on iOS, so failing to open the store is a programming error.
        let store = try! SessionStore.standard()
        let watch = GarminWatchService(
            store: store,
            weather: { try? await PhoneSync.weatherReport() },
            calendar: { PhoneSync.calendarEvents() }
        )
        // State restoration only works when the central exists before launch finishes.
        if watch.pairedWatch != nil { GarminBluetooth.activate() }
        let environment = AppEnvironment(watch: watch)
        environment.mirrorImportsToHealth()
        return environment
    }

    /// Writes every batch the watch imports to Apple Health. Runs for the life of the app.
    private func mirrorImportsToHealth() {
        let watch = self.watch
        let writer = HealthKitWriter()
        Task {
            for await event in watch.events {
                guard case let .healthBatchImported(batch) = event else { continue }
                let paired = watch.pairedWatch
                _ = try? await writer.save(
                    batch,
                    deviceName: paired?.name ?? "Garmin watch",
                    deviceModel: paired?.info?.deviceModel ?? paired?.catalogID ?? "Garmin watch",
                    firmware: paired?.info?.softwareVersionString ?? ""
                )
            }
        }
    }
}
