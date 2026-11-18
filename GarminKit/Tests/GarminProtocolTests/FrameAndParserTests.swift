import Testing
import Foundation
import GarminModels
@testable import GarminProtocol

// Byte sequences marked "garmin-ble" were produced by vendor/garmin-ble's GfdiMessageBuilder.

@Test func systemEventFrameMatchesGarminBLE() {
    // garmin-ble: build_system_event(event_type=16, value=0)
    let frame = GFDISystemEvent(.timeUpdated, value: .byte(0)).frame().encoded()
    #expect(Array(frame) == [0x08, 0x00, 0xA6, 0x13, 0x10, 0x00, 0xDF, 0xC5])
}

@Test func statusAckForCurrentTimeMatchesGarminBLE() {
    // garmin-ble: build_status_ack(ref_message_type=5052)
    let frame = GFDIResponse.ack(.currentTimeRequest).frame().encoded()
    #expect(Array(frame) == [0x09, 0x00, 0x88, 0x13, 0xBC, 0x13, 0x00, 0xB1, 0x4F])
}

@Test func protobufAckMatchesGarminBLE() {
    // garmin-ble: build_protobuf_ack(ref_msg_type=5043, request_id=42, data_offset=1048576)
    let chunk = GFDIProtobufChunk(requestID: 42, dataOffset: 1_048_576, totalLength: 2_000_000, data: Data([1, 2, 3]))
    let frame = GFDIProtobufRequest(chunk: chunk).acknowledgement().frame().encoded()
    #expect(Array(frame) == [0x11, 0x00, 0x88, 0x13, 0xB3, 0x13, 0x00, 0x2A, 0x00,
                             0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0xDA, 0xC5])
}

@Test func protobufResponseFrameMatchesGarminBLE() {
    // garmin-ble: build_protobuf_response(request_id=7, data_offset=0, total_length=3, proto_bytes=b"\x01\x02\x03")
    let chunk = GFDIProtobufChunk(requestID: 7, dataOffset: 0, totalLength: 3, data: Data([1, 2, 3]))
    let frame = GFDIProtobufResponse(chunk: chunk).frame().encoded()
    #expect(Array(frame) == [0x17, 0x00, 0xB4, 0x13, 0x07, 0x00,
                             0x00, 0x00, 0x00, 0x00,
                             0x03, 0x00, 0x00, 0x00,
                             0x03, 0x00, 0x00, 0x00,
                             0x01, 0x02, 0x03, 0x99, 0x99])
}

@Test func unknownTypeParsesAsUnhandled() throws {
    let frame = GFDIFrame(messageType: 5999, payload: Data([0xAA, 0xBB]))
    let parsed = try #require(GFDIMessageParser.parse(frame) as? GFDIUnhandled)
    #expect(parsed.messageType == 5999)
    #expect(parsed.payload == Data([0xAA, 0xBB]))
}

@Test func truncatedPayloadParsesAsUnhandled() throws {
    // BATTERY_STATUS needs three bytes; this one has two.
    let parsed = GFDIMessageParser.parse(GFDIFrame(messageType: 5023, payload: Data([0x10, 0x2A])))
    #expect(parsed as? GFDIUnhandled != nil)
}

@Test func typedStatusParsesFromResponse() throws {
    // RESPONSE (5000) to DOWNLOAD_REQUEST (5002): status ACK, result notReady (3), maxFileSize 0x1000.
    let frame = GFDIFrame(messageType: 5000, payload: Data([0x8A, 0x13, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00]))
    let status = try #require(GFDIMessageParser.parse(frame) as? GFDIDownloadRequestStatus)
    #expect(status.result == .notReady)
    #expect(status.maxFileSize == 0x1000)
}

@Test func responseWithoutTypedModelStaysResponse() throws {
    // CURRENT_TIME_REQUEST has no typed status; the raw RESPONSE keeps its status.
    let frame = GFDIFrame(messageType: 5000, payload: Data([0xBC, 0x13, 0x02]))
    let response = try #require(GFDIMessageParser.parse(frame) as? GFDIResponse)
    #expect(response.originalType == 5052)
    #expect(response.status == .unsupported)
}

