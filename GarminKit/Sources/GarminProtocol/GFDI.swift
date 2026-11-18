import Foundation
import GarminCore

// CONTRACT (owned by the integrator; message agents may add cases/helpers but must not change signatures).
//
// A GFDI frame on the wire (after COBS / MLR unwrapping) is:
//   u16 length (whole frame incl. length and CRC) | u16 messageType | payload | u16 CRC (GarminCRC over everything before it)
// When bit 15 of messageType is set, the low byte is the type offset from 5000 and bits 8...14 are a sequence number.

public enum GFDIMessageID: UInt16, Sendable, CaseIterable {
    case response = 5000
    case downloadRequest = 5002
    case uploadRequest = 5003
    case fileTransferData = 5004
    case createFile = 5005
    case deleteFile = 5006
    case filter = 5007
    case setFileFlag = 5008
    case fileAvailable = 5009
    case fitDefinition = 5011
    case fitData = 5012
    case weatherRequest = 5014
    case weatherAlert = 5015
    case liveTrackTrackingRequest = 5016
    case ephemerisDataRequest = 5019
    case ephemerisData = 5020
    case cancelFileTransfer = 5022
    case batteryStatus = 5023
    case deviceInformation = 5024
    case liveTrackStopTracking = 5025
    case deviceSettings = 5026
    case queuedDownload = 5027
    case ephemerisEpoRequest = 5028
    case ephemerisEpoData = 5029
    case systemEvent = 5030
    case supportedFileTypesRequest = 5031
    case notificationUpdate = 5033
    case notificationControl = 5034
    case notificationData = 5035
    case notificationSubscription = 5036
    case synchronization = 5037
    case findMyPhoneRequest = 5039
    case findMyPhoneCancel = 5040
    case musicControl = 5041
    case musicControlCapabilities = 5042
    case protobufRequest = 5043
    case protobufResponse = 5044
    case cancelProtobuf = 5045
    case liveTrackAutoStart = 5046
    case liveTrackAutoStartCancel = 5047
    case liveTrackAutoStartFailure = 5048
    case musicControlEntityUpdate = 5049
    case configuration = 5050
    case currentTimeRequest = 5052
    case compressedFileData = 5054
    case authNegotiation = 5101
    case ltkReconnect = 5102
    case secureSession = 5111
}

/// ACK/NAK status inside a RESPONSE (5000) frame. rawValue = wire byte.
public enum GFDIStatus: UInt8, Sendable {
    case ack = 0, nak, unsupported, decodeError, crcError, lengthError
}

public enum GFDIError: Error, Equatable {
    case tooShort
    case lengthMismatch(declared: Int, actual: Int)
    case crcMismatch(expected: UInt16, actual: UInt16)
    case unexpectedMessage(UInt16)
    case malformed(String)
}

/// A decoded frame: message type (sequence bits stripped, 5000-offset form normalised) and raw payload.
public struct GFDIFrame: Sendable, Equatable {
    public var messageType: UInt16
    public var payload: Data

    public init(messageType: UInt16, payload: Data) {
        self.messageType = messageType
        self.payload = payload
    }

    public var id: GFDIMessageID? { GFDIMessageID(rawValue: messageType) }

    /// Serialises length + type + payload + CRC.
    public func encoded() -> Data {
        var w = ByteWriter()
        w.writeUInt16(0) // patched below
        w.writeUInt16(messageType)
        w.writeData(payload)
        w.setUInt16(UInt16(w.count + 2), at: 0)
        w.writeUInt16(GarminCRC.compute(w.bytes))
        return w.data
    }

    public static func decode(_ data: Data) throws -> GFDIFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { throw GFDIError.tooShort }
        let declared = Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        guard declared == bytes.count else { throw GFDIError.lengthMismatch(declared: declared, actual: bytes.count) }
        let expected = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        let actual = GarminCRC.compute(bytes[0..<(bytes.count - 2)])
        guard expected == actual else { throw GFDIError.crcMismatch(expected: expected, actual: actual) }
        var type = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        if type & 0x8000 != 0 { type = (type & 0xFF) + 5000 }
        return GFDIFrame(messageType: type, payload: Data(bytes[4..<(bytes.count - 2)]))
    }
}

/// Phone -> watch message.
public protocol GFDIOutgoing: Sendable {
    static var messageID: GFDIMessageID { get }
    func encodePayload(into writer: inout ByteWriter)
}

/// Watch -> phone message.
public protocol GFDIIncoming: Sendable {
    static var messageID: GFDIMessageID { get }
    init(payload: inout ByteReader) throws
}

public extension GFDIOutgoing {
    func frame() -> GFDIFrame {
        var w = ByteWriter()
        encodePayload(into: &w)
        return GFDIFrame(messageType: Self.messageID.rawValue, payload: w.data)
    }
}

public extension GFDIIncoming {
    init(frame: GFDIFrame) throws {
        guard frame.messageType == Self.messageID.rawValue else { throw GFDIError.unexpectedMessage(frame.messageType) }
        var r = ByteReader(frame.payload)
        try self.init(payload: &r)
    }
}

/// RESPONSE (5000) frame: `u16 originalType | u8 status | message-specific bytes`.
/// Both directions: the phone ACKs watch requests with this, and the watch ACKs phone requests.
public struct GFDIResponse: GFDIIncoming, GFDIOutgoing, Equatable {
    public static let messageID = GFDIMessageID.response
    public var originalType: UInt16
    public var status: GFDIStatus
    /// Message-specific trailing bytes (e.g. DeviceInformation reply, DownloadRequest status...).
    public var body: Data

    public init(originalType: UInt16, status: GFDIStatus = .ack, body: Data = Data()) {
        self.originalType = originalType
        self.status = status
        self.body = body
    }

    public init(payload r: inout ByteReader) throws {
        originalType = try r.readUInt16()
        status = GFDIStatus(rawValue: try r.readUInt8()) ?? .nak
        body = Data(r.readRest())
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt16(originalType)
        w.writeUInt8(status.rawValue)
        w.writeData(body)
    }
}
