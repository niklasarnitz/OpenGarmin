import Foundation
import GarminFIT
import GarminModels

/// The import stage. It turns the FIT files in the inbox into history, separately from the download stage and off the
/// main actor. A run imports everything the inbox holds as one batch: one history merge, one snapshot write and one
/// `.imported` event, after which the files move from the inbox to `FIT/`. Files that were not imported before a
/// restart are imported by the next run.
actor FITImporter {
    enum Event: Sendable {
        /// An import run has started.
        case started
        /// A batch was merged. `batch` is the part of it that goes to Apple Health (see `healthPart`); `history` is the
        /// retained history after the merge.
        case imported(HealthBatch, history: HealthBatch)
        /// The run ended: the inbox is empty, or its files could not be stored yet and stay there for the next run.
        case finished
        case log(String)
    }

    private var history: HistoryStore
    private let report: @Sendable (Event) -> Void
    /// Runs once at the start of each run, before the inbox is read. Tests use it to hold the import stage.
    private let beforeImport: @Sendable () async -> Void
    private var running = false

    /// - Parameters:
    ///   - report: receives the events, on any thread.
    ///   - beforeImport: a delay before each run, for tests.
    init(history: HistoryStore, report: @escaping @Sendable (Event) -> Void,
         beforeImport: @escaping @Sendable () async -> Void = {}) {
        self.history = history
        self.report = report
        self.beforeImport = beforeImport
    }

    /// Keeps a downloaded file in the inbox and starts a run. The file is durable once this returns, so the watch
    /// may archive it.
    func accept(_ bytes: Data, fileKey: String) throws {
        try history.writeToInbox(bytes, fileKey: fileKey)
        start()
    }

    /// Merges a batch that has no FIT file into the history at once, as one import under `fileKey`. The batch is also
    /// kept in `Batches/` for the backend upload.
    func acceptBatch(_ batch: HealthBatch, fileKey: String) throws {
        try history.saveBatch(batch, fileKey: fileKey)
        try history.commit([HistoryStore.Entry(key: fileKey, batch: batch)])
        report(.imported(Self.healthPart(of: fileKey, batch), history: history.history))
    }

    /// The part of a file's or batch's data that goes to Apple Health. A watch file goes whole. Garmin Connect data goes
    /// only for its activities: the Connect app already wrote its steps, sleep, heart rate and HRV to Health, and the
    /// watch's own data covers the rest. Connect data keeps its place in the history and the backend upload.
    static func healthPart(of fileKey: String, _ batch: HealthBatch) -> HealthBatch {
        guard fileKey.contains("connect") else { return batch }
        var part = HealthBatch()
        part.activities = batch.activities
        return part
    }

    /// Whether the file is imported or waiting in the inbox. Either way it is safe to archive on the watch.
    func isKnown(_ fileKey: String) -> Bool {
        history.isImported(fileKey) || FileManager.default.fileExists(atPath: history.inboxFile(for: fileKey).path)
    }

    /// Whether a check of this key found nothing to import (see `markChecked`).
    func wasChecked(_ fileKey: String) -> Bool {
        history.isImported(HistoryStore.checkedKey(fileKey))
    }

    /// Merges one day of Garmin Connect data into the history in one commit: each batch under its own key (kept in
    /// `Batches/` for the backend upload), and the keys whose check found nothing. One `.imported` event covers the day.
    func acceptDay(_ batches: [(key: String, batch: HealthBatch)], checked: [String]) throws {
        for item in batches { try history.saveBatch(item.batch, fileKey: item.key) }
        let entries = batches.map { HistoryStore.Entry(key: $0.key, batch: $0.batch) }
            + checked.map { HistoryStore.Entry(key: HistoryStore.checkedKey($0), batch: HealthBatch()) }
        try history.commit(entries)
        guard !batches.isEmpty else { return }
        var health = HealthBatch()
        for item in batches { health.merge(Self.healthPart(of: item.key, item.batch)) }
        report(.imported(health, history: history.history))
    }

    /// Whether the history holds an activity with this id, or one that started within a minute of `start`.
    func hasActivity(id: String, starting start: Date) -> Bool {
        history.history.activities.contains { $0.id == id || abs($0.start.timeIntervalSince(start)) <= 60 }
    }

    /// Starts a run, unless one is going. Called at launch, on connect and after each accepted file.
    func start() {
        guard !running else { return }
        running = true
        Task { await run() }
    }

    /// Snapshots written so far, for tests that check a sync costs one write per batch.
    var snapshotWrites: Int { history.writes }

    private func run() async {
        report(.started)
        await beforeImport()
        while true {
            let files = history.pendingFiles()
            if files.isEmpty || !importBatch(files) { break }
        }
        running = false
        report(.finished)
    }

    /// Imports one batch of inbox files. Returns false when the store could not be written, and then the files stay in
    /// the inbox for the next run.
    private func importBatch(_ files: [(key: String, url: URL)]) -> Bool {
        var entries: [HistoryStore.Entry] = []
        var batch = HealthBatch()
        var health = HealthBatch()
        for file in files where !history.isImported(file.key) {
            // A file that does not decode is still recorded, so it is not imported again.
            var decoded = HealthBatch()
            do {
                let fit = try FitDecoder.decode(Data(contentsOf: file.url))
                decoded = FitExtractor.extract(fit, unitNumber: Self.unitNumber(of: file.key))
            } catch {
                report(.log("Skipped FIT file \(file.key): \(error)"))
            }
            batch.merge(decoded)
            health.merge(Self.healthPart(of: file.key, decoded))
            entries.append(HistoryStore.Entry(key: file.key, batch: decoded))
        }
        do {
            // A file already in the history (the app stopped after the commit) is only moved out of the inbox.
            if !entries.isEmpty { try history.commit(entries) }
            for file in files { try history.archiveFile(file.url, fileKey: file.key) }
        } catch {
            report(.log("Could not store \(files.count) FIT files: \(error)"))
            return false
        }
        if batch != HealthBatch() { report(.imported(health, history: history.history)) }
        return true
    }

    /// File keys start with the watch's unit number, which the extractor puts into activity ids.
    private static func unitNumber(of fileKey: String) -> UInt32? {
        UInt32(fileKey.prefix { $0 != "-" })
    }
}
