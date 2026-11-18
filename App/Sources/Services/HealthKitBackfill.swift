import Foundation
import GarminBackend
import HealthKit
import Observation

/// Uploads the whole Apple Health history to the backend: every readable type, from every source, one month at a time.
/// It only reads Health. A chunk the server takes is kept under its key, and chunks it already has are skipped, so a run
/// that was cancelled or killed picks up where it stopped. Started by hand; a run that was killed resumes on the next launch.
@MainActor
@Observable
final class HealthKitBackfill {
    private static let startedKey = "backend.healthKit.started"
    private static let completedKey = "backend.healthKit.completed"

    private(set) var isRunning = false
    /// What the run is reading now: the type and the month.
    private(set) var progress: String?
    /// Items the server took in this run.
    private(set) var uploaded = 0
    private(set) var completedAt: Date? = UserDefaults.standard.object(forKey: completedKey) as? Date
    private(set) var errorMessage: String?
    /// Chunks the server refused, by key, with its reason. The next run tries them again.
    private(set) var skipped: [String: String] = [:]

    @ObservationIgnored private let makeClient: @MainActor () -> BackendClient?
    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The keys the server has: read at the start of a run, then extended with each chunk it takes.
    @ObservationIgnored private var have: Set<String> = []

    init(makeClient: @escaping @MainActor () -> BackendClient?) {
        self.makeClient = makeClient
    }

