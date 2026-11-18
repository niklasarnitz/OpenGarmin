import Foundation
import GarminCore

// Protobuf transport (Gadgetbridge `ProtobufMessage`, `ProtobufStatusMessage`, `ProtocolBufferHandler`).
// The bytes are a serialized `Smart` message. Encoding and decoding those bytes belongs to GarminProtobuf;
// this file handles chunking and the status bookkeeping.

/// One chunk of a PROTOBUF_REQUEST (5043) or PROTOBUF_RESPONSE (5044).
/// Layout: `requestID (u16) | dataOffset (u32) | totalLength (u32) | chunkLength (u32) | bytes`.
public struct GFDIProtobufChunk: Sendable, Equatable {
    public var requestID: UInt16
    public var dataOffset: UInt32
    /// Length of the whole message, which can be longer than this chunk.
    public var totalLength: UInt32
    public var data: Data

    public init(requestID: UInt16, dataOffset: UInt32, totalLength: UInt32, data: Data) {
        self.requestID = requestID
        self.dataOffset = dataOffset
        self.totalLength = totalLength
        self.data = data
    }

    init(reader r: inout ByteReader) throws {
        requestID = try r.readUInt16()
        dataOffset = try r.readUInt32()
        totalLength = try r.readUInt32()
        let length = try r.readUInt32()
        data = try r.readData(Int(length))
    }

    /// Splits a serialized message into chunks of at most `maxChunkSize` bytes, in offset order.
    public static func split(requestID: UInt16, bytes: Data, maxChunkSize: Int) -> [GFDIProtobufChunk] {
        let total = UInt32(bytes.count)
        return stride(from: 0, to: bytes.count, by: maxChunkSize).map { start in
            GFDIProtobufChunk(requestID: requestID, dataOffset: UInt32(start), totalLength: total,
                              data: bytes.subdata(in: start..<min(start + maxChunkSize, bytes.count)))
        }
    }

    /// True when this chunk is the whole message (Gadgetbridge `ProtobufMessage.isComplete`).
    public var isComplete: Bool {
        dataOffset == 0 && Int(totalLength) == data.count
    }

    func encode(into w: inout ByteWriter) {
        w.writeUInt16(requestID)
        w.writeUInt32(dataOffset)
        w.writeUInt32(totalLength)
        w.writeUInt32(UInt32(data.count))
        w.writeData(data)
    }

    /// The ACK for a received chunk: a plain ACK when the message is complete, otherwise a status
    /// that keeps the chunk and names its offset, so the sender sends the next one.
    func acknowledgement(for type: GFDIMessageID) -> GFDIResponse {
        if isComplete { return .ack(type) }
        return GFDIProtobufStatus(
            originalType: type, status: .ack, requestID: requestID, dataOffset: dataOffset, chunk: .kept, code: .noError
        ).response
    }
}

/// PROTOBUF_REQUEST (5043). Sent by both sides. Acknowledge a watch chunk with `acknowledgement()`.
public struct GFDIProtobufRequest: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.protobufRequest
    public var chunk: GFDIProtobufChunk

    public init(chunk: GFDIProtobufChunk) {
        self.chunk = chunk
    }

    public init(payload r: inout ByteReader) throws {
        chunk = try GFDIProtobufChunk(reader: &r)
    }

    public func encodePayload(into w: inout ByteWriter) {
        chunk.encode(into: &w)
    }

    public func acknowledgement() -> GFDIResponse {
        chunk.acknowledgement(for: Self.messageID)
    }
}

/// PROTOBUF_RESPONSE (5044). Sent by both sides. Acknowledge a watch chunk with `acknowledgement()`.
public struct GFDIProtobufResponse: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.protobufResponse
    public var chunk: GFDIProtobufChunk

    public init(chunk: GFDIProtobufChunk) {
        self.chunk = chunk
    }

    public init(payload r: inout ByteReader) throws {
        chunk = try GFDIProtobufChunk(reader: &r)
    }

    public func encodePayload(into w: inout ByteWriter) {
        chunk.encode(into: &w)
    }

    public func acknowledgement() -> GFDIResponse {
        chunk.acknowledgement(for: Self.messageID)
    }
}

