import Testing
import Foundation
import GarminModels
@testable import GarminProtocol

// Payloads are the bytes after the handle byte, as garmin-ble's metric parsers read them. Expected values come from
// garmin-ble's wire-format notes, and the accelerometer block is packed by hand.

@Test func heartRateSkipsZeroBpmAndUnknownResting() {
    #expect(RealtimeReadings.parse(.heartRate, Data([0x00, 72, 58])) == .heartRate(bpm: 72, resting: 58))
    #expect(RealtimeReadings.parse(.heartRate, Data([0x00, 72, 0])) == .heartRate(bpm: 72, resting: nil))
    #expect(RealtimeReadings.parse(.heartRate, Data([0x00, 0, 58])) == nil)
    #expect(RealtimeReadings.parse(.heartRate, Data([0x00, 72])) == nil)
}

@Test func stepsAndCaloriesAreLittleEndianPairs() {
    // 8234 steps (0x202A) of a 10000 goal (0x2710).
    #expect(RealtimeReadings.parse(.steps, Data([0x2A, 0x20, 0, 0, 0x10, 0x27, 0, 0])) == .steps(count: 8234, goal: 10000))
    // 1500 total kcal (0x05DC) and 320 active (0x0140).
    #expect(RealtimeReadings.parse(.calories, Data([0xDC, 0x05, 0, 0, 0x40, 0x01, 0, 0])) == .calories(total: 1500, active: 320))
}

@Test func hrvIsOneRRIntervalInMilliseconds() {
    #expect(RealtimeReadings.parse(.hrv, Data([0xB4, 0x03])) == .hrv(rrMilliseconds: 948))
}

@Test func signedLevelsDropTheirUnknownValues() {
    // Stress -30 means the watch cannot score right now.
    #expect(RealtimeReadings.parse(.stress, Data([0xE2])) == nil)
    #expect(RealtimeReadings.parse(.stress, Data([26])) == .stress(26))
    // Body battery 0x7F is unknown.
    #expect(RealtimeReadings.parse(.bodyBattery, Data([0x7F])) == nil)
    #expect(RealtimeReadings.parse(.bodyBattery, Data([75])) == .bodyBattery(75))
    // Respiration -2 means no reading yet.
    #expect(RealtimeReadings.parse(.respiration, Data([0xFE])) == nil)
    #expect(RealtimeReadings.parse(.respiration, Data([15])) == .respiration(15))
}

@Test func spo2TreatsTheSensorNotReadySentinelAsNoReading() {
    #expect(RealtimeReadings.parse(.spo2, Data([255])) == nil)
    #expect(RealtimeReadings.parse(.spo2, Data([97])) == .spo2(97))
}

@Test func accelerometerUnpacksThreeSignedSamplesPerPacket() {
    // Timestamp 0x1234, then nine 12-bit values 1 2 3 4 5 6 7 8 -1 packed two per three bytes. The last value is
    // negative: 0xFFF is -1 in 12-bit two's complement, so reading it unsigned would give 4095 counts.
    let packet = Data([
        0x34, 0x12,
        0x01, 0x20, 0x00,
        0x03, 0x40, 0x00,
        0x05, 0x60, 0x00,
        0x07, 0x80, 0x00,
        0xFF, 0x0F,
    ])
    #expect(RealtimeReadings.parse(.accelerometer, packet) == .accelerometer([
        AccelerationSample(x: 1 / 256, y: 2 / 256, z: 3 / 256),
        AccelerationSample(x: 4 / 256, y: 5 / 256, z: 6 / 256),
        AccelerationSample(x: 7 / 256, y: 8 / 256, z: -1 / 256),
    ]))
}

@Test func realtimeServiceCodesMatchGarminBLE() {
    #expect(LiveMetric.heartRate.serviceCode == 6)
    #expect(LiveMetric.steps.serviceCode == 7)
    #expect(LiveMetric.calories.serviceCode == 8)
    #expect(LiveMetric.hrv.serviceCode == 12)
    #expect(LiveMetric.stress.serviceCode == 13)
    #expect(LiveMetric.accelerometer.serviceCode == 16)
    #expect(LiveMetric.spo2.serviceCode == 19)
    #expect(LiveMetric.bodyBattery.serviceCode == 20)
    #expect(LiveMetric.respiration.serviceCode == 21)
    #expect(Array(RealtimeReadings.startPayload) == [0x01])
    #expect(Array(RealtimeReadings.stopPayload) == [0x00])
}
