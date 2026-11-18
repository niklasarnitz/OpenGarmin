import CoreLocation
import Foundation
import HealthKit

// The Apple Health data the backend takes (docs/backend-api.md, HealthKit). Dates go out as ISO 8601.

public struct BackendDevice: Codable, Sendable, Equatable {
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var hardwareVersion: String?
    public var softwareVersion: String?
}

extension BackendDevice {
    init?(_ device: HKDevice?) {
        guard let device else { return nil }
        self.init(name: device.name, manufacturer: device.manufacturer, model: device.model,
                  hardwareVersion: device.hardwareVersion, softwareVersion: device.softwareVersion)
    }
}

/// A quantity sample (`value` and `unit`) or a category sample (`categoryValue`).
public struct BackendSample: Codable, Sendable, Equatable {
    public var uuid: String
    /// The HealthKit identifier, such as `HKQuantityTypeIdentifierStepCount`.
    public var type: String
    public var start: Date
    public var end: Date
    public var value: Double?
    public var unit: String?
    public var categoryValue: Int?
    public var sourceBundle: String
    public var sourceName: String
    public var device: BackendDevice?
    public var metadata: [String: String]?
}

extension BackendSample {
    /// A Health sample. A quantity sample is converted to `unit`, the type's preferred unit.
    public init(_ sample: HKSample, unit: HKUnit?) {
        let quantity = sample as? HKQuantitySample
        self.init(uuid: sample.uuid.uuidString, type: sample.sampleType.identifier, start: sample.startDate,
                  end: sample.endDate,
                  value: quantity.flatMap { sample in unit.map { sample.quantity.doubleValue(for: $0) } },
                  unit: quantity == nil ? nil : unit?.unitString,
                  categoryValue: (sample as? HKCategorySample)?.value,
                  sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                  sourceName: sample.sourceRevision.source.name,
                  device: BackendDevice(sample.device),
                  metadata: sample.metadata?.mapValues { String(describing: $0) })
    }
}

public struct BackendWorkoutEvent: Codable, Sendable, Equatable {
    public var type: Int
    public var start: Date
    public var end: Date
}

public struct BackendRoutePoint: Codable, Sendable, Equatable {
    public var t: Date
    public var lat: Double
    public var lon: Double
    public var alt: Double?
    public var hAcc: Double?
    public var vAcc: Double?
    public var speed: Double?
    public var course: Double?
}

extension BackendRoutePoint {
    public init(_ location: CLLocation) {
        // Core Location reports an unknown speed, course or accuracy as a negative number.
        func known(_ value: Double) -> Double? { value < 0 ? nil : value }
        self.init(t: location.timestamp, lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                  alt: location.altitude, hAcc: known(location.horizontalAccuracy),
                  vAcc: known(location.verticalAccuracy), speed: known(location.speed),
                  course: known(location.course))
    }
}

public struct BackendWorkout: Codable, Sendable, Equatable {
    public var uuid: String
    public var activityType: UInt
    public var start: Date
    public var end: Date
    public var duration: Double
    public var totalEnergyKcal: Double?
    public var totalDistanceMeters: Double?
    public var sourceBundle: String
    public var sourceName: String
    public var device: BackendDevice?
    public var metadata: [String: String]?
    public var events: [BackendWorkoutEvent]?
    public var route: [BackendRoutePoint]?
}

extension BackendWorkout {
    /// A workout with its route, when the caller fetched one.
    public init(_ workout: HKWorkout, route: [BackendRoutePoint]?) {
        // The per-workout totals are deprecated in favour of statistics queries per type. They are the only totals
        // that cover every activity type without one query per type.
        self.init(uuid: workout.uuid.uuidString, activityType: workout.workoutActivityType.rawValue,
                  start: workout.startDate, end: workout.endDate, duration: workout.duration,
                  totalEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                  totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                  sourceBundle: workout.sourceRevision.source.bundleIdentifier,
                  sourceName: workout.sourceRevision.source.name,
                  device: BackendDevice(workout.device),
                  metadata: workout.metadata?.mapValues { String(describing: $0) },
                  events: workout.workoutEvents?.map {
                      BackendWorkoutEvent(type: $0.type.rawValue, start: $0.dateInterval.start, end: $0.dateInterval.end)
                  },
                  route: route)
    }
}

public struct BackendElectrocardiogram: Codable, Sendable, Equatable {
    public var uuid: String
    public var start: Date
    public var end: Date
    public var classification: Int
    public var averageHeartRate: Double?
    public var samplingFrequency: Double?
    /// Lead I in microvolts.
    public var voltages: [Double]?
    public var sourceBundle: String
    public var sourceName: String
    public var device: BackendDevice?
}

extension BackendElectrocardiogram {
    public init(_ ecg: HKElectrocardiogram, voltages: [Double]?) {
        self.init(uuid: ecg.uuid.uuidString, start: ecg.startDate, end: ecg.endDate,
                  classification: ecg.classification.rawValue,
                  averageHeartRate: ecg.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                  samplingFrequency: ecg.samplingFrequency?.doubleValue(for: .hertz()),
                  voltages: voltages,
                  sourceBundle: ecg.sourceRevision.source.bundleIdentifier,
                  sourceName: ecg.sourceRevision.source.name,
                  device: BackendDevice(ecg.device))
    }
}

/// The chunks of the Apple Health upload. Each chunk is final once the server has it, so its key names the data it holds:
/// `healthkit-<type>-<yyyy-MM>-<chunk>`.
public enum HealthKitChunks {
    /// Limits per request, from the backend API. Electrocardiograms carry about 15,000 voltages each, so they go 50 at a time.
    public static let sampleLimit = 5000
    public static let workoutLimit = 200
    public static let electrocardiogramLimit = 50

    public static func key(type: String, month: Date, chunk: Int, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "healthkit-\(type)-" + String(format: "%04ld-%02ld", parts.year ?? 0, parts.month ?? 0) + "-\(chunk)"
    }

    /// The items in order, cut into chunks of `size`. No items give no chunks.
    public static func chunks<Item>(_ items: [Item], size: Int) -> [[Item]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}
