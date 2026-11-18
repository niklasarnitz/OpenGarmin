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
    /// Connect IQ apps the watch lists as installed, as last refreshed.
    var installedApps: [InstalledApp] { get }
    func refreshInstalledApps() async throws
    func deleteInstalledApp(_ app: InstalledApp) async throws
    /// Installs a Connect IQ .prg file. `progress` reports the upload as a fraction from 0 to 1.
    func installApp(_ prg: Data, progress: @escaping @MainActor (Double) -> Void) async throws
    /// Converts a GPX track to a course and uploads it. `progress` reports the upload as a fraction from 0 to 1.
    func installCourse(gpx: Data, name: String, includeTurns: Bool,
                       progress: @escaping @MainActor (Double) -> Void) async throws
}
