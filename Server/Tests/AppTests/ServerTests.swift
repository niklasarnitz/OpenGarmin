import Foundation
import FluentSQL
import GarminFIT
import GarminModels
import Vapor
import XCTest
import XCTVapor
@testable import App

/// End-to-end tests against a real Postgres. Set TEST_DATABASE_URL to a disposable database; each test drops and
/// recreates the public schema, so never point it at data you keep.
final class ServerTests: XCTestCase {
    func testAccountsSessionsAndCSRF() async throws {
        try await withHarness { h in
            let token = try await register(h, "owner@example.com")

            let second = try await send(h, .POST, "/api/v1/auth/register", headers: headers(),
                                        body: try json(["email": "other@example.com", "password": "correct horse"]))
            XCTAssertEqual(second.status, .forbidden, "signup is closed after the first account")

            // One failure is counted now; nine more reach the limit of ten, so the next attempt is refused.
            let wrong = try await send(h, .POST, "/api/v1/auth/login", headers: headers(),
                                       body: try json(["email": "owner@example.com", "password": "wrong password"]))
            XCTAssertEqual(wrong.status, .unauthorized)

            let me = try await send(h, .GET, "/api/v1/me", headers: headers(bearer: token))
            XCTAssertEqual(me.status, .ok)
            XCTAssertEqual(try me.decode(UserDTO.self).email, "owner@example.com")
            let r1 = try await send(h, .GET, "/api/v1/me", headers: headers()).status
            XCTAssertEqual(r1, .unauthorized)

            // The same token as a session cookie.
            let r2 = try await send(h, .GET, "/api/v1/me", headers: headers(cookie: token)).status
            XCTAssertEqual(r2, .ok)

            // Cookie-authenticated writes must carry X-Requested-With; bearer writes need nothing extra.
            let batch = try json(["key": "csrf-1", "source": "watch", "batch": [:] as [String: Any]])
            let r3 = try await send(h, .POST, "/api/v1/batches", headers: headers(cookie: token), body: batch).status
            XCTAssertEqual(r3, .forbidden)
            let r4 = try await send(h, .POST, "/api/v1/batches", headers: headers(cookie: token, csrf: true), body: batch).status
            XCTAssertEqual(r4, .ok)
            let r5 = try await send(h, .POST, "/api/v1/batches", headers: headers(bearer: token), body: batch).status
            XCTAssertEqual(r5, .ok)

            let patched = try await send(h, .PATCH, "/api/v1/me", headers: headers(bearer: token),
                                         body: try json(["timeZone": "Not/AZone"]))
            XCTAssertEqual(patched.status, .badRequest)

            // Ten failed sign-ins, then even the right password is refused for a while.
            for _ in 0..<9 {
                _ = try await send(h, .POST, "/api/v1/auth/login", headers: headers(),
                                   body: try json(["email": "owner@example.com", "password": "wrong password"]))
            }
            let blocked = try await send(h, .POST, "/api/v1/auth/login", headers: headers(),
                                         body: try json(["email": "owner@example.com", "password": "correct horse"]))
            XCTAssertEqual(blocked.status, .tooManyRequests)

            let r6 = try await send(h, .POST, "/api/v1/auth/logout", headers: headers(bearer: token)).status
            XCTAssertEqual(r6, .noContent)
            let r7 = try await send(h, .GET, "/api/v1/me", headers: headers(bearer: token)).status
            XCTAssertEqual(r7, .unauthorized)
        }
    }