/// RESPONSE (5000) to a protobuf chunk, for either 5043 or 5044. Body:
/// `requestID (u16) | dataOffset (u32) | chunk status (u8) | code (u8)`.
/// It is a RESPONSE, so it is sent and received as a `GFDIResponse`. `originalType` says which request it answers.
public struct GFDIProtobufStatus: GFDIIncoming, Sendable, Equatable {
    public enum Chunk: UInt8, Sendable, Equatable { case kept = 0, discarded = 1 }

    public enum Code: UInt8, Sendable, Equatable {
        case noError = 0, unknownRequestID = 100, duplicatePacket = 101, missingPacket = 102
        case exceededTotalLength = 103, parseError = 200, unknown = 201
    }

    public static let messageID = GFDIMessageID.response
    public var originalType: GFDIMessageID
    public var status: GFDIStatus
    public var requestID: UInt16
    public var dataOffset: UInt32
    public var chunk: Chunk
    public var code: Code

    public init(originalType: GFDIMessageID, status: GFDIStatus, requestID: UInt16, dataOffset: UInt32,
                chunk: Chunk, code: Code) {
        self.originalType = originalType
        self.status = status
        self.requestID = requestID
        self.dataOffset = dataOffset
        self.chunk = chunk
        self.code = code
    }

    public init(response: GFDIResponse) throws {
        guard let type = GFDIMessageID(rawValue: response.originalType),
              type == .protobufRequest || type == .protobufResponse else {
            throw GFDIError.unexpectedMessage(response.originalType)
        }
        var body = ByteReader(response.body)
        let requestID = try body.readUInt16()
        let dataOffset = try body.readUInt32()
        let chunk = try body.readEnum(Chunk.self)
        let code = try body.readEnum(Code.self)
        self.init(originalType: type, status: response.status, requestID: requestID,
                  dataOffset: dataOffset, chunk: chunk, code: code)
    }

    public init(payload r: inout ByteReader) throws {
        try self.init(response: GFDIResponse(payload: &r))
    }

    /// True when the watch accepted the chunk.
    public var isOK: Bool {
        status == .ack && chunk == .kept && code == .noError
    }

    public var response: GFDIResponse {
        var w = ByteWriter()
        w.writeUInt16(requestID)
        w.writeUInt32(dataOffset)
        w.writeUInt8(chunk.rawValue)
        w.writeUInt8(code.rawValue)
        return GFDIResponse(originalType: originalType.rawValue, status: status, body: w.data)
    }
}

/// Rebuilds chunked protobuf messages for each request ID (Gadgetbridge `ProtocolBufferHandler`).
public struct GFDIProtobufReassembler: Sendable {
    private struct Partial: Sendable {
        var total: Int
        var data: Data
    }

    private var partials: [UInt16: Partial] = [:]

    public init() {}

    /// Feeds one chunk. Returns the whole message when this chunk completes it. A chunk that does not
    /// continue the buffered bytes throws and leaves the buffer as it was.
    public mutating func accept(_ chunk: GFDIProtobufChunk) throws -> Data? {
        if chunk.isComplete {
            partials[chunk.requestID] = nil
            return chunk.data
        }
        if chunk.dataOffset == 0 {
            partials[chunk.requestID] = Partial(total: Int(chunk.totalLength), data: chunk.data)
        } else {
            guard var partial = partials[chunk.requestID] else { return nil }
            guard Int(chunk.dataOffset) == partial.data.count else {
                throw GFDIError.malformed("protobuf #\(chunk.requestID) chunk at \(chunk.dataOffset), expected \(partial.data.count)")
            }
            partial.data.append(chunk.data)
            partials[chunk.requestID] = partial
        }
        guard let partial = partials[chunk.requestID], partial.data.count == partial.total else { return nil }
        partials[chunk.requestID] = nil
        return partial.data
    }
}
