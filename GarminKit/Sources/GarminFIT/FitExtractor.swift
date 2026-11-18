import Foundation
import GarminCore
import GarminModels

/// Turns decoded FIT messages into `HealthBatch` samples and activities. Field numbers and scales come
/// from Gadgetbridge's `fit_profile.json`; the semantics follow its `FitImporter`.
public enum FitExtractor {
    public static func extract(_ file: FitFile, unitNumber: UInt32?) -> HealthBatch {
        var batch = HealthBatch()
        extractMonitoring(file, into: &batch)
        extractHeartRate(file, into: &batch)
        extractStress(file, into: &batch)
        extractSpo2AndRespiration(file, into: &batch)
        extractHeartRateVariability(file, into: &batch)
        extractSleep(file, into: &batch)
        extractRawSleep(file, into: &batch)
        extractNaps(file, into: &batch)
        extractHrvStatus(file, into: &batch)
        extractTrainingMetrics(file, into: &batch)
        extractActivities(file, unitNumber: unitNumber, into: &batch)
        return batch
    }

    // MARK: - Monitoring (global 55, 211)

    /// Steps, distance and active calories are cumulative per activity type, so each reading becomes the
    /// interval since the previous reading of that type. Intensity minutes are per record.
    private static func extractMonitoring(_ file: FitFile, into batch: inout HealthBatch) {
        var samples: [(ts: Int64, message: FitMessage)] = []
        var last: Int64?
        for message in file.messages(MonitoringMessage.number) {
            guard let ts = monitoringTimestamp(message, last: last) else { continue }
            last = ts
            samples.append((ts, message))
        }
        samples = samples.enumerated()
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
            .map(\.element)

        var counters = CounterTracker()
        var previousTs: Int64?
        for (ts, message) in samples {
            let activityType = message.int(MonitoringMessage.activityType)
                ?? message.byte(MonitoringMessage.currentActivityTypeIntensity).map { $0 & 0x1F }
                ?? -1

            if let cycles = message.int(MonitoringMessage.cycles),
               let interval = counters.growth(.steps, activityType, ts: ts, value: Double(cycles)) {
                batch.steps.append(interval)
            }
            if let meters = message.double(MonitoringMessage.distance, scale: 100),
               let interval = counters.growth(.distance, activityType, ts: ts, value: meters) {
                batch.distance.append(interval)
            }
            if let kcal = message.int(MonitoringMessage.activeCalories),
               let interval = counters.growth(.activeCalories, activityType, ts: ts, value: Double(kcal)) {
                batch.activeEnergyKcal.append(interval)
            }

            let minutes = (message.int(MonitoringMessage.moderateMinutes) ?? 0)
                + (message.int(MonitoringMessage.vigorousMinutes) ?? 0)
            let start = previousTs ?? ts - 60
            if minutes > 0, start < ts {
                batch.intensityMinutes.append(IntervalSample(start: date(start), end: date(ts), value: Double(minutes)))
            }
            previousTs = ts

            if let bpm = message.int(MonitoringMessage.heartRate), bpm > 0 {
                batch.heartRate.append(HeartRateSample(date: date(ts), bpm: Int(bpm)))
            }
        }
    }

    /// The timestamp of a monitoring record. Once a previous record is known, `timestamp_16` (seconds, 16 bits)
    /// is placed relative to it, with rollover; otherwise the running timestamp is used.
    private static func monitoringTimestamp(_ message: FitMessage, last: Int64?) -> Int64? {
        if let last, let timestamp16 = message.int(MonitoringMessage.timestamp16) {
            var diff = (timestamp16 & 0xFFFF) - (last & 0xFFFF)
            if diff < -32768 {
                diff += 65536
            } else if diff > 32768 {
                diff -= 65536
            }
            return last + diff
        }
        return message.timestamp
    }