    func testFitUploadDecodesOnceAndDownloadsTheOriginalBytes() async throws {
        try await withHarness { h in
            let token = try await register(h, "fit@example.com")
            let bytes = activityFIT()

            let first = try await uploadFIT(h, token: token, bytes: bytes, key: "watch-0-1137052800", source: "watch")
            XCTAssertEqual(first.status, .ok)
            let stored = try first.decode(UploadResult.self)
            XCTAssertFalse(stored.duplicate)
            XCTAssertEqual(stored.sha256, ContentHash.sha256Hex(bytes))

            let again = try await uploadFIT(h, token: token, bytes: bytes, key: "watch-0-1137052800", source: "watch")
            let repeated = try again.decode(UploadResult.self)
            XCTAssertTrue(repeated.duplicate)
            XCTAssertEqual(repeated.id, stored.id)

            // The same bytes under another key share the stored file and add no activity.
            let other = try await uploadFIT(h, token: token, bytes: bytes, key: "connect-activity-7", source: "connect")
            XCTAssertTrue(try other.decode(UploadResult.self).duplicate)
            let r8 = try await scalar(h, "SELECT count(*) AS count FROM fit_files")
            XCTAssertEqual(r8, 2)
            let r9 = try await scalar(h, "SELECT count(*) AS count FROM activities")
            XCTAssertEqual(r9, 1)
            let r10 = try await scalar(h, "SELECT count(*) AS count FROM activity_records")
            XCTAssertEqual(r10, 2)
            let r11 = try await partitions(h, "activity_records")
            XCTAssertEqual(r11, ["activity_records_2026_01"])

            let page = try await send(h, .GET, "/api/v1/activities", headers: headers(bearer: token))
            let activity = try XCTUnwrap(try page.decode(ActivityPage.self).items.first)
            XCTAssertEqual(activity.sport, 1)
            XCTAssertEqual(try XCTUnwrap(activity.distance), 5_000, accuracy: 0.001)
            XCTAssertEqual(activity.start, Date(timeIntervalSince1970: 1_768_118_400))

            let detail = try await send(h, .GET, "/api/v1/activities/\(activity.id)", headers: headers(bearer: token)).decode(ActivityDetail.self)
            XCTAssertEqual(detail.records.count, 2)
            XCTAssertEqual(detail.records[0].heartRate, 140)
            XCTAssertEqual(try XCTUnwrap(detail.records[0].latitude), 52.52, accuracy: 0.000_001)

            let download = try await send(h, .GET, "/api/v1/activities/\(activity.id)/fit", headers: headers(bearer: token))
            XCTAssertEqual(Data(download.body.readableBytesView), bytes)

            let sync = try await send(h, .GET, "/api/v1/sync/state", headers: headers(bearer: token)).decode(SyncState.self)
            XCTAssertEqual(Set(sync.keys), ["watch-0-1137052800", "connect-activity-7"])
        }
    }

    func testHealthKitSamplesUpsertAndPartitionByMonth() async throws {
        try await withHarness { h in
            let token = try await register(h, "health@example.com")
            let items: [[String: Any]] = [
                sample(type: "HKQuantityTypeIdentifierHeartRate", start: "2026-01-15T10:00:00Z", end: "2026-01-15T10:00:00Z", value: 60),
                sample(type: "HKQuantityTypeIdentifierHeartRate", start: "2026-03-02T10:00:00Z", end: "2026-03-02T10:00:00Z", value: 62),
                [
                    "uuid": UUID().uuidString, "type": "HKCategoryTypeIdentifierSleepAnalysis",
                    "start": "2026-01-14T23:00:00Z", "end": "2026-01-15T06:00:00Z", "categoryValue": 1,
                    "sourceBundle": "com.apple.health", "sourceName": "Apple Watch",
                ],
            ]
            let first = try await send(h, .POST, "/api/v1/healthkit/samples", headers: headers(bearer: token),
                                       body: try json(["key": "hk-1", "items": items]))
            XCTAssertEqual(first.status, .ok)
            XCTAssertFalse(try first.decode(UploadResult.self).duplicate)

            // Same rows under a new key: upserted by uuid, so nothing is added.
            let second = try await send(h, .POST, "/api/v1/healthkit/samples", headers: headers(bearer: token),
                                        body: try json(["key": "hk-2", "items": items]))
            XCTAssertEqual(second.status, .ok)
            let r12 = try await scalar(h, "SELECT count(*) AS count FROM healthkit_samples")
            XCTAssertEqual(r12, 3)
            let r13 = try await partitions(h, "healthkit_samples")
            XCTAssertEqual(r13, ["healthkit_samples_2026_01", "healthkit_samples_2026_02", "healthkit_samples_2026_03"])

            let types = try await send(h, .GET, "/api/v1/healthkit/types", headers: headers(bearer: token)).decode([HealthTypeSummary].self)
            let heartRate = try XCTUnwrap(types.first { $0.type == "HKQuantityTypeIdentifierHeartRate" })
            XCTAssertEqual(heartRate.count, 2)
            XCTAssertEqual(heartRate.last, TimeCoding.parse("2026-03-02T10:00:00Z"))

            let sync = try await send(h, .GET, "/api/v1/sync/state", headers: headers(bearer: token)).decode(SyncState.self)
            XCTAssertEqual(Set(sync.keys), ["hk-1", "hk-2"])
        }
    }

