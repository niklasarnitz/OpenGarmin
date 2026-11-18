import Foundation
import GarminModels

/// Health records the watch sends beyond the core metrics: raw sleep streams, naps, HRV status, training readiness
/// and load, recovery time, and the components of the sleep score.
extension FitExtractor {
    static func extractRawSleep(_ file: FitFile, into batch: inout HealthBatch) {
        // The sleep data info, the raw rows and the sleep levels place each other, so they are read in file order.
        var stream = RawSleepStream()
        for message in file.messages where [FitMesg.sleepDataInfo, FitMesg.sleepDataRaw, FitMesg.sleepLevel].contains(message.globalNumber) {
            switch message.globalNumber {
            case FitMesg.sleepDataInfo:
                stream.onInfo(timestamp: message.timestamp, sampleLength: message.int(1))
            case FitMesg.sleepDataRaw:
                var features: [Double]?
                if case .bytes(let bytes)? = message[0] { features = RawSleepRow.features(bytes) }
                stream.onRaw(heartRate: RawSleepRow.heartRate(features), movement: RawSleepRow.movement(features))
            default:
                guard let level = message.int(0), (0...4).contains(level) else { continue }
                stream.onLevel(timestamp: message.timestamp, level: level)
            }
        }
        // Without raw rows the sleep levels are a staged night, which the sleep sessions already describe.
        if stream.rawCount > 0 {
            batch.rawSleepMinutes += stream.minutes
        }
    }

    static func extractNaps(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.napEvent) {
            guard let start = message.int(0), let end = message.int(2), end >= start else { continue }
            batch.naps.append(Nap(start: date(start), end: date(end)))
        }
    }

    static func extractHrvStatus(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.hrvStatusSummary) {
            guard let ts = message.timestamp else { continue }
            batch.hrvStatus.append(HRVStatusSample(
                date: date(ts),
                weeklyAverage: message.double(0, scale: 128),
                lastNightAverage: message.double(1, scale: 128),
                lastNight5MinHigh: message.double(2, scale: 128),
                baselineLowUpper: message.double(3, scale: 128),
                baselineBalancedLower: message.double(4, scale: 128),
                baselineBalancedUpper: message.double(5, scale: 128),
                status: message.int(6).flatMap { HRVStatus.fromFit($0) }
            ))
        }
    }

    static func extractTrainingMetrics(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.trainingReadiness) {
            guard let ts = message.timestamp, let score = message.int(0) else { continue }
            batch.trainingReadiness.append(PointSample(date: date(ts), value: Double(score)))
        }
        for message in file.messages(FitMesg.trainingLoad) {
            guard let ts = message.timestamp else { continue }
            let acute = message.double(3)
            let chronic = message.double(4)
            guard acute != nil || chronic != nil else { continue }
            batch.trainingLoad.append(TrainingLoadSample(date: date(ts), acute: acute, chronic: chronic))
        }
        for message in file.messages(FitMesg.metricRecovery) {
            guard let ts = message.timestamp, let minutes = message.int(0), minutes >= 0 else { continue }
            batch.recoveryTime.append(PointSample(date: date(ts), value: Double(minutes)))
        }
    }

    /// The components of a sleep assessment (FIT 346). The overall score is read by the caller.
    static func sleepScoreBreakdown(_ message: FitMessage) -> SleepScoreBreakdown {
        func score(_ field: UInt8) -> Int? { message.int(field).map(Int.init) }
        return SleepScoreBreakdown(
            duration: score(4), quality: score(7), recovery: score(8), deep: score(3), light: score(5), rem: score(9),
            awakeTime: score(1), awakenings: score(2), interruptions: score(14), restlessness: score(10),
            combinedAwake: score(0), awakeningsCount: score(11),
            averageStress: message.double(15, scale: 100)
        )
    }
}

extension HRVStatus {
    /// Garmin's HrvStatus numbers: 0 none, 1 poor, 2 low, 3 unbalanced, 4 balanced.
    static func fromFit(_ number: Int64) -> HRVStatus? {
        switch number {
        case 0: HRVStatus.none
        case 1: .poor
        case 2: .low
        case 3: .unbalanced
        case 4: .balanced
        default: nil
        }
    }
}
