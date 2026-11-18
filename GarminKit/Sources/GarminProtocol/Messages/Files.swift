import Foundation
import GarminCore

// File transfer messages (Gadgetbridge `FileTransferHandler` and the `messages` classes it uses).
// File types are raw `dataType`/`subType` bytes; mapping them to `FileType` belongs to the session.

// MARK: - Download

/// DOWNLOAD_REQUEST (5002), phone -> watch. Answered by `GFDIDownloadRequestStatus`.
public struct GFDIDownloadRequest: GFDIOutgoing, Sendable, Equatable {
    public enum Mode: UInt8, Sendable, Equatable {
        case continueTransfer = 0, new = 1
    }

    public static let messageID = GFDIMessageID.downloadRequest
    public var fileIndex: UInt16
    public var dataOffset: UInt32
    public var mode: Mode
    public var crcSeed: UInt16
    public var dataSize: UInt32
    /// Bit 0 requests compression.
    public var flags: UInt8

    public init(fileIndex: UInt16, dataOffset: UInt32, mode: Mode, crcSeed: UInt16, dataSize: UInt32, flags: UInt8 = 0) {
        self.fileIndex = fileIndex; self.dataOffset = dataOffset; self.mode = mode
        self.crcSeed = crcSeed; self.dataSize = dataSize; self.flags = flags
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt16(fileIndex)
        w.writeUInt32(dataOffset)
        w.writeUInt8(mode.rawValue)
        w.writeUInt16(crcSeed)
        w.writeUInt32(dataSize)
        w.writeUInt8(flags)
    }
}

/// RESPONSE (5002): the watch's answer to a download request. Only the ACK carries a body.
public struct GFDIDownloadRequestStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable {
        case ok, indexNotFound, notReadable, notReady, invalidRequest, crcMismatch, rangeExceedsFile
    }

    public static let originalType = GFDIMessageID.downloadRequest
    public var status: GFDIStatus
    public var result: Result
    public var maxFileSize: UInt32

    public init(status: GFDIStatus = .ack, result: Result, maxFileSize: UInt32) {
        self.status = status; self.result = result; self.maxFileSize = maxFileSize
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        result = try r.readEnum(Result.self)
        maxFileSize = try r.readUInt32()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt32(maxFileSize)
    }
}

// MARK: - Upload

/// UPLOAD_REQUEST (5003), phone -> watch. Answered by `GFDIUploadRequestStatus`.
public struct GFDIUploadRequest: GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.uploadRequest
    public var fileIndex: UInt16
    public var size: UInt32
    public var dataOffset: UInt32
    public var crcSeed: UInt16

    public init(fileIndex: UInt16, size: UInt32, dataOffset: UInt32 = 0, crcSeed: UInt16 = 0) {
        self.fileIndex = fileIndex; self.size = size; self.dataOffset = dataOffset; self.crcSeed = crcSeed
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt16(fileIndex)
        w.writeUInt32(size)
        w.writeUInt32(dataOffset)
        w.writeUInt16(crcSeed)
    }
}

/// RESPONSE (5003): the watch's answer to an upload request. Only the ACK carries a body.
public struct GFDIUploadRequestStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable {
        case ok, indexUnknown, indexNotWriteable, noSpaceLeft, invalid, notReady, crcIncorrect
    }

    public static let originalType = GFDIMessageID.uploadRequest
    public var status: GFDIStatus
    public var result: Result
    public var dataOffset: UInt32
    public var maxFileSize: UInt32
    public var crcSeed: UInt16

    public init(status: GFDIStatus = .ack, result: Result, dataOffset: UInt32, maxFileSize: UInt32, crcSeed: UInt16) {
        self.status = status; self.result = result; self.dataOffset = dataOffset
        self.maxFileSize = maxFileSize; self.crcSeed = crcSeed
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        result = try r.readEnum(Result.self)
        dataOffset = try r.readUInt32()
        maxFileSize = try r.readUInt32()
        crcSeed = try r.readUInt16()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt32(dataOffset)
        w.writeUInt32(maxFileSize)
        w.writeUInt16(crcSeed)
    }
}

// MARK: - File data

/// FILE_TRANSFER_DATA (5004). Phone -> watch carries an upload chunk; watch -> phone carries a download chunk.
/// The phone ACKs a watch chunk with `acknowledgement()`. Layout: `flags | crc | dataOffset | data`.
public struct GFDIFileTransferData: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.fileTransferData
    public var flags: UInt8
    public var crc: UInt16
    public var dataOffset: UInt32
    public var data: Data

    public init(flags: UInt8 = 0, crc: UInt16, dataOffset: UInt32, data: Data) {
        self.flags = flags; self.crc = crc; self.dataOffset = dataOffset; self.data = data
    }

    public init(payload r: inout ByteReader) throws {
        flags = try r.readUInt8()
        crc = try r.readUInt16()
        dataOffset = try r.readUInt32()
        data = r.readRemainingData()
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(flags)
        w.writeUInt16(crc)
        w.writeUInt32(dataOffset)
        w.writeData(data)
    }

    /// The ACK for a chunk from the watch: OK, with the offset just past this chunk.
    public func acknowledgement() -> GFDIResponse {
        GFDIFileTransferDataStatus(transfer: .ok, dataOffset: dataOffset &+ UInt32(data.count)).response
    }
}

