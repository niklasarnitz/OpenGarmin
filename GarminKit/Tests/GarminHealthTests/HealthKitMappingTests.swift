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
