import Foundation
import CoreLocation
import HealthKit
import GarminModels

public enum HealthKitWriterError: Error, Equatable {
    case healthDataUnavailable
    case workoutNotSaved
}

/// What one `save` wrote, and what it had to leave out.
public struct SaveSummary: Sendable, Equatable {
    /// Samples written per HealthBatch field, e.g. "heartRate" or "steps". Sleep stages are counted under "sleep".
    public var samplesWritten: [String: Int] = [:]
    /// Samples left out per field because Garmin Connect already wrote data for that time.
    public var samplesAlreadyInHealth: [String: Int] = [:]
    /// Activities left out because Health already has a workout from another app at that time.
    public var workoutsAlreadyInHealth = 0
    public var sleepSessionsWritten = 0
    public var workoutsWritten = 0
    public var routePointsWritten = 0
    /// Batch fields that were not written, with the reason.
    public var skipped: [String] = []

    public init() {}
}

/// Writes Garmin data to Apple Health. Saves are idempotent: every object carries a sync identifier and version,
/// so syncing the same watch data again replaces the saved objects instead of duplicating them. Data Garmin Connect
/// already wrote to Health is left out, so a watch that was also synced with Connect is not counted twice.
public actor HealthKitWriter {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Asks for exactly the types `save` writes and `readProfile` reads.
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitWriterError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: Self.writeTypes, read: Self.readTypes)
    }

    /// Saves a batch with one HealthKit call for all its samples, then one workout per activity. Callers save batches
    /// one after another, so two saves never run at the same time. Sync identifiers keep a batch that is saved again
    /// from duplicating its samples.
    public func save(_ batch: HealthBatch, deviceName: String, deviceModel: String, firmware: String) async throws -> SaveSummary {
        let device = HKDevice(name: deviceName, manufacturer: "Garmin", model: deviceModel, hardwareVersion: nil,
                              firmwareVersion: firmware, softwareVersion: nil, localIdentifier: nil,
                              udiDeviceIdentifier: nil)
        var summary = SaveSummary()
        var groups = HealthKitMapping.samples(for: batch, device: device)
        for index in groups.indices {
            let kept = await withoutGarminConnectData(groups[index].samples)
            summary.samplesAlreadyInHealth[groups[index].field] = groups[index].samples.count - kept.count
            groups[index].samples = kept
            summary.samplesWritten[groups[index].field] = kept.count
        }
        summary.sleepSessionsWritten = batch.sleep.count
        // HealthKit lets only Apple write exercise minutes.
        if !batch.intensityMinutes.isEmpty { summary.skipped.append("intensityMinutes: appleExerciseTime is read-only") }
        if !batch.stress.isEmpty { summary.skipped.append("stress: no HealthKit type") }
        if !batch.bodyBattery.isEmpty { summary.skipped.append("bodyBattery: no HealthKit type") }
        // A first sync can hold weeks of samples; save them in large chunks rather than one unbounded call.
        let samples = groups.flatMap(\.samples)
        for start in stride(from: 0, to: samples.count, by: 10_000) {
            try await store.save(Array(samples[start..<min(start + 10_000, samples.count)]))
        }

        #if os(iOS)
        let otherWorkouts = await workoutsFromOtherApps(overlapping: batch.activities)
        for activity in batch.activities {
            if HealthKitMapping.isCovered(activity.start, activity.end, by: otherWorkouts) {
                summary.workoutsAlreadyInHealth += 1
                continue
            }
            try await saveWorkout(activity, device: device)
            summary.workoutsWritten += 1
            summary.routePointsWritten += activity.records.filter { $0.latitude != nil && $0.longitude != nil }.count
        }
        #else
        // HKWorkoutBuilder is iOS and watchOS only, so workouts cannot be written from this platform.
        if !batch.activities.isEmpty { summary.skipped.append("activities: HKWorkoutBuilder is iOS only") }
        #endif

        return summary
    }

    /// Height and weight are the latest samples; birth date and sex come from the Health profile.
    public func readProfile() async -> UserProfile {
        var profile = UserProfile()
        if let components = try? store.dateOfBirthComponents() {
            profile.birthDate = Calendar.current.date(from: components)
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            if sex == .female { profile.gender = .female }
            if sex == .male { profile.gender = .male }
        }
        profile.heightCm = await latest(.height, unit: .meterUnit(with: .centi))
        profile.weightKg = await latest(.bodyMass, unit: .gramUnit(with: .kilo))
        return profile
    }

    private static let writeTypes: Set<HKSampleType> = [
        HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate), HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.flightsClimbed),
        HKQuantityType(.oxygenSaturation), HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN), HKCategoryType(.sleepAnalysis),
        HKWorkoutType.workoutType(), HKSeriesType.workoutRoute(),
    ]

    /// The written types are also read, to find what Garmin Connect already wrote.
    private static let readTypes: Set<HKObjectType> = Set(writeTypes.map { $0 as HKObjectType }).union([
        HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
        HKQuantityType(.height), HKQuantityType(.bodyMass),
    ])

    /// `samples` (all of one type) without those whose time Garmin Connect already covers in Health. Without read
    /// access the query finds nothing, so everything is written.
    private func withoutGarminConnectData(_ samples: [HKSample]) async -> [HKSample] {
        guard let type = samples.first?.sampleType,
              let start = samples.map(\.startDate).min(), let end = samples.map(\.endDate).max() else { return samples }
        let range = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-HealthKitMapping.coverageTolerance),
                                                end: end.addingTimeInterval(HealthKitMapping.coverageTolerance))
        let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: range)], sortDescriptors: [])
        let existing = (try? await descriptor.result(for: store)) ?? []
        let covered = HealthKitMapping.merged(
            existing.filter { HealthKitMapping.isGarminConnect(bundleIdentifier: $0.sourceRevision.source.bundleIdentifier) }
                .map { DateInterval(start: $0.startDate, end: $0.endDate) },
            tolerance: HealthKitMapping.coverageTolerance)
        guard !covered.isEmpty else { return samples }
        return samples.filter { !HealthKitMapping.isCovered($0.startDate, $0.endDate, by: covered) }
    }

    /// Workouts any other app (Garmin Connect, Apple Watch, Strava) saved during these activities.
    private func workoutsFromOtherApps(overlapping activities: [Activity]) async -> [DateInterval] {
        guard let start = activities.map(\.start).min(), let end = activities.map(\.end).max() else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))], sortDescriptors: [])
        let own = Bundle.main.bundleIdentifier ?? "com.niklasarnitz.opengarmin"
        let workouts = ((try? await descriptor.result(for: store)) ?? [])
            .filter { $0.sourceRevision.source.bundleIdentifier != own }
        return HealthKitMapping.merged(workouts.map { DateInterval(start: $0.startDate, end: $0.endDate) }, tolerance: 0)
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        return try? await descriptor.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    #if os(iOS)
    /// One HKWorkout with its heart rate samples, and its GPS track as a route when the activity has one.
    private func saveWorkout(_ activity: Activity, device: HKDevice) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = HealthKitMapping.workoutActivityType(for: activity.sport)
        let track = activity.records.filter { $0.latitude != nil && $0.longitude != nil }
        configuration.locationType = track.isEmpty ? .unknown : .outdoor

        let identifier = HealthKitMapping.syncIdentifier("activity", activity.id)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
        try await builder.beginCollection(at: activity.start)
        try await builder.addMetadata(HealthKitMapping.syncMetadata(identifier))
        let heartRates = activity.records.compactMap { record -> HKQuantitySample? in
            guard let bpm = record.heartRate, record.date >= activity.start, record.date <= activity.end else { return nil }
            return HealthKitMapping.quantity(.heartRate, .count().unitDivided(by: .minute()), Double(bpm),
                                             at: record.date, record.date, device)
        }
        if !heartRates.isEmpty { try await builder.addSamples(heartRates) }
        try await builder.endCollection(at: activity.end)
        guard let workout = try await builder.finishWorkout() else { throw HealthKitWriterError.workoutNotSaved }

        guard !track.isEmpty else { return }
        // Garmin's records carry no accuracy, so horizontal accuracy is nominal. A negative vertical accuracy
        // tells CoreLocation the altitude is unknown.
        let locations = track.map { record in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: record.latitude!, longitude: record.longitude!),
                       altitude: record.altitude ?? 0, horizontalAccuracy: 5,
                       verticalAccuracy: record.altitude == nil ? -1 : 5, timestamp: record.date)
        }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: device)
        try await routeBuilder.insertRouteData(locations)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: HealthKitMapping.syncMetadata(identifier + ".route"))
    }
    #endif
}
