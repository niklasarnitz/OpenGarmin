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
public final class BLEGarminLink: NSObject, GarminLink {
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
    private var channel: MLRChannel?
    private var decoder = CobsDecoder()

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var retransmitTask: Task<Void, Never>?

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
        if var mlr = channel {
            let packets = mlr.send(encoded)
            channel = mlr
            for packet in packets { write(packet) }
            scheduleRetransmit()
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
        retransmitTask?.cancel()
        retransmitTask = nil
        channel = nil
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
            if let next = handshake.receive(data) { writeHandshake(next) }
            switch handshake.step {
            case let .open(handle) where channel == nil:
                channel = MLRChannel(handle: handle, maxWrite: maxWrite)
                setReady(protocolVersion: 2)
            case let .refused(status):
                fail("watch refused the GFDI channel (status \(status))")
            default:
                break
            }
            return
        }
        guard var mlr = channel else { return }
        let received = mlr.receive(data)
        channel = mlr
        for packet in received.outgoing { write(packet) }
        for message in received.messages { deliver(decoder.feed(message)) }
        scheduleRetransmit()
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

    /// Resends unacknowledged MLR packets once a second until the watch has acknowledged everything.
    private func scheduleRetransmit() {
        guard retransmitTask == nil, (channel?.unacknowledgedCount ?? 0) > 0 else { return }
        retransmitTask = Task { [weak self] in
            while true {
                guard (try? await Task.sleep(for: .seconds(1))) != nil,
                      let self, let channel = self.channel, channel.unacknowledgedCount > 0 else { break }
                for packet in channel.retransmit() { self.write(packet) }
            }
            self?.retransmitTask = nil
        }
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
