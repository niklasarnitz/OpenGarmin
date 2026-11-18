import Foundation
import Testing
import GarminFIT

// Byte sequences assembled by hand from the FIT layout (not with FitEncoder), CRCs included.
//
// File 1: little endian, 14-byte header. Definitions for global 18 (timestamp only) and global 20
// (heart_rate uint8, speed uint16). Records: a normal timestamp, then two compressed timestamps,
// one of them wrapping the 5-bit offset; the first speed is the invalid sentinel 0xFFFF.
private let littleEndianFile: [UInt8] = [
    0x0E, 0x10, 0x7D, 0x52, 0x26, 0x00, 0x00, 0x00, 0x2E, 0x46, 0x49, 0x54, 0x97, 0x05,
    0x41, 0x00, 0x00, 0x12, 0x00, 0x01, 0xFD, 0x04, 0x86,
    0x01, 0x00, 0xCA, 0x9A, 0x3B,
    0x40, 0x00, 0x00, 0x14, 0x00, 0x02, 0x03, 0x01, 0x02, 0x06, 0x02, 0x84,
    0x00, 0x90, 0xFF, 0xFF,
    0x85, 0x78, 0x20, 0x03,
    0x83, 0x64, 0x00, 0x00,
    0x14, 0x73,
]

// File 2: big endian, 12-byte header. Global 20 with timestamp, distance (uint32) and altitude (uint16),
// a field_description (206) that types developer field 0 as uint16, and a developer field of that type.
private let bigEndianFile: [UInt8] = [
    0x0C, 0x20, 0x7D, 0x52, 0x41, 0x00, 0x00, 0x00, 0x2E, 0x46, 0x49, 0x54,
    0x41, 0x00, 0x01, 0x00, 0x14, 0x03, 0xFD, 0x04, 0x86, 0x05, 0x04, 0x86, 0x02, 0x02, 0x84,
    0x01, 0x3B, 0x9A, 0xCA, 0x00, 0x00, 0x00, 0x30, 0x39, 0x07, 0xD0,
    0x42, 0x00, 0x01, 0x00, 0xCE, 0x03, 0x00, 0x01, 0x02, 0x01, 0x01, 0x02, 0x02, 0x01, 0x02,
    0x02, 0x00, 0x00, 0x84,
    0x63, 0x00, 0x01, 0x00, 0x14, 0x01, 0xFD, 0x04, 0x86, 0x01, 0x00, 0x02, 0x00,
    0x03, 0x3B, 0x9A, 0xCA, 0x64, 0x12, 0x34,
    0x16, 0xE5,
]

private let firstTimestamp: Int64 = 1_000_000_000

@Test func decodesCompressedTimestampsAndDropsInvalidValues() throws {
    let file = try FitDecoder.decode(Data(littleEndianFile))

    #expect(file.protocolVersion == 0x10)
    #expect(file.profileVersion == 21117)
    #expect(file.messages.count == 4)

    #expect(file.messages[0].globalNumber == 18)
    #expect(file.messages[0][253]?.int == firstTimestamp)

    // The record after the normal timestamp inherits it; its speed sentinel is dropped.
    #expect(file.messages[1].globalNumber == 20)
    #expect(file.messages[1][253]?.int == firstTimestamp)
    #expect(file.messages[1][3]?.int == 144)
    #expect(file.messages[1][6] == nil)

    // Compressed header 0x85: offset 5 from ...000 (no wrap) -> +5.
    #expect(file.messages[2][253]?.int == firstTimestamp + 5)
    #expect(file.messages[2][3]?.int == 120)
    #expect(file.messages[2][6]?.int == 800)

    // Compressed header 0x83: offset 3 is below the running low 5 bits (5), so it wraps: +3 + 32 -> +35.
    #expect(file.messages[3][253]?.int == firstTimestamp + 35)
    #expect(file.messages[3][3]?.int == 100)
    #expect(file.messages[3][6]?.int == 0)
}

@Test func decodesBigEndianWithDeveloperFields() throws {
    let file = try FitDecoder.decode(Data(bigEndianFile))

    #expect(file.protocolVersion == 0x20)
    #expect(file.messages.count == 3)

    #expect(file.messages[0][253]?.int == firstTimestamp)
    #expect(file.messages[0][5]?.int == 12345)
    #expect(file.messages[0][2]?.int == 2000)
    #expect(file.messages[0].developerFields.isEmpty)

    // field_description message: developer index 0, field 0, base type 0x84 (uint16).
    #expect(file.messages[1].globalNumber == 206)
    #expect(file.messages[1][2]?.int == 0x84)

    // A uint16 developer field would read 0x1234 as one value; a byte fallback would give two bytes.
    #expect(file.messages[2][253]?.int == firstTimestamp + 100)
    #expect(file.messages[2].developerFields[0] == .uint(0x1234))
}

@Test func decodesChainedFiles() throws {
    let file = try FitDecoder.decode(Data(littleEndianFile + bigEndianFile))

    // The second file's messages follow the first file's four.
    #expect(file.messages.count == 7)
    #expect(file.protocolVersion == 0x10)
    #expect(file.messages[4].globalNumber == 20)
    #expect(file.messages[4][5]?.int == 12345)
    #expect(file.messages[4][253]?.int == firstTimestamp)
    #expect(file.messages[5].globalNumber == 206)
    #expect(file.messages[6].developerFields[0] == .uint(0x1234))
}

@Test func rejectsCorruptChecksum() {
    var corrupt = littleEndianFile
    corrupt[corrupt.count - 1] ^= 0xFF
    #expect(throws: FitError.crcMismatch) {
        try FitDecoder.decode(Data(corrupt))
    }
}

@Test func rejectsTruncatedFile() {
    #expect(throws: FitError.truncated) {
        try FitDecoder.decode(Data(littleEndianFile.dropLast(5)))
    }
}
