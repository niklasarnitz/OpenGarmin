import Foundation

// CONTRACT (owned by the integrator; the transport agent implements it, must not change these signatures).

public enum LinkState: Sendable, Equatable {
    case disconnected
    case connecting
    /// BLE connected, characteristics discovered, MLR/V1 handshake running.
    case handshaking
    /// GFDI channel ready; `send` is allowed.
    case ready(protocolVersion: Int, maxWritePayload: Int)
    case failed(String)
}

public struct DiscoveredWatch: Sendable, Hashable, Identifiable {
    /// CoreBluetooth peripheral identifier (stable per phone).
    public var id: UUID
    public var name: String
    public var rssi: Int
    public init(id: UUID, name: String, rssi: Int) { self.id = id; self.name = name; self.rssi = rssi }
}

/// A bidirectional GFDI pipe to one watch. Frames are complete GFDI frames
/// (length | type | payload | crc) with COBS and MLR wrapping already removed.
public protocol GarminLink: AnyObject, Sendable {
    var states: AsyncStream<LinkState> { get }
    var incomingFrames: AsyncStream<Data> { get }
    func connect() async throws
    func disconnect() async
    func send(_ gfdiFrame: Data) async throws
}
