import Foundation
import GarminModels

// CONTRACT (owned by the integrator). The app UI talks only to `WatchService`.
// The session agent implements `GarminWatchService`; the UI agent may use `PreviewWatchService` for previews.

public enum WatchConnectionState: Sendable, Equatable {
    case noWatchPaired
    case searching
    case connecting
    case pairing(passkeyHint: String?)
    case connected
    case syncing(progress: Double, detail: String)
    case disconnected(lastSeen: Date?)
    case failed(String)
}

/// Progress of the one file being downloaded from the watch during a sync.
public struct FileTransferProgress: Sendable, Equatable {
    /// File bytes received so far (uncompressed).
    public var bytes: Int
    /// The file's size, when the watch reported it.
    public var totalBytes: Int?
    public init(bytes: Int, totalBytes: Int?) { self.bytes = bytes; self.totalBytes = totalBytes }
    /// 0...1, or nil when the size is unknown.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(bytes) / Double(totalBytes), 1)
    }
}

public struct PairedWatch: Sendable, Codable, Hashable, Identifiable {
    /// CoreBluetooth peripheral identifier.
    public var id: UUID
    public var name: String
    /// Matching entry from the device catalog, e.g. "garmin_venu_4".
    public var catalogID: String?
    public var info: DeviceInfo?
    public var capabilities: Set<GarminCapability>
    public var lastSync: Date?
    public init(id: UUID, name: String, catalogID: String? = nil, info: DeviceInfo? = nil,
                capabilities: Set<GarminCapability> = [], lastSync: Date? = nil) {
        self.id = id; self.name = name; self.catalogID = catalogID; self.info = info
        self.capabilities = capabilities; self.lastSync = lastSync
    }
}

public struct NearbyWatch: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    /// Matching entry from the device catalog, nil when the name is not a known Garmin device.
    public var catalogID: String?
    public init(id: UUID, name: String, rssi: Int, catalogID: String?) {
        self.id = id; self.name = name; self.rssi = rssi; self.catalogID = catalogID
    }
}

public enum WatchEvent: Sendable {
    case findMyPhone(started: Bool)
    /// The watch chose a positive action of a notification the app sent. `actionIndex` is 0-based into its `actions`.
    case notificationAction(id: Int, actionIndex: Int)
    case healthBatchImported(HealthBatch)
    case battery(BatteryStatus)
    case log(String)
}

@MainActor
public protocol WatchService: AnyObject, Observable {
    var state: WatchConnectionState { get }
    var pairedWatch: PairedWatch? { get }
    var battery: BatteryStatus? { get }
    var nearby: [NearbyWatch] { get }
    /// Most recent synced data kept for the dashboard (also written to HealthKit by the app).
    var latest: HealthBatch { get }
    /// The file currently downloading during a sync, nil otherwise.
    var fileProgress: FileTransferProgress? { get }
    var events: AsyncStream<WatchEvent> { get }

    func startScanning()
    func stopScanning()
    func pair(_ watch: NearbyWatch) async throws
    func forget() async
    func reconnect() async
    func syncNow() async
    func findMyWatch() async throws
    func sendWeather(_ report: WeatherReport) async throws
    func sendNotification(_ notification: PhoneNotification) async throws
    func sendCalendar(_ events: [CalendarEvent]) async throws
    func sendWorkout(_ plan: WorkoutPlan) async throws
    func updateProfile(_ profile: UserProfile) async throws
    func setTime() async throws
    /// Alarm slots the watch takes from the phone. 0 when the watch keeps its alarms in its settings screens.
    var alarmSlots: Int { get }
    func settingsScreen(_ id: UInt32) async throws -> WatchSettingsScreen
    func changeSetting(screen: UInt32, entryID: UInt32, _ change: WatchSettingChange) async throws -> WatchSettingsOutcome
    func setAlarms(_ alarms: [WatchAlarm]) async throws
}