/// RESPONSE (5004). The phone ACKs watch chunks with it, and the watch's reply to an upload chunk is parsed with it.
public struct GFDIFileTransferDataStatus: GFDIResponseMessage, Equatable {
    public enum Transfer: UInt8, Sendable, Equatable {
        case ok, resend, abort, crcMismatch, offsetMismatch, syncPaused
    }

    public static let originalType = GFDIMessageID.fileTransferData
    public var status: GFDIStatus
    public var transfer: Transfer
    public var dataOffset: UInt32

    public init(status: GFDIStatus = .ack, transfer: Transfer, dataOffset: UInt32) {
        self.status = status; self.transfer = transfer; self.dataOffset = dataOffset
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        transfer = try r.readEnum(Transfer.self)
        dataOffset = try r.readUInt32()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(transfer.rawValue)
        w.writeUInt32(dataOffset)
    }
}

// MARK: - Create, filter, flags, types, availability

/// CREATE_FILE (5005). Phone -> watch creates a file of `fileSize`; watch -> phone asks for the same. Layout:
/// `fileSize | dataType | subType | fileIndex | reserved | subTypeMask | numberMask | path (u16 length) | fileID`.
public struct GFDICreateFile: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.createFile
    public var fileSize: UInt32
    public var dataType: UInt8
    public var subType: UInt8
    public var fileIndex: UInt16
    public var subTypeMask: UInt8
    public var numberMask: UInt16
    public var path: String
    public var fileID: UInt64

    public init(fileSize: UInt32, dataType: UInt8, subType: UInt8, fileIndex: UInt16 = 0, subTypeMask: UInt8 = 0,
                numberMask: UInt16 = 0xFFFF, path: String = "", fileID: UInt64) {
        self.fileSize = fileSize; self.dataType = dataType; self.subType = subType; self.fileIndex = fileIndex
        self.subTypeMask = subTypeMask; self.numberMask = numberMask; self.path = path; self.fileID = fileID
    }

    public init(payload r: inout ByteReader) throws {
        fileSize = try r.readUInt32()
        dataType = try r.readUInt8()
        subType = try r.readUInt8()
        fileIndex = try r.readUInt16()
        _ = try r.readUInt8() // reserved
        subTypeMask = try r.readUInt8()
        numberMask = try r.readUInt16()
        path = try r.readString16()
        fileID = try r.readUInt64()
    }

    /// The phone's ACK for a watch request to create a file.
    public func acknowledgement() -> GFDIResponse { .ack(.createFile) }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt32(fileSize)
        w.writeUInt8(dataType)
        w.writeUInt8(subType)
        w.writeUInt16(fileIndex)
        w.writeUInt8(0)
        w.writeUInt8(subTypeMask)
        w.writeUInt16(numberMask)
        let pathBytes = Array(path.utf8)
        w.writeUInt16(UInt16(pathBytes.count))
        w.writeBytes(pathBytes)
        w.writeUInt64(fileID)
    }
}

/// RESPONSE (5005): the watch's answer to a create-file request. Only the ACK carries a body.
public struct GFDICreateFileStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable {
        case ok, duplicate, noSpace, unsupported, noSlots, noSpaceForType
    }

    public static let originalType = GFDIMessageID.createFile
    public var status: GFDIStatus
    public var result: Result
    public var fileIndex: UInt16
    public var dataType: UInt8
    public var subType: UInt8
    public var fileNumber: UInt16

    public init(status: GFDIStatus = .ack, result: Result, fileIndex: UInt16, dataType: UInt8, subType: UInt8, fileNumber: UInt16) {
        self.status = status; self.result = result; self.fileIndex = fileIndex
        self.dataType = dataType; self.subType = subType; self.fileNumber = fileNumber
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        result = try r.readEnum(Result.self)
        fileIndex = try r.readUInt16()
        dataType = try r.readUInt8()
        subType = try r.readUInt8()
        fileNumber = try r.readUInt16()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt16(fileIndex)
        w.writeUInt8(dataType)
        w.writeUInt8(subType)
        w.writeUInt16(fileNumber)
    }
}

/// FILTER (5007), phone -> watch. Chooses which files the watch lists for sync.
public struct GFDIFilter: GFDIOutgoing, Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Equatable {
        case allFiles = 0, defaultFilter = 1, unknown2 = 2, onlyNew = 3
    }

    public static let messageID = GFDIMessageID.filter
    public var kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(kind.rawValue)
    }
}

/// RESPONSE (5007). Only the ACK carries a body.
public struct GFDIFilterStatus: GFDIResponseMessage, Equatable {
    public static let originalType = GFDIMessageID.filter
    public var status: GFDIStatus
    public var unknown: UInt8

