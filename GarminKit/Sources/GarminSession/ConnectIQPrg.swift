import Foundation

/// A Connect IQ app file (.prg): the app's identifier and kind, read from its entry points as Gadgetbridge's
/// `garmin_prg.ksy` describes the file. The watch installs the file as it is, so the rest of the file is not read.
public struct ConnectIQPrg: Sendable, Hashable {
    public enum AppType: Sendable, Hashable {
        case watchFace, watchApp, dataField, widget, background, audioContentProvider, glance
        case unknown

        init(raw: UInt32) {
            self = switch raw {
            case 0: .watchFace
            case 1: .watchApp
            case 2: .dataField
            case 3: .widget
            case 4: .background
            case 5: .audioContentProvider
            case 6: .glance
            default: .unknown
            }
        }
    }

    /// The app's identifier, the UUID of its first entry point. The watch lists the app under it.
    public var appID: UUID
    public var type: AppType
    public var size: Int

    /// The largest PRG the phone reads, as Gadgetbridge limits them.
    public static let maximumSize = 10 * 1024 * 1024

    public init(data: Data) throws {
        guard data.count <= Self.maximumSize else { throw ConnectIQPrgError.tooLarge }
        // Every file starts with the head section, whose magic begins with these bytes.
        guard data.prefix(3) == Data([0xd0, 0x00, 0xd0]) else { throw ConnectIQPrgError.notPRG }
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 8 <= bytes.count {
            let magic = Self.u32(bytes, offset)
            if magic == 0 { break } // end of sections
            let length = Int(Self.u32(bytes, offset + 4))
            let start = offset + 8
            guard start + length <= bytes.count else { throw ConnectIQPrgError.truncated }
            if magic == Self.entryPointsMagic, let entry = Self.firstEntryPoint(bytes, start, length) {
                appID = entry.id
                type = entry.type
                size = data.count
                return
            }
            offset = start + length
        }
        throw ConnectIQPrgError.noEntryPoint
    }

    private static let entryPointsMagic: UInt32 = 0x6060_c0de
    private static let entryPointSize = 36

    private static func firstEntryPoint(_ bytes: [UInt8], _ start: Int, _ length: Int) -> (id: UUID, type: AppType)? {
        guard length >= 2 else { return nil }
        let count = Int(bytes[start]) << 8 | Int(bytes[start + 1])
        guard count > 0, length >= 2 + entryPointSize else { return nil }
        // Entry point: UUID (16 bytes), module, class, label and icon label IDs (4 bytes each), app type (4 bytes).
        let entry = start + 2
        let id = UUID(uuid: (
            bytes[entry], bytes[entry + 1], bytes[entry + 2], bytes[entry + 3],
            bytes[entry + 4], bytes[entry + 5], bytes[entry + 6], bytes[entry + 7],
            bytes[entry + 8], bytes[entry + 9], bytes[entry + 10], bytes[entry + 11],
            bytes[entry + 12], bytes[entry + 13], bytes[entry + 14], bytes[entry + 15]
        ))
        return (id, AppType(raw: u32(bytes, entry + 32)))
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

public enum ConnectIQPrgError: Error, Equatable, Sendable {
    case notPRG
    case truncated
    case noEntryPoint
    case tooLarge
}

extension ConnectIQPrgError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPRG: "This is not a Connect IQ app file."
        case .truncated: "The Connect IQ app file is incomplete."
        case .noEntryPoint: "The Connect IQ app file has no entry point."
        case .tooLarge: "The Connect IQ app file is larger than 10 MB."
        }
    }
}
