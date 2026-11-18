import Foundation
import Observation
import GarminModels
import GarminSession

/// Fake device for previews and simulator runs. Mirrors the real service's behaviour closely enough
/// that every screen can be exercised without hardware.
@MainActor
@Observable
final class PreviewWatchService: WatchService {
    private(set) var state: WatchConnectionState = .connected
    private(set) var pairedWatch: PairedWatch? = PreviewData.pairedWatch()
    private(set) var battery: BatteryStatus? = BatteryStatus(percent: 78, isCharging: false)
    private(set) var nearby: [NearbyWatch] = []
    private(set) var latest: HealthBatch = PreviewData.batch()
    let events = AsyncStream<WatchEvent>.makeStream().stream

    private var scanTask: Task<Void, Never>?

    func startScanning() {
        guard scanTask == nil else { return }
        state = .searching
        scanTask = Task {
            for watch in PreviewData.nearby {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                nearby.append(watch)
            }
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        if state == .searching {
            state = pairedWatch == nil ? .noWatchPaired : .connected
        }
    }

    func pair(_ watch: NearbyWatch) async throws {
        state = .pairing(passkeyHint: "Confirm the code shown on the watch")
        try await Task.sleep(for: .seconds(2))
        stopScanning()
        pairedWatch = PairedWatch(id: watch.id, name: watch.name, catalogID: watch.catalogID,
                                  capabilities: PreviewData.capabilities, lastSync: nil)
        battery = BatteryStatus(percent: 100, isCharging: true)
        state = .connected
    }

    func forget() async {
        pairedWatch = nil
        battery = nil
        latest = HealthBatch()
        state = .noWatchPaired
    }

    func reconnect() async {
        state = .connecting
        try? await Task.sleep(for: .seconds(1))
        state = .connected
    }

    func syncNow() async {
        guard pairedWatch != nil else { return }
        let steps = ["Heart rate", "Sleep", "Steps", "Stress", "Body battery", "Activities"]
        for (index, detail) in steps.enumerated() {
            state = .syncing(progress: Double(index + 1) / Double(steps.count), detail: detail)
            try? await Task.sleep(for: .milliseconds(400))
        }
        state = .connected
        pairedWatch?.lastSync = .now
    }

    func findMyWatch() async throws { try await simulateRoundTrip() }
    func sendWeather(_ report: WeatherReport) async throws { try await simulateRoundTrip() }
    func sendNotification(_ notification: PhoneNotification) async throws { try await simulateRoundTrip() }
    func sendCalendar(_ events: [CalendarEvent]) async throws { try await simulateRoundTrip() }
    func sendWorkout(_ plan: WorkoutPlan) async throws { try await simulateRoundTrip() }
    func updateProfile(_ profile: UserProfile) async throws { try await simulateRoundTrip() }
    func setTime() async throws { try await simulateRoundTrip() }

    private(set) var installedApps: [InstalledApp] = [
        InstalledApp(id: UUID(), name: "Moon Phase", kind: .watchFace, version: 3, isSystem: false),
        InstalledApp(id: UUID(), name: "Gradient Sky", kind: .watchFace, version: nil, isSystem: true),
        InstalledApp(id: UUID(), name: "Cadence Plus", kind: .dataField, version: 12, isSystem: false),
    ]

    func refreshInstalledApps() async throws { try await simulateRoundTrip() }

    func deleteInstalledApp(_ app: InstalledApp) async throws {
        try await simulateRoundTrip()
        installedApps.removeAll { $0 == app }
    }

    func installApp(_ prg: Data, progress: @escaping @MainActor (Double) -> Void) async throws {
        try await simulateRoundTrip()
        progress(1)
    }

    func installCourse(gpx: Data, name: String, includeTurns: Bool,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        try await simulateRoundTrip()
        progress(1)
    }

    private func simulateRoundTrip() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}