    func testWorkoutRouteIsReplacedAndPartitioned() async throws {
        try await withHarness { h in
            let token = try await register(h, "workout@example.com")
            let uuid = UUID().uuidString
            func workout(_ points: [(String, Double, Double)]) -> [String: Any] {
                [
                    "uuid": uuid, "activityType": 37, "start": "2026-01-15T10:00:00Z", "end": "2026-01-15T10:30:00Z",
                    "duration": 1800, "totalDistanceMeters": 3000, "sourceBundle": "com.apple.health", "sourceName": "Apple Watch",
                    "route": points.map { ["t": $0.0, "lat": $0.1, "lon": $0.2] },
                ]
            }
            let threePoints = [
                ("2026-01-15T10:00:00Z", 52.50, 13.40), ("2026-01-15T10:00:10Z", 52.51, 13.41), ("2026-01-15T10:00:20Z", 52.52, 13.42),
            ]
            let up1 = try await send(h, .POST, "/api/v1/healthkit/workouts", headers: headers(bearer: token),
                                     body: try json(["key": "wk-1", "items": [workout(threePoints)]]))
            XCTAssertEqual(up1.status, .ok)
            let r14 = try await scalar(h, "SELECT count(*) AS count FROM healthkit_route_points")
            XCTAssertEqual(r14, 3)
            let r15 = try await partitions(h, "healthkit_route_points")
            XCTAssertEqual(r15, ["healthkit_route_points_2026_01"])

            // A later upload of the same workout with a shorter route replaces the route, not appends to it.
            let up2 = try await send(h, .POST, "/api/v1/healthkit/workouts", headers: headers(bearer: token),
                                     body: try json(["key": "wk-2", "items": [workout(Array(threePoints.prefix(2)))]]))
            XCTAssertEqual(up2.status, .ok)
            let r16 = try await scalar(h, "SELECT count(*) AS count FROM healthkit_workouts")
            XCTAssertEqual(r16, 1)
            let r17 = try await scalar(h, "SELECT count(*) AS count FROM healthkit_route_points")
            XCTAssertEqual(r17, 2)
        }
    }

