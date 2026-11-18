import Foundation
import GarminModels

/// What the import reads from Garmin Connect. `GarminConnectClient` is the real source; tests use a fake.
public protocol ConnectDataSource: Sendable {
    func activities(start: Int, limit: Int, from: Date?, to: Date?, calendar: Calendar) async throws -> [ConnectActivity]
    func originalFIT(id: Int64) async throws -> Data?
    func dailyData(day: Date, kinds: Set<ConnectDayKind>, useArchive: Bool, calendar: Calendar) async throws
        -> [ConnectDayKind: HealthBatch]
}

extension GarminConnectClient: ConnectDataSource {}

/// What the import stage has for a key: nothing, data it imported (or is about to), or a check that found nothing.
public enum ConnectKeyState: Sendable, Equatable {
    case missing
    case imported
    case checkedEmpty
}

/// Where the import puts what it downloaded: the watch's import stage. It also says what it already has. The watch
/// service runs on the main actor, so the sink does too.
@MainActor
public protocol ConnectImportSink: Sendable {
    func importState(of key: String) async -> ConnectKeyState
    /// Whether the history holds an activity with this id, or one that started within a minute of `start`.
    func hasActivity(id: String, starting start: Date) async -> Bool
    func importFITFile(_ bytes: Data, key: String) async throws
    /// One day: its batches under their keys, and the keys whose check found nothing, so the next import skips them.
    func importDay(_ batches: [(key: String, batch: HealthBatch)], checked: [String]) async throws
}

/// How far an import has got. Activities and days are counted separately.
public struct ConnectImportProgress: Sendable, Equatable {
    public struct Counts: Sendable, Equatable {
        public var imported = 0
        /// Already in the history, or no data on Garmin.
        public var skipped = 0
        public var failed = 0

        public var done: Int { imported + skipped + failed }
    }

    public var activities = Counts()
    public var days = Counts()
    /// Activities in the list Garmin returned for the range.
    public var activityTotal = 0
    /// Days in the range. For "all" it is an estimate until the walk ends; nil while there is nothing to estimate from.
    public var dayTotal: Int?
    /// The message of the last item that failed.
    public var lastFailure: String?

    public init() {}

    mutating func update(_ kind: ConnectImportKind, _ change: (inout Counts) -> Void) {
        switch kind {
        case .activity: change(&activities)
        case .day: change(&days)
        }
    }
}

enum ConnectImportKind: Sendable {
    case activity
    case day
}

/// The keys the import stores data under. Garmin Connect keys contain "connect" (see `BackendSource`).
enum ConnectImportKey {
    /// Garmin's epoch, 1989-12-31T00:00:00Z, in Unix seconds. The watch's activity ids count from it.
    static let garminEpoch = Date(timeIntervalSince1970: 631_065_600)
    /// Combined daily imports of earlier versions: v2 held stress, steps, resting heart rate and HRV; v3 held all four
    /// and the sleep.
    static let combinedV2 = "connect-daily-v2-"
    static let combinedV3 = "connect-daily-v3-"

    static func activity(unit: UInt32, id: Int64) -> String {
        "\(unit)-connect-\(id)"
    }

    /// The id the watch's copy of an activity has in the history.
    static func watchActivity(unit: UInt32, start: Date) -> String {
        "\(unit)-\(Int(start.timeIntervalSince(garminEpoch)))"
    }

    static func day(_ kind: ConnectDayKind, date: String) -> String {
        switch kind {
        case .stress: "connect-stress-\(date)"
        case .sleep: "connect-sleep-v3-\(date)"
        case .steps: "connect-steps-\(date)"
        case .restingHeartRate: "connect-rhr-\(date)"
        case .hrv: "connect-hrv-\(date)"
        }
    }
}

/// Imports a range of a Garmin Connect account into the watch's import stage.
///
/// Two stages run side by side. The download stage asks the sink what it has and skips that before it downloads: it
/// fetches up to three activities at once, while the days walk back one at a time, each asking only for the kinds it
/// lacks. The client keeps all Garmin requests to three in flight. The processing stage hands each download to the sink.
/// The two stages meet in a buffer of `bufferLimit` items, so the download stage never runs further ahead. A failed item
/// is counted and the rest go on. Cancelling the task stops both stages.
public enum ConnectImport {
    static let bufferLimit = 4
    static let activityWindow = 3

