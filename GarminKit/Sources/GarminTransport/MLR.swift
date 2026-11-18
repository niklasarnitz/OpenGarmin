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
/// The caller writes the returned packets and feeds every inbound packet to `receive`. It also runs two timers:
/// - the acknowledgement timer: when `receive` returns `ack == .delayed`, call `ackTimedOut()` after `ackDelay`
///   unless a later `receive` returns `.sent` first. Acknowledgements are batched: one goes out immediately only
///   once `ackThreshold` packets are unacknowledged or a packet arrives out of sequence.
/// - the retransmission timer: (re)start it with `retransmissionTimeout` when `send` puts the first packet in
///   flight or `receive` returns `acknowledgedNew`, stop it when nothing is in flight, and call
///   `retransmissionTimedOut()` when it fires. Each timeout doubles the timeout (up to 20 s) and halves the send
///   window; any new acknowledgement resets both.
struct MLRChannel: Sendable {
    enum AckAction: Equatable, Sendable {
        /// Nothing to acknowledge (no data arrived).
        case none
        /// An acknowledgement is in `outgoing`; cancel a pending acknowledgement timer.
        case sent
        /// (Re)start the acknowledgement timer.
        case delayed
    }

    struct Received: Equatable, Sendable {
        /// In-order payloads from the peer. Each is a piece of a COBS-encoded GFDI frame.
        var messages: [Data] = []
        /// Packets to write: acknowledgements, and queued data that the acknowledgements made room for.
        var outgoing: [Data] = []
        var ack: AckAction = .none
        /// The peer acknowledged packets this side sent; restart the retransmission timer.
        var acknowledgedNew = false
    }

    static let sequenceModulus: UInt8 = 64
    static let maxWindow = 32
    static let ackThreshold = 5
    static let ackDelay: Duration = .milliseconds(20)
    static let initialRetransmissionTimeout: Duration = .seconds(1)
    static let maxRetransmissionTimeout: Duration = .seconds(20)

    let handle: UInt8
    /// Payload bytes per packet: the write size minus the 2-byte header.
    private let maxPayload: Int
    private var queue: [Data] = []
    private var inFlight: [Sent] = []
    private var nextSendSeq: UInt8 = 0
    private var nextRecvSeq: UInt8 = 0
    /// The reqNum of the last acknowledgement-only packet sent.
    private var lastSentAck: UInt8 = 0
    private(set) var window = MLRChannel.maxWindow
    private(set) var retransmissionTimeout = MLRChannel.initialRetransmissionTimeout

    private struct Sent: Sendable {
        let seq: UInt8
        let payload: Data
        /// The reqNum the packet carried when first sent; retransmissions repeat it, as Gadgetbridge does.
        let reqNum: UInt8
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

    /// Handles one inbound packet. Packets for another handle, or without the MLR flag, are ignored.
    mutating func receive(_ data: Data) -> Received {
        guard let packet = MLRPacket(decoding: data), packet.handle == handle else { return Received() }
        var result = Received()
        result.acknowledgedNew = acknowledge(upTo: packet.reqNum)
        if !packet.payload.isEmpty {
            if packet.seqNum == nextRecvSeq {
                nextRecvSeq = (nextRecvSeq + 1) % Self.sequenceModulus
                result.messages.append(packet.payload)
                let unacknowledged = Self.distance(from: lastSentAck, to: nextRecvSeq)
                if unacknowledged >= Self.ackThreshold {
                    result.outgoing.append(makeAck())
                    result.ack = .sent
                } else {
                    result.ack = .delayed
                }
            } else {
                // The sender should not send these; acknowledge the expected number again so it retransmits.
                result.outgoing.append(makeAck())
                result.ack = .sent
            }
        }
        result.outgoing += transmit()
        return result
    }

    /// The acknowledgement timer fired: acknowledge everything received so far.
    mutating func ackTimedOut() -> Data {
        makeAck()
    }

    /// The retransmission timer fired: back off and resend everything unacknowledged.
    mutating func retransmissionTimedOut() -> [Data] {
        retransmissionTimeout = min(retransmissionTimeout * 2, Self.maxRetransmissionTimeout)
        window = max(1, window / 2)
        return inFlight.map { MLRPacket(handle: handle, reqNum: $0.reqNum, seqNum: $0.seq, payload: $0.payload).encoded() }
    }

    private mutating func makeAck() -> Data {
        lastSentAck = nextRecvSeq
        return MLRPacket(handle: handle, reqNum: nextRecvSeq, seqNum: 0).encoded()
    }

    private mutating func transmit() -> [Data] {
        var out: [Data] = []
        while !queue.isEmpty, inFlight.count < window {
            let payload = queue.removeFirst()
            out.append(MLRPacket(handle: handle, reqNum: nextRecvSeq, seqNum: nextSendSeq, payload: payload).encoded())
            inFlight.append(Sent(seq: nextSendSeq, payload: payload, reqNum: nextRecvSeq))
            nextSendSeq = (nextSendSeq + 1) % Self.sequenceModulus
        }
        return out
    }

    /// Drops every packet the peer's `reqNum` covers and recovers from a backoff. A reqNum that acks nothing new,
    /// or more than is in flight, is ignored. Returns whether anything was acknowledged.
    private mutating func acknowledge(upTo reqNum: UInt8) -> Bool {
        let oldest = inFlight.first?.seq ?? nextSendSeq
        let count = Self.distance(from: oldest, to: reqNum)
        guard count > 0, count <= inFlight.count else { return false }
        inFlight.removeFirst(count)
        retransmissionTimeout = Self.initialRetransmissionTimeout
        window = min(window + count, Self.maxWindow)
        return true
    }

    private static func distance(from a: UInt8, to b: UInt8) -> Int {
        (Int(b) - Int(a) + Int(sequenceModulus)) % Int(sequenceModulus)
    }
}