    func testRollupUsesLocalDaysSourcesAndRebuildsOnTimeZoneChange() async throws {
        try await withHarness { h in
            let token = try await register(h, "rollup@example.com")
            // Europe/Berlin is UTC+1 in January. The first two steps fall on different local days but the same UTC day.
            _ = try await send(h, .POST, "/api/v1/batches", headers: headers(bearer: token), body: try json([
                "key": "rollup-batch", "source": "watch",
                "batch": [
                    "steps": [
                        ["start": "2026-01-10T22:00:00Z", "end": "2026-01-10T22:30:00Z", "value": 100],
                        ["start": "2026-01-10T23:30:00Z", "end": "2026-01-10T23:45:00Z", "value": 40],
                    ],
                    "stress": [
                        ["date": "2026-01-10T22:30:00Z", "value": 99],
                        ["date": "2026-01-11T06:00:00Z", "value": 20],
                        ["date": "2026-01-11T08:00:00Z", "value": 40],
                    ],
                ],
            ]))
            _ = try await send(h, .POST, "/api/v1/healthkit/samples", headers: headers(bearer: token), body: try json([
                "key": "rollup-hk",
                "items": [
                    sample(type: "HKQuantityTypeIdentifierStepCount", start: "2026-01-11T08:00:00Z", end: "2026-01-11T08:01:00Z",
                           value: 7, bundle: "com.garmin.connect.mobile"),
                    sample(type: "HKQuantityTypeIdentifierStepCount", start: "2026-01-11T08:00:00Z", end: "2026-01-11T08:01:00Z",
                           value: 5, bundle: "com.apple.health"),
                ],
            ]))

            let query = "/api/v1/metrics/daily?from=2026-01-09T23:00:00Z&to=2026-01-12T23:00:00Z"
                + "&metrics=steps,stress,HKQuantityTypeIdentifierStepCount"
            let berlin = try await dailyRows(h, token: token, query: query)
            XCTAssertEqual(berlin, [
                "2026-01-10 steps garmin 100.0 - -",
                "2026-01-10 stress garmin 99.0 99.0 99.0",
                "2026-01-11 HKQuantityTypeIdentifierStepCount healthkit:com.apple.health 5.0 - -",
                "2026-01-11 HKQuantityTypeIdentifierStepCount healthkit:garmin-mirror 7.0 - -",
                "2026-01-11 steps garmin 40.0 - -",
                "2026-01-11 stress garmin 30.0 20.0 40.0",
            ])

            // The dashboard sends plain days, which start at midnight in the user's time zone.
            let days = try await dailyRows(h, token: token, query: "/api/v1/metrics/daily?from=2026-01-10&to=2026-01-13"
                + "&metrics=steps,stress,HKQuantityTypeIdentifierStepCount")
            XCTAssertEqual(days, berlin)

            // Day boundaries move with the user's time zone: in UTC both steps are on the 10th.
            let patched = try await send(h, .PATCH, "/api/v1/me", headers: headers(bearer: token), body: try json(["timeZone": "UTC"]))
            XCTAssertEqual(patched.status, .ok)
            let utc = try await dailyRows(h, token: token, query: query)
            XCTAssertEqual(utc, [
                "2026-01-10 steps garmin 140.0 - -",
                "2026-01-10 stress garmin 99.0 99.0 99.0",
                "2026-01-11 HKQuantityTypeIdentifierStepCount healthkit:com.apple.health 5.0 - -",
                "2026-01-11 HKQuantityTypeIdentifierStepCount healthkit:garmin-mirror 7.0 - -",
                "2026-01-11 stress garmin 30.0 20.0 40.0",
            ])
        }
    }

    func testRawSamplesStayFullResolutionForYearsAndPage() async throws {
        try await withHarness { h in
            let token = try await register(h, "raw@example.com")
            _ = try await send(h, .POST, "/api/v1/batches", headers: headers(bearer: token), body: try json([
                "key": "old-steps", "source": "watch",
                "batch": ["steps": [
                    ["start": "2020-03-01T10:00:00Z", "end": "2020-03-01T10:01:00Z", "value": 1],
                    ["start": "2020-03-01T10:01:00Z", "end": "2020-03-01T10:02:00Z", "value": 2],
                    ["start": "2020-03-01T10:02:00Z", "end": "2020-03-01T10:03:00Z", "value": 3],
                ]],
            ]))

            let range = "from=2020-01-01T00:00:00Z&to=2021-01-01T00:00:00Z&resolution=raw&limit=2"
            let first = try await send(h, .GET, "/api/v1/samples/steps?\(range)", headers: headers(bearer: token))
                .decode(SamplePage.self)
            XCTAssertEqual(first.items.map(\.value), [1, 2])
            let cursor = try XCTUnwrap(first.nextCursor)

            let second = try await send(h, .GET, "/api/v1/samples/steps?\(range)&cursor=\(cursor)", headers: headers(bearer: token))
                .decode(SamplePage.self)
            XCTAssertEqual(second.items.map(\.value), [3])
            XCTAssertNil(second.nextCursor)
        }
    }

