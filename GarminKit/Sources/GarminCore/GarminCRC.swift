/// Garmin CRC-16 (nibble table), as in Gadgetbridge's ChecksumCalculator. Used by GFDI frames and FIT files.
public enum GarminCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    public static func compute<C: Collection>(_ bytes: C, seed: UInt16 = 0) -> UInt16 where C.Element == UInt8 {
        var crc = seed
        for b in bytes {
            crc = ((crc >> 4) & 0x0FFF) ^ table[Int(crc & 0xF)] ^ table[Int(b & 0xF)]
            crc = ((crc >> 4) & 0x0FFF) ^ table[Int(crc & 0xF)] ^ table[Int((b >> 4) & 0xF)]
        }
        return crc
    }
}