@Test func configurationRoundTripsCapabilities() throws {
    let caps: Set<GarminCapability> = [.sync, .weatherConditions, .realtimeSettings]
    let config = GFDIConfiguration(capabilities: caps)
    // Gadgetbridge bit positions: SYNC 3, WEATHER_CONDITIONS 26, REALTIME_SETTINGS 92.
    #expect(config.bitmask.count == 17)
    #expect(config.bitmask[0] == 0x08)
    #expect(config.bitmask[3] == 0x04)
    #expect(config.bitmask[11] == 0x10)

    let frame = config.frame()
    let parsed = try #require(GFDIMessageParser.parse(frame) as? GFDIConfiguration)
    #expect(parsed.capabilities == caps)
    #expect(parsed.bitmask == config.bitmask)
}

@Test func synchronizationReadsFileBits() throws {
    // type automatic (1), 8-byte bitmask with bit 3 (workouts, byte 0) and bit 26 (sleep, byte 3).
    let frame = GFDIFrame(messageType: 5037, payload: Data([0x01, 0x08, 0x08, 0, 0, 0x04, 0, 0, 0, 0]))
    let sync = try #require(GFDIMessageParser.parse(frame) as? GFDISynchronization)
    #expect(sync.kind == .automatic)
    #expect(sync.contains(.workouts))
    #expect(sync.contains(.sleep))
    #expect(!sync.contains(.activities))
}

@Test func batteryStatusDecodes() throws {
    let frame = GFDIFrame(messageType: 5023, payload: Data([0x10, 0x2A, 87, 1, 2, 3, 4]))
    let battery = try #require(GFDIMessageParser.parse(frame) as? GFDIBatteryStatus)
    #expect(battery.condition == .good)
    #expect(battery.voltage == 0.42)
    #expect(battery.percent == 87)
}

@Test func deviceInformationDecodesAndAcknowledges() throws {
    // protocol 150, product 3, unit 0x01020304, software 1234, max packet 512, then strings and a classic MAC.
    var payload: [UInt8] = [150, 0, 3, 0, 4, 3, 2, 1, 0xD2, 0x04, 0x00, 0x02]
    payload += [4] + Array("Venu".utf8)
    payload += [7] + Array("Venu 4 ".utf8.prefix(7))
    payload += [5] + Array("VENU4".utf8)
    payload += [1]                              // has MAC
    payload += [0xAA, 0, 0, 0, 0, 0x11]         // BLE address
    payload += [0x01, 0x02, 0x03, 0x04, 0x05, 0x06] // classic address, stored little-endian
    payload += [0x00]                           // unknown trailing byte
    let frame = GFDIFrame(messageType: 5024, payload: Data(payload))
    let info = try #require(GFDIMessageParser.parse(frame) as? GFDIDeviceInformation)
    #expect(info.protocolVersion == 150)
    #expect(info.unitNumber == 0x0102_0304)
    #expect(info.softwareVersion == 1234)
    #expect(info.maxPacketSize == 512)
    #expect(info.bluetoothName == "Venu")
    #expect(info.deviceModel == "VENU4")
    #expect(info.classicAddress == "06:05:04:03:02:01")

    // Reply: protocol 150, product -1, unit -1, software 7791, max -1, then phone name, maker, model, flags.
    let ack = info.acknowledgement(phoneName: "Phone", manufacturer: "Maker", model: "M1")
    var expected: [UInt8] = [150, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x6F, 0x1E, 0xFF, 0xFF]
    expected += [5] + Array("Phone".utf8) + [5] + Array("Maker".utf8) + [2] + Array("M1".utf8) + [1]
    #expect(ack.status == .ack)
    #expect(ack.originalType == 5024)
    #expect(Array(ack.body) == expected)
}

@Test func currentTimeReplyUsesGadgetbridgeLayout() throws {
    // reference 0x01020304; fixed offset zones have no DST transitions, so both DST fields are 0.
    let frame = GFDIFrame(messageType: 5052, payload: Data([0x04, 0x03, 0x02, 0x01]))
    let request = try #require(GFDIMessageParser.parse(frame) as? GFDICurrentTimeRequest)
    #expect(request.referenceID == 0x0102_0304)

    let date = Date(timeIntervalSince1970: 631_065_600 + 1000)
    let reply = request.acknowledgement(at: date, timeZone: TimeZone(secondsFromGMT: 3600)!)
    #expect(reply.originalType == 5052)
    #expect(Array(reply.body) == [
        0x04, 0x03, 0x02, 0x01,  // referenceID
        0xE8, 0x03, 0x00, 0x00,  // garmin time 1000
        0x10, 0x0E, 0x00, 0x00,  // UTC offset 3600
        0x00, 0x00, 0x00, 0x00,  // next DST end
        0x00, 0x00, 0x00, 0x00,  // next DST start
    ])
}