    func testWebShellFallsBackOnlyForPagesNotApi() async throws {
        try await withHarness { h in
            let page = try await send(h, .GET, "/dashboard", headers: headers())
            XCTAssertEqual(page.status, .ok)
            XCTAssertTrue(String(decoding: page.body.readableBytesView, as: UTF8.self).contains("OpenGarmin"))
            let r18 = try await send(h, .GET, "/api/v1/unknown", headers: headers()).status
            XCTAssertEqual(r18, .notFound)
            let r19 = try await send(h, .GET, "/healthz", headers: headers()).status
            XCTAssertEqual(r19, .ok)
        }
    }

    func testConnectRawArchivesOnceParsesAgainAndChecksSleepMapping() async throws {
        try await withHarness { h in
            let token = try await register(h, "connect@example.com")
            let swapped = try connectSleepNight(
                day: "2026-01-11", startMs: connectNightStartMs, endMs: connectNightEndMs, levels: connectNightSwappedLevels,
                totals: ["deepSleepSeconds": 3600, "lightSleepSeconds": 14400, "remSleepSeconds": 9000, "awakeSleepSeconds": 1800])
            // Night of 11 January 22:00 to 12 January 06:00, whose totals fit neither assignment.
            let inconsistent = try connectSleepNight(
                day: "2026-01-12", startMs: 1_768_168_800_000, endMs: 1_768_197_600_000, levels: [
                    ("2026-01-11T22:00:00.0", "2026-01-11T23:00:00.0", 0),
                    ("2026-01-11T23:00:00.0", "2026-01-12T03:00:00.0", 1),
                    ("2026-01-12T03:00:00.0", "2026-01-12T03:30:00.0", 2),
                    ("2026-01-12T03:30:00.0", "2026-01-12T06:00:00.0", 3),
                ],
                totals: ["deepSleepSeconds": 3600, "lightSleepSeconds": 14400, "remSleepSeconds": 3600, "awakeSleepSeconds": 7200])

            func archive(_ key: String, _ endpoint: String, _ day: String, _ body: [String: Any]) async throws -> Reply {
                try await send(h, .POST, "/api/v1/connect/raw", headers: headers(bearer: token), body: try json([
                    "key": key, "endpoint": endpoint, "day": day, "fetchedAt": "\(day)T07:00:00Z", "body": body,
                ]))
            }
            let first = try await archive("connect-sleep-0111", "dailySleepData", "2026-01-11", swapped)
            XCTAssertEqual(first.status, .ok)
            XCTAssertFalse(try first.decode(UploadResult.self).duplicate)
            let again = try await archive("connect-sleep-0111", "dailySleepData", "2026-01-11", swapped)
            XCTAssertTrue(try again.decode(UploadResult.self).duplicate)
            let second = try await archive("connect-sleep-0112", "dailySleepData", "2026-01-12", inconsistent)
            XCTAssertEqual(second.status, .ok)

            let rawRows = try await scalar(h, "SELECT count(*) AS count FROM connect_raw")
            XCTAssertEqual(rawRows, 2)
            let sessions = try await scalar(h, "SELECT count(*) AS count FROM sleep_sessions")
            XCTAssertEqual(sessions, 2)
            // Code 2 was REM for the swapped night, so the 03:00 level is REM and the 05:30 level awake.
            let remAtThree = try await scalar(h, "SELECT count(*) AS count FROM sleep_stages WHERE stage = 'rem' AND start_ts = '2026-01-11T03:00:00Z'")
            XCTAssertEqual(remAtThree, 1)

            let sync = try await send(h, .GET, "/api/v1/sync/state", headers: headers(bearer: token)).decode(SyncState.self)
            XCTAssertTrue(sync.keys.contains("connect-sleep-0111"))
            XCTAssertTrue(sync.keys.contains("connect-sleep-0112"))

            let diagnostics = try await send(h, .GET, "/api/v1/connect/diagnostics", headers: headers(bearer: token))
                .decode(ConnectDiagnostics.self)
            XCTAssertEqual(diagnostics.nights, 2)
            XCTAssertEqual(diagnostics.mismatches.map(\.day), ["2026-01-12"])
            XCTAssertEqual(diagnostics.mismatches.first?.minutesPerCode["3"], 150)
            // Code 3 is awake on both nights: the swapped night's 30 minutes and the other night's 150 against 120.
            let awakeCode3 = diagnostics.mappingAgreement.first { $0.code == 3 && $0.stage == "awake" }
            XCTAssertEqual(awakeCode3?.nights, 2)
            XCTAssertEqual(awakeCode3?.share, 1)

            // A parser change: archived responses are parsed again, with no duplicate rows.
            try await h.app.db.sql().raw("UPDATE connect_raw SET parser_version = 0").run()
            await ConnectArchive.reprocessOutdated(h.app)
            let current = try await scalar(h, "SELECT count(*) AS count FROM connect_raw WHERE parser_version = \(ConnectParser.version)")
            XCTAssertEqual(current, 2)
            let stages = try await scalar(h, "SELECT count(*) AS count FROM sleep_stages")
            XCTAssertEqual(stages, 8)
            let remAfter = try await scalar(h, "SELECT count(*) AS count FROM sleep_stages WHERE stage = 'rem' AND start_ts = '2026-01-11T03:00:00Z'")
            XCTAssertEqual(remAfter, 1)
        }
    }

