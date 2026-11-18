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
        /// A batch was merged. `batch` is what was new; `history` is the retained history after it.
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
        report(.imported(batch, history: history.history))
    }

    /// Whether the file is imported or waiting in the inbox. Either way it is safe to archive on the watch.
    func isKnown(_ fileKey: String) -> Bool {
        history.isImported(fileKey) || FileManager.default.fileExists(atPath: history.inboxFile(for: fileKey).path)
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
        if batch != HealthBatch() { report(.imported(batch, history: history.history)) }
        return true
    }

    /// File keys start with the watch's unit number, which the extractor puts into activity ids.
    private static func unitNumber(of fileKey: String) -> UInt32? {
        UInt32(fileKey.prefix { $0 != "-" })
    }
}