    private static func extractHeartRate(_ file: FitFile, into batch: inout HealthBatch) {
        // The `hr` message carries one bpm per second, ending at its timestamp plus fractional_timestamp.
        for message in file.messages(FitMesg.hr) {
            guard let ts = message.timestamp else { continue }
            let bpms = message.ints(6)
            let fraction = message.double(0, scale: 32768) ?? 0
            for (index, bpm) in bpms.enumerated() where bpm > 0 {
                let t = Double(ts) + fraction - Double(bpms.count - 1 - index)
                batch.heartRate.append(HeartRateSample(date: date(t), bpm: Int(bpm)))
            }
        }
        for message in file.messages(FitMesg.monitoringHrData) {
            guard let ts = message.timestamp, let bpm = message.int(1) ?? message.int(0), bpm > 0 else { continue }
            batch.restingHeartRate.append(PointSample(date: date(ts), value: Double(bpm)))
        }
    }

    // MARK: - Stress, body battery, SpO2, respiration, HRV

    private static func extractStress(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.stressLevel) {
            guard let ts = message.timestamp else { continue }
            if let stress = message.int(0), stress >= 0 {
                batch.stress.append(PointSample(date: date(ts), value: Double(stress)))
            }
            if let energy = message.int(3) {
                batch.bodyBattery.append(PointSample(date: date(ts), value: Double(energy)))
            }
        }
    }

    private static func extractSpo2AndRespiration(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.spo2Data) {
            guard let ts = message.timestamp, let percent = message.int(0), percent > 0 else { continue }
            batch.spo2.append(PointSample(date: date(ts), value: Double(percent) / 100))
        }
        for message in file.messages(FitMesg.respirationRate) {
            guard let ts = message.timestamp, let rate = message.double(0, scale: 100), rate > 0 else { continue }
            batch.respirationRate.append(PointSample(date: date(ts), value: rate))
        }
    }

    private static func extractHeartRateVariability(_ file: FitFile, into batch: inout HealthBatch) {
        for message in file.messages(FitMesg.hrvValue) {
            guard let ts = message.timestamp, let rmssd = message.double(0, scale: 128), rmssd > 0 else { continue }
            batch.hrv.append(PointSample(date: date(ts), value: rmssd))
        }
    }

    // MARK: - Sleep

    /// Sleep levels are sent when the stage changes, so each level lasts until the next one. Levels more than
    /// four hours apart start a new session. The sleep assessment score goes to the session it falls in.
    private static func extractSleep(_ file: FitFile, into batch: inout HealthBatch) {
        let levels = file.messages(FitMesg.sleepLevel)
            .compactMap { message -> (ts: Int64, stage: SleepStage)? in
                guard let ts = message.timestamp, let level = message.int(0), let stage = sleepStage(level) else { return nil }
                return (ts, stage)
            }
            .sorted { $0.ts < $1.ts }

        var groups: [[(ts: Int64, stage: SleepStage)]] = []
        for level in levels {
            if let previous = groups.last?.last, level.ts - previous.ts <= 4 * 3600 {
                groups[groups.count - 1].append(level)
            } else {
                groups.append([level])
            }
        }

        var sessions: [SleepSession] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let intervals = zip(group, group.dropFirst()).compactMap { current, next -> SleepInterval? in
                guard next.ts > current.ts else { return nil }
                return SleepInterval(start: date(current.ts), end: date(next.ts), stage: current.stage)
            }
            guard !intervals.isEmpty else { continue }
            sessions.append(SleepSession(start: date(first.ts), end: date(last.ts), intervals: intervals))
        }

        for message in file.messages(FitMesg.sleepAssessment) {
            guard let ts = message.timestamp, let score = message.int(6), !sessions.isEmpty else { continue }
            let index = sessions.indices.min { distance(from: sessions[$0], to: ts) < distance(from: sessions[$1], to: ts) }
            if let index {
                sessions[index].score = Int(score)
                sessions[index].scoreBreakdown = sleepScoreBreakdown(message)
            }
        }
        batch.sleep += sessions
    }

    private static func sleepStage(_ level: Int64) -> SleepStage? {
        switch level {
        case 0: .unmeasurable
        case 1: .awake
        case 2: .light
        case 3: .deep
        case 4: .rem
        default: nil
        }
    }

    private static func distance(from session: SleepSession, to ts: Int64) -> TimeInterval {
        let time = date(ts)
        if time < session.start { return session.start.timeIntervalSince(time) }
        if time > session.end { return time.timeIntervalSince(session.end) }
        return 0
    }
}