    /// A Connect activity summary and the FIT file of the same run are stored once, in either order.
    func testConnectActivitySummaryAndFITFileOfOneRunAreStoredOnce() async throws {
        try await withHarness { h in
            let token = try await register(h, "activities@example.com")
            func listed(_ key: String) async throws -> Reply {
                try await send(h, .POST, "/api/v1/connect/raw", headers: headers(bearer: token), body: try json([
                    "key": key, "endpoint": "activityList", "fetchedAt": "2026-01-12T07:00:00Z",
                    "body": [[
                        "activityId": 987654, "startTimeGMT": "2026-01-11 08:00:30", "duration": 1800,
                        "activityType": ["typeKey": "running"], "distance": 5000,
                    ]],
                ]))
            }
            let summary = try await listed("connect-list-1")
            XCTAssertEqual(summary.status, .ok)
            let summaries = try await scalar(h, "SELECT count(*) AS count FROM activities WHERE external_id = 'connect-987654'")
            XCTAssertEqual(summaries, 1)

            // The FIT file of the same run starts 30 seconds earlier and replaces the summary.
            let fit = try await uploadFIT(h, token: token, bytes: activityFIT(), key: "watch-run-1", source: "watch")
            XCTAssertEqual(fit.status, .ok)
            let afterFIT = try await scalar(h, "SELECT count(*) AS count FROM activities")
            XCTAssertEqual(afterFIT, 1)
            let leftover = try await scalar(h, "SELECT count(*) AS count FROM activities WHERE external_id LIKE 'connect-%'")
            XCTAssertEqual(leftover, 0)

            // The summary listed again is already covered by the FIT activity and adds nothing.
            _ = try await listed("connect-list-2")
            let afterAgain = try await scalar(h, "SELECT count(*) AS count FROM activities")
            XCTAssertEqual(afterAgain, 1)
        }
    }

