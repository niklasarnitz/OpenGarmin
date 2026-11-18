import Foundation
import Testing
import GarminFIT
import GarminModels

/// Garmin/FIT epoch, 1989-12-31T00:00:00Z, as seconds since 1970.
private let garminEpoch: TimeInterval = 631_065_600

private func fitDate(_ seconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds) + garminEpoch)
}

private func file(_ messages: [FitMessage]) -> FitFile {
    FitFile(protocolVersion: 0x10, profileVersion: 21117, messages: messages)
}

private func monitoring(_ ts: Int64, type: Int64, cycles: Int64, kcal: Int64? = nil) -> FitMessage {
    var fields: [UInt8: FitValue] = [253: .int(ts), 5: .int(type), 3: .int(cycles)]
    fields[19] = kcal.map { FitValue.int($0) }
    return FitMessage(globalNumber: 55, fields: fields)
}

@Test func monitoringCountersBecomeIntervalsPerActivityType() {
    let batch = FitExtractor.extract(file([
        monitoring(1000, type: 1, cycles: 100, kcal: 10),
        monitoring(1060, type: 1, cycles: 150, kcal: 12),
        // A different activity type keeps its own counter: its first reading yields no interval.
        monitoring(1120, type: 2, cycles: 20, kcal: 5),
        monitoring(1180, type: 1, cycles: 160),
        // A lower reading than the previous one is a counter reset, so the reading is the growth.
        monitoring(1240, type: 1, cycles: 5),
    ]), unitNumber: nil)

    #expect(batch.steps.map(\.value) == [50, 10, 5])
    #expect(batch.steps.map(\.start) == [fitDate(1000), fitDate(1060), fitDate(1180)])
    #expect(batch.steps.map(\.end) == [fitDate(1060), fitDate(1180), fitDate(1240)])
    #expect(batch.activeEnergyKcal.map(\.value) == [2])
}

@Test func monitoringTimestamp16WrapsForward() {
    // 1_000_013_808 is 0x3B9AFFF0: its low 16 bits are 0xFFF0. The next record's timestamp_16 is 0x0010,
    // which is 32 seconds later across the wrap, not 65_504 seconds earlier.
    let batch = FitExtractor.extract(file([
        FitMessage(globalNumber: 55, fields: [253: .int(1_000_013_808), 26: .int(0xFFF0), 27: .int(70)]),
        FitMessage(globalNumber: 55, fields: [26: .int(0x0010), 27: .int(71)]),
    ]), unitNumber: nil)

    #expect(batch.heartRate.map(\.bpm) == [70, 71])
    #expect(batch.heartRate.map(\.date) == [fitDate(1_000_013_808), fitDate(1_000_013_840)])
}

@Test func extractsStressSpo2RespirationAndHrv() {
    let t: Int64 = 1_000_000_000
    let batch = FitExtractor.extract(file([
        FitMessage(globalNumber: 227, fields: [0: .int(42), 3: .int(60), 253: .int(t)]),
        FitMessage(globalNumber: 269, fields: [0: .int(97), 253: .int(t)]),
        FitMessage(globalNumber: 297, fields: [0: .int(1550), 253: .int(t)]),
        FitMessage(globalNumber: 371, fields: [0: .int(5760), 253: .int(t)]),
    ]), unitNumber: nil)

    #expect(batch.stress.map(\.value) == [42])
    #expect(batch.bodyBattery.map(\.value) == [60])
    #expect(batch.spo2.map(\.value) == [0.97])
    #expect(batch.respirationRate.map(\.value) == [15.5])
    // HRV is sent scaled by 128: 5760 / 128 = 45 ms.
    #expect(batch.hrv.map(\.value) == [45])
}

@Test func sleepLevelsBecomeIntervalsAndScoreGoesToNearestSession() {
    let s: Int64 = 1_000_000_000
    func level(_ ts: Int64, _ stage: Int64) -> FitMessage {
        FitMessage(globalNumber: 275, fields: [0: .int(stage), 253: .int(ts)])
    }
    let batch = FitExtractor.extract(file([
        level(s, 1), level(s + 600, 2), level(s + 1800, 3), level(s + 3600, 4),
        // More than four hours later: a second session.
        level(s + 30_000, 2), level(s + 30_600, 3),
        FitMessage(globalNumber: 346, fields: [6: .int(85), 253: .int(s + 3700)]),
    ]), unitNumber: nil)

    #expect(batch.sleep.count == 2)
    #expect(batch.sleep[0].start == fitDate(s))
    #expect(batch.sleep[0].end == fitDate(s + 3600))
    #expect(batch.sleep[0].intervals.map(\.stage) == [.awake, .light, .deep])
    #expect(batch.sleep[0].intervals[2].start == fitDate(s + 1800))
    #expect(batch.sleep[0].intervals[2].end == fitDate(s + 3600))
    #expect(batch.sleep[0].score == 85)
    #expect(batch.sleep[1].intervals.map(\.stage) == [.light])
    #expect(batch.sleep[1].score == nil)
}

@Test func extractsActivityWithLapsAndRecords() {
    let s: Int64 = 1_000_000_000
    let batch = FitExtractor.extract(file([
        FitMessage(globalNumber: 18, fields: [
            2: .int(s), 5: .int(1), 7: .int(1_800_000), 8: .int(1_740_000), 9: .int(500_000),
            11: .int(320), 14: .int(3000), 124: .int(3100), 16: .int(150), 17: .int(170), 22: .int(40),
        ]),
        FitMessage(globalNumber: 19, fields: [2: .int(s), 7: .int(900_000), 9: .int(100_000)]),
        FitMessage(globalNumber: 20, fields: [
            253: .int(s + 10), 0: .int(626_588_007), 1: .int(159_927_879), 2: .int(2675),
            3: .int(140), 5: .int(12345), 6: .int(2500),
        ]),
    ]), unitNumber: 42)

    #expect(batch.activities.count == 1)
    let activity = batch.activities[0]
    #expect(activity.id == "42-1000000000")
    #expect(activity.sport == .running)
    #expect(activity.start == fitDate(s))
    #expect(activity.end == fitDate(s + 1800))
    #expect(activity.duration == 1740)
    #expect(activity.distance == 5000)
    #expect(activity.activeCalories == 320)
    #expect(activity.averageHeartRate == 150)
    #expect(activity.maxHeartRate == 170)
    #expect(activity.totalAscent == 40)
    // Enhanced speed (124) wins over speed (14).
    #expect(activity.averageSpeed == 3.1)

    #expect(activity.laps.count == 1)
    #expect(activity.laps[0].distance == 1000)
    #expect(activity.laps[0].end == fitDate(s + 900))

    #expect(activity.records.count == 1)
    let record = activity.records[0]
    #expect(record.date == fitDate(s + 10))
    // Semicircles to degrees: 626588007 * 180 / 2^31 is 52.52 degrees.
    #expect(abs((record.latitude ?? 0) - 52.52) < 1e-5)
    #expect(abs((record.longitude ?? 0) - 13.405) < 1e-5)
    // Altitude is raw / 5 - 500: 2675 / 5 - 500 = 35 m.
    #expect(record.altitude == 35)
    #expect(record.heartRate == 140)
    #expect(record.speed == 2.5)
    #expect(record.distance == 123.45)
}