    /// What the download stage needs: the activities of the range, and the days the walk covers.
    private struct Plan: Sendable {
        let activities: [ConnectActivity]
        let unit: UInt32
        let today: Date
        /// The first day of the range; nil walks every day back to the earliest activity.
        let first: Date?
        let earliest: Date?
        let calendar: Calendar
    }

    /// - Parameters:
    ///   - days: the days before today to import; 0 imports every activity and all daily data.
    ///   - unit: the watch's unit number, which keys the activities.
    ///   - report: receives the progress after each item.
    /// - Returns: the final progress. A cancelled import returns what it had done.
    @MainActor
    public static func run<Source: ConnectDataSource, Sink: ConnectImportSink>(
        days: Int, unit: UInt32, now: Date = .now, calendar: Calendar = .current,
        source: Source, sink: Sink, report: (ConnectImportProgress) -> Void
    ) async throws -> ConnectImportProgress {
        let today = calendar.startOfDay(for: now)
        let first = days == 0 ? nil : calendar.date(byAdding: .day, value: -(days - 1), to: today)
        let activities = try await listActivities(source, from: first, to: days == 0 ? nil : today, calendar: calendar)
        let earliest = activities.map { calendar.startOfDay(for: $0.start) }.min()
        let plan = Plan(activities: activities, unit: unit, today: today, first: first, earliest: earliest, calendar: calendar)

        var progress = ConnectImportProgress()
        progress.activityTotal = activities.count
        progress.dayTotal = days == 0 ? estimatedDays(earliest: earliest, today: today, calendar: calendar) : max(0, days - 1)
        report(progress)

        let buffer = BoundedBuffer<ConnectDownload>(capacity: bufferLimit)
        return try await withTaskCancellationHandler {
            async let downloading: Void = download(plan, source: source, sink: sink, into: buffer)
            while let item = await buffer.next() {
                await process(item, sink: sink, into: &progress)
                if days == 0, let total = progress.dayTotal, progress.days.done > total {
                    progress.dayTotal = progress.days.done
                }
                report(progress)
            }
            await downloading
            if days == 0 { progress.dayTotal = progress.days.done }
            report(progress)
            return progress
        } onCancel: {
            Task { await buffer.cancel() }
        }
    }

    /// The days "all" walks: from yesterday back to 30 days before the earliest activity, when no data ends it sooner.
    private static func estimatedDays(earliest: Date?, today: Date, calendar: Calendar) -> Int? {
        guard let earliest, let lowest = calendar.date(byAdding: .day, value: -30, to: earliest),
              let count = calendar.dateComponents([.day], from: lowest, to: today).day else { return nil }
        return max(0, count)
    }

    /// Every activity between two calendar days, in pages of 100. The range goes to Garmin, so a page only holds
    /// activities inside it; the list is read once per import.
    private static func listActivities(_ source: some ConnectDataSource, from first: Date?, to last: Date?,
                                       calendar: Calendar) async throws -> [ConnectActivity] {
        var all: [ConnectActivity] = []
        var start = 0
        while true {
            let page = try await source.activities(start: start, limit: 100, from: first, to: last, calendar: calendar)
            all += page
            if page.count < 100 { return all }
            start += 100
        }
    }

    // MARK: - Download stage

