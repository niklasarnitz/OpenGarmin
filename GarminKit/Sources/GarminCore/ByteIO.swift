import Foundation

public enum ByteIOError: Error, Equatable {
    case outOfBounds(needed: Int, remaining: Int)
    case invalidString
}

/// Little-endian (by default) cursor over immutable bytes. Mirrors Gadgetbridge's GarminByteBufferReader.
public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public var position: Int
    public var limit: Int
    public var bigEndian: Bool

    public init(_ data: Data, bigEndian: Bool = false) {
        self.init([UInt8](data), bigEndian: bigEndian)
    }

    public init(_ bytes: [UInt8], bigEndian: Bool = false) {
        self.bytes = bytes
        self.position = 0
        self.limit = bytes.count
        self.bigEndian = bigEndian
    }

    public var remaining: Int { limit - position }
    public var isAtEnd: Bool { position >= limit }

    private func check(_ n: Int) throws {
        if n > remaining { throw ByteIOError.outOfBounds(needed: n, remaining: remaining) }
    }

    public mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try check(n)
        defer { position += n }
        return Array(bytes[position..<(position + n)])
    }

    public mutating func readData(_ n: Int) throws -> Data { Data(try readBytes(n)) }

    public mutating func readRest() -> [UInt8] {
        defer { position = limit }
        return Array(bytes[position..<limit])
    }

    public mutating func skip(_ n: Int) throws { try check(n); position += n }

    private mutating func readInteger<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try check(size)
        var value: T = 0
        for i in 0..<size {
            let byte = T(bytes[position + i])
            value |= bigEndian ? byte << (8 * (size - 1 - i)) : byte << (8 * i)
        }
        position += size
        return value
    }

    public mutating func readUInt8() throws -> UInt8 { try readInteger(UInt8.self) }
    public mutating func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }
    public mutating func readUInt16() throws -> UInt16 { try readInteger(UInt16.self) }
    public mutating func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }
    public mutating func readUInt32() throws -> UInt32 { try readInteger(UInt32.self) }
    public mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    public mutating func readUInt64() throws -> UInt64 { try readInteger(UInt64.self) }
    public mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }
    public mutating func readFloat32() throws -> Float { Float(bitPattern: try readUInt32()) }
    public mutating func readFloat64() throws -> Double { Double(bitPattern: try readUInt64()) }

    /// String prefixed with a one-byte length (Gadgetbridge `readString`).
    public mutating func readString() throws -> String {
        let n = Int(try readUInt8())
        guard let s = String(bytes: try readBytes(n), encoding: .utf8) else { throw ByteIOError.invalidString }
        return s
    }

    /// String prefixed with a two-byte length (Gadgetbridge `readString2`).
    public mutating func readString16() throws -> String {
        let n = Int(try readUInt16())
        guard let s = String(bytes: try readBytes(n), encoding: .utf8) else { throw ByteIOError.invalidString }
        return s
    }

    public mutating func readNullTerminatedString() throws -> String {
        var out: [UInt8] = []
        while true {
            let b = try readUInt8()
            if b == 0 { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Growable little-endian (by default) writer. Mirrors Gadgetbridge's MessageWriter.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public var bigEndian: Bool

    public init(bigEndian: Bool = false) { self.bigEndian = bigEndian }

    public var data: Data { Data(bytes) }
    public var count: Int { bytes.count }

    public mutating func write<T: FixedWidthInteger>(_ value: T) {
        let v = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeUInt8(_ v: UInt8) { write(v) }
    public mutating func writeUInt16(_ v: UInt16) { write(v) }
    public mutating func writeUInt32(_ v: UInt32) { write(v) }
    public mutating func writeUInt64(_ v: UInt64) { write(v) }
    public mutating func writeInt8(_ v: Int8) { write(v) }
    public mutating func writeInt16(_ v: Int16) { write(v) }
    public mutating func writeInt32(_ v: Int32) { write(v) }
    public mutating func writeInt64(_ v: Int64) { write(v) }
    public mutating func writeFloat32(_ v: Float) { write(v.bitPattern) }
    public mutating func writeFloat64(_ v: Double) { write(v.bitPattern) }
    public mutating func writeBytes<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
    public mutating func writeData(_ d: Data) { bytes.append(contentsOf: d) }

    /// One-byte length prefixed UTF-8 string (Gadgetbridge `writeString`). Truncates to 255 bytes.
    public mutating func writeString(_ s: String) {
        let utf8 = Array(s.utf8.prefix(255))
        writeUInt8(UInt8(utf8.count))
        writeBytes(utf8)
    }

    /// Overwrites a UInt16 at an absolute offset.
    public mutating func setUInt16(_ v: UInt16, at offset: Int) {
        let le = bigEndian ? v.bigEndian : v.littleEndian
        withUnsafeBytes(of: le) { raw in
            bytes[offset] = raw[0]
            bytes[offset + 1] = raw[1]
        }
    }
}

public extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.replacingOccurrences(of: " ", with: ""))
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self.init(out)
    }
}

/// Garmin epoch: 1989-12-31T00:00:00Z. Used by GFDI and FIT timestamps.
public enum GarminTime {
    public static let epochOffset: TimeInterval = 631_065_600

    public static func date(fromGarmin seconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + epochOffset)
    }

    public static func garminSeconds(from date: Date) -> UInt32 {
        UInt32(clamping: Int64((date.timeIntervalSince1970 - epochOffset).rounded(.down)))
    }
}
