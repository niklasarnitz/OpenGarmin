import Foundation
import GarminCore
import GarminModels

// MARK: - Device identity

/// DEVICE_INFORMATION (5024), watch -> phone. The phone answers with `acknowledgement`, which is the
/// phone's own identity (Gadgetbridge `DeviceInformationMessage`).
public struct GFDIDeviceInformation: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.deviceInformation
    public var protocolVersion: Int
    public var productNumber: Int
    public var unitNumber: UInt32
    public var softwareVersion: Int
    public var maxPacketSize: Int
    public var bluetoothName: String
    public var deviceName: String
    public var deviceModel: String
    /// Classic Bluetooth address ("AA:BB:CC:DD:EE:FF") when the watch reports one.
    public var classicAddress: String?

    public init(payload r: inout ByteReader) throws {
        protocolVersion = Int(try r.readUInt16())
        productNumber = Int(try r.readUInt16())
        unitNumber = try r.readUInt32()
        softwareVersion = Int(try r.readUInt16())
        maxPacketSize = Int(try r.readUInt16())
        bluetoothName = try r.readString()
        deviceName = try r.readString()
        deviceModel = try r.readString()
        if r.remaining > 0 {
            let hasMac = try r.readUInt8()
            if hasMac == 1 {
                _ = try r.readBytes(6) // BLE address, not used
                let classic = try r.readBytes(6) // stored little-endian
                classicAddress = classic.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            if r.remaining > 0 { try r.skip(1) }
        }
    }

    /// The phone's ACK: protocol 150, unknown product/unit/max packet (-1), software 77.91, then the phone's
    /// Bluetooth name, manufacturer and model. Flag bit 0 is set for protocol 1.xx watches.
    public func acknowledgement(phoneName: String, manufacturer: String, model: String) -> GFDIResponse {
        var w = ByteWriter()
        w.writeUInt16(150)
        w.writeUInt16(0xFFFF)
        w.writeUInt32(0xFFFF_FFFF)
        w.writeUInt16(7791)
        w.writeUInt16(0xFFFF)
        w.writeString(phoneName)
        w.writeString(manufacturer)
        w.writeString(model)
        w.writeUInt8(protocolVersion / 100 == 1 ? 1 : 0)
        return .ack(.deviceInformation, body: w.data)
    }

    public var deviceInfo: DeviceInfo {
        DeviceInfo(protocolVersion: protocolVersion, productNumber: productNumber, unitNumber: unitNumber,
                   softwareVersion: softwareVersion, maxPacketSize: maxPacketSize, bluetoothName: bluetoothName,
                   deviceName: deviceName, deviceModel: deviceModel)
    }
}

// MARK: - Capabilities

/// CONFIGURATION (5050). The watch sends its capability bitmask; the phone ACKs with `acknowledgement`
/// and then sends its own CONFIGURATION frame (not a RESPONSE) built from `init(capabilities:)`.
public struct GFDIConfiguration: GFDIIncoming, GFDIOutgoing, Sendable, Equatable {
    public static let messageID = GFDIMessageID.configuration
    /// Raw capability bits, bit `i` = Gadgetbridge capability `i`, LSB first. Kept whole so bits without a
    /// `GarminCapability` case survive a round trip.
    public var bitmask: [UInt8]

    public init(bitmask: [UInt8]) {
        self.bitmask = bitmask
    }

    public init(capabilities: Set<GarminCapability>) {
        self.bitmask = GFDICapabilityBits.encode(capabilities)
    }

    public init(payload r: inout ByteReader) throws {
        let count = try r.readUInt8()
        bitmask = try r.readBytes(Int(count))
    }

    public var capabilities: Set<GarminCapability> { GFDICapabilityBits.decode(bitmask) }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(UInt8(bitmask.count))
        w.writeBytes(bitmask)
    }

    public func acknowledgement() -> GFDIResponse { .ack(.configuration) }
}

/// `GarminCapability.rawValue` is the bit index in Gadgetbridge's capability bitmask.
enum GFDICapabilityBits {
    /// `(129 + 7) / 8`: Gadgetbridge sends its capability set as a fixed-width bitmask of its 129 entries.
    static let byteCount = 17

    static func encode(_ capabilities: Set<GarminCapability>) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for item in capabilities {
            let bit = item.rawValue
            bytes[bit / 8] |= UInt8(1 << (bit % 8))
        }
        return bytes
    }

    static func decode(_ bytes: [UInt8]) -> Set<GarminCapability> {
        var result = Set<GarminCapability>()
        for (byteIndex, byte) in bytes.enumerated() {
            for bit in 0..<8 where byte & UInt8(1 << bit) != 0 {
                if let item = GarminCapability(rawValue: byteIndex * 8 + bit) { result.insert(item) }
            }
        }
        return result
    }
}

// MARK: - Time

