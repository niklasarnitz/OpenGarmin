import Foundation
import HealthKit
import Testing
@testable import GarminBackend

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private let march = utc.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
private let base = URL(string: "https://opengarmin.example")!

@Suite struct HealthKitKeyTests {
    @Test func keyNamesTheTypeTheMonthAndTheChunk() {
        let key = HealthKitChunks.key(type: "HKQuantityTypeIdentifierStepCount", month: march, chunk: 2, calendar: utc)
        #expect(key == "healthkit-HKQuantityTypeIdentifierStepCount-2026-03-2")
    }

    @Test func chunksCutInOrderAtTheLimit() {
        #expect(HealthKitChunks.chunks(Array(0..<12_001), size: 5000).map(\.count) == [5000, 5000, 2001])
        #expect(HealthKitChunks.chunks(Array(0..<5000), size: 5000).map(\.count) == [5000])
        #expect(HealthKitChunks.chunks(Array(0..<401), size: 200).last == [400])
        #expect(HealthKitChunks.chunks([Int](), size: 200).isEmpty)
    }
}

@Suite struct HealthKitBodyTests {
    private func items(_ body: [BackendSample]) throws -> [[String: Any]] {
        let request = try BackendRequests.healthKit(base, token: nil, path: "healthkit/samples", key: "k", items: body)
        let object = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        return try #require(object?["items"] as? [[String: Any]])
    }

    @Test func aQuantitySampleSendsItsValueAndUnitAndNoCategoryValue() throws {
        let sample = BackendSample(uuid: "U1", type: "HKQuantityTypeIdentifierStepCount", start: march,
                                   end: march.addingTimeInterval(60), value: 4500, unit: "count", categoryValue: nil,
                                   sourceBundle: "com.apple.health", sourceName: "Health", device: nil, metadata: nil)
        let item = try #require(items([sample]).first)
        #expect(Set(item.keys) == ["uuid", "type", "start", "end", "value", "unit", "sourceBundle", "sourceName"])
        #expect(item["start"] as? String == "2026-03-15T12:00:00Z")
        #expect(item["value"] as? Double == 4500)
        #expect(item["unit"] as? String == "count")
    }

    @Test func aCategorySampleSendsItsValueWithoutQuantityFields() throws {
        let sample = BackendSample(uuid: "U2", type: "HKCategoryTypeIdentifierSleepAnalysis", start: march,
                                   end: march, value: nil, unit: nil, categoryValue: 1,
                                   sourceBundle: "b", sourceName: "n", device: nil, metadata: nil)
        let item = try #require(items([sample]).first)
        #expect(item["categoryValue"] as? Int == 1)
        #expect(item["value"] == nil)
        #expect(item["unit"] == nil)
    }

    @Test func aWorkoutRoutePointSendsTheTimeAndTheKnownFieldsOnly() throws {
        let workout = BackendWorkout(uuid: "W1", activityType: 37, start: march, end: march, duration: 1800,
                                     totalEnergyKcal: nil, totalDistanceMeters: 5000, sourceBundle: "b", sourceName: "n",
                                     device: nil, metadata: nil, events: nil,
                                     route: [BackendRoutePoint(t: march, lat: 52.5, lon: 13.4, alt: nil, hAcc: 5,
                                                               vAcc: nil, speed: nil, course: nil)])
        let request = try BackendRequests.healthKit(base, token: nil, path: "healthkit/workouts", key: "k", items: [workout])
        #expect(request.url?.path == "/api/v1/healthkit/workouts")
        let object = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let route = try #require(((object?["items"] as? [[String: Any]])?.first?["route"]) as? [[String: Any]])
        #expect(Set(route[0].keys) == ["t", "lat", "lon", "hAcc"])
        #expect(route[0]["t"] as? String == "2026-03-15T12:00:00Z")
        #expect(route[0]["lat"] as? Double == 52.5)
    }

    @Test func aQuantitySampleMapsItsValueInTheGivenUnit() throws {
        let type = try #require(HKQuantityType.quantityType(forIdentifier: .stepCount))
        let hk = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 4500),
                                  start: march, end: march.addingTimeInterval(60))
        let sample = BackendSample(hk, unit: .count())
        #expect(sample.type == "HKQuantityTypeIdentifierStepCount")
        #expect(sample.value == 4500)
        #expect(sample.unit == "count")
        #expect(sample.categoryValue == nil)
    }
}
