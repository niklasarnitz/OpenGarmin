import Foundation
import Observation
import GarminDevices
import GarminFIT
import GarminModels
import GarminTransport

/// Why a command on the watch service failed.
public enum GarminWatchError: Error, Equatable, Sendable {
    case notConnected
    case busy
    case timedOut
    case uploadFailed(String)
    case unsupported(String)
}

extension GarminWatchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "The watch is not connected."
        case .busy: "The watch is busy with another transfer."
        case .timedOut: "The watch did not answer in time."
        case let .uploadFailed(reason): "The upload failed: \(reason)"
        case let .unsupported(reason): reason
        }
    }
}

/// The device service the UI talks to. It owns the link to the paired watch, keeps the connection alive with
/// backoff, and turns the session's output into the state and events the app shows.
@MainActor
@Observable
public final class GarminWatchService: WatchService {
    public private(set) var state: WatchConnectionState {
        // A dropped link or a finished sync leaves no file downloading.
        didSet {
            if case .syncing = state {} else {
                fileProgress = nil
            }
        }
    }
    public private(set) var pairedWatch: PairedWatch?
    public private(set) var battery: BatteryStatus?
    public private(set) var nearby: [NearbyWatch] = []
    public private(set) var installedApps: [InstalledApp] = []
    /// The retained history: every imported activity and the samples of the last 30 days.
    public private(set) var latest: HealthBatch
    public private(set) var fileProgress: FileTransferProgress?
    public let events: AsyncStream<WatchEvent>
    public private(set) var emergencyContacts: [EmergencyContact]
    /// The GPS satellite data the watch takes from the phone: its URLs, cached files and refresh.
    public let agps: AGPSCache

    @ObservationIgnored private let eventSink: AsyncStream<WatchEvent>.Continuation
    @ObservationIgnored private let store: SessionStore
    /// The import stage: turns the downloaded files into history, off the main actor.
    @ObservationIgnored private let importer: FITImporter
    /// Whether the import stage is running. It can outlive the watch's sync.
    @ObservationIgnored private var importing = false
    @ObservationIgnored private let phoneName: String
    @ObservationIgnored private let weatherProvider: (@MainActor () async -> WeatherReport?)?
    @ObservationIgnored private let calendarProvider: (@MainActor () async -> [CalendarEvent])?
    @ObservationIgnored private let makeLink: @MainActor (UUID) -> any GarminServiceLink
    @ObservationIgnored private var session: GFDISession?
    @ObservationIgnored private var activeLink: (any GarminServiceLink)?
    @ObservationIgnored private var connection: Task<Void, Never>?
    /// Bumped whenever the connection is replaced, so a stale connection stops touching the state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var scanner: GarminScanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The apps' live readings, by subscriber. The watch streams the union of their metrics.
    @ObservationIgnored private var liveSubscribers: [UUID: (metrics: Set<LiveMetric>, sink: AsyncStream<LiveReading>.Continuation)] = [:]

    /// Shown after the watch's sync ends while the import stage still saves the files.
    private static let savingState = WatchConnectionState.syncing(progress: 1, detail: "Saving…")

