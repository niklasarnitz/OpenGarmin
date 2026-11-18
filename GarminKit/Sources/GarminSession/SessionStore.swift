import Foundation
import GarminModels

/// One calendar day of watch data, derived from the retained history.
public struct DailySummary: Sendable, Codable, Hashable, Identifiable {
    /// Start of the day in the local calendar.
    public var day: Date
    public var steps: Double
    public var activeEnergyKcal: Double
    /// metres
    public var distance: Double
    public var intensityMinutes: Double
    public var restingHeartRate: Double?
    public var averageStress: Double?
    public var sleepMinutes: Double?
    public var sleepScore: Int?
    public var activityCount: Int

    public var id: Date { day }
}

/// What the session keeps between launches: the paired watch, which files were imported, the retained history and
/// the raw FIT files. Everything lives in Application Support, so it survives relaunches but not a reinstall.
@MainActor
public final class SessionStore {
    /// Samples older than this are dropped from the history. Activities and their records are kept.
    public static let retention: TimeInterval = 30 * 24 * 3600

    struct Snapshot: Codable {
        var history = HealthBatch()
        var days: [DailySummary] = []
        var importedFiles: Set<String> = []
    }

    private static let pairedWatchKey = "garmin.pairedWatch"
    private static let userProfileKey = "garmin.userProfile"

    public let directory: URL
    private let defaults: UserDefaults
    private let calendar: Calendar
    private var snapshot: Snapshot

