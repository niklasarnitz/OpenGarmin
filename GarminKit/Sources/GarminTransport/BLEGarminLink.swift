import os
import CoreBluetooth
import Foundation
import GarminCore

public enum GarminLinkError: Error, Equatable {
    case notReady
    case unknownWatch
    case failed(String)
}

/// CoreBluetooth `GarminLink` for one watch. Uses multi-link reliable framing (V2) when the watch exposes its
/// MLR characteristics, and plain COBS over V1 or V0 otherwise.
@MainActor
public final class BLEGarminLink: NSObject, GarminServiceLink {
    public nonisolated let states: AsyncStream<LinkState>
    public nonisolated let incomingFrames: AsyncStream<Data>
    private let stateSink: AsyncStream<LinkState>.Continuation
    private let frameSink: AsyncStream<Data>.Continuation

    private let peripheralID: UUID
    private var state: LinkState = .disconnected
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var tx: CBCharacteristic?
    private var usesMLR = false
    private var maxWrite = 20
    private var outbox: [Data] = []

    private var handshake = GFDIHandshake()
    private var lastHandshakeWrite: Data?
    private var pairingAttempts = 0
    /// MLR channels by handle: the GFDI channel and each open file transfer service.
    private var channels: [UInt8: MLRChannel] = [:]
    private var gfdiHandle: UInt8?
    /// Payload sinks of the open file transfer services, by handle.
    private var serviceSinks: [UInt8: AsyncStream<Data>.Continuation] = [:]
    /// Service handles the watch opened without MLR.
    private var plainHandles: Set<UInt8> = []
    /// Service codes in use, and the registrations still waiting for the watch's reply.
    private var openServices: Set<UInt16> = []
    private var openRequests: [UInt16: CheckedContinuation<UInt8, Error>] = [:]
    private var decoder = CobsDecoder()

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    /// Per-handle MLR timers: the batched acknowledgement and the retransmission timeout.
    private var ackTimers: [UInt8: Task<Void, Never>] = [:]
    private var retransmitTimers: [UInt8: Task<Void, Never>] = [:]

    /// Long enough for the user to answer iOS's pairing dialog.
    private static let handshakeTimeout: Duration = .seconds(60)
    private static let maxPairingAttempts = 3

    /// MLR (V2) pairs, probed in order: receive is 0x2810 + i and send is 0x2820 + i, as in Gadgetbridge.
    private static let mlrPairs: [(tx: CBUUID, rx: CBUUID)] = (0..<5).map {
        (tx: garminUUID(0x2820 + $0), rx: garminUUID(0x2810 + $0))
    }
    private static let v1Pair = (tx: garminUUID(0x4C80), rx: garminUUID(0xCD28))
    private static let v0Pair = (
        tx: CBUUID(string: "DF334C80-E6A7-D082-274D-78FC66F85E16"),
        rx: CBUUID(string: "4ACBCD28-7425-868E-F447-915C8F00D0CB")
    )

    /// The file transfer services Gadgetbridge rotates through (FILE_TRANSFER_2 ... FILE_TRANSFER_E).
    private static let fileTransferServices: [UInt16] = [0x2018, 0x4018, 0x6018, 0xa018, 0xc018, 0xe018]

