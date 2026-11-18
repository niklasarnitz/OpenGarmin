import Testing
import Foundation
@testable import GarminCore

@Test func crcMatchesKnownValue() {
    // "123456789" -> CRC-16/ARC 0xBB3D (Garmin's nibble table implements CRC-16/ARC).
    #expect(GarminCRC.compute(Array("123456789".utf8)) == 0xBB3D)
}

@Test func readerWriterRoundTripLittleEndian() throws {
    var w = ByteWriter()
    w.writeUInt16(0x1234); w.writeUInt32(0xDEADBEEF); w.writeString("Venu 4")
    #expect(Array(w.bytes.prefix(2)) == [0x34, 0x12])
    var r = ByteReader(w.bytes)
    #expect(try r.readUInt16() == 0x1234)
    #expect(try r.readUInt32() == 0xDEADBEEF)
    #expect(try r.readString() == "Venu 4")
    #expect(r.isAtEnd)
}
