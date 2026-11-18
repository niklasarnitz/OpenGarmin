import HealthKit
import GarminModels

/// HealthKit access: the types the app writes and reads, and the profile prefill for onboarding.
@MainActor
enum HealthStore {
    private static let store = HKHealthStore()

    private static let shareTypes: Set<HKSampleType> = [
        HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate), HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.flightsClimbed),
        HKQuantityType(.oxygenSaturation), HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN), HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(),
    ]

    private static let readTypes: Set<HKObjectType> = Set(shareTypes.map { $0 as HKObjectType }).union([
        HKQuantityType(.bodyMass), HKQuantityType(.height),
        HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
        HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
    ])

    static func requestAccess() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return (try? await store.requestAuthorization(toShare: shareTypes, read: readTypes)) != nil
    }

    /// Prefills the profile from Health. Anything Health does not know stays empty.
    static func profileDefaults() async -> UserProfile {
        var profile = UserProfile()
        if let components = try? store.dateOfBirthComponents() {
            profile.birthDate = Calendar.current.date(from: components)
        }
        switch try? store.biologicalSex().biologicalSex {
        case .female?: profile.gender = .female
        case .male?: profile.gender = .male
        default: break
        }
        profile.weightKg = await latest(.bodyMass)?.doubleValue(for: .gramUnit(with: .kilo))
        profile.heightCm = await latest(.height)?.doubleValue(for: .meterUnit(with: .centi))
        return profile
    }

    private static func latest(_ identifier: HKQuantityTypeIdentifier) async -> HKQuantity? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        return try? await descriptor.result(for: store).first?.quantity
    }
}
