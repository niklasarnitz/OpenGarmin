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
    /// Uploads the watch's files and the Garmin Connect batches to the self-hosted backend.
    let backend: BackendSync

    init(watch: any WatchService, backend: BackendSync) {
        self.watch = watch
        self.backend = backend
    }

    /// The one place the real device service gets wired in. Launching with `-preview` runs the UI on
    /// `PreviewWatchService` instead, without hardware.
    static func live() -> AppEnvironment {
        if ProcessInfo.processInfo.arguments.contains("-preview") {
            return AppEnvironment(watch: PreviewWatchService(), backend: BackendSync(directory: FileManager.default.temporaryDirectory))
        }
        // Application Support is always available on iOS, so failing to open the store is a programming error.
        let store = try! SessionStore.standard()
        let watch = GarminWatchService(
            store: store,
            weather: { try? await PhoneSync.weatherReport() },
            calendar: { CalendarSync.events() }
        )
        // State restoration only works when the central exists before launch finishes.
        if watch.pairedWatch != nil { GarminBluetooth.activate() }
        let backend = BackendSync(directory: store.directory)
        let environment = AppEnvironment(watch: watch, backend: backend)
        environment.handleWatchEvents()
        CalendarSync.pushChanges(to: watch)
        WatchCommands.syncNow = { await watch.syncNow() }
        WatchCommands.findMyWatch = { try await watch.findMyWatch() }
        WatchCommands.sendWorkout = { try await watch.sendWorkout($0) }
        LiveSync.start(watch)
        // Uploads what a previous run left behind, and finishes an Apple Health upload that was killed.
        backend.requestUpload()
        backend.healthKit.resumeIfStarted()
        return environment
    }

    /// Writes every batch the watch imports to Apple Health, starts the backend upload and raises the find-my-phone
    /// alert. Runs for the life of the app. It is the only consumer of `watch.events`, because an AsyncStream delivers
    /// each event once.
    private func handleWatchEvents() {
        let watch = self.watch
        let writer = HealthKitWriter()
        let backend = self.backend
        Task {
            for await event in watch.events {
                if case let .findMyPhone(started) = event {
                    FindMyPhoneAlert.update(started: started)
                    continue
                }
                guard case let .healthBatchImported(batch) = event else { continue }
                backend.requestUpload()
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