    public init(peripheralID: UUID) {
        self.peripheralID = peripheralID
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: LinkState.self)
        let (frameStream, frameContinuation) = AsyncStream.makeStream(of: Data.self)
        states = stateStream
        incomingFrames = frameStream
        stateSink = stateContinuation
        frameSink = frameContinuation
        stateContinuation.yield(.disconnected)
        super.init()
    }

    public func connect() async throws {
        switch state {
        case .disconnected, .failed: break
        default: throw GarminLinkError.failed("link is already in use")
        }
        pairingAttempts = 0
        setState(.connecting)
        let central = GarminCentral.shared
        await central.ready()
        guard central.manager.state == .poweredOn else {
            end(in: .failed("Bluetooth is off or not allowed"))
            throw GarminLinkError.failed("Bluetooth is off or not allowed")
        }
        guard let peripheral = central.peripheral(for: peripheralID) else {
            end(in: .failed("watch is not known to this phone"))
            throw GarminLinkError.unknownWatch
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.links[peripheralID] = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            central.manager.connect(peripheral)
        }
    }

    public func disconnect() async {
        end(in: .disconnected)
    }

    /// Sends one GFDI frame. Only allowed once the link is `.ready`.
    public func send(_ gfdiFrame: Data) async throws {
        guard case .ready = state else { throw GarminLinkError.notReady }
        let encoded = Cobs.encode(gfdiFrame)
        if let handle = gfdiHandle {
            for packet in queue(encoded, on: handle) { write(packet) }
        } else {
            // V1 and V0 have no packet header, so the whole write is payload.
            for chunk in chunked(encoded, size: maxWrite) { write(chunk) }
        }
    }

    // MARK: - Connection lifecycle

    /// Tears the link down, moves to `newState`, and fails a pending `connect()`.
    private func end(in newState: LinkState) {
        watchdog?.cancel()
        watchdog = nil
        (Array(ackTimers.values) + Array(retransmitTimers.values)).forEach { $0.cancel() }
        ackTimers = [:]
        retransmitTimers = [:]
        channels = [:]
        gfdiHandle = nil
        serviceSinks.values.forEach { $0.finish() }
        serviceSinks = [:]
        plainHandles = []
        openServices = []
        let waiting = Array(openRequests.values)
        openRequests = [:]
        waiting.forEach { $0.resume(throwing: GarminLinkError.notReady) }
        outbox = []
        decoder = CobsDecoder()
        handshake = GFDIHandshake()
        lastHandshakeWrite = nil
        characteristics = [:]
        tx = nil
        GarminCentral.shared.links[peripheralID] = nil
        if let peripheral {
            peripheral.delegate = nil
            GarminCentral.shared.manager.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        setState(newState)
        if let continuation = connectContinuation {
            connectContinuation = nil
            var message = "disconnected"
            if case let .failed(reason) = newState { message = reason }
            continuation.resume(throwing: GarminLinkError.failed(message))
        }
    }

    private func fail(_ message: String) {
        guard peripheral != nil else { return }
        end(in: .failed(message))
    }

    private func setState(_ newState: LinkState) {
        state = newState
        stateSink.yield(newState)
    }

    private func setReady(protocolVersion: Int) {
        watchdog?.cancel()
        watchdog = nil
        setState(.ready(protocolVersion: protocolVersion, maxWritePayload: maxWrite))
        connectContinuation?.resume()
        connectContinuation = nil
    }

    // MARK: - Discovery and handshake

    private func findPair() -> (tx: CBCharacteristic, rx: CBCharacteristic, mlr: Bool)? {
        for pair in Self.mlrPairs {
            if let t = characteristics[pair.tx], let r = characteristics[pair.rx] { return (t, r, true) }
        }
        for pair in [Self.v1Pair, Self.v0Pair] {
            if let t = characteristics[pair.tx], let r = characteristics[pair.rx] { return (t, r, false) }
        }
        return nil
    }

    private func startHandshake() {
        setState(.handshaking)
        handshake = GFDIHandshake()
        writeHandshake(MLRControl.closeAllRequest())
        watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: BLEGarminLink.handshakeTimeout)) != nil else { return }
            self?.fail("watch did not complete the GFDI handshake")
        }
    }

    /// Handshake writes use write-with-response. That is the access a bonded or encrypted watch rejects until
    /// iOS has paired, so a rejected write is retried after the user has had time to answer the dialog.
    private func writeHandshake(_ data: Data) {
        guard let peripheral, let tx else { return }
        lastHandshakeWrite = data
        peripheral.writeValue(data, for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    private static func isPairingRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CBATTErrorDomain else { return false }
        return nsError.code == CBATTError.Code.insufficientEncryption.rawValue
            || nsError.code == CBATTError.Code.insufficientAuthentication.rawValue
    }

    // MARK: - Receiving

    private func route(_ data: Data) {
        guard usesMLR else {
            deliver(decoder.feed(data))
            return
        }
        if data.first == 0 {
            control(data)
            return
        }
        guard let first = data.first else { return }
        // As Gadgetbridge (#5476): a plain handle byte can have the high bit set too, so MLR is tried first and
        // anything no MLR channel takes is read as `[handle] payload`.
        let handle = (first >> 4) & 0x07
        guard first & 0x80 != 0, var mlr = channels[handle] else {
            if plainHandles.contains(first) {
                serviceSinks[first]?.yield(data.dropFirst())
            } else {
                Self.log("dropped packet len=\(data.count) head=\(data.prefix(8).hexString)")
            }
            return
        }
        let received = mlr.receive(data)
        channels[handle] = mlr
        for packet in received.outgoing { write(packet) }
        switch received.ack {
        case .delayed: startAckTimer(handle)
        case .sent: ackTimers.removeValue(forKey: handle)?.cancel()
        case .none: break
        }
        if received.acknowledgedNew { restartRetransmitTimer(handle) }
        for message in received.messages {
            if handle == gfdiHandle {
                deliver(decoder.feed(message))
            } else {
                serviceSinks[handle]?.yield(message)
            }
        }
    }

    /// Replies on handle 0: the GFDI handshake, and the file transfer services the watch opens or closes.
    private func control(_ data: Data) {
        if let next = handshake.receive(data) { writeHandshake(next) }
        switch handshake.step {
        case let .open(handle) where gfdiHandle == nil:
            gfdiHandle = handle
            channels[handle] = MLRChannel(handle: handle, maxWrite: maxWrite)
            setReady(protocolVersion: 2)
        case let .refused(status):
            fail("watch refused the GFDI channel (status \(status))")
        default:
            break
        }
        switch MLRControl.decode(data) {
        case let .register(service, status, handle, reliable)? where service != MLRControl.gfdiService:
            Self.log("register reply service=\(String(service, radix: 16)) status=\(status) handle=\(handle) reliable=\(reliable) raw=\(data.hexString)")
            guard let waiting = openRequests.removeValue(forKey: service) else { return }
            if status == 0 {
                // As Gadgetbridge: the watch decides. Reliable handles run MLR, the others carry `[handle] payload`.
                // The reply's handle byte carries the MLR flag (e.g. 0x83), but MLR packets only carry its low
                // three bits, so reliable channels are keyed by those.
                if reliable {
                    let key = handle & 0x07
                    channels[key] = MLRChannel(handle: key, maxWrite: maxWrite)
                    waiting.resume(returning: key)
                } else {
                    plainHandles.insert(handle)
                    waiting.resume(returning: handle)
                }
            } else {
                openServices.remove(service)
                waiting.resume(throwing: GarminLinkError.failed("watch refused the file transfer (status \(status))"))
            }
        // Only file services this link opened; GFDI closes (e.g. leftovers of a previous client) must not touch them.
        case let .closeHandle(service, handle)? where service != MLRControl.gfdiService && openServices.contains(service):
            Self.log("close handle service=\(String(service, radix: 16)) handle=\(handle)")
            // A plain handle closes under its own byte; a reliable one under its low three bits.
            let key = plainHandles.remove(handle) != nil ? handle : handle & 0x07
            channels[key] = nil
            ackTimers.removeValue(forKey: key)?.cancel()
            retransmitTimers.removeValue(forKey: key)?.cancel()
            openServices.remove(service)
            serviceSinks.removeValue(forKey: key)?.finish()
        default:
            break
        }
    }

    private func deliver(_ frames: [Data]) {
        for frame in frames { frameSink.yield(frame) }
    }

    // MARK: - Writing

    private func write(_ packet: Data) {
        outbox.append(packet)
        flush()
    }

    /// CoreBluetooth drops write-without-response when its buffer is full, so only write while it has room.
    private func flush() {
        guard let peripheral, let tx else { return }
        while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(outbox.removeFirst(), for: tx, type: .withoutResponse)
        }
    }

    /// Queues a message on an MLR handle and returns the packets that fit its window now. Starts the
    /// retransmission timer when these are the first packets in flight.
    private func queue(_ message: Data, on handle: UInt8) -> [Data] {
        guard var mlr = channels[handle] else { return [] }
        let wasIdle = mlr.unacknowledgedCount == 0
        let packets = mlr.send(message)
        channels[handle] = mlr
        if wasIdle, mlr.unacknowledgedCount > 0 { restartRetransmitTimer(handle) }
        return packets
    }

    /// Sends a raw payload on a file transfer service. Service payloads are not COBS-framed.
    func sendService(_ payload: Data, on handle: UInt8) {
        if plainHandles.contains(handle) {
            for chunk in chunked(payload, size: maxWrite - 1) { write(Data([handle]) + chunk) }
        } else {
            for packet in queue(payload, on: handle) { write(packet) }
        }
    }

    private static let logger = Logger(subsystem: "com.niklasarnitz.opengarmin", category: "transport")

    /// Transport diagnostics: unified logging, and stdout for `devicectl --console`.
    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[transport] \(message)")
    }

    /// Acknowledges the watch's packets after `MLRChannel.ackDelay`, unless an acknowledgement goes out first.
    private func startAckTimer(_ handle: UInt8) {
        ackTimers[handle]?.cancel()
        ackTimers[handle] = Task { [weak self] in
            guard (try? await Task.sleep(for: MLRChannel.ackDelay)) != nil,
                  let self, var mlr = self.channels[handle] else { return }
            let ack = mlr.ackTimedOut()
            self.channels[handle] = mlr
            self.ackTimers[handle] = nil
            self.write(ack)
        }
    }

    /// Restarts the handle's retransmission timer, or stops it when nothing is in flight. On expiry the channel backs
    /// off, resends what is unacknowledged, and the timer runs again with the longer timeout.
    private func restartRetransmitTimer(_ handle: UInt8) {
        retransmitTimers.removeValue(forKey: handle)?.cancel()
        guard let mlr = channels[handle], mlr.unacknowledgedCount > 0 else { return }
        let timeout = mlr.retransmissionTimeout
        retransmitTimers[handle] = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil,
                  let self, var mlr = self.channels[handle] else { return }
            let packets = mlr.retransmissionTimedOut()
            self.channels[handle] = mlr
            for packet in packets { self.write(packet) }
            self.restartRetransmitTimer(handle)
        }
    }

    // MARK: - File transfer services

    public func openFileTransfer() async throws -> any GarminServiceChannel {
        guard case .ready = state else { throw GarminLinkError.notReady }
        guard let code = Self.fileTransferServices.first(where: { !openServices.contains($0) }) else {
            throw GarminLinkError.failed("no file transfer service is free")
        }
        openServices.insert(code)
        let handle: UInt8 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt8, Error>) in
            openRequests[code] = continuation
            let request = MLRControl.registerRequest(service: code, reliable: true)
            Self.log("register request service=\(String(code, radix: 16)) raw=\(request.hexString)")
            write(request)
        }
        let (stream, sink) = AsyncStream.makeStream(of: Data.self)
        serviceSinks[handle] = sink
        return BLEServiceChannel(link: self, handle: handle, incoming: stream)
    }

    // MARK: - Called by GarminCentral

    func didConnect() {
        peripheral?.discoverServices(GarminCentral.serviceUUIDs)
    }

    func didFail(_ error: Error?) {
        fail("could not connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func didDisconnect(_ error: Error?) {
        guard peripheral != nil else { return }
        if case .ready = state {
            end(in: .disconnected)
        } else {
            fail("link dropped during connect: \(error?.localizedDescription ?? "unknown error")")
        }
    }
}

