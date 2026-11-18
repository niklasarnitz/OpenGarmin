import Foundation

/// FIT base types. The raw value is the base type identifier written in field definitions
/// (the same identifiers as Gadgetbridge's `BaseType`).
public enum FitBaseType: UInt8, Sendable, CaseIterable {
    case enumeration = 0x00
    case sint8 = 0x01
    case uint8 = 0x02
    case sint16 = 0x83
    case uint16 = 0x84
    case sint32 = 0x85
    case uint32 = 0x86
    case string = 0x07
    case float32 = 0x88
    case float64 = 0x89
    case uint8z = 0x0A
    case uint16z = 0x8B
    case uint32z = 0x8C
    case byte = 0x0D
    case sint64 = 0x8E
    case uint64 = 0x8F
    case uint64z = 0x90

    /// The base type number: the low five bits of the identifier, as read from a definition.
    var number: UInt8 { rawValue & 0x1F }

    static func fromNumber(_ number: UInt8) -> FitBaseType? {
        allCases.first { $0.number == number }
    }

    /// Byte size of one element.
    public var size: Int {
        switch self {
        case .enumeration, .sint8, .uint8, .uint8z, .byte, .string: 1
        case .sint16, .uint16, .uint16z: 2
        case .sint32, .uint32, .uint32z, .float32: 4
        case .sint64, .uint64, .uint64z, .float64: 8
        }
    }

    /// Raw bits of FIT's invalid sentinel for this type. Zero-invalid types (`z` suffix) use 0.
    var invalidBits: UInt64 {
        switch self {
        case .enumeration, .uint8, .byte: 0xFF
        case .sint8: 0x7F
        case .uint16: 0xFFFF
        case .sint16: 0x7FFF
        case .uint32, .float32: 0xFFFF_FFFF
        case .sint32: 0x7FFF_FFFF
        case .uint64, .float64: UInt64.max
        case .sint64: UInt64(Int64.max)
        case .uint8z, .uint16z, .uint32z, .uint64z, .string: 0
        }
    }

    var isSigned: Bool {
        switch self {
        case .sint8, .sint16, .sint32, .sint64: true
        default: false
        }
    }

    var isFloat: Bool { self == .float32 || self == .float64 }

    /// Maps raw element bits to a value. Returns nil for the invalid sentinel (and NaN floats).
    func decodeBits(_ bits: UInt64) -> FitValue? {
        if bits == invalidBits { return nil }
        switch self {
        case .sint8, .sint16, .sint32, .sint64:
            let shift = UInt64(64 - 8 * size)
            return .int(Int64(bitPattern: bits << shift) >> Int64(shift))
        case .float32:
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            return value.isNaN ? nil : .double(Double(value))
        case .float64:
            let value = Double(bitPattern: bits)
            return value.isNaN ? nil : .double(value)
        default:
            return .uint(bits)
        }
    }

    /// Raw element bits for `value`. Absent values, values outside the type's range, and
    /// non-scalar values are written as the invalid sentinel, as Gadgetbridge does.
    func encodeBits(_ value: FitValue?) -> UInt64 {
        guard let value else { return invalidBits }
        if isFloat {
            guard let double = FitBaseType.doubleValue(value) else { return invalidBits }
            return self == .float32 ? UInt64(Float(double).bitPattern) : double.bitPattern
        }
        guard let number = FitBaseType.integerValue(value) else { return invalidBits }
        let bitCount = 8 * size
        let maxUnsigned: Int128 = (Int128(1) << bitCount) - 1
        let minValue: Int128 = isSigned ? -(Int128(1) << (bitCount - 1)) : 0
        let maxValue: Int128 = isSigned ? (Int128(1) << (bitCount - 1)) - 1 : maxUnsigned
        guard number >= minValue, number <= maxValue else { return invalidBits }
        return UInt64(truncatingIfNeeded: number) & UInt64(truncatingIfNeeded: maxUnsigned)
    }

    /// Scalar numeric value as an integer. Doubles are rounded half up, like Java's `Math.round`.
    private static func integerValue(_ value: FitValue) -> Int128? {
        switch value {
        case .int(let v): Int128(v)
        case .uint(let v): Int128(v)
        case .double(let v): v.isFinite && abs(v) < 1e30 ? Int128(floor(v + 0.5)) : nil
        default: nil
        }
    }

    private static func doubleValue(_ value: FitValue) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .uint(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }
}

extension FitBaseType {
    /// Decodes one field of raw bytes. Returns nil when the field is absent or entirely invalid.
    static func decodeField(_ raw: [UInt8], base: FitBaseType, bigEndian: Bool) -> FitValue? {
        switch base {
        case .string:
            let text = raw.prefix { $0 != 0 }
            return text.isEmpty ? nil : .string(String(decoding: text, as: UTF8.self))
        case .byte:
            return raw.contains { $0 != 0xFF } ? .bytes(raw) : nil
        default:
            let size = base.size
            let count = raw.count / size
            var values: [FitValue] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let slice = raw[(index * size)..<((index + 1) * size)]
                if let value = base.decodeBits(readBits(slice, bigEndian: bigEndian)) {
                    values.append(value)
                }
            }
            if count == 1 { return values.first }
            return values.isEmpty ? nil : .array(values)
        }
    }

    static func readBits(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> UInt64 {
        var bits: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            if bigEndian {
                bits = bits << 8 | UInt64(byte)
            } else {
                bits |= UInt64(byte) << (8 * UInt64(index))
            }
        }
        return bits
    }
}
