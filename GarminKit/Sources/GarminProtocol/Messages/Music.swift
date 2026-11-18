import Foundation
import GarminCore

// Music control: the watch sends media keys, and the phone answers with its command list and track metadata.

/// Media commands. The wire value is the position in Gadgetbridge's `GarminMusicControlCommand`.
public enum GFDIMusicCommand: UInt8, Sendable, CaseIterable {
    case togglePlayPause, skipToNextItem, skipToPreviousItem, volumeUp, volumeDown
    case play, pause, skipForward, skipBackwards
}

/// MUSIC_CONTROL (5041), watch -> phone. Answer with `acknowledgement()`.
public struct GFDIMusicControl: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.musicControl
    public var command: GFDIMusicCommand

    public init(command: GFDIMusicCommand) {
        self.command = command
    }

    public init(payload r: inout ByteReader) throws {
        command = try r.readEnum(GFDIMusicCommand.self)
    }

    public func acknowledgement() -> GFDIResponse { .ack(.musicControl) }
}

/// MUSIC_CONTROL_CAPABILITIES (5042), watch -> phone. Some watches send no capability byte at all.
public struct GFDIMusicControlCapabilities: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.musicControlCapabilities
    /// The watch's capability byte, or 0 when it sent none. The phone's reply does not depend on it.
    public var supported: UInt8

    public init(supported: UInt8) {
        self.supported = supported
    }

    public init(payload r: inout ByteReader) throws {
        supported = 0
        if r.remaining > 0 { supported = try r.readUInt8() }
    }

    /// The phone's ACK lists every command it supports: count, then each command's wire value.
    public func acknowledgement() -> GFDIResponse {
        var w = ByteWriter()
        w.writeUInt8(UInt8(GFDIMusicCommand.allCases.count))
        for command in GFDIMusicCommand.allCases {
            w.writeUInt8(command.rawValue)
        }
        return .ack(.musicControlCapabilities, body: w.data)
    }
}

/// Track and player attributes the phone can push (Gadgetbridge `MusicControlEntityUpdateMessage`).
public enum GFDIMusicAttribute: Sendable, Hashable, CaseIterable {
    case playerName, playerPlaybackInfo, playerVolume
    case queueIndex, queueCount, queueShuffle, queueRepeat
    case trackArtist, trackAlbum, trackTitle, trackDuration

    /// Gadgetbridge's entity id and the attribute's ordinal inside that entity.
    var wireIDs: (entity: UInt8, ordinal: UInt8) {
        switch self {
        case .playerName: (0, 0)
        case .playerPlaybackInfo: (0, 1)
        case .playerVolume: (0, 2)
        case .queueIndex: (1, 0)
        case .queueCount: (1, 1)
        case .queueShuffle: (1, 2)
        case .queueRepeat: (1, 3)
        case .trackArtist: (2, 0)
        case .trackAlbum: (2, 1)
        case .trackTitle: (2, 2)
        case .trackDuration: (2, 3)
        }
    }
}

/// MUSIC_CONTROL_ENTITY_UPDATE (5049), phone -> watch. The payload is a list of entries, each
/// `length (u8) | entity (u8) | ordinal (u8) | 0 (u8) | value`, where length counts the three bytes after it
/// plus the value. Entries are written in `GFDIMusicAttribute` order.
public struct GFDIMusicEntityUpdate: GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.musicControlEntityUpdate
    public var attributes: [GFDIMusicAttribute: String]

    public init(attributes: [GFDIMusicAttribute: String]) {
        self.attributes = attributes
    }

    public func encodePayload(into w: inout ByteWriter) {
        for attribute in GFDIMusicAttribute.allCases {
            guard var value = attributes[attribute] else { continue }
            // The length byte holds value + 3 in 8 bits, so longer values are cut at a character boundary.
            while value.utf8.count > 252 { value.removeLast() }
            let bytes = Array(value.utf8)
            let ids = attribute.wireIDs
            w.writeUInt8(UInt8(bytes.count + 3))
            w.writeUInt8(ids.entity)
            w.writeUInt8(ids.ordinal)
            w.writeUInt8(0)
            w.writeBytes(bytes)
        }
    }
}