    func testInsightsEndpointAndWorkingHoursAreValidated() async throws {
        try await withHarness { h in
            let token = try await register(h, "insights@example.com")
            let badDays = try await send(h, .PATCH, "/api/v1/me", headers: headers(bearer: token),
                                         body: try json(["workDays": [0, 1]]))
            XCTAssertEqual(badDays.status, .badRequest, "weekdays are 1 (Monday) to 7 (Sunday)")
            let badHours = try await send(h, .PATCH, "/api/v1/me", headers: headers(bearer: token),
                                          body: try json(["workStart": 17, "workEnd": 9]))
            XCTAssertEqual(badHours.status, .badRequest)

            let patched = try await send(h, .PATCH, "/api/v1/me", headers: headers(bearer: token),
                                         body: try json(["workDays": [1, 2, 3, 4, 5], "workStart": 8, "workEnd": 16]))
            XCTAssertEqual(patched.status, .ok)
            let me = try patched.decode(UserDTO.self)
            XCTAssertEqual(me.workDays, [1, 2, 3, 4, 5])
            XCTAssertEqual(me.workEnd, 16)

            let empty = try await send(h, .GET, "/api/v1/insights?from=2020-01-01&to=2020-02-01&lang=de", headers: headers(bearer: token))
            XCTAssertEqual(empty.status, .ok)
            XCTAssertEqual(try empty.decode([Insight].self).count, 0)
            let reversed = try await send(h, .GET, "/api/v1/insights?from=2020-02-01&to=2020-01-01", headers: headers(bearer: token))
            XCTAssertEqual(reversed.status, .badRequest)
            let anonymous = try await send(h, .GET, "/api/v1/insights", headers: headers())
            XCTAssertEqual(anonymous.status, .unauthorized)
        }
    }

    // MARK: - Helpers

    private struct Harness {
        let app: Application
        let tester: XCTApplicationTester
    }

