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
        HKQuantityType(.heartRateVariabilitySDNN), HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
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

    /// Today's data as Apple Health has it, from any app (Garmin Connect, Apple Watch, OpenGarmin), so Today has
    /// something to show when the watch's own files went to Garmin Connect. Stress and Body Battery are not in Health.
    static func today() async -> HealthBatch {
        var batch = HealthBatch()
        let now = Date.now, midnight = Calendar.current.startOfDay(for: now)
        let today = HKQuery.predicateForSamples(withStart: midnight, end: now)
        // Health sums steps and energy across sources without double counting; one interval holds the day's total.
        if let steps = await sum(.stepCount, today, .count()) {
            batch.steps = [IntervalSample(start: midnight, end: now, value: steps)]
        }
        if let energy = await sum(.activeEnergyBurned, today, .kilocalorie()) {
            batch.activeEnergyKcal = [IntervalSample(start: midnight, end: now, value: energy)]
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        batch.heartRate = await samples(.heartRate, today).map {
            HeartRateSample(date: $0.endDate, bpm: Int($0.quantity.doubleValue(for: bpm).rounded()))
        }
        batch.restingHeartRate = await latestPoint(.restingHeartRate, bpm)
        batch.spo2 = await latestPoint(.oxygenSaturation, .percent())
        batch.hrv = await latestPoint(.heartRateVariabilitySDNN, .secondUnit(with: .milli))
        batch.respirationRate = await latestPoint(.respiratoryRate, bpm)
        batch.sleep = await lastNight().map { [$0] } ?? []
        return batch
    }

    private static func sum(_ id: HKQuantityTypeIdentifier, _ predicate: NSPredicate, _ unit: HKUnit) async -> Double? {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate), options: .cumulativeSum)
        return try? await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: unit)
    }

    private static func samples(_ id: HKQuantityTypeIdentifier, _ predicate: NSPredicate) async -> [HKQuantitySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate)])
        return (try? await descriptor.result(for: store)) ?? []
    }

    /// The newest reading of the last three days, so overnight values such as HRV still show during the day.
    private static func latestPoint(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> [PointSample] {
        let recent = HKQuery.predicateForSamples(withStart: .now.addingTimeInterval(-3 * 86_400), end: .now)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: recent)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        guard let sample = try? await descriptor.result(for: store).first else { return [] }
        return [PointSample(date: sample.endDate, value: sample.quantity.doubleValue(for: unit))]
    }

    /// Sleep stages that ended in the last 24 hours. When several apps recorded the night, the source with the most
    /// staged time wins, so two overlapping recordings are not added up.
    private static func lastNight() async -> SleepSession? {
        let window = HKQuery.predicateForSamples(withStart: .now.addingTimeInterval(-86_400), end: .now)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let staged = ((try? await descriptor.result(for: store)) ?? []).compactMap { sample -> (String, SleepInterval)? in
            guard let stage = sleepStage(sample.value) else { return nil }
            return (sample.sourceRevision.source.bundleIdentifier,
                    SleepInterval(start: sample.startDate, end: sample.endDate, stage: stage))
        }
        let bySource = Dictionary(grouping: staged, by: \.0).mapValues { $0.map(\.1) }
        guard let intervals = bySource.values.max(by: { duration($0) < duration($1) }),
              let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return SleepSession(start: start, end: end, intervals: intervals)
    }

    private static func duration(_ intervals: [SleepInterval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Time in bed is not a stage; the session spans the staged samples.
    private static func sleepStage(_ value: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .awake?: .awake
        case .asleepCore?: .light
        case .asleepDeep?: .deep
        case .asleepREM?: .rem
        case .asleepUnspecified?: .unmeasurable
        default: nil
        }
    }
}

extension HealthBatch {
    /// This batch, with each empty field taken from `other`. The watch's own data wins wherever it has some.
    func fillingGaps(from other: HealthBatch) -> HealthBatch {
        var result = self
        func fill<T>(_ path: WritableKeyPath<HealthBatch, [T]>) {
            if result[keyPath: path].isEmpty { result[keyPath: path] = other[keyPath: path] }
        }
        fill(\.heartRate); fill(\.restingHeartRate); fill(\.steps); fill(\.activeEnergyKcal)
        fill(\.spo2); fill(\.hrv); fill(\.respirationRate); fill(\.sleep)
        return result
    }
}
