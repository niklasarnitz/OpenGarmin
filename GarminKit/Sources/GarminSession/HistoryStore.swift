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

/// The history on disk: the samples of the retention period, every imported activity, one summary per day, the keys
/// of the files already imported, and the raw FIT files. Only the import stage (`FITImporter`) owns and writes it, so
/// it never runs on the main actor. Layout under `directory`: `history.json`, `Inbox/` (files waiting for import) and
/// `FIT/` (imported files).
struct HistoryStore {
    /// Samples older than this are dropped from the history. Activities and their records are kept.
    static let retention: TimeInterval = 30 * 24 * 3600

    struct Snapshot: Codable {
        var history = HealthBatch()
        var days: [DailySummary] = []
        var importedFiles: Set<String> = []
    }

    /// One file of a commit. A file that did not decode has an empty batch: it is recorded as imported, not retried.
    struct Entry {
        var key: String
        var batch: HealthBatch
    }

    let directory: URL
    private(set) var snapshot: Snapshot
    /// How many snapshots have been written by this store. Tests use it to check that a batch costs one write.
    private(set) var writes = 0
    private let calendar: Calendar

    init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
        if let data = try? Data(contentsOf: directory.appendingPathComponent("history.json")),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    var history: HealthBatch { snapshot.history }

    func isImported(_ fileKey: String) -> Bool {
        snapshot.importedFiles.contains(fileKey)
    }

    /// Merges a commit into the history: one merge, one daily-summary recompute and one snapshot write, however many
    /// files it holds. Overlapping files (the watch's monitoring files share samples) do not duplicate samples.
    mutating func commit(_ entries: [Entry], now: Date = .now) throws {
        var batch = HealthBatch()
        for entry in entries { batch.merge(entry.batch) }
        var next = snapshot
        var history = Self.merged(next.history, with: batch, cutoff: now.addingTimeInterval(-Self.retention))
        history.activities.sort { $0.start < $1.start }
        next.history = history
        next.days = dailySummaries(for: history)
        next.importedFiles.formUnion(entries.map(\.key))
        try write(next)
        snapshot = next
        writes += 1
    }

    // MARK: - Files

    var inboxDirectory: URL { directory.appendingPathComponent("Inbox", isDirectory: true) }
    private var fitDirectory: URL { directory.appendingPathComponent("FIT", isDirectory: true) }

    func inboxFile(for fileKey: String) -> URL {
        inboxDirectory.appendingPathComponent(fileKey + ".fit")
    }

    /// Writes a downloaded file into the inbox. The write is atomic, so a crash leaves either the whole file or none.
    func writeToInbox(_ bytes: Data, fileKey: String) throws {
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        try bytes.write(to: inboxFile(for: fileKey), options: .atomic)
    }

    /// The inbox files, by file key, in name order.
    func pendingFiles() -> [(key: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "fit" }
            .map { (key: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.key < $1.key }
    }

    /// Moves an inbox file into `FIT/`, where imported files are kept.
    func archiveFile(_ url: URL, fileKey: String) throws {
        try FileManager.default.createDirectory(at: fitDirectory, withIntermediateDirectories: true)
        let destination = fitDirectory.appendingPathComponent(fileKey + ".fit")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private func write(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
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
