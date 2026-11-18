import Foundation
import GarminCore

/// Decodes FIT files into raw messages. Values are unscaled; invalid sentinels are dropped.
///
/// Handles 12- and 14-byte headers, normal and compressed-timestamp data headers, definitions
/// with developer fields (typed through `field_description`), both byte orders, and chained files.
/// Field 253 (`timestamp`) is filled with the running timestamp on every data message, so a
/// message without its own timestamp, or with a compressed header, still carries one.
public enum FitDecoder {
    public static func decode(_ data: Data) throws -> FitFile {
        let bytes = [UInt8](data)
        let first = try decodeFile(bytes, at: 0)
        var messages = first.messages
        var offset = first.end
        // Trailing bytes that do not start another FIT file are ignored.
        while offset < bytes.count, hasFitMagic(bytes, at: offset) {
            let next = try decodeFile(bytes, at: offset)
            messages += next.messages
            offset = next.end
        }
        return FitFile(protocolVersion: first.protocolVersion, profileVersion: first.profileVersion, messages: messages)
    }

    private struct DecodedFile {
        var protocolVersion: UInt8
        var profileVersion: UInt16
        var messages: [FitMessage]
        /// Offset just past this file's CRC.
        var end: Int
    }

    private struct FieldDefinition {
        var number: UInt8
        var size: Int
        var baseType: FitBaseType
    }

    private struct DeveloperFieldDefinition {
        var number: UInt8
        var size: Int
        var developerIndex: UInt8
    }

    private struct MessageDefinition {
        var globalNumber: UInt16
        var bigEndian: Bool
        var fields: [FieldDefinition]
        var developerFields: [DeveloperFieldDefinition]
    }

    private static let magic: UInt32 = 0x5449_462E
    private static let timestampField: UInt8 = 253
    private static let fieldDescriptionMessage: UInt16 = 206

    private static func hasFitMagic(_ bytes: [UInt8], at offset: Int) -> Bool {
        bytes.count >= offset + 12 && bytes[(offset + 8)..<(offset + 12)].elementsEqual([0x2E, 0x46, 0x49, 0x54])
    }

    private static func decodeFile(_ bytes: [UInt8], at start: Int) throws -> DecodedFile {
        var reader = ByteReader(bytes)
        reader.position = start
        let headerSize: Int
        let protocolVersion: UInt8
        let profileVersion: UInt16
        let dataSize: Int
        do {
            headerSize = Int(try reader.readUInt8())
            guard headerSize >= 12 else { throw FitError.invalidHeader }
            protocolVersion = try reader.readUInt8()
            profileVersion = try reader.readUInt16()
            dataSize = Int(try reader.readUInt32())
            guard try reader.readUInt32() == magic else { throw FitError.invalidHeader }
            if headerSize >= 14 {
                let headerCRC = try reader.readUInt16()
                if headerCRC != 0, headerCRC != GarminCRC.compute(bytes[start..<(start + 12)]) {
                    throw FitError.crcMismatch
                }
            }
        } catch is ByteIOError {
            throw FitError.truncated
        }

        let dataStart = start + headerSize
        let dataEnd = dataStart + dataSize
        guard dataEnd + 2 <= bytes.count else { throw FitError.truncated }

        reader.position = dataStart
        reader.limit = dataEnd
        let messages: [FitMessage]
        do {
            messages = try decodeRecords(&reader)
        } catch is ByteIOError {
            throw FitError.truncated
        }

        let storedCRC = UInt16(bytes[dataEnd]) | UInt16(bytes[dataEnd + 1]) << 8
        guard storedCRC == GarminCRC.compute(bytes[start..<dataEnd]) else { throw FitError.crcMismatch }

        return DecodedFile(protocolVersion: protocolVersion, profileVersion: profileVersion,
                           messages: messages, end: dataEnd + 2)
    }

