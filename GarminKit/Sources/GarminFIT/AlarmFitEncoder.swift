import Foundation
import GarminCore
import GarminModels

/// Encodes alarms as a FIT settings file (file type 2), laid out as Gadgetbridge's `GarminSupport.onSetAlarms` writes
/// it: big-endian values, local type 0 with a definition per message, and the fields in the order Gadgetbridge sets
/// them. The file has the FILE_ID, one ALARM_SETTINGS message per alarm, and a DEVICE_SETTINGS message listing them.
/// Without alarms it has only the FILE_ID, which is what clears the watch's alarms.
public enum AlarmFitEncoder {
    private static let settingsFileType: Int64 = 2
    private static let deviceSettings: UInt16 = 2
    private static let alarmSettings: UInt16 = 222
    /// Gadgetbridge's AlarmMode.CUSTOM: every alarm has its own time.
    private static let customMode: Int64 = 5
    /// Gadgetbridge sends a one-time alarm with the repeat mask 128, because its own mask is 0 then.
    private static let onceRepeat: Int64 = 128

    public static func encode(_ alarms: [WatchAlarm], now: Date = .now) -> Data {
        var body = ByteWriter()
        for message in messages(alarms, now: now) {
            body.writeBytes(FitEncoder.definitionMessage(localType: 0, message, bigEndian: true))
            body.writeBytes(FitEncoder.dataMessage(localType: 0, message, bigEndian: true))
        }
        return FitEncoder.wrap(body.bytes)
    }

    private static func messages(_ alarms: [WatchAlarm], now: Date) -> [FitEncodeMessage] {
        let created = Int64(GarminTime.garminSeconds(from: now))
        let fileId = FitEncodeMessage(globalNumber: 0, fields: [
            field(0, .enumeration, settingsFileType),
            field(1, .uint16, 1), // Garmin
            field(2, .uint16, 65534), // Connect
            field(4, .uint32, created),
            field(3, .uint32z, 1),
            field(5, .uint16, 1),
        ])
        guard !alarms.isEmpty else { return [fileId] }

        let alarmMessages = alarms.enumerated().map { index, alarm in
            FitEncodeMessage(globalNumber: alarmSettings, fields: [
                field(0, .uint16, minuteOfDay(alarm)),
                field(1, .uint32z, repeatMask(alarm)),
                field(2, .enumeration, alarm.isEnabled ? 1 : 0),
                field(3, .enumeration, Int64(alarm.sound.rawValue)),
                field(4, .enumeration, alarm.backlight ? 1 : 0),
                field(5, .uint32, created),
                field(7, .uint8, 0), // snooze
                field(8, .enumeration, 0), // label: none
                field(254, .uint16, Int64(index)), // message index
            ])
        }

        // Gadgetbridge adds the device settings only when at least one alarm is enabled.
        guard alarms.contains(where: \.isEnabled) else { return [fileId] + alarmMessages }
        let deviceMessage = FitEncodeMessage(globalNumber: deviceSettings, fields: [
            FitEncodeField(8, .uint16, .array(alarms.map { .int(minuteOfDay($0)) })),
            FitEncodeField(9, .enumeration, .array(alarms.map { _ in .int(customMode) })),
            FitEncodeField(28, .enumeration, .array(alarms.map { .int($0.isEnabled ? 1 : 0) })),
            FitEncodeField(92, .uint32z, .array(alarms.map { .int(repeatMask($0)) })),
        ])
        return [fileId] + alarmMessages + [deviceMessage]
    }

    private static func minuteOfDay(_ alarm: WatchAlarm) -> Int64 {
        Int64(alarm.hour * 60 + alarm.minute)
    }

    private static func repeatMask(_ alarm: WatchAlarm) -> Int64 {
        guard !alarm.weekdays.isEmpty else { return onceRepeat }
        return Int64(alarm.weekdays.reduce(0) { $0 | $1.bit })
    }

    private static func field(_ number: UInt8, _ baseType: FitBaseType, _ value: Int64) -> FitEncodeField {
        FitEncodeField(number, baseType, .int(value))
    }
}