    private static func download(_ plan: Plan, source: some ConnectDataSource, sink: some ConnectImportSink,
                                 into buffer: BoundedBuffer<ConnectDownload>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await downloadActivities(plan, source: source, sink: sink, into: buffer) }
            group.addTask { await downloadDays(plan, source: source, sink: sink, into: buffer) }
        }
        await buffer.finish()
    }

    private static func downloadActivities(_ plan: Plan, source: some ConnectDataSource,
                                           sink: some ConnectImportSink, into buffer: BoundedBuffer<ConnectDownload>) async {
        await withTaskGroup(of: ConnectDownload.self) { group in
            var pending = plan.activities.makeIterator()
            for _ in 0..<activityWindow {
                guard let activity = pending.next() else { break }
                group.addTask { await fetchActivity(activity, unit: plan.unit, source: source, sink: sink) }
            }
            for await item in group {
                guard await buffer.put(item) else {
                    group.cancelAll()
                    return
                }
                guard let activity = pending.next() else { continue }
                group.addTask { await fetchActivity(activity, unit: plan.unit, source: source, sink: sink) }
            }
        }
    }

    /// An activity is skipped when the import stage has its key, or the history has the watch's copy of it. Only the
    /// rest is downloaded.
    private static func fetchActivity(_ activity: ConnectActivity, unit: UInt32, source: some ConnectDataSource,
                                      sink: some ConnectImportSink) async -> ConnectDownload {
        let key = ConnectImportKey.activity(unit: unit, id: activity.id)
        if await sink.importState(of: key) != .missing { return .skipped(.activity) }
        let watchID = ConnectImportKey.watchActivity(unit: unit, start: activity.start)
        if await sink.hasActivity(id: watchID, starting: activity.start) { return .skipped(.activity) }
        do {
            guard let fit = try await source.originalFIT(id: activity.id) else { return .skipped(.activity) }
            return .fit(key: key, fit)
        } catch {
            return .failed(.activity, "Activity \(activity.id): \(error.localizedDescription)")
        }
    }

    /// Walks the days newest first, up to yesterday. "All" stops after 30 days in a row without data once it is past the
    /// earliest activity. A day counts as empty when it has no data, whether it was checked before or is checked now.
    private static func downloadDays(_ plan: Plan, source: some ConnectDataSource, sink: some ConnectImportSink,
                                     into buffer: BoundedBuffer<ConnectDownload>) async {
        let calendar = plan.calendar
        // Garmin may still fill yesterday and the day before, so their empty answers are not recorded.
        let recentFrom = calendar.date(byAdding: .day, value: -2, to: plan.today) ?? plan.today
        var day = calendar.date(byAdding: .day, value: -1, to: plan.today)
        var emptyDays = 0
        while let current = day {
            if let first = plan.first {
                if current < first { break }
            } else if emptyDays >= 30 && current < (plan.earliest ?? .distantFuture) {
                break
            }
            let result = await fetchDay(current, recent: current >= recentFrom, source: source, sink: sink, calendar: calendar)
            if result.failure == nil { emptyDays = result.hasData ? 0 : emptyDays + 1 }
            guard await buffer.put(.day(result)) else { return }
            day = calendar.date(byAdding: .day, value: -1, to: current)
        }
    }

    /// The kinds of one day the import stage lacks, read from Garmin. The combined keys of earlier versions count:
    /// v3 holds every kind, and v2 every kind but the sleep.
    private static func fetchDay(_ day: Date, recent: Bool, source: some ConnectDataSource, sink: some ConnectImportSink,
                                 calendar: Calendar) async -> DayDownload {
        let date = ConnectRequests.day(day, calendar: calendar)
        let combinedV3 = await sink.importState(of: ConnectImportKey.combinedV3 + date) == .imported
        let combinedV2 = await sink.importState(of: ConnectImportKey.combinedV2 + date) == .imported
        var result = DayDownload()
        var needed: Set<ConnectDayKind> = []
        for kind in ConnectDayKind.allCases {
            if combinedV3 || (combinedV2 && kind != .sleep) {
                result.hasData = true
                continue
            }
            switch await sink.importState(of: ConnectImportKey.day(kind, date: date)) {
            case .imported: result.hasData = true
            case .checkedEmpty: continue
            case .missing: needed.insert(kind)
            }
        }
        guard !needed.isEmpty else { return result }
        do {
            let fetched = try await source.dailyData(day: day, kinds: needed, useArchive: !recent, calendar: calendar)
            for kind in ConnectDayKind.allCases where needed.contains(kind) {
                let batch = fetched[kind] ?? HealthBatch()
                let key = ConnectImportKey.day(kind, date: date)
                if !batch.isEmpty {
                    result.batches.append(KeyedBatch(key: key, batch: batch))
                    result.hasData = true
                } else if !recent {
                    result.checked.append(key)
                }
            }
        } catch {
            return DayDownload(failure: "Day \(date): \(error.localizedDescription)")
        }
        return result
    }

    // MARK: - Processing stage

    /// Hands one download to the sink and counts the outcome.
    @MainActor
    private static func process(_ item: ConnectDownload, sink: some ConnectImportSink,
                                into progress: inout ConnectImportProgress) async {
        switch item {
        case let .fit(key, bytes):
            await count(.activity, in: &progress) { try await sink.importFITFile(bytes, key: key) }
        case let .day(day):
            await importDay(day, sink: sink, into: &progress)
        case let .skipped(kind):
            progress.update(kind) { $0.skipped += 1 }
        case let .failed(kind, message):
            progress.update(kind) { $0.failed += 1 }
            progress.lastFailure = message
        }
    }

    /// One day is one commit to the history. It counts as imported when a kind was imported, as failed when it could not
    /// be read or stored, and as skipped when there was nothing new.
    @MainActor
    private static func importDay(_ day: DayDownload, sink: some ConnectImportSink,
                                  into progress: inout ConnectImportProgress) async {
        if let failure = day.failure {
            progress.days.failed += 1
            progress.lastFailure = failure
            return
        }
        do {
            if !day.batches.isEmpty || !day.checked.isEmpty {
                try await sink.importDay(day.batches.map { (key: $0.key, batch: $0.batch) }, checked: day.checked)
            }
            if day.batches.isEmpty { progress.days.skipped += 1 } else { progress.days.imported += 1 }
        } catch {
            progress.days.failed += 1
            progress.lastFailure = error.localizedDescription
        }
    }

    @MainActor
    private static func count(_ kind: ConnectImportKind, in progress: inout ConnectImportProgress,
                              _ work: () async throws -> Void) async {
        do {
            try await work()
            progress.update(kind) { $0.imported += 1 }
        } catch {
            progress.update(kind) { $0.failed += 1 }
            progress.lastFailure = error.localizedDescription
        }
    }
}