    /// - Parameters:
    ///   - weather: supplies the forecast when the watch asks for it.
    ///   - calendar: supplies the events the watch can show, pushed after each handshake.
    ///   - makeLink: creates the link for a watch. Tests replace it with a fake.
    public init(store: SessionStore,
                phoneName: String = "iPhone",
                weather: (@MainActor () async -> WeatherReport?)? = nil,
                calendar: (@MainActor () async -> [CalendarEvent])? = nil,
                makeLink: @escaping @MainActor (UUID) -> any GarminServiceLink = { BLEGarminLink(peripheralID: $0) }) {
        let (stream, sink) = AsyncStream.makeStream(of: WatchEvent.self)
        events = stream
        eventSink = sink
        self.store = store
        agps = AGPSCache(directory: store.directory.appendingPathComponent("AGPS", isDirectory: true))
        self.phoneName = phoneName
        weatherProvider = weather
        calendarProvider = calendar
        self.makeLink = makeLink
        let history = HistoryStore(directory: store.directory)
        latest = history.history
        let (importEvents, importSink) = AsyncStream.makeStream(of: FITImporter.Event.self)
        importer = FITImporter(history: history, report: { importSink.yield($0) })
        emergencyContacts = store.emergencyContacts
        let paired = store.pairedWatch
        pairedWatch = paired
        state = paired == nil ? .noWatchPaired : .disconnected(lastSeen: paired?.lastSync)
        Task { [weak self] in
            for await event in importEvents { self?.handleImport(event) }
        }
        // Files that were downloaded but not imported before the app stopped are imported now.
        Task { await self.importer.start() }
        if paired != nil { startConnection() }
    }

    // MARK: - Discovery and pairing

    public func startScanning() {
        guard scanner == nil else { return }
        let scanner = GarminScanner()
        self.scanner = scanner
        if pairedWatch == nil { state = .searching }
        scanTask = Task { [weak self] in
            for await watches in scanner.watches {
                self?.nearby = watches.map {
                    NearbyWatch(id: $0.id, name: $0.name, rssi: $0.rssi,
                                catalogID: GarminDeviceCatalog.match(bluetoothName: $0.name)?.id)
                }
            }
        }
        Task { await scanner.start() }
    }

    public func stopScanning() {
        scanner?.stop()
        scanner = nil
        scanTask?.cancel()
        scanTask = nil
        if state == .searching {
            state = pairedWatch == nil ? .noWatchPaired : .disconnected(lastSeen: pairedWatch?.lastSync)
        }
    }

    public func pair(_ watch: NearbyWatch) async throws {
        stopScanning()
        setPairedWatch(PairedWatch(id: watch.id, name: watch.name, catalogID: watch.catalogID))
        await activeLink?.disconnect()
        startConnection()
    }

    public func forget() async {
        generation += 1
        connection?.cancel()
        connection = nil
        session?.disconnected()
        session = nil
        await activeLink?.disconnect()
        activeLink = nil
        setPairedWatch(nil)
        battery = nil
        installedApps = []
        state = .noWatchPaired
    }

    public func reconnect() async {
        guard pairedWatch != nil else { return }
        await activeLink?.disconnect()
        startConnection()
    }

    // MARK: - Commands

    public func syncNow() async {
        await session?.requestSync()
    }

