import Foundation
import GarminCore

/// One field to write. `value` holds the raw FIT value (scale and offset already applied); nil writes
/// the invalid sentinel of `baseType`.
public struct FitEncodeField: Sendable, Hashable {
    public var number: UInt8
    public var baseType: FitBaseType
    public var value: FitValue?

    public init(_ number: UInt8, _ baseType: FitBaseType, _ value: FitValue?) {
        self.number = number
        self.baseType = baseType
        self.value = value
    }
}

/// A global FIT message to write, with its fields in definition order.
public struct FitEncodeMessage: Sendable, Hashable {
    public var globalNumber: UInt16
    public var fields: [FitEncodeField]

    public init(globalNumber: UInt16, fields: [FitEncodeField]) {
        self.globalNumber = globalNumber
        self.fields = fields
    }
}

/// Writes FIT definition and data messages, laid out as Gadgetbridge's `RecordDefinition` and `RecordData`.
public enum FitEncoder {
    /// A complete FIT file: 14-byte header with CRC, the messages, and the file CRC. Definitions are
    /// written when a message's layout differs from the one last defined for its local message type.
    public static func encodeFile(_ messages: [FitEncodeMessage], protocolVersion: UInt8 = 0x10,
                                  profileVersion: UInt16 = 21117) -> Data {
        var body = ByteWriter()
        var slots = [Layout?](repeating: nil, count: 16)
        var nextSlot = 0
        for message in messages {
            let layout = Layout(message)
            let localType: UInt8
            if let existing = slots.firstIndex(of: layout) {
                localType = UInt8(existing)
            } else {
                localType = UInt8(nextSlot)
                slots[nextSlot] = layout
                nextSlot = (nextSlot + 1) % slots.count
                body.writeBytes(definitionMessage(localType: localType, message, bigEndian: false))
            }
            body.writeBytes(dataMessage(localType: localType, message, bigEndian: false))
        }
        return wrap(body.bytes, protocolVersion: protocolVersion, profileVersion: profileVersion)
    }

    /// A FIT file around `body`: the 14-byte header with its CRC, the body, and the file CRC.
    public static func wrap(_ body: [UInt8], protocolVersion: UInt8 = 0x10, profileVersion: UInt16 = 21117) -> Data {
        var file = ByteWriter()
        file.writeUInt8(14)
        file.writeUInt8(protocolVersion)
        file.writeUInt16(profileVersion)
        file.writeUInt32(UInt32(body.count))
        file.writeBytes(Array(".FIT".utf8))
        file.writeUInt16(GarminCRC.compute(file.bytes))
        file.writeBytes(body)
        file.writeUInt16(GarminCRC.compute(file.bytes))
        return file.data
    }

    /// The definition message that gives `localType` the layout of `message`.
    public static func definitionMessage(localType: UInt8, _ message: FitEncodeMessage, bigEndian: Bool) -> Data {
        var writer = ByteWriter(bigEndian: bigEndian)
        writer.writeUInt8(0x40 | localType)
        writer.writeUInt8(0)
        writer.writeUInt8(bigEndian ? 1 : 0)
        writer.write(message.globalNumber)
        writer.writeUInt8(UInt8(message.fields.count))
        for field in message.fields {
            writer.writeUInt8(field.number)
            writer.writeUInt8(UInt8(field.size))
            writer.writeUInt8(field.baseType.rawValue)
        }
        return writer.data
    }

    /// A data message for `localType`. Its values follow the layout of the definition sent for it.
    public static func dataMessage(localType: UInt8, _ message: FitEncodeMessage, bigEndian: Bool) -> Data {
        var writer = ByteWriter(bigEndian: bigEndian)
        writer.writeUInt8(localType)
        for field in message.fields {
            write(field, to: &writer)
        }
        return writer.data
    }

    private static func write(_ field: FitEncodeField, to writer: inout ByteWriter) {
        if field.baseType == .string {
            var text: [UInt8] = []
            if case .string(let s)? = field.value {
                text = Array(s.utf8.prefix(field.size - 1))
            }
            writer.writeBytes(text)
            writer.writeBytes([UInt8](repeating: 0, count: field.size - text.count))
            return
        }
        var elements: [FitValue?]
        switch field.value {
        case .array(let values)?: elements = values
        case .bytes(let bytes)?: elements = bytes.map { FitValue.uint(UInt64($0)) }
        case let value: elements = [value]
        }
        if elements.isEmpty { elements = [nil] }
        for element in elements {
            let bits = field.baseType.encodeBits(element)
            let size = field.baseType.size
            for index in 0..<size {
                let shift = writer.bigEndian ? 8 * (size - 1 - index) : 8 * index
                writer.writeUInt8(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
            }
        }
    }

    /// Layout of a message as written in its definition; two messages with equal layouts share a definition.
    private struct Layout: Equatable {
        struct Field: Equatable {
            var number: UInt8
            var baseType: FitBaseType
            var size: Int
        }

        var globalNumber: UInt16
        var fields: [Field]

        init(_ message: FitEncodeMessage) {
            globalNumber = message.globalNumber
            fields = message.fields.map { Field(number: $0.number, baseType: $0.baseType, size: $0.size) }
        }
    }
}

extension FitEncodeField {
    /// Size of the field in bytes. Strings are their UTF-8 length plus a terminator, up to 255 bytes, as in
    /// Gadgetbridge. Other fields are their element count times the element size.
    var size: Int {
        if baseType == .string {
            guard case .string(let text)? = value else { return 1 }
            return min(text.utf8.count + 1, 255)
        }
        let count: Int
        switch value {
        case .array(let values)?: count = max(1, values.count)
        case .bytes(let bytes)?: count = max(1, bytes.count)
        default: count = 1
        }
        return count * baseType.size
    }
}
