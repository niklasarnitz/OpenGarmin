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
    /// Samples written per HealthBatch field, e.g. "heartRate" or "steps". Sleep sessions are counted separately.
    public var samplesWritten: [String: Int] = [:]
    public var sleepSessionsWritten = 0
    public var workoutsWritten = 0
    public var routePointsWritten = 0
    /// Batch fields that were not written, with the reason.
    public var skipped: [String] = []

    public init() {}
}

/// Writes Garmin data to Apple Health. Saves are idempotent: every object carries a sync identifier and version,
/// so syncing the same watch data again replaces the saved objects instead of duplicating them.
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

    public func save(_ batch: HealthBatch, deviceName: String, deviceModel: String, firmware: String) async throws -> SaveSummary {
        let device = HKDevice(name: deviceName, manufacturer: "Garmin", model: deviceModel, hardwareVersion: nil,
                              firmwareVersion: firmware, softwareVersion: nil, localIdentifier: nil,
                              udiDeviceIdentifier: nil)
        var summary = SaveSummary()
        var objects: [HKObject] = []

        func add(_ field: String, _ samples: [HKSample]) {
            objects += samples
            summary.samplesWritten[field, default: 0] += samples.count
        }

        let bpm = HKUnit.count().unitDivided(by: .minute())
        add("heartRate", batch.heartRate.map { quantity(.heartRate, bpm, Double($0.bpm), at: $0.date, $0.date, device) })
        add("restingHeartRate", point(batch.restingHeartRate, .restingHeartRate, bpm, device))
        add("steps", interval(batch.steps, .stepCount, .count(), device))
        add("activeEnergyKcal", interval(batch.activeEnergyKcal, .activeEnergyBurned, .kilocalorie(), device))
        add("restingEnergyKcal", interval(batch.restingEnergyKcal, .basalEnergyBurned, .kilocalorie(), device))
        add("distance", interval(batch.distance, .distanceWalkingRunning, .meter(), device))
        add("floorsClimbed", interval(batch.floorsClimbed, .flightsClimbed, .count(), device))
        add("intensityMinutes", interval(batch.intensityMinutes, .appleExerciseTime, .minute(), device))
        add("spo2", point(batch.spo2, .oxygenSaturation, .percent(), device))
        add("respirationRate", point(batch.respirationRate, .respiratoryRate, bpm, device))
        // Garmin's HRV is RMSSD, but HealthKit's only HRV type is SDNN. The values are stored as SDNN anyway,
        // so the Health app shows them as a trend rather than as a clinical SDNN reading.
        add("hrv", point(batch.hrv, .heartRateVariabilitySDNN, .secondUnit(with: .milli), device))
        if !batch.stress.isEmpty { summary.skipped.append("stress: no HealthKit type") }
        if !batch.bodyBattery.isEmpty { summary.skipped.append("bodyBattery: no HealthKit type") }

        for session in batch.sleep {
            objects.append(sleepSample(HKCategoryValueSleepAnalysis.inBed, session.start, session.end, device))
            for interval in session.intervals {
                objects.append(sleepSample(HealthKitMapping.sleepValue(for: interval.stage), interval.start, interval.end, device))
            }
            summary.sleepSessionsWritten += 1
        }
        try await store.save(objects)

        #if os(iOS)
        for activity in batch.activities {
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
        HKQuantityType(.appleExerciseTime), HKQuantityType(.oxygenSaturation), HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN), HKCategoryType(.sleepAnalysis),
        HKWorkoutType.workoutType(), HKSeriesType.workoutRoute(),
    ]

    private static let readTypes: Set<HKObjectType> = [
        HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
        HKQuantityType(.height), HKQuantityType(.bodyMass),
    ]

    private func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double,
                          at start: Date, _ end: Date, _ device: HKDevice) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, device: device,
                         metadata: syncMetadata(HealthKitMapping.syncIdentifier(id.rawValue, HealthKitMapping.epochMillis(start), HealthKitMapping.epochMillis(end))))
    }

    private func point(_ samples: [PointSample], _ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ device: HKDevice) -> [HKSample] {
        samples.map { quantity(id, unit, $0.value, at: $0.date, $0.date, device) }
    }

    private func interval(_ samples: [IntervalSample], _ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ device: HKDevice) -> [HKSample] {
        samples.map { quantity(id, unit, $0.value, at: $0.start, $0.end, device) }
    }

    private func sleepSample(_ value: HKCategoryValueSleepAnalysis, _ start: Date, _ end: Date, _ device: HKDevice) -> HKCategorySample {
        HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue, start: start, end: end,
                         device: device,
                         metadata: syncMetadata(HealthKitMapping.syncIdentifier("sleep", HealthKitMapping.epochMillis(start), HealthKitMapping.epochMillis(end), String(value.rawValue))))
    }

    private func syncMetadata(_ identifier: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: identifier, HKMetadataKeySyncVersion: HealthKitMapping.syncVersion]
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
        try await builder.addMetadata(syncMetadata(identifier))
        let heartRates = activity.records.compactMap { record -> HKQuantitySample? in
            guard let bpm = record.heartRate, record.date >= activity.start, record.date <= activity.end else { return nil }
            return quantity(.heartRate, .count().unitDivided(by: .minute()), Double(bpm), at: record.date, record.date, device)
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
        _ = try await routeBuilder.finishRoute(with: workout, metadata: syncMetadata(identifier + ".route"))
    }
    #endif
}