/// CURRENT_TIME_REQUEST (5052), watch -> phone.
public struct GFDICurrentTimeRequest: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.currentTimeRequest
    public var referenceID: UInt32

    public init(payload r: inout ByteReader) throws {
        referenceID = try r.readUInt32()
    }

    /// The time reply. The next two DST transitions follow Gadgetbridge: the transition after the next one
    /// is written first, then the next one.
    public func acknowledgement(at date: Date = Date(), timeZone: TimeZone = .current) -> GFDIResponse {
        let start = timeZone.nextDaylightSavingTimeTransition(after: date)
        let end = start.flatMap { timeZone.nextDaylightSavingTimeTransition(after: $0) }
        let reply = GFDICurrentTimeResponse(
            referenceID: referenceID,
            garminTime: GarminTime.garminSeconds(from: date),
            utcOffset: Int32(timeZone.secondsFromGMT(for: date)),
            nextDSTEnd: end.map(GarminTime.garminSeconds(from:)) ?? 0,
            nextDSTStart: start.map(GarminTime.garminSeconds(from:)) ?? 0
        )
        return reply.response
    }
}

/// RESPONSE (5052) with the time. Layout: `referenceID | garminTime | utcOffset | nextDSTEnd | nextDSTStart`.
public struct GFDICurrentTimeResponse: GFDIResponseMessage, Equatable {
    public static let originalType = GFDIMessageID.currentTimeRequest
    public var status: GFDIStatus
    public var referenceID: UInt32
    public var garminTime: UInt32
    public var utcOffset: Int32
    public var nextDSTEnd: UInt32
    public var nextDSTStart: UInt32

    public init(status: GFDIStatus = .ack, referenceID: UInt32, garminTime: UInt32, utcOffset: Int32,
                nextDSTEnd: UInt32, nextDSTStart: UInt32) {
        self.status = status; self.referenceID = referenceID; self.garminTime = garminTime
        self.utcOffset = utcOffset; self.nextDSTEnd = nextDSTEnd; self.nextDSTStart = nextDSTStart
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        referenceID = try r.readUInt32()
        garminTime = try r.readUInt32()
        utcOffset = try r.readInt32()
        nextDSTEnd = try r.readUInt32()
        nextDSTStart = try r.readUInt32()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt32(referenceID)
        w.writeUInt32(garminTime)
        w.writeInt32(utcOffset)
        w.writeUInt32(nextDSTEnd)
        w.writeUInt32(nextDSTStart)
    }
}

// MARK: - Sync and battery

/// SYNCHRONIZATION (5037), watch -> phone. Gadgetbridge ACKs it without a body.
public struct GFDISynchronization: GFDIIncoming, Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Equatable {
        case manual = 0, automatic = 1, type2 = 2
    }

    public static let messageID = GFDIMessageID.synchronization
    public var kind: Kind
    /// Bit `n` set means `GFDISyncFileType(rawValue: n)` is requested. A 4-byte bitmask is zero-extended.
    public var fileTypes: UInt64

    public init(payload r: inout ByteReader) throws {
        kind = try r.readEnum(Kind.self)
        let size = try r.readUInt8()
        switch size {
        case 8: fileTypes = try r.readUInt64()
        case 4: fileTypes = UInt64(try r.readUInt32())
        default: throw GFDIError.malformed("synchronization bitmask size \(size)")
        }
    }

    public func contains(_ type: GFDISyncFileType) -> Bool {
        fileTypes & (UInt64(1) << UInt64(type.rawValue)) != 0
    }

    public func acknowledgement() -> GFDIResponse { .ack(.synchronization) }
}

/// BATTERY_STATUS (5023), watch -> phone. Bytes after the first three are not decoded by Gadgetbridge either.
public struct GFDIBatteryStatus: GFDIIncoming, Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        case good, ok, low, critical, new, invalid
        /// Condition bits that are not defined, as the raw `0x70` mask value.
        case other(UInt8)
    }

    public static let messageID = GFDIMessageID.batteryStatus
    public var condition: Condition
    public var voltage: Double
    public var percent: Int

    public init(payload r: inout ByteReader) throws {
        let wire = try r.readUInt8()
        voltage = Double(try r.readUInt8()) / 100
        percent = Int(try r.readUInt8())
        switch wire & 0x70 {
        case 0x10: condition = .good
        case 0x20: condition = .ok
        case 0x30: condition = .low
        case 0x40: condition = .critical
        case 0x50: condition = .new
        case 0x70: condition = .invalid
        default: condition = .other(wire & 0x70)
        }
    }

    public func acknowledgement() -> GFDIResponse { .ack(.batteryStatus) }
}

// MARK: - Phone -> watch events and settings

/// SYSTEM_EVENT (5030), phone -> watch.
public struct GFDISystemEvent: GFDIOutgoing, Sendable, Equatable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        case syncComplete, syncFail, factoryReset, pairStart, pairComplete, pairFail
        case hostDidEnterForeground, hostDidEnterBackground, syncReady, newDownloadAvailable
        case deviceSoftwareUpdate, deviceDisconnect, tutorialComplete
        case setupWizardStart, setupWizardComplete, setupWizardSkipped
        case timeUpdated, triggerReboot
    }

    public enum Value: Sendable, Equatable {
        case byte(UInt8)
        case text(String)
    }

    public static let messageID = GFDIMessageID.systemEvent
    public var kind: Kind
    public var value: Value

    public init(_ kind: Kind, value: Value = .byte(0)) {
        self.kind = kind
        self.value = value
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(kind.rawValue)
        switch value {
        case .byte(let byte): w.writeUInt8(byte)
        case .text(let text): w.writeString(text)
        }
    }
}

