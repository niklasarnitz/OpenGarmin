import Foundation
import Testing
import GarminModels
@testable import GarminShared

@Suite struct WatchSnapshotTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09T01:46:40Z

    private func batch() -> HealthBatch {
        var batch = HealthBatch()
        batch.steps = [
            IntervalSample(start: now.addingTimeInterval(-3600), end: now, value: 1200),
            IntervalSample(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-300), value: 300.4),
            // Yesterday: not counted.
            IntervalSample(start: now.addingTimeInterval(-86400 - 3600), end: now.addingTimeInterval(-86400), value: 5000),
        ]
        batch.heartRate = [
            HeartRateSample(date: now.addingTimeInterval(-600), bpm: 62),
            HeartRateSample(date: now.addingTimeInterval(-60), bpm: 70),
            HeartRateSample(date: now.addingTimeInterval(-300), bpm: 80),
        ]
        batch.bodyBattery = [
            PointSample(date: now.addingTimeInterval(-5000), value: 90),
            PointSample(date: now.addingTimeInterval(-100), value: 64.6),
        ]
        batch.stress = [
            PointSample(date: now.addingTimeInterval(-100), value: 20),
            PointSample(date: now.addingTimeInterval(-200), value: 31),
            PointSample(date: now.addingTimeInterval(-86400), value: 99),
        ]
        batch.sleep = [
            SleepSession(start: now.addingTimeInterval(-10 * 3600), end: now.addingTimeInterval(-2 * 3600),
                         intervals: [], score: 82),
        ]
        return batch
    }

    private func snapshot(at date: Date) -> WatchSnapshot {
        WatchSnapshot(batch: batch(), watchName: "Venu 4", lastSync: now.addingTimeInterval(-1000),
                      battery: BatteryStatus(percent: 78, isCharging: true),
                      now: date, calendar: calendar)
    }

    @Test func summarisesTodayAndLatestReadings() {
        let snapshot = snapshot(at: now)
        #expect(snapshot.steps == 1500)
        #expect(snapshot.heartRate == 70)
        #expect(snapshot.bodyBattery == 65)
        #expect(snapshot.stress == 26)
        #expect(snapshot.sleepMinutes == 480)
        #expect(snapshot.sleepScore == 82)
        #expect(snapshot.watchName == "Venu 4")
        #expect(snapshot.watchBattery == 78)
        #expect(snapshot.isCharging)
        #expect(snapshot.lastSync == now.addingTimeInterval(-1000))
    }

    @Test func dropsSleepEndedADayAgo() {
        // The last session ended exactly 24 hours before this moment: no longer "last night".
        #expect(snapshot(at: now.addingTimeInterval(22 * 3600)).sleepMinutes == nil)
        #expect(snapshot(at: now.addingTimeInterval(21 * 3600)).sleepMinutes == 480)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = snapshot(at: now)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
