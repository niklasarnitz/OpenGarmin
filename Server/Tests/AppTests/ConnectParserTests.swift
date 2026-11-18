import Foundation
import GarminModels
import XCTest
@testable import App

/// Sleep levels as Garmin Connect sends them, with the DTO totals of the same night. Times are GMT strings.
func connectSleepNight(day: String, startMs: Int64, endMs: Int64, levels: [(String, String, Int)],
                       totals: [String: Int]) throws -> [String: Any] {
    var dto: [String: Any] = ["calendarDate": day, "sleepStartTimestampGMT": startMs, "sleepEndTimestampGMT": endMs]
    for (key, value) in totals { dto[key] = value }
    let sleepLevels: [[String: Any]] = levels.map { ["startGMT": $0.0, "endGMT": $0.1, "activityLevel": $0.2] }
    let data = try JSONSerialization.data(withJSONObject: ["dailySleepDTO": dto, "sleepLevels": sleepLevels])
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The night of 10 to 11 January 2026, 22:00 to 06:00 GMT (480 minutes). Codes 0 to 3 hold 60, 240, 30 and 150 minutes.
let connectNightLevels: [(String, String, Int)] = [
    ("2026-01-10T22:00:00.0", "2026-01-10T23:00:00.0", 0),
    ("2026-01-10T23:00:00.0", "2026-01-11T03:00:00.0", 1),
    ("2026-01-11T03:00:00.0", "2026-01-11T03:30:00.0", 2),
    ("2026-01-11T03:30:00.0", "2026-01-11T06:00:00.0", 3),
]

/// The same night with codes 2 and 3 swapped in time: code 2 holds 150 minutes, code 3 holds 30.
let connectNightSwappedLevels: [(String, String, Int)] = [
    ("2026-01-10T22:00:00.0", "2026-01-10T23:00:00.0", 0),
    ("2026-01-10T23:00:00.0", "2026-01-11T03:00:00.0", 1),
    ("2026-01-11T03:00:00.0", "2026-01-11T05:30:00.0", 2),
    ("2026-01-11T05:30:00.0", "2026-01-11T06:00:00.0", 3),
]

let connectNightStartMs: Int64 = 1_768_082_400_000 // 2026-01-10T22:00:00Z
let connectNightEndMs: Int64 = 1_768_111_200_000 // 2026-01-11T06:00:00Z

final class ConnectParserTests: XCTestCase {
    /// DTO totals that fit code 2 as awake (30 minutes) and code 3 as REM (150 minutes): the default assignment.
    func testDefaultAssignmentIsKeptWhenTotalsFitIt() throws {
        let json = try connectSleepNight(day: "2026-01-11", startMs: connectNightStartMs, endMs: connectNightEndMs,
                                         levels: connectNightLevels,
                                         totals: ["deepSleepSeconds": 3600, "lightSleepSeconds": 14400,
                                                  "remSleepSeconds": 9000, "awakeSleepSeconds": 1800])
        let (session, check) = ConnectParser.sleep(json, day: "2026-01-11")

        XCTAssertEqual(check?.mapping, [0: .deep, 1: .light, 2: .awake, 3: .rem])
        XCTAssertEqual(check?.errorMinutes, 0)
        XCTAssertEqual(check?.agrees, true)
        XCTAssertEqual(session?.intervals.count, 4)
    }

    /// Totals that fit code 2 as REM (150 minutes) and code 3 as awake (30 minutes) must reassign both codes.
    func testSwappedAssignmentIsChosenWhenTotalsImplyIt() throws {
        let json = try connectSleepNight(day: "2026-01-11", startMs: connectNightStartMs, endMs: connectNightEndMs,
                                         levels: connectNightSwappedLevels,
                                         totals: ["deepSleepSeconds": 3600, "lightSleepSeconds": 14400,
                                                  "remSleepSeconds": 9000, "awakeSleepSeconds": 1800])
        let (session, check) = ConnectParser.sleep(json, day: "2026-01-11")

        XCTAssertEqual(check?.mapping, [0: .deep, 1: .light, 2: .rem, 3: .awake])
        XCTAssertEqual(check?.errorMinutes, 0)
        XCTAssertEqual(check?.agrees, true)
        // The 03:00 to 05:30 level is REM now, not awake.
        let rem = session?.intervals.first { $0.start == Date(timeIntervalSince1970: 1_768_100_400) }
        XCTAssertEqual(rem?.stage, .rem)
        XCTAssertEqual(rem?.end, Date(timeIntervalSince1970: 1_768_109_400))
    }

    /// Totals that fit neither assignment: the best one is kept, and the night is reported as disagreeing.
    func testInconsistentTotalsAreReportedAsDisagreement() throws {
        let json = try connectSleepNight(day: "2026-01-11", startMs: connectNightStartMs, endMs: connectNightEndMs,
                                         levels: connectNightLevels,
                                         totals: ["deepSleepSeconds": 3600, "lightSleepSeconds": 14400,
                                                  "remSleepSeconds": 3600, "awakeSleepSeconds": 7200])
        let (_, check) = ConnectParser.sleep(json, day: "2026-01-11")

        // Code 1 (240 minutes) must be light and code 3 (150) awake, since 150 against 120 is the closest fit. Codes 0
        // (60) and 2 (30) take deep and REM (60 each) in either order: 30 for the awake gap plus 30 for the other.
        XCTAssertEqual(check?.mapping[1], .light)
        XCTAssertEqual(check?.mapping[3], .awake)
        XCTAssertEqual(check?.errorMinutes, 60)
        XCTAssertEqual(check?.agrees, false)
    }

    /// Without the DTO totals there is nothing to check against: the default assignment and no check.
    func testNightWithoutTotalsUsesDefaultAndIsNotChecked() throws {
        let json = try connectSleepNight(day: "2026-01-11", startMs: connectNightStartMs, endMs: connectNightEndMs,
                                         levels: connectNightSwappedLevels, totals: [:])
        let (session, check) = ConnectParser.sleep(json, day: "2026-01-11")

        XCTAssertNil(check)
        XCTAssertEqual(session?.intervals.first { $0.start == Date(timeIntervalSince1970: 1_768_100_400) }?.stage, .awake)
    }
}
