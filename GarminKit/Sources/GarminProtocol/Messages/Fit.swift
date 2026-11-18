import Foundation
import GarminCore

// FIT definitions and data. The payload is a FIT record stream. Decoding and encoding it belongs to GarminFIT,
// so these types carry the raw bytes.

/// FIT_DEFINITION (5011). Sent by both sides. Answer a watch definition with `acknowledgement()`.
public struct GFDIFitDefinition: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.fitDefinition
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(payload r: inout ByteReader) throws {
        data = r.readRemainingData()
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeData(data)
    }

    public func acknowledgement() -> GFDIResponse {
        GFDIFitDefinitionStatus(result: .applied).response
    }
}

/// RESPONSE (5011). Body: `result (u8)`.
public struct GFDIFitDefinitionStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable { case applied, notUnique, outOfRange, notReady }

    public static let originalType = GFDIMessageID.fitDefinition
    public var status: GFDIStatus
    public var result: Result

    public init(status: GFDIStatus = .ack, result: Result) {
        self.status = status
        self.result = result
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        result = try r.readEnum(Result.self)
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
    }
}

/// FIT_DATA (5012). Sent by both sides. Answer a watch data message with `acknowledgement()`.
public struct GFDIFitData: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.fitData
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(payload r: inout ByteReader) throws {
        data = r.readRemainingData()
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeData(data)
    }

    public func acknowledgement() -> GFDIResponse {
        GFDIFitDataStatus(result: .applied).response
    }
}

/// RESPONSE (5012). Body: `result (u8)`.
public struct GFDIFitDataStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable { case applied, noDefinition, mismatch, notReady }

    public static let originalType = GFDIMessageID.fitData
    public var status: GFDIStatus
    public var result: Result

    public init(status: GFDIStatus = .ack, result: Result) {
        self.status = status
        self.result = result
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        result = try r.readEnum(Result.self)
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
    }
}
