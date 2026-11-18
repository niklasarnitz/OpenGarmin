import Foundation

/// A realtime metric the watch streams while the app subscribes to it.
public enum LiveMetric: String, Sendable, Hashable, CaseIterable {
    case heartRate, steps, calories, hrv, stress, spo2, bodyBattery, respiration, accelerometer
}

/// One acceleration sample in g, as garmin-ble reports it (256 counts per g).
public struct AccelerationSample: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) {
        self.x = x; self.y = y; self.z = z
    }
}

/// One realtime reading. Each reading comes from the watch's realtime service for its metric.
public enum LiveReading: Sendable, Hashable {
    case heartRate(bpm: Int, resting: Int?)
    case steps(count: Int, goal: Int)
    case calories(total: Int, active: Int)
    case hrv(rrMilliseconds: Int)
    case stress(Int)
    case spo2(Int)
    case bodyBattery(Int)
    case respiration(Int)
    /// Three samples per packet, about 26 Hz.
    case accelerometer([AccelerationSample])

    public var metric: LiveMetric {
        switch self {
        case .heartRate: .heartRate
        case .steps: .steps
        case .calories: .calories
        case .hrv: .hrv
        case .stress: .stress
        case .spo2: .spo2
        case .bodyBattery: .bodyBattery
        case .respiration: .respiration
        case .accelerometer: .accelerometer
        }
    }
}
