import Foundation
import Testing
import GarminModels
@testable import GarminConnect

/// Answers the Garmin Connect calls of a client from a table and logs each URL, so a test can count what the import asked
/// for. The log and the answer are guarded by a lock, because URLProtocol answers on its own threads.
final class GarminStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: ((URL) -> (status: Int, body: Data))?
    nonisolated(unsafe) private static var log: [String] = []

    static func install(_ answer: @escaping (URL) -> (status: Int, body: Data)) {
        lock.withLock {
            self.answer = answer
            log = []
        }
    }

    static var requests: [String] {
        lock.withLock { log }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GarminStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let answer = GarminStub.lock.withLock { () -> (status: Int, body: Data) in
            GarminStub.log.append(url.absoluteString)
            return GarminStub.answer?(url) ?? (404, Data())
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The Garmin data of the fixture account: an activity on 8 January that Garmin lists first, and one on 6 January that
/// the watch already delivered. Days 7 and 6 have data (6 has no resting heart rate or HRV in its sleep), day 5 has none.
private enum Fixture {
    static let stress = Data(#"{ "stressValuesArray" : [[1767830400000, 25]] }"#.utf8)
    static let steps = Data(#"[{"startGMT":"2026-01-07 10:00:00","endGMT":"2026-01-07 10:15:00","steps":120}]"#.utf8)
    static let sleep7 = Data(#"{"dailySleepDTO":{"calendarDate":"2026-01-07","sleepStartTimestampGMT":1767744000000,"sleepEndTimestampGMT":1767772800000},"sleepLevels":[{"startGMT":"2026-01-07 00:00:00","endGMT":"2026-01-07 01:00:00","activityLevel":1}],"restingHeartRate":50,"avgOvernightHrv":40}"#.utf8)
    static let sleep6 = Data(#"{"dailySleepDTO":{"calendarDate":"2026-01-06","sleepStartTimestampGMT":1767657600000,"sleepEndTimestampGMT":1767686400000},"sleepLevels":[{"startGMT":"2026-01-06 00:00:00","endGMT":"2026-01-06 01:00:00","activityLevel":0}]}"#.utf8)
    static let summary6 = Data(#"{"restingHeartRate":52}"#.utf8)
    static let hrv6 = Data(#"{"hrvSummary":{"lastNightAvg":41},"sleepEndTimestampGMT":"2026-01-06 06:00:00"}"#.utf8)
    static let activities = Data(#"[{"activityId":111,"startTimeGMT":"2026-01-08 14:10:21"},{"activityId":222,"startTimeGMT":"2026-01-06 09:00:00"}]"#.utf8)
    static let fit = Data([1, 2, 3])

    /// Garmin's answer for a request: the fixture's body, or 404 where Garmin has no data.
    static func answer(_ url: URL) -> (status: Int, body: Data) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let path = url.path
        let body: Data?
        if path == "/activitylist-service/activities/search/activities" {
            body = value("start") == "0" ? activities : Data("[]".utf8)
        } else if path.hasPrefix("/download-service/files/activity/") {
            body = storedZip(name: "activity.fit", data: fit)
        } else if path.contains("/dailyStress/") {
            body = url.lastPathComponent == "2026-01-07" ? stress : nil
        } else if path.contains("/dailySleepData/") {
            body = ["2026-01-07": sleep7, "2026-01-06": sleep6][value("date") ?? ""]
        } else if path.contains("/dailySummaryChart/") {
            body = value("date") == "2026-01-07" ? steps : nil
        } else if path.contains("/usersummary/") {
            body = value("calendarDate") == "2026-01-06" ? summary6 : nil
        } else if path.contains("/hrv/") {
            body = url.lastPathComponent == "2026-01-06" ? hrv6 : nil
        } else {
            body = nil
        }
        if let body { return (200, body) }
        return (404, Data())
    }

    /// A zip archive with one stored entry, the shape of Garmin's original-activity download.
    static func storedZip(name: String, data: Data) -> Data {
        let nameBytes = Data(name.utf8)
        var out = Data()
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }
        u32(0x0403_4b50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0)
        u32(data.count); u32(data.count); u16(nameBytes.count); u16(0)
        out.append(nameBytes)
        out.append(data)
        let central = out.count
        u32(0x0201_4b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0)
        u32(data.count); u32(data.count); u16(nameBytes.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        out.append(nameBytes)
        let centralSize = out.count - central
        u32(0x0605_4b50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(central); u16(0)
        return out
    }
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 8 January 2026, 12:00 UTC. The import of four days walks 7, 6 and 5 January; 8 January is today and is left out.
private let now = Date(timeIntervalSince1970: 1_767_873_600)

private let credentials = ConnectCredentials(
    consumer: ConnectConsumer(key: "key", secret: "secret"),
    oauth1: ConnectOAuth1Token(token: "token", secret: "secret", mfaToken: nil),
    access: ConnectAccessToken(value: "AT", type: "Bearer", expiresAt: .distantFuture),
    displayName: "tester")

/// The import stage as the import sees it: what each key holds, and what it was handed.
@MainActor
private final class FakeSink: ConnectImportSink {
    var states: [String: ConnectKeyState] = [:]
    /// Start times of the watch's own activities in the history.
    var watchStarts: [Date] = []
    private(set) var fitKeys: [String] = []
    private(set) var dayCommits = 0

    func importState(of key: String) async -> ConnectKeyState {
        states[key] ?? .missing
    }

    func hasActivity(id: String, starting start: Date) async -> Bool {
        watchStarts.contains { abs($0.timeIntervalSince(start)) <= 60 }
    }

    func importFITFile(_ bytes: Data, key: String) async throws {
        fitKeys.append(key)
        states[key] = .imported
    }

    func importDay(_ batches: [(key: String, batch: HealthBatch)], checked: [String]) async throws {
        dayCommits += 1
        for item in batches { states[item.key] = .imported }
        for key in checked { states[key] = .checkedEmpty }
    }
}

@Suite struct ConnectRequestLimiterTests {
    private actor Gauge {
        private var running = 0
        private(set) var peak = 0

        func enter() {
            running += 1
            peak = max(peak, running)
        }

        func leave() {
            running -= 1
        }
    }

    @Test func neverMoreThanThreeRequestsAreInFlight() async throws {
        let limiter = ConnectRequestLimiter(limit: 3)
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await limiter.run {
                        await gauge.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await gauge.peak == 3)
    }
}

@Suite struct ConnectRateLimitTests {
    @Test func aRateLimitWaitsForRetryAfterOrDoublesFromTwoSeconds() async throws {
        var waits: [Double] = []
        var calls = 0
        let value = try await retryingWhenRateLimited(sleep: { waits.append(Double($0.components.seconds)) }) {
            calls += 1
            switch calls {
            case 1, 3: throw GarminConnectError.rateLimited(retryAfter: nil)
            case 2: throw GarminConnectError.rateLimited(retryAfter: 7)
            default: return "done"
            }
        }
        #expect(value == "done")
        #expect(calls == 4)
        // The first and third failures have no Retry-After, so they wait 2 s and then 2 << 2 = 8 s; the second waits 7 s.
        #expect(waits == [2, 7, 8])
    }

    @Test func otherErrorsAreNotRetried() async throws {
        var calls = 0
        await #expect(throws: GarminConnectError.http(500)) {
            _ = try await retryingWhenRateLimited(sleep: { _ in }) { () async throws -> Int in
                calls += 1
                throw GarminConnectError.http(500)
            }
        }
        #expect(calls == 1)
    }
}

@Suite(.serialized) @MainActor struct ConnectImportPipelineTests {
    private func makeRawDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func makeClient(raw: URL) -> GarminConnectClient {
        GarminConnectClient(raw: ConnectRawStore(directory: raw), session: GarminStub.session(), credentials: credentials)
    }

    private func count(_ fragment: String) -> Int {
        GarminStub.requests.filter { $0.contains(fragment) }.count
    }

    private func runImport(client: GarminConnectClient, sink: FakeSink) async throws -> ConnectImportProgress {
        try await ConnectImport.run(days: 4, unit: 3, now: now, calendar: utc, source: client, sink: sink, report: { _ in })
    }

    @Test func eachItemIsProcessedOnceAndTheSecondRunAsksGarminAlmostNothing() async throws {
        GarminStub.install(Fixture.answer)
        let sink = FakeSink()
        // The watch already holds an activity that started 30 s after the Connect activity of 6 January.
        sink.watchStarts = [Date(timeIntervalSince1970: 1_767_690_030)]
        let client = makeClient(raw: makeRawDirectory())

        let first = try await runImport(client: client, sink: sink)

        #expect(first.activities == .init(imported: 1, skipped: 1, failed: 0))
        #expect(first.days == .init(imported: 2, skipped: 1, failed: 0))
        #expect(sink.fitKeys == ["3-connect-111"])
        #expect(sink.dayCommits == 3)
        #expect(count("/activitylist-service/") == 1)
        #expect(count("/download-service/") == 1)
        #expect(count("/dailyStress/") == 3)
        #expect(count("/dailySleepData/") == 3)
        #expect(count("/dailySummaryChart/") == 3)
        // Only 6 January lacks resting heart rate and HRV in its sleep, and 5 January lacks the sleep itself.
        #expect(count("/usersummary/") == 2)
        #expect(count("/hrv/") == 2)

        GarminStub.install(Fixture.answer)
        let second = try await runImport(client: client, sink: sink)

        // Activities are listed again, but nothing is downloaded: both have keys or a watch copy. Empty days were checked
        // and are skipped; yesterday and the day before may still fill, so their empty kinds are asked again.
        #expect(second.activities == .init(imported: 0, skipped: 2, failed: 0))
        #expect(second.days == .init(imported: 0, skipped: 3, failed: 0))
        #expect(sink.fitKeys == ["3-connect-111"])
        #expect(sink.dayCommits == 3)
        #expect(count("/activitylist-service/") == 1)
        #expect(count("/download-service/") == 0)
        #expect(count("/dailyStress/") == 1)
        #expect(count("/dailySummaryChart/") == 1)
        #expect(count("/dailySleepData/") == 0)
        #expect(count("/usersummary/") == 0)
        #expect(count("/hrv/") == 0)
    }

    @Test func aDayUnderTheCombinedV2KeyFetchesOnlyItsSleep() async throws {
        GarminStub.install(Fixture.answer)
        let sink = FakeSink()
        sink.states["connect-daily-v2-2026-01-06"] = .imported
        _ = try await runImport(client: makeClient(raw: makeRawDirectory()), sink: sink)

        let day6 = GarminStub.requests.filter { $0.contains("2026-01-06") }
        #expect(day6.count == 1)
        #expect(day6.first?.contains("/dailySleepData/") == true)
        #expect(sink.states["connect-sleep-v3-2026-01-06"] == .imported)
    }

    @Test func rawResponsesAreKeptByteForByteAndReparsedFromDiskWithoutAsking() async throws {
        GarminStub.install(Fixture.answer)
        let raw = makeRawDirectory()
        let client = makeClient(raw: raw)
        let sink = FakeSink()
        _ = try await runImport(client: client, sink: sink)

        let kept = try Data(contentsOf: raw.appending(path: "dailyStress/2026-01-07.json"))
        #expect(kept == Fixture.stress)

        // Garmin now refuses everything. A parser fix re-reads the kept responses instead of asking again.
        GarminStub.install { _ in (500, Data()) }
        let parsed = try await client.dailyData(day: now.addingTimeInterval(-86_400), kinds: Set(ConnectDayKind.allCases),
                                                useArchive: true, calendar: utc)

        #expect(GarminStub.requests.isEmpty)
        #expect(parsed[.stress]?.stress.map(\.value) == [25])
        #expect(parsed[.steps]?.steps.count == 1)
        #expect(parsed[.sleep]?.sleep.count == 1)
        #expect(parsed[.restingHeartRate]?.restingHeartRate.map(\.value) == [50])
        #expect(parsed[.hrv]?.hrv.map(\.value) == [40])
    }
}