/// DEVICE_SETTINGS (5026), phone -> watch. Settings are written in raw-value order.
public struct GFDISetDeviceSettings: GFDIOutgoing, Sendable, Equatable {
    public enum Setting: UInt8, Sendable, CaseIterable {
        case deviceName, currentTime, daylightSavingsTimeOffset, timeZoneOffset
        case nextDaylightSavingsStart, nextDaylightSavingsEnd
        case autoUploadEnabled, weatherConditionsEnabled, weatherAlertsEnabled
    }

    public enum Value: Sendable, Equatable {
        case text(String)
        case int(Int32)
        case bool(Bool)
    }

    public static let messageID = GFDIMessageID.deviceSettings
    public var settings: [Setting: Value]

    public init(settings: [Setting: Value]) {
        self.settings = settings
    }

    public func encodePayload(into w: inout ByteWriter) {
        w.writeUInt8(UInt8(settings.count))
        for (setting, value) in settings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            w.writeUInt8(setting.rawValue)
            switch value {
            case .text(let text):
                w.writeString(text)
            case .int(let value):
                w.writeUInt8(4)
                w.writeInt32(value)
            case .bool(let value):
                w.writeUInt8(1)
                w.writeUInt8(value ? 1 : 0)
            }
        }
    }
}

// MARK: - Find my phone, weather

/// FIND_MY_PHONE_REQUEST (5039), watch -> phone. `duration` is in seconds as the watch sends it.
public struct GFDIFindMyPhoneRequest: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.findMyPhoneRequest
    public var duration: UInt8

    public init(payload r: inout ByteReader) throws {
        duration = try r.readUInt8()
    }

    public func acknowledgement() -> GFDIResponse { .ack(.findMyPhoneRequest) }
}

/// FIND_MY_PHONE_CANCEL (5040), watch -> phone. Has no payload.
public struct GFDIFindMyPhoneCancel: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.findMyPhoneCancel

    public init(payload r: inout ByteReader) throws {}

    public func acknowledgement() -> GFDIResponse { .ack(.findMyPhoneCancel) }
}

/// WEATHER_REQUEST (5014), watch -> phone. Coordinates are the raw signed integers the watch sends.
public struct GFDIWeatherRequest: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.weatherRequest
    public var format: UInt8
    public var latitude: Int32
    public var longitude: Int32
    public var hoursOfForecast: UInt8

    public init(payload r: inout ByteReader) throws {
        format = try r.readUInt8()
        latitude = try r.readInt32()
        longitude = try r.readInt32()
        hoursOfForecast = try r.readUInt8()
    }

    public func acknowledgement() -> GFDIResponse { .ack(.weatherRequest) }
}

// MARK: - Auth negotiation

/// AUTH_NEGOTIATION (5101), watch -> phone. `unknown` and `flags` are echoed back in the ACK.
public struct GFDIAuthNegotiation: GFDIIncoming, Sendable, Equatable {
    public static let messageID = GFDIMessageID.authNegotiation
    public var unknown: UInt8
    /// Gadgetbridge `AuthFlags` bit set (UNK_00000001 is bit 0).
    public var flags: UInt32

    public init(payload r: inout ByteReader) throws {
        unknown = try r.readUInt8()
        flags = try r.readUInt32()
    }

    /// The ACK: `GUESS_OK` with the watch's `unknown` and `flags` echoed.
    public func acknowledgement() -> GFDIResponse {
        GFDIAuthNegotiationStatus(status: .ack, result: .guessOK, unknown: unknown, flags: flags).response
    }
}

/// RESPONSE (5101). The phone ACKs the watch's request with `result: .guessOK`, and the watch's reply to an
/// auth message is parsed the same way.
public struct GFDIAuthNegotiationStatus: GFDIResponseMessage, Equatable {
    public enum Result: UInt8, Sendable, Equatable {
        case guessOK = 0, guessKO = 1
    }

    public static let originalType = GFDIMessageID.authNegotiation
    public var status: GFDIStatus
    public var result: Result
    public var unknown: UInt8
    public var flags: UInt32

    public init(status: GFDIStatus, result: Result, unknown: UInt8, flags: UInt32) {
        self.status = status; self.result = result; self.unknown = unknown; self.flags = flags
    }

    public init(status: GFDIStatus, body r: inout ByteReader) throws {
        self.status = status
        result = try r.readEnum(Result.self)
        unknown = try r.readUInt8()
        flags = try r.readUInt32()
    }

    public func writeBody(into w: inout ByteWriter) {
        w.writeUInt8(result.rawValue)
        w.writeUInt8(unknown)
        w.writeUInt32(flags)
    }
}