    /// Starts a run unless one is going. Needs a signed-in account.
    func start() {
        guard !isRunning else { return }
        guard let client = makeClient() else {
            errorMessage = String(localized: "Sign in to the backend first.")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = String(localized: "Health data is not available on this device.")
            return
        }
        isRunning = true
        errorMessage = nil
        uploaded = 0
        skipped = [:]
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        task = Task {
            do {
                try await run(client)
                completedAt = .now
                UserDefaults.standard.set(completedAt, forKey: Self.completedKey)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
            progress = nil
        }
    }

    /// Stops the run. The chunks already taken stay on the server, and the next run starts from the rest.
    func cancel() {
        task?.cancel()
        UserDefaults.standard.set(false, forKey: Self.startedKey)
    }

    /// Resumes a run that was killed before it completed.
    func resumeIfStarted() {
        guard UserDefaults.standard.bool(forKey: Self.startedKey), completedAt == nil, makeClient() != nil else { return }
        start()
    }

    private func run(_ client: BackendClient) async throws {
        try await health.requestAuthorization(toShare: [], read: HealthKitTypes.readable)
        have = try await client.syncState()
        let calendar = Calendar.current
        let units = try await health.preferredUnits(for: Set(HealthKitTypes.quantityTypes))

        for type in HealthKitTypes.sampleTypes {
            let unit = (type as? HKQuantityType).flatMap { units[$0] }
            if type is HKQuantityType, unit == nil { continue }
            for month in try await months(of: type, calendar: calendar) {
                progress = "\(Self.name(type.identifier)), \(Self.label(month))"
                let predicate = Self.predicate(month)
                let samples = try await HKSampleQueryDescriptor(
                    predicates: [.sample(type: type, predicate: predicate)], sortDescriptors: []
                ).result(for: health)
                let items = samples.sorted { ($0.startDate, $0.uuid.uuidString) < ($1.startDate, $1.uuid.uuidString) }
                    .map { BackendSample($0, unit: unit) }
                try await upload(items, kind: type.identifier, month: month, limit: HealthKitChunks.sampleLimit,
                                 calendar: calendar) { try await client.uploadSamples($0, key: $1) }
            }
        }

        let workoutType = HKWorkoutType.workoutType()
        for month in try await months(of: workoutType, calendar: calendar) {
            progress = "Workouts, \(Self.label(month))"
            let workouts = try await HKSampleQueryDescriptor(
                predicates: [.workout(Self.predicate(month))], sortDescriptors: []
            ).result(for: health)
            var items: [BackendWorkout] = []
            for workout in workouts.sorted { ($0.startDate, $0.uuid.uuidString) < ($1.startDate, $1.uuid.uuidString) } {
                let route = try await routePoints(of: workout)
                items.append(BackendWorkout(workout, route: route))
            }
            try await upload(items, kind: "workout", month: month, limit: HealthKitChunks.workoutLimit,
                             calendar: calendar) { try await client.uploadWorkouts($0, key: $1) }
        }

        let ecgType = HKObjectType.electrocardiogramType()
        for month in try await months(of: ecgType, calendar: calendar) {
            progress = "Electrocardiograms, \(Self.label(month))"
            let ecgs = try await HKSampleQueryDescriptor(
                predicates: [.electrocardiogram(Self.predicate(month))], sortDescriptors: []
            ).result(for: health)
            var items: [BackendElectrocardiogram] = []
            for ecg in ecgs.sorted { ($0.startDate, $0.uuid.uuidString) < ($1.startDate, $1.uuid.uuidString) } {
                let voltages = try await voltages(of: ecg)
                items.append(BackendElectrocardiogram(ecg, voltages: voltages))
            }
            try await upload(items, kind: "electrocardiogram", month: month,
                             limit: HealthKitChunks.electrocardiogramLimit, calendar: calendar) {
                try await client.uploadElectrocardiograms($0, key: $1)
            }
        }
    }

    /// Sends the items of one type and month in chunks. A chunk the server has is skipped, and one it refuses is recorded
    /// and passed over. Any other failure stops the run.
    private func upload<Item: Sendable>(_ items: [Item], kind: String, month: DateInterval, limit: Int, calendar: Calendar,
                              send: ([Item], String) async throws -> Void) async throws {
        for (index, chunk) in HealthKitChunks.chunks(items, size: limit).enumerated() {
            let key = HealthKitChunks.key(type: kind, month: month.start, chunk: index, calendar: calendar)
            guard !have.contains(key) else { continue }
            try Task.checkCancellation()
            do {
                try await send(chunk, key)
                have.insert(key)
                uploaded += chunk.count
            } catch BackendError.rejected(_, let message) {
                skipped[key] = message
            }
        }
    }

    /// The calendar months from the type's first sample up to now. A type without samples has none.
    private func months(of type: HKSampleType, calendar: Calendar) async throws -> [DateInterval] {
        let first = try await HKSampleQueryDescriptor(
            predicates: [.sample(type: type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 1
        ).result(for: health).first?.startDate
        guard let first, var month = calendar.dateInterval(of: .month, for: first) else { return [] }
        var months: [DateInterval] = []
        while month.start <= .now {
            months.append(month)
            guard let next = calendar.dateInterval(of: .month, for: month.end) else { break }
            month = next
        }
        return months
    }

    /// The points of every route of a workout. Nil when the workout has no route.
    private func routePoints(of workout: HKWorkout) async throws -> [BackendRoutePoint]? {
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))], sortDescriptors: []
        ).result(for: health)
        guard !routes.isEmpty else { return nil }
        var points: [BackendRoutePoint] = []
        for route in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: health) {
                points.append(BackendRoutePoint(location))
            }
        }
        return points
    }

    /// The lead I voltages of an electrocardiogram, in microvolts.
    private func voltages(of ecg: HKElectrocardiogram) async throws -> [Double] {
        var values: [Double] = []
        for try await measurement in HKElectrocardiogramQueryDescriptor(ecg).results(for: health) {
            if let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                values.append(quantity.doubleValue(for: .voltUnit(with: .micro)))
            }
        }
        return values
    }

    private static func predicate(_ month: DateInterval) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: month.start, end: month.end, options: [.strictStartDate])
    }

    private static func label(_ month: DateInterval) -> String {
        month.start.formatted(.dateTime.year().month(.abbreviated))
    }

    /// "HKQuantityTypeIdentifierStepCount" -> "StepCount", for the progress line.
    private static func name(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }
}
