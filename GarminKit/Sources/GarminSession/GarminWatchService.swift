import Foundation
import Observation
import GarminDevices
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

/// The device service the UI talks to. It owns the link to the paired watch, keeps the connection alive with
/// backoff, and turns the session's output into the state and events the app shows.
@MainActor
@Observable
public final class GarminWatchService: WatchService {
    public private(set) var state: WatchConnectionState
    public private(set) var pairedWatch: PairedWatch?
    public private(set) var battery: BatteryStatus?
    public private(set) var nearby: [NearbyWatch] = []
    /// The retained history: every imported activity and the samples of the last 30 days.
    public private(set) var latest: HealthBatch
    public let events: AsyncStream<WatchEvent>
    /// The GPS satellite data the watch takes from the phone: its URLs, cached files and refresh.
    public let agps: AGPSCache

    @ObservationIgnored private let eventSink: AsyncStream<WatchEvent>.Continuation
    @ObservationIgnored private let store: SessionStore
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
        latest = store.history
        let paired = store.pairedWatch
        pairedWatch = paired
        state = paired == nil ? .noWatchPaired : .disconnected(lastSeen: paired?.lastSync)
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

    public func updateProfile(_ profile: UserProfile) async throws {
        throw GarminWatchError.unsupported("Sending the user profile is not ported yet")
    }

    public func setTime() async throws {
        guard let session else { throw GarminWatchError.notConnected }
        try await session.setTime()
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
        return GFDISession(link: link, store: store, capabilities: GFDISession.phoneCapabilities,
                           phoneName: phoneName, newSyncProtocol: newSync, weatherProvider: weatherProvider,
                           agps: agps) { [weak self] output in
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
            let session = session
            Task { [weak self] in
                if let calendar = self?.calendarProvider {
                    session?.setCalendar(await calendar())
                }
                await session?.requestSync()
            }
        case let .progress(fraction, detail):
            state = .syncing(progress: fraction, detail: detail)
        case .syncFinished:
            if var watch = pairedWatch {
                watch.lastSync = .now
                setPairedWatch(watch)
            }
            state = .connected
        case let .event(event):
            if case let .battery(status) = event { battery = status }
            if case .healthBatchImported = event { latest = store.history }
            eventSink.yield(event)
        }
    }
}
