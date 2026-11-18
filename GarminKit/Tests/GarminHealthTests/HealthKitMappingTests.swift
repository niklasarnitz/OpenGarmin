import Foundation
import HealthKit
import Testing
import GarminModels
@testable import GarminHealth

@Test func commonSportsMapToTheirActivityTypes() {
    #expect(HealthKitMapping.workoutActivityType(for: .running) == .running)
    #expect(HealthKitMapping.workoutActivityType(for: .cycling) == .cycling)
    #expect(HealthKitMapping.workoutActivityType(for: .swimming) == .swimming)
    #expect(HealthKitMapping.workoutActivityType(for: .walking) == .walking)
    #expect(HealthKitMapping.workoutActivityType(for: .hiit) == .highIntensityIntervalTraining)
}

@Test func electricBikeIsCyclingAndHikingIsNotRunning() {
    // Guards against collapsing unrelated sports into one activity type.
    #expect(HealthKitMapping.workoutActivityType(for: .eBiking) == .cycling)
    #expect(HealthKitMapping.workoutActivityType(for: .hiking) == .hiking)
    #expect(HealthKitMapping.workoutActivityType(for: .hiking) != .running)
}

@Test func unknownSportFallsBackToOther() {
    #expect(HealthKitMapping.workoutActivityType(for: .generic) == .other)
}

@Test func sleepStagesMapToDistinctHealthKitValues() {
    #expect(HealthKitMapping.sleepValue(for: .awake) == .awake)
    #expect(HealthKitMapping.sleepValue(for: .light) == .asleepCore)
    #expect(HealthKitMapping.sleepValue(for: .deep) == .asleepDeep)
    #expect(HealthKitMapping.sleepValue(for: .rem) == .asleepREM)
    #expect(HealthKitMapping.sleepValue(for: .unmeasurable) == .asleepUnspecified)
    #expect(Set(SleepStage.allCases.map(HealthKitMapping.sleepValue(for:))).count == SleepStage.allCases.count)
}

@Test func syncIdentifierDependsOnEveryPart() {
    let base = HealthKitMapping.syncIdentifier("steps", "1000", "2000")
    #expect(base == "com.niklasarnitz.opengarmin.steps.1000.2000")
    // Same start, different end is a different sample.
    #expect(base != HealthKitMapping.syncIdentifier("steps", "1000", "3000"))
    #expect(base != HealthKitMapping.syncIdentifier("heartRate", "1000", "2000"))
}

@Test func epochMillisRoundsToTheNearestMillisecond() {
    #expect(HealthKitMapping.epochMillis(Date(timeIntervalSince1970: 1.5)) == "1500")
    #expect(HealthKitMapping.epochMillis(Date(timeIntervalSince1970: 0.0004)) == "0")
    #expect(HealthKitMapping.epochMillis(Date(timeIntervalSince1970: 0.0006)) == "1")
}

@Test func mergedBatchBuildsOneBulkSampleArrayWithDistinctSyncIdentifiers() {
    let device = HKDevice(name: "Venu 4", manufacturer: "Garmin", model: "Venu 4", hardwareVersion: nil,
                          firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    let start = Date(timeIntervalSince1970: 1_000)
    var first = HealthBatch()
    first.steps = [IntervalSample(start: start, end: start.addingTimeInterval(60), value: 50)]
    first.restingHeartRate = [PointSample(date: start, value: 52)]
    var second = HealthBatch()
    second.steps = [IntervalSample(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), value: 30)]
    second.sleep = [SleepSession(start: start, end: start.addingTimeInterval(3600), intervals: [
        SleepInterval(start: start, end: start.addingTimeInterval(1800), stage: .light),
        SleepInterval(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3600), stage: .deep),
    ])]
    var merged = HealthBatch()
    merged.merge(first)
    merged.merge(second)

    let groups = HealthKitMapping.samples(for: merged, device: device)
    let all = groups.flatMap(\.samples)
    // Two steps, one resting heart rate, and a sleep session with its time in bed and two stages.
    #expect(all.count == 6)
    #expect(groups.first { $0.field == "steps" }?.samples.count == 2)
    #expect(groups.first { $0.field == "sleep" }?.samples.count == 3)
    // Every sample has its own sync identifier, so saving the batch again replaces the saved samples.
    let identifiers = all.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }
    #expect(Set(identifiers).count == 6)
}