/// One file transfer service on a BLE link. Payloads go to the watch on its handle, and `incoming` finishes when the
/// watch closes the handle or the link ends.
@MainActor
public final class BLEServiceChannel: GarminServiceChannel {
    public nonisolated let incoming: AsyncStream<Data>
    private weak var link: BLEGarminLink?
    private let handle: UInt8

    fileprivate init(link: BLEGarminLink, handle: UInt8, incoming: AsyncStream<Data>) {
        self.link = link
        self.handle = handle
        self.incoming = incoming
    }

    public func send(_ payload: Data) async throws {
        guard let link else { throw GarminLinkError.notReady }
        link.sendService(payload, on: handle)
    }
}

extension BLEGarminLink: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return fail(error.localizedDescription) }
        let services = peripheral.services ?? []
        if services.isEmpty { return fail("watch exposes no Garmin services") }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { return fail(error.localizedDescription) }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        guard let pair = findPair() else { return fail("watch exposes no Garmin GFDI characteristics") }
        tx = pair.tx
        usesMLR = pair.mlr
        peripheral.setNotifyValue(true, for: pair.rx)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { return fail(error.localizedDescription) }
        maxWrite = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        if usesMLR {
            startHandshake()
        } else {
            setReady(protocolVersion: 1)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { return fail(error.localizedDescription) }
        guard let value = characteristic.value else { return }
        route(value)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        // Only handshake writes use write-with-response, so a failed one is a handshake failure.
        guard Self.isPairingRequired(error), pairingAttempts < Self.maxPairingAttempts,
              let data = lastHandshakeWrite else {
            return fail("handshake write failed: \(error.localizedDescription)")
        }
        pairingAttempts += 1
        Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            self?.writeHandshake(data)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }
}
