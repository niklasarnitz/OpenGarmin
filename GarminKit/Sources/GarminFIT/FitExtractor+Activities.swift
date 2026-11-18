import Foundation
import GarminModels

extension FitExtractor {
    /// One activity per session message. Laps and records are assigned to the session they fall into.
    static func extractActivities(_ file: FitFile, unitNumber: UInt32?, into batch: inout HealthBatch) {
        let laps = file.messages(FitMesg.lap)
        let records = file.messages(FitMesg.record)

        for session in file.messages(FitMesg.session) {
            guard let startTs = session.int(2) ?? session.timestamp else { continue }
            let start = Double(startTs)
            let elapsed = session.double(7, scale: 1000)
            let timer = session.double(8, scale: 1000)
            let duration = timer ?? elapsed ?? 0
            let end = start + (elapsed ?? duration)

            let sessionLaps: [ActivityLap] = laps.compactMap { lap in
                guard let lapStartTs = lap.int(2) ?? lap.timestamp else { return nil }
                let lapStart = Double(lapStartTs)
                guard lapStart >= start, lapStart <= end else { return nil }
                return ActivityLap(
                    start: date(lapStart),
                    end: date(lapStart + (lap.double(7, scale: 1000) ?? 0)),
                    distance: lap.double(9, scale: 100),
                    calories: lap.double(11),
                    averageHeartRate: lap.int(15).map(Int.init)
                )
            }

            let sessionRecords: [ActivityRecord] = records.compactMap { record in
                guard let ts = record.timestamp, Double(ts) >= start, Double(ts) <= end else { return nil }
                return activityRecord(record)
            }

            batch.activities.append(Activity(
                id: "\(unitNumber ?? 0)-\(startTs)",
                sport: Sport(rawValue: Int(session.int(5) ?? 0)) ?? .generic,
                subSport: session.int(6).map(Int.init),
                start: date(start),
                end: date(end),
                duration: duration,
                distance: session.double(9, scale: 100),
                activeCalories: session.double(11),
                averageHeartRate: session.int(16).map(Int.init),
                maxHeartRate: session.int(17).map(Int.init),
                totalAscent: session.double(22),
                totalDescent: session.double(23),
                averageSpeed: session.double(124, scale: 1000) ?? session.double(14, scale: 1000),
                averageCadence: session.int(18).map(Int.init),
                averagePower: session.int(20).map(Int.init),
                trainingEffect: session.double(24, scale: 10),
                laps: sessionLaps,
                records: sessionRecords
            ))
        }
    }

    private static func activityRecord(_ message: FitMessage) -> ActivityRecord? {
        guard let ts = message.timestamp else { return nil }
        // position_lat / position_long are semicircles: 2^31 semicircles is 180 degrees.
        let semicircleDegrees = 180.0 / 2_147_483_648.0
        return ActivityRecord(
            date: date(ts),
            latitude: message.double(0).map { $0 * semicircleDegrees },
            longitude: message.double(1).map { $0 * semicircleDegrees },
            altitude: message.double(78, scale: 5, offset: 500) ?? message.double(2, scale: 5, offset: 500),
            heartRate: message.int(3).map(Int.init),
            speed: message.double(73, scale: 1000) ?? message.double(6, scale: 1000),
            distance: message.double(5, scale: 100),
            cadence: message.int(4).map(Int.init),
            power: message.int(7).map(Int.init),
            temperature: message.double(13)
        )
    }
}
