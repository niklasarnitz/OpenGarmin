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
}