    private struct Reply {
        let status: HTTPStatus
        let headers: HTTPHeaders
        let body: ByteBuffer

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try TimeCoding.decoder.decode(T.self, from: Data(body.readableBytesView))
        }
    }

    private struct NameRow: Decodable {
        let name: String
    }

    private struct CountBox: Decodable {
        let count: Int
    }

    private func withHarness(allowSignup: Bool = false, _ body: (Harness) async throws -> Void) async throws {
        guard let url = ProcessInfo.processInfo.environment["TEST_DATABASE_URL"] else {
            throw XCTSkip("Set TEST_DATABASE_URL to a disposable Postgres database to run the server tests.")
        }
        let app = try await Application.make(.testing)
        do {
            let dataDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opengarmin-tests-\(UUID().uuidString)").path
            try await configure(app, config: ServerConfig(databaseURL: url, dataDirectory: dataDirectory, allowSignup: allowSignup))
            try await app.db.sql().raw("DROP SCHEMA public CASCADE").run()
            try await app.db.sql().raw("CREATE SCHEMA public").run()
            try await app.autoMigrate()
            try await body(Harness(app: app, tester: try app.testable()))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func send(_ h: Harness, _ method: HTTPMethod, _ path: String, headers: HTTPHeaders = HTTPHeaders(),
                      body: ByteBuffer? = nil) async throws -> Reply {
        var reply: Reply?
        _ = try await h.tester.test(method, path, headers: headers, body: body) { response in
            reply = Reply(status: response.status, headers: response.headers, body: response.body)
        }
        return try XCTUnwrap(reply)
    }

    private func headers(bearer: String? = nil, cookie: String? = nil, csrf: Bool = false) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        if let bearer { headers.add(name: .authorization, value: "Bearer \(bearer)") }
        if let cookie { headers.add(name: .cookie, value: "\(SessionToken.cookieName)=\(cookie)") }
        if csrf { headers.add(name: "X-Requested-With", value: "XMLHttpRequest") }
        return headers
    }

    private func json(_ object: Any) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        buffer.writeBytes(try JSONSerialization.data(withJSONObject: object))
        return buffer
    }

    private func register(_ h: Harness, _ email: String) async throws -> String {
        let reply = try await send(h, .POST, "/api/v1/auth/register", headers: headers(),
                                   body: try json(["email": email, "password": "correct horse"]))
        XCTAssertEqual(reply.status, .ok)
        return try reply.decode(TokenResponse.self).token
    }

    private func sample(type: String, start: String, end: String, value: Double, bundle: String = "com.apple.health") -> [String: Any] {
        [
            "uuid": UUID().uuidString, "type": type, "start": start, "end": end, "value": value, "unit": "count",
            "sourceBundle": bundle, "sourceName": "Test",
        ]
    }

    private func uploadFIT(_ h: Harness, token: String, bytes: Data, key: String, source: String) async throws -> Reply {
        let boundary = "OGTest\(UUID().uuidString)"
        var body = ByteBufferAllocator().buffer(capacity: bytes.count + 512)
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"activity.fit\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n")
        body.writeBytes(bytes)
        body.writeString("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\n\(key)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\n\(source)\r\n--\(boundary)--\r\n")
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(token)")
        headers.add(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        return try await send(h, .POST, "/api/v1/fit-files", headers: headers, body: body)
    }

    private func dailyRows(_ h: Harness, token: String, query: String) async throws -> [String] {
        let rows = try await send(h, .GET, query, headers: headers(bearer: token))
        let days = try JSONDecoder().decode([MetricDay].self, from: Data(rows.body.readableBytesView))
        return days.map { day in
            [day.day, day.metric, day.source, String(day.value),
             day.min.map { String($0) } ?? "-", day.max.map { String($0) } ?? "-"].joined(separator: " ")
        }
    }

    private func scalar(_ h: Harness, _ sql: String) async throws -> Int {
        let row = try await h.app.db.sql().raw(SQLQueryString(sql)).first(decoding: CountBox.self)
        return try XCTUnwrap(row).count
    }

    /// Monthly partitions of a parent table, by name.
    private func partitions(_ h: Harness, _ parent: String) async throws -> [String] {
        try await h.app.db.sql().raw(SQLQueryString("""
            SELECT relname AS name FROM pg_class
            WHERE relname ~ '^\(parent)_[0-9]{4}_[0-9]{2}$' ORDER BY relname
            """)).all(decoding: NameRow.self).map(\.name)
    }

    /// A 2026-01-11 08:00 UTC run with two records, built with GarminKit's encoder.
    private func activityFIT() -> Data {
        let start: Int64 = 1_137_052_800 // 2026-01-11T08:00:00Z in Garmin seconds
        func semicircles(_ degrees: Double) -> Int64 { Int64((degrees / (180.0 / 2_147_483_648.0)).rounded()) }
        func record(_ time: Int64, _ lat: Double, _ lon: Double, _ bpm: Int64) -> [FitEncodeField] {
            [
                FitEncodeField(253, .uint32, .int(time)),
                FitEncodeField(0, .sint32, .int(semicircles(lat))),
                FitEncodeField(1, .sint32, .int(semicircles(lon))),
                FitEncodeField(3, .uint8, .int(bpm)),
            ]
        }
        return FitEncoder.encodeFile([
            FitEncodeMessage(globalNumber: 18, fields: [
                FitEncodeField(2, .uint32, .int(start)),
                FitEncodeField(5, .enumeration, .int(1)),
                FitEncodeField(7, .uint32, .int(1_800_000)),
                FitEncodeField(8, .uint32, .int(1_800_000)),
                FitEncodeField(9, .uint32, .int(500_000)),
                FitEncodeField(16, .uint8, .int(150)),
            ]),
            FitEncodeMessage(globalNumber: 20, fields: record(start + 10, 52.52, 13.405, 140)),
            FitEncodeMessage(globalNumber: 20, fields: record(start + 20, 52.53, 13.406, 142)),
        ])
    }
}
