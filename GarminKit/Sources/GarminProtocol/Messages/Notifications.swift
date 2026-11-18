import Foundation
import GarminCore

// Notifications (Gadgetbridge `NotificationsHandler` and the NOTIFICATION_* messages). The watch asks for
// notification text with CONTROL, the phone sends the text in DATA chunks and announces it with UPDATE,
// and SUBSCRIPTION turns delivery on or off.

/// Notification attributes the watch can request (Gadgetbridge `NotificationAttribute`).
public enum GFDINotificationAttribute: UInt8, Sendable, CaseIterable {
    case appIdentifier = 0, title = 1, subtitle = 2, message = 3, messageSize = 4, date = 5
    case negativeActionLabel = 7, actions = 127, attachments = 128
}

/// One requested attribute. `maxLength` is 0 when the watch sets no limit.
public struct GFDINotificationAttributeRequest: Sendable, Equatable {
    public var attribute: GFDINotificationAttribute
    public var maxLength: UInt16

    public init(attribute: GFDINotificationAttribute, maxLength: UInt16 = 0) {
        self.attribute = attribute
        self.maxLength = maxLength
    }
}

/// NOTIFICATION_CONTROL (5034), watch -> phone. Answer with `acknowledgement()`. Attribute values follow as
/// NOTIFICATION_DATA chunks.
public struct GFDINotificationControl: GFDIIncoming, Sendable, Equatable {
    public enum LegacyAction: UInt8, Sendable, Equatable { case accept = 0, refuse = 1 }

    public enum Request: Sendable, Equatable {
        case notificationAttributes(id: Int32, attributes: [GFDINotificationAttributeRequest])
        case appAttributes(appIdentifier: String, attributes: [UInt8])
        case legacyAction(id: Int32, action: LegacyAction)
        /// `actionID` is Gadgetbridge's `NotificationAction` code. `text` is present when the watch sends a reply.
        case action(id: Int32, actionID: UInt8, text: String?)
    }

    public static let messageID = GFDIMessageID.notificationControl
    public var request: Request

    public init(request: Request) {
        self.request = request
    }

    public init(payload r: inout ByteReader) throws {
        switch try r.readUInt8() {
        case 0: // GET_NOTIFICATION_ATTRIBUTES
            let id = try r.readInt32()
            var attributes: [GFDINotificationAttributeRequest] = []
            while r.remaining > 0 {
                let attribute = try r.readEnum(GFDINotificationAttribute.self)
                var maxLength: UInt16 = 0
                switch attribute {
                case .title, .subtitle, .message:
                    maxLength = try r.readUInt16()
                case .actions: // length, then one byte Gadgetbridge does not use
                    maxLength = try r.readUInt16()
                    try r.skip(1)
                default:
                    break
                }
                attributes.append(GFDINotificationAttributeRequest(attribute: attribute, maxLength: maxLength))
            }
            request = .notificationAttributes(id: id, attributes: attributes)
        case 1: // GET_APP_ATTRIBUTES
            let appIdentifier = try r.readNullTerminatedString()
            request = .appAttributes(appIdentifier: appIdentifier, attributes: r.readRest())
        case 2: // PERFORM_LEGACY_NOTIFICATION_ACTION
            let id = try r.readInt32()
            let action = try r.readEnum(LegacyAction.self)
            request = .legacyAction(id: id, action: action)
        case 128: // PERFORM_NOTIFICATION_ACTION
            let id = try r.readInt32()
            let actionID = try r.readUInt8()
            var text: String?
            if r.remaining > 0 { text = try r.readNullTerminatedString() }
            request = .action(id: id, actionID: actionID, text: text)
        default:
            throw GFDIError.malformed("notification control command")
        }
    }

    /// The phone's ACK: chunk OK, no error.
    public func acknowledgement() -> GFDIResponse {
        GFDINotificationControlStatus(chunk: .ok, code: .noError).response
    }
}

/// RESPONSE (5034). Body: `chunk status (u8) | code (u8)`.
public struct GFDINotificationControlStatus: GFDIResponseMessage, Equatable {
    public enum Chunk: UInt8, Sendable, Equatable { case ok, error }
    public enum Code: UInt8, Sendable, Equatable { case noError = 0, unknownCommand = 160 }

    public static let originalType = GFDIMessageID.notificationControl
    public var status: GFDIStatus
    public var chunk: Chunk
    public var code: Code

    public init(status: GFDIStatus = .ack, chunk: Chunk, code: Code) {
        self.status = status
        self.chunk = chunk
        self.code = code
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        chunk = try r.readEnum(Chunk.self)
        code = try r.readEnum(Code.self)
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(chunk.rawValue)
        w.writeUInt8(code.rawValue)
    }
}

