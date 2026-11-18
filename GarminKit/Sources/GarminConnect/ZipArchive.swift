import Foundation

/// Reads the files of a zip archive, which is what Garmin's original-activity download sends. The sizes come from the
/// central directory, because an entry written as a stream leaves them out of its local header. Stored and deflated
/// entries are read; directories are skipped.
enum ZipArchive {
    struct Entry: Equatable {
        var name: String
        var data: Data
    }

    static func entries(_ archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard let end = endOfCentralDirectory(bytes) else { throw GarminConnectError.malformedResponse }
        let count = Int(try uint16(bytes, end + 10))
        var offset = Int(try uint32(bytes, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try uint32(bytes, offset) == 0x0201_4b50 else { throw GarminConnectError.malformedResponse }
            let method = try uint16(bytes, offset + 10)
            let compressedSize = Int(try uint32(bytes, offset + 20))
            let uncompressedSize = Int(try uint32(bytes, offset + 24))
            let nameLength = Int(try uint16(bytes, offset + 28))
            let extraLength = Int(try uint16(bytes, offset + 30))
            let commentLength = Int(try uint16(bytes, offset + 32))
            let localOffset = Int(try uint32(bytes, offset + 42))
            let name = String(decoding: try slice(bytes, offset + 46, nameLength), as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            guard !name.hasSuffix("/") else { continue }
            guard try uint32(bytes, localOffset) == 0x0403_4b50 else { throw GarminConnectError.malformedResponse }
            let localNameLength = Int(try uint16(bytes, localOffset + 26))
            let localExtraLength = Int(try uint16(bytes, localOffset + 28))
            let compressed = Data(try slice(bytes, localOffset + 30 + localNameLength + localExtraLength,
                                            compressedSize))
            let data: Data
            switch method {
            case 0:
                data = compressed
            case 8:
                // Compression's zlib is raw deflate, which is what a zip entry holds.
                data = try (compressed as NSData).decompressed(using: .zlib) as Data
            default:
                throw GarminConnectError.malformedResponse
            }
            guard data.count == uncompressedSize else { throw GarminConnectError.malformedResponse }
            entries.append(Entry(name: name, data: data))
        }
        return entries
    }

    /// The end-of-central-directory record, searched from the end because a zip comment may follow it.
    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        for index in stride(from: bytes.count - 22, through: lowest, by: -1)
        where bytes[index] == 0x50 && bytes[index + 1] == 0x4b && bytes[index + 2] == 0x05 && bytes[index + 3] == 0x06 {
            return index
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], _ index: Int) throws -> UInt16 {
        let part = try slice(bytes, index, 2)
        return UInt16(part[0]) | UInt16(part[1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ index: Int) throws -> UInt32 {
        let part = try slice(bytes, index, 4)
        return UInt32(part[0]) | UInt32(part[1]) << 8 | UInt32(part[2]) << 16 | UInt32(part[3]) << 24
    }

    private static func slice(_ bytes: [UInt8], _ index: Int, _ length: Int) throws -> [UInt8] {
        guard index >= 0, length >= 0, index + length <= bytes.count else { throw GarminConnectError.malformedResponse }
        return Array(bytes[index..<index + length])
    }
}
