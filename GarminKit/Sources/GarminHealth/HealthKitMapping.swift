import Foundation
import HealthKit
import GarminModels

/// Pure mapping from GarminModels to HealthKit vocabulary. No store access, so it is testable.
enum HealthKitMapping {
    /// Bumped when the mapping changes, so HealthKit can tell old saved objects from new ones.
    static let syncVersion = 1

    static func workoutActivityType(for sport: Sport) -> HKWorkoutActivityType {
        switch sport {
        case .generic, .flying, .motorcycling, .driving, .hangGliding, .skyDiving, .tactical, .jumpmaster,
             .multisport, .racket:
            .other
        case .running: .running
        case .cycling, .eBiking: .cycling
        case .transition: .transition
        case .fitnessEquipment: .mixedCardio
        case .swimming: .swimming
        case .basketball: .basketball
        case .soccer: .soccer
        case .tennis: .tennis
        case .americanFootball: .americanFootball
        case .training: .crossTraining
        case .walking: .walking
        case .crossCountrySkiing: .crossCountrySkiing
        case .alpineSkiing: .downhillSkiing
        case .snowboarding: .snowboarding
        case .snowshoeing, .snowmobiling: .snowSports
        case .rowing: .rowing
        case .mountaineering, .rockClimbing, .floorClimbing: .climbing
        case .hiking: .hiking
        case .paddling, .kayaking, .rafting, .standUpPaddleboarding: .paddleSports
        case .boating, .waterSkiing, .wakeboarding, .waterTubing: .waterSports
        case .golf: .golf
        case .horsebackRiding: .equestrianSports
        case .hunting: .hunting
        case .fishing: .fishing
        case .inlineSkating, .iceSkating: .skatingSports
        case .sailing: .sailing
        case .surfing, .windsurfing, .kitesurfing, .wakesurfing: .surfingSports
        case .boxing: .boxing
        case .baseball: .baseball
        case .diving, .snorkeling: .underwaterDiving
        case .hiit: .highIntensityIntervalTraining
        case .wheelchairPushWalk: .wheelchairWalkPace
        case .wheelchairPushRun: .wheelchairRunPace
        case .meditation: .mindAndBody
        case .discGolf: .discSports
        case .cricket: .cricket
        case .rugby: .rugby
        case .hockey: .hockey
        case .lacrosse: .lacrosse
        case .volleyball: .volleyball
        case .mixedMartialArts: .martialArts
        case .dance: .cardioDance
        case .jumpRope: .jumpRope
        }
    }

    /// Garmin's light sleep is HealthKit's core sleep. Unmeasurable time is asleep without a stage.
    static func sleepValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .awake: .awake
        case .light: .asleepCore
        case .deep: .asleepDeep
        case .rem: .asleepREM
        case .unmeasurable: .asleepUnspecified
        }
    }

    /// Stable identifier per sample, so saving the same watch data again replaces the saved object.
    /// Parts are the sample's kind and its times (or Garmin's activity id), in epoch milliseconds.
    static func syncIdentifier(_ kind: String, _ parts: String...) -> String {
        (["com.niklasarnitz.opengarmin", kind] + parts).joined(separator: ".")
    }

    static func epochMillis(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The HealthKit samples of a batch, grouped by the batch field they come from. Pure: no store access, so a
    /// merged batch becomes one array that the writer saves in one call. Sleep sessions form the "sleep" group.
    static func samples(for batch: HealthBatch, device: HKDevice) -> [(field: String, samples: [HKSample])] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var groups: [(field: String, samples: [HKSample])] = [
            ("heartRate", batch.heartRate.map { quantity(.heartRate, bpm, Double($0.bpm), at: $0.date, $0.date, device) }),
            ("restingHeartRate", points(batch.restingHeartRate, .restingHeartRate, bpm, device)),
            ("steps", intervals(batch.steps, .stepCount, .count(), device)),
            ("activeEnergyKcal", intervals(batch.activeEnergyKcal, .activeEnergyBurned, .kilocalorie(), device)),
            ("restingEnergyKcal", intervals(batch.restingEnergyKcal, .basalEnergyBurned, .kilocalorie(), device)),
            ("distance", intervals(batch.distance, .distanceWalkingRunning, .meter(), device)),
            ("floorsClimbed", intervals(batch.floorsClimbed, .flightsClimbed, .count(), device)),
            ("intensityMinutes", intervals(batch.intensityMinutes, .appleExerciseTime, .minute(), device)),
            ("spo2", points(batch.spo2, .oxygenSaturation, .percent(), device)),
            ("respirationRate", points(batch.respirationRate, .respiratoryRate, bpm, device)),
            // Garmin's HRV is RMSSD, but HealthKit's only HRV type is SDNN. The values are stored as SDNN anyway,
            // so the Health app shows them as a trend rather than as a clinical SDNN reading.
            ("hrv", points(batch.hrv, .heartRateVariabilitySDNN, .secondUnit(with: .milli), device)),
        ]
        groups.append(("sleep", batch.sleep.flatMap { sleepSamples($0, device: device) }))
        return groups
    }

    static func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double,
                         at start: Date, _ end: Date, _ device: HKDevice) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, device: device,
                         metadata: syncMetadata(syncIdentifier(id.rawValue, epochMillis(start), epochMillis(end))))
    }

    static func points(_ samples: [PointSample], _ id: HKQuantityTypeIdentifier, _ unit: HKUnit,
                       _ device: HKDevice) -> [HKSample] {
        samples.map { quantity(id, unit, $0.value, at: $0.date, $0.date, device) }
    }

    static func intervals(_ samples: [IntervalSample], _ id: HKQuantityTypeIdentifier, _ unit: HKUnit,
                          _ device: HKDevice) -> [HKSample] {
        samples.map { quantity(id, unit, $0.value, at: $0.start, $0.end, device) }
    }

    /// The time in bed, then one sample per sleep stage.
    static func sleepSamples(_ session: SleepSession, device: HKDevice) -> [HKSample] {
        var samples: [HKSample] = [sleepSample(.inBed, session.start, session.end, device)]
        for interval in session.intervals {
            samples.append(sleepSample(sleepValue(for: interval.stage), interval.start, interval.end, device))
        }
        return samples
    }

    static func sleepSample(_ value: HKCategoryValueSleepAnalysis, _ start: Date, _ end: Date,
                            _ device: HKDevice) -> HKCategorySample {
        HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue, start: start, end: end,
                         device: device,
                         metadata: syncMetadata(syncIdentifier("sleep", epochMillis(start), epochMillis(end),
                                                               String(value.rawValue))))
    }

    static func syncMetadata(_ identifier: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: identifier, HKMetadataKeySyncVersion: syncVersion]
    }
}
