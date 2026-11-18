import Foundation
import GarminCore

/// A RESPONSE (5000) frame whose body depends on the message it answers.
///
/// Typed statuses are parsed from the watch's replies to phone requests, and the same type encodes
/// the phone's ACK to a watch request. `response` is the frame body (`originalType | status | body`).
public protocol GFDIResponseMessage: GFDIIncoming, GFDIOutgoing, Sendable {
    /// The message type this RESPONSE answers (`originalType` on the wire).
    static var originalType: GFDIMessageID { get }
    var status: GFDIStatus { get }
    /// Decodes the body that follows the status byte.
    init(status: GFDIStatus, body: inout ByteReader) throws
    func writeBody(into writer: inout ByteWriter)
}

public extension GFDIResponseMessage {
    static var messageID: GFDIMessageID { .response }

    var response: GFDIResponse {
        var w = ByteWriter()
        writeBody(into: &w)
        return GFDIResponse(originalType: Self.originalType.rawValue, status: status, body: w.data)
    }

    func encodePayload(into writer: inout ByteWriter) {
        response.encodePayload(into: &writer)
    }

    init(payload reader: inout ByteReader) throws {
        let response = try GFDIResponse(payload: &reader)
        guard response.originalType == Self.originalType.rawValue else {
            throw GFDIError.unexpectedMessage(response.originalType)
        }
        var body = ByteReader(response.body)
        try self.init(status: response.status, body: &body)
    }
}

public extension GFDIResponse {
    /// A plain ACK (status 0) for `message` with an optional body.
    static func ack(_ message: GFDIMessageID, body: Data = Data()) -> GFDIResponse {
        GFDIResponse(originalType: message.rawValue, status: .ack, body: body)
    }
}

/// A frame the parser does not model: unknown types, known types without a typed model, and payloads
/// that fail to decode. Carries the raw type and payload so callers can log or inspect it.
public struct GFDIUnhandled: GFDIIncoming, Sendable, Equatable {
    /// Unknown types have no `GFDIMessageID`, so this is never used to decode. Build values with `init(messageType:payload:)`.
    public static let messageID = GFDIMessageID.response
    public var messageType: UInt16
    public var payload: Data

    public init(messageType: UInt16, payload: Data) {
        self.messageType = messageType
        self.payload = payload
    }

    public init(payload reader: inout ByteReader) throws {
        throw GFDIError.malformed("GFDIUnhandled is built by GFDIMessageParser, not decoded from a payload")
    }

    public var frame: GFDIFrame { GFDIFrame(messageType: messageType, payload: payload) }
}

extension ByteReader {
    mutating func readEnum<E: RawRepresentable>(_: E.Type) throws -> E where E.RawValue == UInt8 {
        let raw = try readUInt8()
        guard let value = E(rawValue: raw) else { throw GFDIError.malformed("\(E.self) value \(raw)") }
        return value
    }

    mutating func readRemainingData() -> Data { Data(readRest()) }
}

/// Stops a typed status from decoding a NAK body that Gadgetbridge does not define.
func requireAck(_ status: GFDIStatus, for message: GFDIMessageID) throws {
    guard status == .ack else { throw GFDIError.malformed("\(message) status \(status) has no body") }
}