/// NOTIFICATION_UPDATE (5033), phone -> watch. Adds, changes, or removes a notification on the watch.
/// Gadgetbridge has no typed status for it, so the watch's reply is a plain `GFDIResponse`.
public struct GFDINotificationUpdate: GFDIOutgoing, Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Equatable { case add, modify, remove }

    public enum Category: UInt8, Sendable, Equatable, CaseIterable {
        case other, incomingCall, missedCall, voicemail, social, schedule, email, news
        case healthAndFitness, businessAndFinance, location, entertainment, sms
    }

    /// Gadgetbridge `NotificationFlag` bit positions.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let background = Flags(rawValue: 1 << 0)
        public static let foreground = Flags(rawValue: 1 << 1)
        public static let unknown = Flags(rawValue: 1 << 2)
        public static let actionAccept = Flags(rawValue: 1 << 3)
        public static let actionDecline = Flags(rawValue: 1 << 4)
    }

    /// Gadgetbridge `NotificationPhoneFlags` bit positions.
    public struct PhoneFlags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let legacyActions = PhoneFlags(rawValue: 1 << 0)
        public static let newActions = PhoneFlags(rawValue: 1 << 1)
        public static let hasAttachments = PhoneFlags(rawValue: 1 << 2)
    }

    public static let messageID = GFDIMessageID.notificationUpdate
    public var kind: Kind
    public var flags: Flags
    public var category: Category
    /// How many notifications of this category are present.
    public var count: UInt8
    public var notificationID: Int32
    public var phoneFlags: PhoneFlags

    public init(kind: Kind, flags: Flags, category: Category, count: UInt8, notificationID: Int32, phoneFlags: PhoneFlags) {
        self.kind = kind
        self.flags = flags
        self.category = category
        self.count = count
        self.notificationID = notificationID
        self.phoneFlags = phoneFlags
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(kind.rawValue)
        w.writeUInt8(flags.rawValue)
        w.writeUInt8(category.rawValue)
        w.writeUInt8(count)
        w.writeInt32(notificationID)
        w.writeUInt8(phoneFlags.rawValue)
    }
}

/// NOTIFICATION_DATA (5035), phone -> watch. One chunk of notification or attribute data.
/// Layout: `messageSize (u16) | crc (u16) | dataOffset (u16) | chunk`.
public struct GFDINotificationData: GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.notificationData
    public var messageSize: UInt16
    public var crc: UInt16
    public var dataOffset: UInt16
    public var chunk: Data

    public init(messageSize: UInt16, crc: UInt16, dataOffset: UInt16, chunk: Data) {
        self.messageSize = messageSize
        self.crc = crc
        self.dataOffset = dataOffset
        self.chunk = chunk
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt16(messageSize)
        w.writeUInt16(crc)
        w.writeUInt16(dataOffset)
        w.writeData(chunk)
    }
}

/// RESPONSE (5035) to a NOTIFICATION_DATA chunk. Body: `transfer status (u8)`.
public struct GFDINotificationDataStatus: GFDIResponseMessage, Equatable {
    public enum Transfer: UInt8, Sendable, Equatable { case ok, resend, abort, crcMismatch, offsetMismatch }

    public static let originalType = GFDIMessageID.notificationData
    public var status: GFDIStatus
    public var transfer: Transfer

    public init(status: GFDIStatus = .ack, transfer: Transfer) {
        self.status = status
        self.transfer = transfer
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        try requireAck(status, for: Self.originalType)
        self.status = status
        transfer = try r.readEnum(Transfer.self)
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(transfer.rawValue)
    }
}

/// NOTIFICATION_SUBSCRIPTION (5036), watch -> phone. Turns delivery of phone notifications on or off.
public struct GFDINotificationSubscription: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.notificationSubscription
    public var enable: Bool
    public var unk: UInt8

    public init(enable: Bool, unk: UInt8) {
        self.enable = enable
        self.unk = unk
    }

    public init(payload r: inout ByteReader) throws {
        enable = try r.readUInt8() == 1
        unk = 0
        if r.remaining > 0 { unk = try r.readUInt8() }
    }

    /// The phone's reply reports whether it sends app notifications. `enable` is echoed; `unk` is sent as 0,
    /// as Gadgetbridge does.
    public func acknowledgement(sendsAppNotifications: Bool) -> GFDIResponse {
        GFDINotificationSubscriptionStatus(
            result: sendsAppNotifications ? .enabled : .disabled, enable: enable, unk: 0
        ).response
    }
}

/// RESPONSE (5036). Body: `result (u8) | enable (u8) | unk (u8)`.
public struct GFDINotificationSubscriptionStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable { case enabled = 0, disabled = 1 }

    public static let originalType = GFDIMessageID.notificationSubscription
    public var status: GFDIStatus
    public var result: Result
    public var enable: Bool
    public var unk: UInt8

    public init(status: GFDIStatus = .ack, result: Result, enable: Bool, unk: UInt8) {
        self.status = status
        self.result = result
        self.enable = enable
        self.unk = unk
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        result = try r.readEnum(Result.self)
        enable = try r.readUInt8() == 1
        unk = try r.readUInt8()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt8(enable ? 1 : 0)
        w.writeUInt8(unk)
    }
}