    /// Reads definitions and data records until the reader's limit.
    private static func decodeRecords(_ reader: inout ByteReader) throws -> [FitMessage] {
        var definitions: [UInt8: MessageDefinition] = [:]
        var developerTypes: [UInt16: FitBaseType] = [:]
        var messages: [FitMessage] = []
        var timestamp: Int64?

        while !reader.isAtEnd {
            let header = try reader.readUInt8()
            if header & 0x80 != 0 {
                // Compressed timestamp: a 5-bit offset from the running timestamp; always a data message.
                let localType = (header >> 5) & 0x03
                let offset = Int64(header & 0x1F)
                let last = timestamp ?? 0
                var updated = (last & ~0x1F) + offset
                if offset < (last & 0x1F) { updated += 32 }
                timestamp = updated
                guard let definition = definitions[localType] else {
                    throw FitError.missingDefinition(localType: localType)
                }
                let message = try readData(definition, &reader, developerTypes, timestamp: timestamp)
                messages.append(message)
            } else if header & 0x40 != 0 {
                let definition = try readDefinition(&reader, hasDeveloperData: header & 0x20 != 0)
                definitions[header & 0x0F] = definition
            } else {
                let localType = header & 0x0F
                guard let definition = definitions[localType] else {
                    throw FitError.missingDefinition(localType: localType)
                }
                let message = try readData(definition, &reader, developerTypes, timestamp: timestamp)
                if let stamped = message[timestampField]?.int {
                    timestamp = stamped
                }
                if message.globalNumber == fieldDescriptionMessage {
                    registerDeveloperField(message, into: &developerTypes)
                }
                messages.append(message)
            }
        }
        return messages
    }

    private static func readDefinition(_ reader: inout ByteReader, hasDeveloperData: Bool) throws -> MessageDefinition {
        _ = try reader.readUInt8()
        let bigEndian = try reader.readUInt8() == 1
        reader.bigEndian = bigEndian
        let globalNumber = try reader.readUInt16()
        var fields: [FieldDefinition] = []
        let fieldCount = Int(try reader.readUInt8())
        for _ in 0..<fieldCount {
            let number = try reader.readUInt8()
            let size = Int(try reader.readUInt8())
            let typeByte = try reader.readUInt8()
            fields.append(FieldDefinition(number: number, size: size,
                                          baseType: FitBaseType.fromNumber(typeByte & 0x1F) ?? .byte))
        }
        var developerFields: [DeveloperFieldDefinition] = []
        if hasDeveloperData {
            let developerCount = Int(try reader.readUInt8())
            for _ in 0..<developerCount {
                let number = try reader.readUInt8()
                let size = Int(try reader.readUInt8())
                let developerIndex = try reader.readUInt8()
                developerFields.append(DeveloperFieldDefinition(number: number, size: size, developerIndex: developerIndex))
            }
        }
        return MessageDefinition(globalNumber: globalNumber, bigEndian: bigEndian,
                                 fields: fields, developerFields: developerFields)
    }

    /// Reads one data message. A field 253 that is absent gets the running timestamp.
    private static func readData(_ definition: MessageDefinition, _ reader: inout ByteReader,
                                 _ developerTypes: [UInt16: FitBaseType], timestamp: Int64?) throws -> FitMessage {
        var fields: [UInt8: FitValue] = [:]
        for field in definition.fields {
            let raw = try reader.readBytes(field.size)
            if let value = FitBaseType.decodeField(raw, base: field.baseType, bigEndian: definition.bigEndian) {
                fields[field.number] = value
            }
        }
        var developerFields: [UInt16: FitValue] = [:]
        for field in definition.developerFields {
            let key = UInt16(field.developerIndex) << 8 | UInt16(field.number)
            let raw = try reader.readBytes(field.size)
            let baseType = developerTypes[key] ?? .byte
            if let value = FitBaseType.decodeField(raw, base: baseType, bigEndian: definition.bigEndian) {
                developerFields[key] = value
            }
        }
        if fields[timestampField] == nil, let timestamp {
            fields[timestampField] = .uint(UInt64(timestamp))
        }
        return FitMessage(globalNumber: definition.globalNumber, fields: fields, developerFields: developerFields)
    }

    private static func registerDeveloperField(_ message: FitMessage, into developerTypes: inout [UInt16: FitBaseType]) {
        guard let index = message[0]?.int, let number = message[1]?.int, let typeId = message[2]?.int,
              let baseType = FitBaseType.fromNumber(UInt8(truncatingIfNeeded: typeId) & 0x1F)
        else { return }
        developerTypes[UInt16(truncatingIfNeeded: index) << 8 | UInt16(truncatingIfNeeded: number)] = baseType
    }
}