// MARK: - Shared helpers

/// Global FIT message numbers used by the extractor.
enum FitMesg {
    static let fileId: UInt16 = 0
    static let session: UInt16 = 18
    static let lap: UInt16 = 19
    static let record: UInt16 = 20
    static let hr: UInt16 = 132
    static let monitoringHrData: UInt16 = 211
    static let stressLevel: UInt16 = 227
    static let spo2Data: UInt16 = 269
    static let sleepDataInfo: UInt16 = 273
    static let sleepDataRaw: UInt16 = 274
    static let sleepLevel: UInt16 = 275
    static let metricRecovery: UInt16 = 284
    static let respirationRate: UInt16 = 297
    static let sleepAssessment: UInt16 = 346
    static let trainingReadiness: UInt16 = 369
    static let hrvStatusSummary: UInt16 = 370
    static let hrvValue: UInt16 = 371
    static let trainingLoad: UInt16 = 378
    static let napEvent: UInt16 = 412
}

/// Field numbers of the monitoring message (global 55).
private enum MonitoringMessage {
    static let number: UInt16 = 55
    static let distance: UInt8 = 2
    static let cycles: UInt8 = 3
    static let activeCalories: UInt8 = 19
    static let activityType: UInt8 = 5
    static let currentActivityTypeIntensity: UInt8 = 24
    static let timestamp16: UInt8 = 26
    static let heartRate: UInt8 = 27
    static let moderateMinutes: UInt8 = 33
    static let vigorousMinutes: UInt8 = 34
}

/// Turns cumulative counters into intervals, one counter per metric and activity type.
private struct CounterTracker {
    enum Metric: Hashable {
        case steps, distance, activeCalories
    }

    private struct Key: Hashable {
        var metric: Metric
        var activityType: Int64
    }

    private var readings: [Key: (ts: Int64, value: Double)] = [:]

    /// The growth since the previous reading of this metric and activity type, as an interval. A value lower
    /// than the previous one is a counter reset, so the value itself is the growth.
    mutating func growth(_ metric: Metric, _ activityType: Int64, ts: Int64, value: Double) -> IntervalSample? {
        let key = Key(metric: metric, activityType: activityType)
        defer { readings[key] = (ts, value) }
        guard let previous = readings[key], previous.ts < ts else { return nil }
        let growth = value >= previous.value ? value - previous.value : value
        guard growth > 0 else { return nil }
        return IntervalSample(start: date(previous.ts), end: date(ts), value: growth)
    }
}

extension FitMessage {
    /// Running timestamp in FIT seconds (field 253).
    var timestamp: Int64? { int(253) }

    func int(_ field: UInt8) -> Int64? { self[field]?.int }

    /// The first byte of a `byte` field. `FitValue.int` does not read byte arrays.
    func byte(_ field: UInt8) -> Int64? {
        if case .bytes(let bytes)? = self[field] { return bytes.first.map { Int64($0) } }
        return nil
    }

    /// The field divided by `scale`, then minus `offset`, as FIT defines physical values.
    func double(_ field: UInt8, scale: Double = 1, offset: Double = 0) -> Double? {
        self[field]?.double.map { $0 / scale - offset }
    }

    /// All integer elements of a field, or its single value.
    func ints(_ field: UInt8) -> [Int64] {
        switch self[field] {
        case .array(let values)?: values.compactMap(\.int)
        case .bytes(let bytes)?: bytes.map { Int64($0) }
        case let value?: value.int.map { [$0] } ?? []
        case nil: []
        }
    }
}

/// A FIT timestamp in seconds since the Garmin epoch, as a `Date`.
func date(_ fitSeconds: Int64) -> Date { date(Double(fitSeconds)) }

func date(_ fitSeconds: Double) -> Date {
    Date(timeIntervalSince1970: fitSeconds + GarminTime.epochOffset)
}