    public func findMyWatch() async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.findMyWatch()
    }

    public func sendWeather(_ report: WeatherReport) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.sendWeather(report)
    }

    public func sendNotification(_ notification: PhoneNotification) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.sendNotification(notification)
    }

    public func sendCalendar(_ events: [CalendarEvent]) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        session.setCalendar(events)
    }

    public func sendWorkout(_ plan: WorkoutPlan) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.sendWorkout(plan)
    }

    /// Saves the profile, then sends it. A profile that could not be sent stays saved and goes out after the next handshake.
    public func updateProfile(_ profile: UserProfile) async throws {
        store.userProfile = profile
        guard let session else { throw GarminWatchError.notConnected }
        try await session.sendProfile(profile)
    }

    public func setTime() async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.setTime()
    }

    // MARK: - Watch settings and alarms

    /// Gadgetbridge's slot count: the catalog's fixed count, else 0 for watches with realtime settings and 10 for the rest.
    public var alarmSlots: Int {
        let fixed = GarminDeviceCatalog.all.first { $0.id == pairedWatch?.catalogID }?.alarmSlotCount
        return fixed ?? (pairedWatch?.capabilities.contains(.realtimeSettings) == true ? 0 : 10)
    }

    public func settingsScreen(_ id: UInt32) async throws -> WatchSettingsScreen {
        guard let session else { throw GarminWatchError.notConnected }
        return try await session.readSettingsScreen(id)
    }

    public func changeSetting(screen: UInt32, entryID: UInt32, _ change: WatchSettingChange) async throws -> WatchSettingsOutcome {
        guard let session else { throw GarminWatchError.notConnected }
        return try await session.changeSetting(screenID: screen, entryID: entryID, change)
    }

    /// Sends the alarms as a settings file, which replaces the watch's alarms. Watches without alarm slots keep them in their settings.
    public func setAlarms(_ alarms: [WatchAlarm]) async throws {
        guard alarmSlots > 0 else { throw GarminWatchError.unsupported("This watch keeps its alarms in its watch settings.") }
        guard alarms.count <= alarmSlots else { throw GarminWatchError.unsupported("This watch has \(alarmSlots) alarm slots.") }
        guard let session else { throw GarminWatchError.notConnected }
        try await session.transferFile(AlarmFitEncoder.encode(alarms), subType: 2)
    }

    // MARK: - Install

    public func refreshInstalledApps() async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.requestInstalledApps()
    }

    public func deleteInstalledApp(_ app: InstalledApp) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.deleteInstalledApp(app)
    }

    public func installApp(_ prg: Data, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.installApp(prg, onProgress: progress)
    }

    public func installCourse(gpx: Data, name: String, includeTurns: Bool,
                              progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.installCourse(gpx: gpx, name: name, includeTurns: includeTurns, onProgress: progress)
    }

    public func setEmergencyContacts(_ contacts: [EmergencyContact]) {
        store.emergencyContacts = contacts
        emergencyContacts = contacts
    }

    public func liveReadings(_ metrics: Set<LiveMetric>) -> AsyncStream<LiveReading> {
        let id = UUID()
        let (stream, sink) = AsyncStream.makeStream(of: LiveReading.self)
        liveSubscribers[id] = (metrics, sink)
        sink.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.liveSubscribers.removeValue(forKey: id)
                self?.syncLive()
            }
        }
        syncLive()
        return stream
    }

    /// Tells the session which metrics the subscribers want.
    private func syncLive() {
        session?.setLive(liveSubscribers.values.reduce(into: Set<LiveMetric>()) { $0.formUnion($1.metrics) })
    }

    // MARK: - Files and batches from outside the watch

    /// Whether a file or batch with this key was imported, or is waiting to be imported.
    public func hasImported(_ key: String) async -> Bool {
        await importer.isKnown(key)
    }

    /// Imports a FIT file that did not come from the watch, such as an activity's original file from Garmin Connect.
    /// It goes through the watch's import stage, so it reaches Health the same way the watch's files do.
    public func importFITFile(_ bytes: Data, key: String) async throws {
        try await importer.accept(bytes, fileKey: key)
    }

    /// Imports a batch that has no FIT file, such as daily stress and Body Battery from Garmin Connect.
    public func importBatch(_ batch: HealthBatch, key: String) async throws {
        try await importer.acceptBatch(batch, fileKey: key)
    }

    // MARK: - Connection

    private func setPairedWatch(_ watch: PairedWatch?) {
        pairedWatch = watch
        store.pairedWatch = watch
    }

    private func startConnection() {
        guard let watch = pairedWatch else { return }
        generation += 1
        let current = generation
        connection?.cancel()
        connection = Task { [weak self] in
            await self?.runConnection(watch, generation: current)
        }
    }

    /// Connects, runs the session until the link drops, and then reconnects with backoff, until replaced.
    private func runConnection(_ watch: PairedWatch, generation current: Int) async {
        while current == generation, !Task.isCancelled {
            let link = makeLink(watch.id)
            let session = makeSession(link: link, generation: current)
            self.session = session
            activeLink = link
            state = .connecting

            var failure: String?
            do {
                try await link.connect()
                await pump(link, session)
            } catch {
                failure = error.localizedDescription
            }
            session.disconnected()
            await link.disconnect()

            guard current == generation, !Task.isCancelled else { return }
            self.session = nil
            activeLink = nil
            reconnectAttempts += 1
            state = failure.map { .failed($0) } ?? .disconnected(lastSeen: pairedWatch?.lastSync)
            try? await Task.sleep(for: .seconds(min(pow(2, Double(reconnectAttempts)), 300)))
        }
    }

    private func makeSession(link: any GarminServiceLink, generation current: Int) -> GFDISession {
        // The catalog says whether Gadgetbridge uses the new sync protocol for this model. Unknown models
        // (nil) decide from the watch's capabilities instead.
        let newSync = GarminDeviceCatalog.all.first(where: { $0.id == pairedWatch?.catalogID })?.usesNewSyncProtocol
        return GFDISession(link: link, importer: importer, capabilities: GFDISession.phoneCapabilities,
                           phoneName: phoneName, newSyncProtocol: newSync, weatherProvider: weatherProvider,
                           agps: agps, contacts: { [weak self] in self?.emergencyContacts ?? [] }) { [weak self] output in
            guard let self, current == self.generation else { return }
            self.handle(output)
        }
    }

    /// Feeds incoming frames to the session until the link fails or disconnects.
    private func pump(_ link: any GarminServiceLink, _ session: GFDISession) async {
        let frames = Task { @MainActor in
            for await frame in link.incomingFrames {
                await session.receive(frame)
            }
        }
        defer { frames.cancel() }
        // The state stream starts with the link's initial .disconnected, so a drop counts only after connecting.
        var sawConnecting = false
        for await linkState in link.states {
            switch linkState {
            case .connecting: sawConnecting = true
            case .failed: return
            case .disconnected where sawConnecting: return
            default: break
            }
        }
    }

    private func handle(_ output: GFDISessionOutput) {
        switch output {
        case let .ready(info, capabilities):
            reconnectAttempts = 0
            if var watch = pairedWatch {
                if let info {
                    watch.info = info
                    watch.catalogID = GarminDeviceCatalog.model(productNumber: info.productNumber)?.id ?? watch.catalogID
                }
                watch.capabilities = capabilities
                setPairedWatch(watch)
            }
            state = .connected
            // Files a stopped import left in the inbox are imported on every connect, not only at launch.
            Task { await self.importer.start() }
            syncLive()
            let session = session
            let profile = store.userProfile
            Task { [weak self] in
                if let calendar = self?.calendarProvider {
                    session?.setCalendar(await calendar())
                }
                // The profile goes first: its upload ends with a sync-complete event, which must not cut the sync short.
                if let profile {
                    do {
                        try await session?.sendProfile(profile)
                    } catch {
                        self?.eventSink.yield(.log("Could not send the user profile: \(error)"))
                    }
                }
                await session?.requestSync()
            }
        case let .progress(fraction, detail):
            state = .syncing(progress: fraction, detail: detail)
        case let .fileProgress(progress):
            fileProgress = progress
        case let .installedApps(apps):
            installedApps = apps
        case .syncFinished:
            if var watch = pairedWatch {
                watch.lastSync = .now
                setPairedWatch(watch)
            }
            state = importing ? Self.savingState : .connected
        case let .live(reading):
            for subscriber in liveSubscribers.values where subscriber.metrics.contains(reading.metric) {
                subscriber.sink.yield(reading)
            }
        case let .event(event):
            if case let .battery(status) = event { battery = status }
            eventSink.yield(event)
        }
    }

    /// Import-stage events. Each imported batch goes to the app as one `healthBatchImported`, which it saves to Health.
    private func handleImport(_ event: FITImporter.Event) {
        switch event {
        case .started:
            importing = true
        case let .imported(batch, history):
            latest = history
            eventSink.yield(.healthBatchImported(batch))
        case .finished:
            importing = false
            if state == Self.savingState { state = .connected }
        case let .log(message):
            eventSink.yield(.log(message))
        }
    }
}
