import Foundation

/// Splits data into pieces of at most `size` bytes. Empty input yields no pieces.
func chunked(_ data: Data, size: Int) -> [Data] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: size).map {
        Data(bytes[$0..<min($0 + size, bytes.count)])
    }
}

/// One multi-link reliable (MLR) data frame. Wire form: `0x80 | handle << 4 | reqNum >> 2`, then
/// `(reqNum & 3) << 6 | seqNum`, then the payload. `reqNum` acknowledges the peer's packets: it is the
/// next sequence number this side expects to receive.
struct MLRPacket: Equatable, Sendable {
    var handle: UInt8
    var reqNum: UInt8
    var seqNum: UInt8
    var payload: Data

    init(handle: UInt8, reqNum: UInt8, seqNum: UInt8, payload: Data = Data()) {
        self.handle = handle
        self.reqNum = reqNum
        self.seqNum = seqNum
        self.payload = payload
    }

    func encoded() -> Data {
        let first: UInt8 = 0x80 | ((handle & 0x07) << 4) | ((reqNum >> 2) & 0x0F)
        let second: UInt8 = ((reqNum & 0x03) << 6) | (seqNum & 0x3F)
        return Data([first, second]) + payload
    }

    /// Nil unless the data is at least two bytes and has the MLR flag set.
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] & 0x80 != 0 else { return nil }
        handle = (bytes[0] >> 4) & 0x07
        reqNum = ((bytes[0] & 0x0F) << 2) | (bytes[1] >> 6)
        seqNum = bytes[1] & 0x3F
        payload = Data(bytes[2...])
    }
}

/// Sans-IO reliable sender and receiver for one MLR handle, following Gadgetbridge's MlrCommunicator.
///
/// The caller writes the returned packets, feeds every inbound packet to `receive`, and calls `retransmit`
/// on a timer while `unacknowledgedCount > 0`. Differences from Gadgetbridge: the send window is fixed
/// (no backoff), and every in-sequence data packet is acknowledged at once instead of batched.
struct MLRChannel: Sendable {
    struct Received: Equatable, Sendable {
        /// In-order payloads from the peer. Each is a piece of a COBS-encoded GFDI frame.
        var messages: [Data] = []
        /// Packets to write: acknowledgements, and queued data that the acknowledgements made room for.
        var outgoing: [Data] = []
    }

    static let sequenceModulus: UInt8 = 64
    static let windowSize = 32

    let handle: UInt8
    /// Payload bytes per packet: the write size minus the 2-byte header.
    private let maxPayload: Int
    private var queue: [Data] = []
    private var inFlight: [Sent] = []
    private var nextSendSeq: UInt8 = 0
    private var nextRecvSeq: UInt8 = 0

    private struct Sent: Sendable {
        let seq: UInt8
        let payload: Data
    }

    /// - Parameter maxWrite: the largest BLE write, header included.
    init(handle: UInt8, maxWrite: Int) {
        precondition(maxWrite > 2, "a write must hold the 2-byte MLR header and at least one payload byte")
        self.handle = handle & 0x07
        maxPayload = maxWrite - 2
    }

    var unacknowledgedCount: Int { inFlight.count }

    /// Queues a message and returns the packets that fit the window now.
    mutating func send(_ message: Data) -> [Data] {
        queue += chunked(message, size: maxPayload)
        return transmit()
    }

    /// Everything unacknowledged, stamped with the current ack.
    func retransmit() -> [Data] {
        inFlight.map { packet($0.seq, $0.payload) }
    }

    /// Handles one inbound packet. Packets for another handle, or without the MLR flag, are ignored.
    mutating func receive(_ data: Data) -> Received {
        guard let packet = MLRPacket(decoding: data), packet.handle == handle else { return Received() }
        acknowledge(upTo: packet.reqNum)
        var result = Received()
        if !packet.payload.isEmpty {
            if packet.seqNum == nextRecvSeq {
                nextRecvSeq = (nextRecvSeq + 1) % Self.sequenceModulus
                result.messages.append(packet.payload)
            }
            // Out-of-sequence packets are re-acked with the sequence number still expected.
            result.outgoing.append(ackPacket)
        }
        result.outgoing += transmit()
        return result
    }

    private var ackPacket: Data {
        MLRPacket(handle: handle, reqNum: nextRecvSeq, seqNum: 0).encoded()
    }

    private func packet(_ seq: UInt8, _ payload: Data) -> Data {
        MLRPacket(handle: handle, reqNum: nextRecvSeq, seqNum: seq, payload: payload).encoded()
    }

    private mutating func transmit() -> [Data] {
        var out: [Data] = []
        while !queue.isEmpty, inFlight.count < Self.windowSize {
            let payload = queue.removeFirst()
            out.append(packet(nextSendSeq, payload))
            inFlight.append(Sent(seq: nextSendSeq, payload: payload))
            nextSendSeq = (nextSendSeq + 1) % Self.sequenceModulus
        }
        return out
    }

    /// Drops every packet the peer's `reqNum` covers. A reqNum that acks nothing new, or more than is in flight, is ignored.
    private mutating func acknowledge(upTo reqNum: UInt8) {
        let oldest = inFlight.first?.seq ?? nextSendSeq
        let count = (Int(reqNum) - Int(oldest) + Int(Self.sequenceModulus)) % Int(Self.sequenceModulus)
        guard count > 0, count <= inFlight.count else { return }
        inFlight.removeFirst(count)
    }
}
