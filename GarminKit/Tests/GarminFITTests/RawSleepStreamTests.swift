import Foundation
import Testing
import GarminFIT
import GarminModels

/// Garmin/FIT epoch, 1989-12-31T00:00:00Z, as seconds since 1970.
private let fitEpoch: TimeInterval = 631_065_600

private func garminDate(_ seconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds) + fitEpoch)
}

/// IEEE 754 half-precision bits of `value`, for the values used below only.
private func half(_ value: Double) -> [UInt8] {
    let bits: UInt16 = switch value {
    case 0: 0x0000
    case 2: 0x4000 // 1.0 * 2^1
    case 60: 0x5380 // 1.875 * 2^5: sign 0, exponent 20, mantissa 896
    case 10: 0x4900 // 1.25 * 2^3: exponent 18, mantissa 256
    default: fatalError("no test value for \(value)")
    }
    return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
}

/// A raw sleep row: ten little-endian half-precision features. Movement is feature 8 and heart rate feature 9.
private func rawRow(movement: Double, heartRate: Double) -> FitValue {
    let features = [0, 0, 0, 0, 0, 0, 0, 0, movement, heartRate].flatMap { half($0) }
    return .bytes(features)
}

@Test func rawSleepRowsArePlacedOneSampleLengthApartAfterTheInfo() {
    let t: Int64 = 1_000_000_000
    let file = FitFile(protocolVersion: 0x10, profileVersion: 21117, messages: [
        // A raw row before the sleep data info is counted but has no place in the stream.
        FitMessage(globalNumber: 274, fields: [0: rawRow(movement: 2, heartRate: 60)]),
        FitMessage(globalNumber: 273, fields: [253: .int(t), 1: .int(30)]), // sample length 30 s
        FitMessage(globalNumber: 274, fields: [0: rawRow(movement: 2, heartRate: 60)]), // slot 0: t
        FitMessage(globalNumber: 274, fields: [0: rawRow(movement: 0, heartRate: 10)]), // slot 1: t + 30, no plausible heart rate
        FitMessage(globalNumber: 275, fields: [0: .int(2), 253: .int(t + 60)]), // light sleep takes slot 2, no minute
        FitMessage(globalNumber: 274, fields: [0: .bytes([1, 2, 3])]), // slot 3: t + 90, a row of the wrong size
        FitMessage(globalNumber: 275, fields: [0: .int(1)]), // awake without a timestamp: slot 4, t + 120
        FitMessage(globalNumber: 275, fields: [0: .int(3), 253: .int(t + 150)]), // deep sleep: slot 5, no minute
    ])

    let batch = FitExtractor.extract(file, unitNumber: nil)

    #expect(batch.rawSleepMinutes.map(\.kind) == [.raw, .raw, .raw, .awake])
    #expect(batch.rawSleepMinutes.map(\.date) == [garminDate(t), garminDate(t + 30), garminDate(t + 90), garminDate(t + 120)])
    #expect(batch.rawSleepMinutes[0].heartRate == 60)
    #expect(batch.rawSleepMinutes[0].movement == 2)
    #expect(batch.rawSleepMinutes[1].heartRate == nil)
    #expect(batch.rawSleepMinutes[1].movement == 0)
    #expect(batch.rawSleepMinutes[2].heartRate == nil)
    #expect(batch.rawSleepMinutes[2].movement == 0) // a missing movement counts as still, as in Gadgetbridge
}

@Test func noRawRowsMeansNoRawSleepMinutes() {
    let t: Int64 = 1_000_000_000
    let file = FitFile(protocolVersion: 0x10, profileVersion: 21117, messages: [
        FitMessage(globalNumber: 273, fields: [253: .int(t), 1: .int(60)]),
        FitMessage(globalNumber: 275, fields: [0: .int(1), 253: .int(t + 60)]),
    ])
    #expect(FitExtractor.extract(file, unitNumber: nil).rawSleepMinutes.isEmpty)
}