/// One batch of a day, with the key it is imported under.
struct KeyedBatch: Sendable {
    let key: String
    let batch: HealthBatch
}

/// One day as the download stage reads it: the batches to import, the keys to record as checked, and whether the day
/// holds data.
struct DayDownload: Sendable {
    var batches: [KeyedBatch] = []
    var checked: [String] = []
    var hasData = false
    /// Set when the day could not be read. Such a day is not counted as empty.
    var failure: String?
}

/// What the download stage hands to the processing stage. Each activity and each day becomes exactly one item.
enum ConnectDownload: Sendable {
    case fit(key: String, Data)
    case day(DayDownload)
    case skipped(ConnectImportKind)
    case failed(ConnectImportKind, String)
}

/// Hands items from the download stage to the processing stage. `put` waits while `capacity` items are waiting, so the
/// producer never runs more than `capacity` items ahead. `cancel` wakes every waiter at once, so a cancelled import
/// cannot hang on either stage.
actor BoundedBuffer<Element: Sendable> {
    private let capacity: Int
    private var items: [Element] = []
    private var finished = false
    private var cancelled = false
    private var putters: [CheckedContinuation<Void, Never>] = []
    private var takers: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Waits for room. False once the buffer is cancelled or finished, and then the item is dropped.
    func put(_ item: Element) async -> Bool {
        while items.count >= capacity && !cancelled {
            await withCheckedContinuation { putters.append($0) }
        }
        guard !cancelled, !finished else { return false }
        items.append(item)
        if !takers.isEmpty { takers.removeFirst().resume() }
        return true
    }

    /// The next item, waiting for one. nil once the buffer is finished and empty, or cancelled.
    func next() async -> Element? {
        while items.isEmpty && !finished && !cancelled {
            await withCheckedContinuation { takers.append($0) }
        }
        guard !cancelled, !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if !putters.isEmpty { putters.removeFirst().resume() }
        return item
    }

    /// No more items will come. The items already waiting are still handed out.
    func finish() {
        finished = true
        resumeAll()
    }

    func cancel() {
        cancelled = true
        items.removeAll()
        resumeAll()
    }

    private func resumeAll() {
        let waiting = putters + takers
        putters = []
        takers = []
        for continuation in waiting { continuation.resume() }
    }
}
