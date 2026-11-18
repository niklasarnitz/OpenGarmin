import Foundation
import GarminModels

/// One stored point, or one interval when `end` is set (steps, energy, distance).
struct SamplePoint: Codable, Sendable {
    let start: Date
    let end: Date?
    let value: Double
}

/// The metrics the samples table holds. Raw values are the names the API uses.
enum Metric: String, CaseIterable {
    case heartRate, restingHeartRate, steps, activeEnergy, restingEnergy, distance, floors, intensityMinutes
    case stress, bodyBattery, spo2, respiration, hrv

    /// The points of this metric in a decoded batch.
    func points(in batch: HealthBatch) -> [SamplePoint] {
        switch self {
        case .heartRate: batch.heartRate.map { SamplePoint(start: $0.date, end: nil, value: Double($0.bpm)) }
        case .restingHeartRate: Self.pointList(batch.restingHeartRate)
        case .steps: Self.intervalList(batch.steps)
        case .activeEnergy: Self.intervalList(batch.activeEnergyKcal)
        case .restingEnergy: Self.intervalList(batch.restingEnergyKcal)
        case .distance: Self.intervalList(batch.distance)
        case .floors: Self.intervalList(batch.floorsClimbed)
        case .intensityMinutes: Self.intervalList(batch.intensityMinutes)
        case .stress: Self.pointList(batch.stress)
        case .bodyBattery: Self.pointList(batch.bodyBattery)
        case .spo2: Self.pointList(batch.spo2)
        case .respiration: Self.pointList(batch.respirationRate)
        case .hrv: Self.pointList(batch.hrv)
        }
    }

    /// Puts stored points back into a batch, for the history export.
    func fill(_ batch: inout HealthBatch, _ points: [SamplePoint]) {
        switch self {
        case .heartRate: batch.heartRate += points.map { HeartRateSample(date: $0.start, bpm: Int($0.value)) }
        case .restingHeartRate: batch.restingHeartRate += Self.pointSamples(points)
        case .steps: batch.steps += Self.intervalSamples(points)
        case .activeEnergy: batch.activeEnergyKcal += Self.intervalSamples(points)
        case .restingEnergy: batch.restingEnergyKcal += Self.intervalSamples(points)
        case .distance: batch.distance += Self.intervalSamples(points)
        case .floors: batch.floorsClimbed += Self.intervalSamples(points)
        case .intensityMinutes: batch.intensityMinutes += Self.intervalSamples(points)
        case .stress: batch.stress += Self.pointSamples(points)
        case .bodyBattery: batch.bodyBattery += Self.pointSamples(points)
        case .spo2: batch.spo2 += Self.pointSamples(points)
        case .respiration: batch.respirationRate += Self.pointSamples(points)
        case .hrv: batch.hrv += Self.pointSamples(points)
        }
    }

    private static func pointList(_ samples: [PointSample]) -> [SamplePoint] {
        samples.map { SamplePoint(start: $0.date, end: nil, value: $0.value) }
    }

    private static func intervalList(_ samples: [IntervalSample]) -> [SamplePoint] {
        samples.map { SamplePoint(start: $0.start, end: $0.end, value: $0.value) }
    }

    private static func pointSamples(_ points: [SamplePoint]) -> [PointSample] {
        points.map { PointSample(date: $0.start, value: $0.value) }
    }

    private static func intervalSamples(_ points: [SamplePoint]) -> [IntervalSample] {
        points.map { IntervalSample(start: $0.start, end: $0.end ?? $0.start, value: $0.value) }
    }
}
