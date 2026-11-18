import Foundation
import Testing
import GarminFIT

@Test func encodedFileDecodesToSameValues() throws {
    let record = FitEncodeMessage(globalNumber: 20, fields: [
        FitEncodeField(1, .uint16, .int(0x1234)),
        FitEncodeField(2, .sint8, .int(-5)),
        FitEncodeField(3, .string, .string("abc")),
        FitEncodeField(4, .uint8, .array([.int(1), .int(2), .int(3)])),
        FitEncodeField(5, .uint32, nil),
    ])
    let other = FitEncodeMessage(globalNumber: 20, fields: [
        FitEncodeField(1, .uint16, .int(7)),
        FitEncodeField(2, .sint8, .int(100)),
        FitEncodeField(3, .string, .string("")),
        FitEncodeField(4, .uint8, .array([.int(9), .int(8), .int(7)])),
        FitEncodeField(5, .uint32, nil),
    ])
    let session = FitEncodeMessage(globalNumber: 18, fields: [FitEncodeField(253, .uint32, .int(1_000_000_000))])

    let file = try FitDecoder.decode(FitEncoder.encodeFile([record, other, session]))

    #expect(file.messages.count == 3)
    #expect(file.messages[0][1] == .uint(0x1234))
    #expect(file.messages[0][2] == .int(-5))
    #expect(file.messages[0][3] == .string("abc"))
    #expect(file.messages[0][4] == .array([.uint(1), .uint(2), .uint(3)]))
    // A nil value is written as the invalid sentinel, so the decoder drops it.
    #expect(file.messages[0][5] == nil)
    #expect(file.messages[1][1] == .uint(7))
    #expect(file.messages[1][2] == .int(100))
    #expect(file.messages[2][253] == .uint(1_000_000_000))
}

@Test func writesDefinitionAndDataInFileByteOrder() {
    let message = FitEncodeMessage(globalNumber: 20, fields: [FitEncodeField(1, .uint16, .int(0x1234))])

    // Definition: local type 0, little endian, global 20, one field (1, 2 bytes, uint16).
    #expect(FitEncoder.definitionMessage(localType: 0, message, bigEndian: false) == Data([0x40, 0x00, 0x00, 0x14, 0x00, 0x01, 0x01, 0x02, 0x84]))
    // Data in big endian: local type 2, then the value high byte first.
    #expect(FitEncoder.dataMessage(localType: 2, message, bigEndian: true) == Data([0x02, 0x12, 0x34]))
}
