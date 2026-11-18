import Foundation
import GarminModels

// Realtime health streams. The watch sends each reading on the service code of its metric, unframed: the first byte
// is the handle, the rest is the reading. Service codes and layouts follow garmin-ble's metrics and Gadgetbridge's
// CommunicatorV2 realtime callbacks.

public extension LiveMetric {
    /// The service code the watch registers for this metric.
    var serviceCode: UInt16 {
        switch self {
        case .heartRate: 6
        case .steps: 7
        case .calories: 8
        case .hrv: 12
        case .stress: 13
        case .accelerometer: 16
        case .spo2: 19
        case .bodyBattery: 20
        case .respiration: 21
        }
    }
}

public enum RealtimeReadings {
    /// Written to a realtime service to start its stream, and to stop it.
    public static let startPayload = Data([0x01])
    public static let stopPayload = Data([0x00])

    /// Parses one reading. `data` is the payload after the handle byte. Values the watch marks as not available give nil.
    public static func parse(_ metric: LiveMetric, _ data: Data) -> LiveReading? {
        let bytes = [UInt8](data)
        switch metric {
        case .heartRate:
            // [type, bpm, resting bpm]. Gadgetbridge drops samples with bpm 0; a resting value of 0 is unknown.
            guard bytes.count >= 3, bytes[1] > 0 else { return nil }
            return .heartRate(bpm: Int(bytes[1]), resting: bytes[2] > 0 ? Int(bytes[2]) : nil)
        case .steps:
            guard bytes.count >= 8 else { return nil }
            return .steps(count: uint32(bytes, 0), goal: uint32(bytes, 4))
        case .calories:
            guard bytes.count >= 8 else { return nil }
            return .calories(total: uint32(bytes, 0), active: uint32(bytes, 4))
        case .hrv:
            guard bytes.count >= 2 else { return nil }
            return .hrv(rrMilliseconds: Int(bytes[0]) | (Int(bytes[1]) << 8))
        case .stress:
            guard let level = signed(bytes, 0), level >= 0 else { return nil }
            return .stress(level)
        case .spo2:
            // 255 is the sensor-not-ready sentinel.
            guard let percent = bytes.first.map(Int.init), percent > 0, percent != 255 else { return nil }
            return .spo2(percent)
        case .bodyBattery:
            // 127 (0x7F) is Gadgetbridge's unknown value.
            guard let level = signed(bytes, 0), (0 ... 100).contains(level) else { return nil }
            return .bodyBattery(level)
        case .respiration:
            guard let breaths = signed(bytes, 0), breaths > 0 else { return nil }
            return .respiration(breaths)
        case .accelerometer:
            // [timestamp u16][14 bytes: nine signed 12-bit values, as three (x, y, z) samples]
            guard bytes.count >= 16 else { return nil }
            let values = unpack12Bit(Array(bytes[2..<16]))
            let samples = stride(from: 0, to: 9, by: 3).map { index in
                AccelerationSample(x: Double(values[index]) / 256, y: Double(values[index + 1]) / 256,
                                   z: Double(values[index + 2]) / 256)
            }
            return .accelerometer(samples)
        }
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (0 ..< 4).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
    }

    private static func signed(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        return Int(Int8(bitPattern: bytes[offset]))
    }

    /// Expands 14 bytes into nine signed 12-bit values, two per three bytes, then one value in the last two bytes.
    private static func unpack12Bit(_ block: [UInt8]) -> [Int] {
        var values: [Int] = []
        for group in 0 ..< 4 {
            let b0 = Int(block[3 * group]), b1 = Int(block[3 * group + 1]), b2 = Int(block[3 * group + 2])
            values.append(b0 | ((b1 & 0x0F) << 8))
            values.append((b1 >> 4) | (b2 << 4))
        }
        values.append(Int(block[12]) | ((Int(block[13]) & 0x0F) << 8))
        return values.map { $0 >= 2048 ? $0 - 4096 : $0 }
    }
}