    public init(directory: URL, defaults: UserDefaults = .standard, calendar: Calendar = .current) throws {
        self.directory = directory
        self.defaults = defaults
        self.calendar = calendar
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.snapshotURL(in: directory)),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    /// The store in the app's Application Support directory.
    public static func standard() throws -> SessionStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try SessionStore(directory: support.appendingPathComponent("OpenGarmin", isDirectory: true))
    }

    /// Everything synced so far: activities in full, samples for the last `retention` period.
    public var history: HealthBatch { snapshot.history }

    /// One summary per day that has data, oldest first.
    public var days: [DailySummary] { snapshot.days }

    public var pairedWatch: PairedWatch? {
        get {
            defaults.data(forKey: Self.pairedWatchKey).flatMap { try? JSONDecoder().decode(PairedWatch.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.pairedWatchKey)
            } else {
                defaults.removeObject(forKey: Self.pairedWatchKey)
            }
        }
    }

    /// The profile the user last saved. It is sent to the watch after every handshake.
    public var userProfile: UserProfile? {
        get {
            defaults.data(forKey: Self.userProfileKey).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.userProfileKey)
            } else {
                defaults.removeObject(forKey: Self.userProfileKey)
            }
        }
    }

    public func isImported(_ fileKey: String) -> Bool {
        snapshot.importedFiles.contains(fileKey)
    }

    /// Stores a raw FIT file, merges its batch into the history and recomputes the daily summaries.
    /// Overlapping files (the watch's monitoring files share samples) do not duplicate samples.
    func record(_ batch: HealthBatch, fileKey: String, fit: Data, now: Date = .now) throws {
        try FileManager.default.createDirectory(at: fitDirectory, withIntermediateDirectories: true)
        try fit.write(to: fitDirectory.appendingPathComponent(Self.safeName(fileKey) + ".fit"), options: .atomic)
        try markImported(fileKey, batch: batch, now: now)
    }

    /// Marks a file as imported without storing it, for files that archived on the watch but could not be decoded.
    func markImported(_ fileKey: String, batch: HealthBatch = HealthBatch(), now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var history = Self.merged(snapshot.history, with: batch, cutoff: cutoff)
        history.activities.sort { $0.start < $1.start }
        snapshot.history = history
        snapshot.days = dailySummaries(for: history)
        snapshot.importedFiles.insert(fileKey)
        try save()
    }

    /// Removes the imported files and history. The paired watch is kept until `pairedWatch` is cleared.
    public func clearHistory() throws {
        snapshot = Snapshot()
        try? FileManager.default.removeItem(at: fitDirectory)
        try save()
    }

    // MARK: - Files

    private var fitDirectory: URL { directory.appendingPathComponent("FIT", isDirectory: true) }

    private static func snapshotURL(in directory: URL) -> URL {
        directory.appendingPathComponent("history.json")
    }

    private func save() throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: Self.snapshotURL(in: directory), options: .atomic)
    }

    private static func safeName(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    // MARK: - Merging

    static func merged(_ base: HealthBatch, with new: HealthBatch, cutoff: Date) -> HealthBatch {
        var out = HealthBatch()
        out.heartRate = union(base.heartRate, new.heartRate).filter { $0.date >= cutoff }
        out.restingHeartRate = union(base.restingHeartRate, new.restingHeartRate).filter { $0.date >= cutoff }
        out.steps = union(base.steps, new.steps).filter { $0.end >= cutoff }
        out.activeEnergyKcal = union(base.activeEnergyKcal, new.activeEnergyKcal).filter { $0.end >= cutoff }
        out.restingEnergyKcal = union(base.restingEnergyKcal, new.restingEnergyKcal).filter { $0.end >= cutoff }
        out.distance = union(base.distance, new.distance).filter { $0.end >= cutoff }
        out.floorsClimbed = union(base.floorsClimbed, new.floorsClimbed).filter { $0.end >= cutoff }
        out.intensityMinutes = union(base.intensityMinutes, new.intensityMinutes).filter { $0.end >= cutoff }
        out.stress = union(base.stress, new.stress).filter { $0.date >= cutoff }
        out.bodyBattery = union(base.bodyBattery, new.bodyBattery).filter { $0.date >= cutoff }
        out.spo2 = union(base.spo2, new.spo2).filter { $0.date >= cutoff }
        out.respirationRate = union(base.respirationRate, new.respirationRate).filter { $0.date >= cutoff }
        out.hrv = union(base.hrv, new.hrv).filter { $0.date >= cutoff }
        out.sleep = union(base.sleep, new.sleep).filter { $0.end >= cutoff }
        let replaced = Set(new.activities.map(\.id))
        out.activities = base.activities.filter { !replaced.contains($0.id) } + union([], new.activities)
        return out
    }

    /// `base` followed by the elements of `new` that are not in it yet.
    private static func union<T: Hashable>(_ base: [T], _ new: [T]) -> [T] {
        var seen = Set(base)
        var out = base
        for element in new where seen.insert(element).inserted {
            out.append(element)
        }
        return out
    }

    // MARK: - Daily summaries

    func dailySummaries(for batch: HealthBatch) -> [DailySummary] {
        var days: [Date: DailySummary] = [:]
        func update(_ date: Date, _ change: (inout DailySummary) -> Void) {
            let day = calendar.startOfDay(for: date)
            var summary = days[day] ?? DailySummary(day: day, steps: 0, activeEnergyKcal: 0, distance: 0,
                                                    intensityMinutes: 0, restingHeartRate: nil, averageStress: nil,
                                                    sleepMinutes: nil, sleepScore: nil, activityCount: 0)
            change(&summary)
            days[day] = summary
        }
        for sample in batch.steps { update(sample.start) { $0.steps += sample.value } }
        for sample in batch.activeEnergyKcal { update(sample.start) { $0.activeEnergyKcal += sample.value } }
        for sample in batch.distance { update(sample.start) { $0.distance += sample.value } }
        for sample in batch.intensityMinutes { update(sample.start) { $0.intensityMinutes += sample.value } }
        for sample in batch.restingHeartRate.sorted(by: { $0.date < $1.date }) {
            update(sample.date) { $0.restingHeartRate = sample.value }
        }
        var stress: [Date: [Double]] = [:]
        for sample in batch.stress { stress[calendar.startOfDay(for: sample.date), default: []].append(sample.value) }
        for (day, values) in stress where !values.isEmpty {
            update(day) { $0.averageStress = values.reduce(0, +) / Double(values.count) }
        }
        for session in batch.sleep {
            update(session.start) {
                $0.sleepMinutes = ($0.sleepMinutes ?? 0) + session.end.timeIntervalSince(session.start) / 60
                if let score = session.score { $0.sleepScore = score }
            }
        }
        for activity in batch.activities { update(activity.start) { $0.activityCount += 1 } }
        return days.values.sorted { $0.day < $1.day }
    }
}
