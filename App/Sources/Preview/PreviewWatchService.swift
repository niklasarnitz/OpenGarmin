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
    private(set) var emergencyContacts: [EmergencyContact] = []

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

    func setEmergencyContacts(_ contacts: [EmergencyContact]) {
        emergencyContacts = contacts
    }

    /// Simulated readings, about twice a second, for the metrics asked for.
    func liveReadings(_ metrics: Set<LiveMetric>) -> AsyncStream<LiveReading> {
        AsyncStream { continuation in
            let task = Task {
                var tick = 0.0
                while !Task.isCancelled {
                    tick += 1
                    let readings: [LiveReading] = [
                        .heartRate(bpm: 64 + Int(9 * sin(tick / 4)), resting: 58),
                        .spo2(96 + Int(2 * sin(tick / 6))),
                        .stress(30 + Int(15 * sin(tick / 5))),
                        .bodyBattery(max(0, 78 - Int(tick) / 10)),
                        .steps(count: 4200 + Int(tick) * 12, goal: 10_000),
                        .accelerometer((0 ..< 3).map { index in
                            AccelerationSample(x: 0.05 * sin(tick + Double(index)), y: 0.02, z: -1)
                        }),
                    ]
                    for reading in readings where metrics.contains(reading.metric) {
                        continuation.yield(reading)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func simulateRoundTrip() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}