    public init(status: GFDIStatus = .ack, unknown: UInt8) {
        self.status = status; self.unknown = unknown
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        unknown = try r.readUInt8()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(unknown)
    }
}

/// File flags for SET_FILE_FLAG. Bit values follow Gadgetbridge's `SetFileFlagsMessage.FileFlags` ordinals.
public struct GFDIFileFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unknown1 = GFDIFileFlags(rawValue: 0x01)
    public static let unknown2 = GFDIFileFlags(rawValue: 0x02)
    public static let crypto = GFDIFileFlags(rawValue: 0x04)
    public static let append = GFDIFileFlags(rawValue: 0x08)
    public static let archive = GFDIFileFlags(rawValue: 0x10)
    public static let erase = GFDIFileFlags(rawValue: 0x20)
    public static let write = GFDIFileFlags(rawValue: 0x40)
    public static let read = GFDIFileFlags(rawValue: 0x80)
}

/// SET_FILE_FLAG (8), phone -> watch.
public struct GFDISetFileFlags: GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.setFileFlag
    public var fileIndex: UInt16
    public var flags: GFDIFileFlags

    public init(fileIndex: UInt16, flags: GFDIFileFlags) {
        self.fileIndex = fileIndex; self.flags = flags
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt16(fileIndex)
        w.writeUInt8(flags.rawValue)
    }
}

/// RESPONSE (5008). Only the ACK carries a body. `fileIndex` is the raw wire value; Gadgetbridge adds 1 to
/// it, but that is an interpretation left to the session.
public struct GFDISetFileFlagsStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable {
        case applied = 0, error = 1
    }

    public static let originalType = GFDIMessageID.setFileFlag
    public var status: GFDIStatus
    public var result: Result
    public var fileIndex: UInt16
    public var flags: GFDIFileFlags

    public init(status: GFDIStatus = .ack, result: Result, fileIndex: UInt16, flags: GFDIFileFlags) {
        self.status = status; self.result = result; self.fileIndex = fileIndex; self.flags = flags
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        result = try r.readEnum(Result.self)
        fileIndex = try r.readUInt16()
        flags = GFDIFileFlags(rawValue: try r.readUInt8())
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt16(fileIndex)
        w.writeUInt8(flags.rawValue)
    }
}

/// SUPPORTED_FILE_TYPES_REQUEST (5031), phone -> watch. Has no payload.
public struct GFDISupportedFileTypesRequest: GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.supportedFileTypesRequest

    public init() {}

    public func encodePayload(into w: inout ByteWriter) {}
}

/// One entry of a supported-file-types list.
public struct GFDIFileTypeInfo: Sendable, Equatable {
    public var dataType: UInt8
    public var subType: UInt8
    public var name: String

    public init(dataType: UInt8, subType: UInt8, name: String) {
        self.dataType = dataType; self.subType = subType; self.name = name
    }
}

/// RESPONSE (5031): the watch's list of file types. Only the ACK carries a body.
public struct GFDISupportedFileTypesStatus: GFDIResponseMessage, Equatable {
    public static let originalType = GFDIMessageID.supportedFileTypesRequest
    public var status: GFDIStatus
    public var types: [GFDIFileTypeInfo]

    public init(status: GFDIStatus = .ack, types: [GFDIFileTypeInfo]) {
        self.status = status; self.types = types
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        let count = try r.readUInt8()
        types = try (0..<count).map { _ in
            GFDIFileTypeInfo(dataType: try r.readUInt8(), subType: try r.readUInt8(), name: try r.readString())
        }
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(UInt8(types.count))
        for type in types {
            w.writeUInt8(type.dataType)
            w.writeUInt8(type.subType)
            w.writeString(type.name)
        }
    }
}

/// FILE_AVAILABLE (5009), watch -> phone. Announces one file on the watch. Gadgetbridge ACKs without a body.
public struct GFDIFileAvailable: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.fileAvailable
    public var fileIndex: UInt16
    public var dataType: UInt8
    public var subType: UInt8
    public var fileNumber: UInt16
    public var specificFlags: UInt8
    public var fileFlags: UInt8
    public var fileSize: UInt32
    /// `nil` when the watch sends a zero timestamp.
    public var date: Date?

    public init(payload r: inout ByteReader) throws {
        fileIndex = try r.readUInt16()
        dataType = try r.readUInt8()
        subType = try r.readUInt8()
        fileNumber = try r.readUInt16()
        specificFlags = try r.readUInt8()
        fileFlags = try r.readUInt8()
        fileSize = try r.readUInt32()
        let timestamp = try r.readUInt32()
        date = timestamp == 0 ? nil : GarminTime.date(fromGarmin: timestamp)
        // Byte 16 is an unknown flag that Gadgetbridge does not read.
    }

    public func acknowledgement() -> GFDIResponse { .ack(.fileAvailable) }
}
