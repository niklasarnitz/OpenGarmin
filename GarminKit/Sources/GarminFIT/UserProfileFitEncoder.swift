import Foundation
import GarminCore
import GarminModels

/// Encodes a `UserProfile` as a FIT settings file (file type 2), laid out as Gadgetbridge writes its settings files
/// (`GarminSupport.onSetAlarms`, `GarminSettingsCustomizer`): big-endian values, and every message under local type 0
/// with its own definition. The file has the FILE_ID, the USER_PROFILE and a DEVICE_SETTINGS message for the clock.
public enum UserProfileFitEncoder {
    private static let settingsFileType: Int64 = 2
    private static let metric: Int64 = 0
    private static let imperial: Int64 = 1
    private static let twelveHour: Int64 = 0
    private static let twentyFourHour: Int64 = 1

    public static func encode(_ profile: UserProfile, now: Date = .now) -> Data {
        var body = ByteWriter()
        for message in messages(profile, now: now) {
            body.writeBytes(FitEncoder.definitionMessage(localType: 0, message, bigEndian: true))
            body.writeBytes(FitEncoder.dataMessage(localType: 0, message, bigEndian: true))
        }
        return FitEncoder.wrap(body.bytes)
    }

    private static func messages(_ profile: UserProfile, now: Date) -> [FitEncodeMessage] {
        let fileId = FitEncodeMessage(globalNumber: 0, fields: [
            field(0, .enumeration, settingsFileType),
            field(1, .uint16, 1), // Garmin
            field(2, .uint16, 65534), // Connect
            field(4, .uint32, Int64(GarminTime.garminSeconds(from: now))),
            field(3, .uint32z, 1),
            field(5, .uint16, 1),
        ])

        // Unset values are left out, so the watch keeps what it has. The units are one choice in Gadgetbridge's
        // profile: every DisplayMeasure field follows the same system.
        let units = profile.usesMetricUnits ? metric : imperial
        let profileValues: [(UInt8, FitBaseType, Int64?)] = [
            (1, .enumeration, profile.gender.map { $0 == .male ? 1 as Int64 : 0 }),
            (3, .uint8, profile.heightCm.map { Int64($0.rounded()) }),
            (4, .uint16, profile.weightKg.map { Int64(($0 * 10).rounded()) }),
            (6, .enumeration, units),
            (7, .enumeration, units),
            (8, .uint8, profile.restingHeartRate.map { Int64($0) }),
            (11, .uint8, profile.maxHeartRate.map { Int64($0) }),
            (13, .enumeration, units),
            (14, .enumeration, units),
            (21, .enumeration, units),
            (24, .uint8, profile.birthDate.map { Int64(Calendar.current.component(.year, from: $0)) - 1900 }),
            (28, .uint32, profile.wakeTime.flatMap(secondsOfDay)),
            (29, .uint32, profile.sleepTime.flatMap(secondsOfDay)),
            (30, .enumeration, units),
        ]
        let userProfile = FitEncodeMessage(globalNumber: 3, fields: profileValues.compactMap { number, type, value in
            value.map { field(number, type, $0) }
        })

        let deviceSettings = FitEncodeMessage(globalNumber: 2, fields: [
            field(4, .enumeration, profile.uses24HourTime ? twentyFourHour : twelveHour), // time_mode
        ])
        return [fileId, userProfile, deviceSettings]
    }

    /// Seconds since local midnight, as the watch stores wake and sleep times.
    private static func secondsOfDay(_ time: DateComponents) -> Int64? {
        guard let hour = time.hour else { return nil }
        let minutes: Int = time.minute ?? 0
        let seconds: Int = time.second ?? 0
        let total: Int = hour * 3600 + minutes * 60 + seconds
        return Int64(total)
    }

    private static func field(_ number: UInt8, _ baseType: FitBaseType, _ value: Int64) -> FitEncodeField {
        FitEncodeField(number, baseType, .int(value))
    }
}
