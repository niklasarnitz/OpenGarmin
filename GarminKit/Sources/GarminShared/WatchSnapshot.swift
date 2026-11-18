import Foundation
import GarminModels

/// The few numbers the home screen widgets show. The app writes it after every change to the watch's data; the
/// widgets only read it, so they never touch Bluetooth or the session store.
public struct WatchSnapshot: Codable, Sendable, Equatable {
    /// When the snapshot was built.
    public var date: Date
    public var steps: Int
    public var heartRate: Int?
    public var sleepMinutes: Int?
    public var sleepScore: Int?
    public var bodyBattery: Int?
    /// Average of today's stress samples, 0-100.
    public var stress: Int?
    public var watchName: String?
    public var watchBattery: Int?
    public var isCharging: Bool
    public var lastSync: Date?

    /// Today's totals and the latest readings of the retained history. "Today" is the day of `now` in `calendar`.
    /// Sleep counts when the last session ended within 24 hours of `now`.
    public init(batch: HealthBatch, watchName: String?, lastSync: Date?, battery: BatteryStatus?,
                now: Date = .now, calendar: Calendar = .current) {
        date = now
        let todaySteps = batch.steps.filter { calendar.isDate($0.start, inSameDayAs: now) }
        steps = Int(todaySteps.reduce(0) { $0 + $1.value }.rounded())
        heartRate = batch.heartRate.max { $0.date < $1.date }?.bpm
        if let session = batch.sleep.max(by: { $0.end < $1.end }), now.timeIntervalSince(session.end) < 24 * 3600 {
            sleepMinutes = Int(session.end.timeIntervalSince(session.start) / 60)
            sleepScore = session.score
        }
        bodyBattery = batch.bodyBattery.max { $0.date < $1.date }.map { Int($0.value.rounded()) }
        let todayStress = batch.stress.filter { calendar.isDate($0.date, inSameDayAs: now) }
        if !todayStress.isEmpty {
            stress = Int((todayStress.reduce(0) { $0 + $1.value } / Double(todayStress.count)).rounded())
        }
        self.watchName = watchName
        watchBattery = battery?.percent
        isCharging = battery?.isCharging ?? false
        self.lastSync = lastSync
    }
}

/// The App Group file the app writes and the widgets read.
public enum WatchSnapshotStore {
    public static let appGroup = "group.com.niklasarnitz.opengarmin"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("watch-snapshot.json")
    }

    /// Does nothing when the App Group is unavailable, as in an unsigned build.
    public static func write(_ snapshot: WatchSnapshot) throws {
        guard let url else { return }
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read() -> WatchSnapshot? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
    }
}
