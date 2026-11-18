import Testing
import Foundation
import GarminModels
@testable import GarminProtocol

@Test func protobufChunksReassembleInOrder() throws {
    let bytes = Data([1, 2, 3, 4, 5])
    let chunks = GFDIProtobufChunk.split(requestID: 9, bytes: bytes, maxChunkSize: 2)
    #expect(chunks.map(\.dataOffset) == [0, 2, 4])
    #expect(chunks.map { Array($0.data) } == [[1, 2], [3, 4], [5]])
    #expect(chunks.allSatisfy { $0.totalLength == 5 })

    var reassembler = GFDIProtobufReassembler()
    #expect(try reassembler.accept(chunks[0]) == nil)
    #expect(try reassembler.accept(chunks[1]) == nil)
    #expect(try reassembler.accept(chunks[2]) == bytes)
}

@Test func protobufReassemblerRejectsGap() throws {
    var reassembler = GFDIProtobufReassembler()
    _ = try reassembler.accept(GFDIProtobufChunk(requestID: 1, dataOffset: 0, totalLength: 6, data: Data([1, 2])))
    #expect(throws: GFDIError.self) {
        _ = try reassembler.accept(GFDIProtobufChunk(requestID: 1, dataOffset: 3, totalLength: 6, data: Data([4])))
    }
}

@Test func protobufRequestFrameParses() throws {
    // requestID 7, offset 0, total 3, chunk 3 bytes.
    let frame = GFDIFrame(messageType: 5043, payload: Data([0x07, 0x00, 0, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3]))
    let request = try #require(GFDIMessageParser.parse(frame) as? GFDIProtobufRequest)
    #expect(request.chunk.requestID == 7)
    #expect(request.chunk.isComplete)
    #expect(request.chunk.data == Data([1, 2, 3]))
}

@Test func protobufStatusFromWatchParses() throws {
    // RESPONSE to PROTOBUF_RESPONSE (5044): ACK, requestID 7, offset 2, DISCARDED, code 102 (MISSING_PACKET).
    let frame = GFDIFrame(messageType: 5000, payload: Data([0xB4, 0x13, 0x00, 0x07, 0x00, 2, 0, 0, 0, 1, 102]))
    let status = try #require(GFDIMessageParser.parse(frame) as? GFDIProtobufStatus)
    #expect(status.originalType == .protobufResponse)
    #expect(status.requestID == 7)
    #expect(status.dataOffset == 2)
    #expect(status.chunk == .discarded)
    #expect(status.code == .missingPacket)
    #expect(!status.isOK)
}

@Test func notificationActionWithReplyParses() throws {
    // PERFORM_NOTIFICATION_ACTION: id 0x0A0B0C0D, action 95 (reply), text "ok".
    let frame = GFDIFrame(messageType: 5034, payload: Data([128, 0x0D, 0x0C, 0x0B, 0x0A, 95, 0x6F, 0x6B, 0]))
    let control = try #require(GFDIMessageParser.parse(frame) as? GFDINotificationControl)
    #expect(control.request == .action(id: 0x0A0B_0C0D, actionID: 95, text: "ok"))
    #expect(Array(control.acknowledgement().body) == [0, 0])
}

@Test func notificationAttributesRequestParses() throws {
    // GET_NOTIFICATION_ATTRIBUTES: id 5; title with max length 0x0102; actions (length 0x0003 and one extra byte); date.
    let frame = GFDIFrame(messageType: 5034, payload: Data([0, 5, 0, 0, 0, 1, 0x02, 0x01, 127, 0x03, 0x00, 0, 5]))
    let control = try #require(GFDIMessageParser.parse(frame) as? GFDINotificationControl)
    #expect(control.request == .notificationAttributes(id: 5, attributes: [
        GFDINotificationAttributeRequest(attribute: .title, maxLength: 0x0102),
        GFDINotificationAttributeRequest(attribute: .actions, maxLength: 3),
        GFDINotificationAttributeRequest(attribute: .date),
    ]))
}

@Test func notificationSubscriptionAcknowledgesWithZeroUnknown() throws {
    let frame = GFDIFrame(messageType: 5036, payload: Data([1, 9]))
    let subscription = try #require(GFDIMessageParser.parse(frame) as? GFDINotificationSubscription)
    #expect(subscription.enable)
    #expect(Array(subscription.acknowledgement(sendsAppNotifications: false).body) == [1, 1, 0])
}

@Test func fitDefinitionPassesRawBytes() throws {
    let frame = GFDIFrame(messageType: 5011, payload: Data([0x40, 0x01, 0x02]))
    let definition = try #require(GFDIMessageParser.parse(frame) as? GFDIFitDefinition)
    #expect(definition.data == Data([0x40, 0x01, 0x02]))
    #expect(Array(definition.acknowledgement().body) == [0])
}
