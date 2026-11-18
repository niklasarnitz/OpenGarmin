import Foundation
import GarminModels
import GarminSession

/// Deterministic sample data so every screen shows realistic content in previews and the simulator.
enum PreviewData {
    static let capabilities: Set<GarminCapability> = [
        .sync, .deviceInitiatesSync, .gncs, .findMyPhone, .findMyWatch, .connectiqHttp,
        .weatherConditions, .weatherAlerts, .workoutDownload, .livetrack, .gpsEphemerisDownload, .incidentDetection,
    ]

    static func pairedWatch(now: Date = .now) -> PairedWatch {
        PairedWatch(
            id: UUID(uuidString: "6E1B3C2A-1F0D-4B7E-9A55-2C8D7E4F1A10")!,
            name: "Venu 4",
            catalogID: "garmin_venu_4",
            info: DeviceInfo(protocolVersion: 2, productNumber: 4369, unitNumber: 1_234_567_890,
                             softwareVersion: 1842, maxPacketSize: 255, bluetoothName: "Venu 4",
                             deviceName: "Venu 4", deviceModel: "Venu 4"),
            capabilities: capabilities,
            lastSync: now.addingTimeInterval(-14 * 60))
    }

    static let nearby: [NearbyWatch] = [
        NearbyWatch(id: UUID(), name: "Venu 4 A3F2", rssi: -46, catalogID: "garmin_venu_4"),
        NearbyWatch(id: UUID(), name: "fenix 8 Pro", rssi: -71, catalogID: "garmin_fenix_8_pro"),
        NearbyWatch(id: UUID(), name: "Forerunner 265", rssi: -84, catalogID: "garmin_forerunner_265"),
    ]

    static let plans: [WorkoutPlan] = [
        WorkoutPlan(name: "Tempo 4 × 1 km", sport: .running, steps: [
            WorkoutStep(name: "Warm up", intensity: .warmup, duration: .time(seconds: 600), target: .heartRateZone(2)),
            WorkoutStep(name: "Tempo", intensity: .interval, duration: .distance(meters: 1000),
                        target: .paceRange(lowSecondsPerKm: 255, highSecondsPerKm: 270)),
            WorkoutStep(name: "Jog", intensity: .recovery, duration: .time(seconds: 120)),
            WorkoutStep(name: "Repeat", intensity: .active, duration: .repeatUntilStepsComplete(fromStep: 1, count: 4)),
            WorkoutStep(name: "Cool down", intensity: .cooldown, duration: .time(seconds: 600)),
        ]),
        WorkoutPlan(name: "Zone 2 spin", sport: .cycling, steps: [
            WorkoutStep(name: "Steady", intensity: .active, duration: .time(seconds: 3600),
                        target: .heartRateRange(low: 120, high: 140)),
        ]),
        WorkoutPlan(name: "Strength A", sport: .training, steps: [
            WorkoutStep(name: "Lifts", intensity: .active, duration: .open),
            WorkoutStep(name: "Rest", intensity: .rest, duration: .time(seconds: 90)),
        ]),
    ]

    /// Health data for "now": heart rate for 24 h, a day of steps, last night's sleep and two activities.
    static func batch(now: Date = .now) -> HealthBatch {
        var batch = HealthBatch()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)

        func at(_ hour: Double, day: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: day, to: dayStart)!.addingTimeInterval(hour * 3600)
        }

        func series(_ values: [Double], every hours: Double) -> [PointSample] {
            values.enumerated()
                .map { PointSample(date: at(Double($0.offset) * hours), value: $0.element) }
                .filter { $0.date <= now }
        }

        for index in 0..<144 {
            let date = now.addingTimeInterval(TimeInterval((index - 143) * 600))
            let hour = calendar.component(.hour, from: date)
            let base = (0...6).contains(hour) ? 54.0 : 68.0
            let bpm = base + 6 * sin(Double(index) / 7) + Double(index % 5)
            batch.heartRate.append(HeartRateSample(date: date, bpm: Int(bpm)))
        }

        batch.restingHeartRate = (0..<7).map { PointSample(date: at(6, day: -$0), value: Double(55 + $0 % 3)) }

        let activityProfile: [Double] = [0, 0, 0, 0, 0, 0, 60, 320, 540, 410, 280, 350,
                                         520, 470, 260, 300, 430, 610, 580, 340, 190, 120, 60, 10]
        for hour in 0..<24 where at(Double(hour)) < now {
            let start = at(Double(hour))
            let end = start.addingTimeInterval(3600)
            let steps = activityProfile[hour] * 2.4
            batch.steps.append(IntervalSample(start: start, end: end, value: steps))
            batch.activeEnergyKcal.append(IntervalSample(start: start, end: end, value: steps * 0.045))
            batch.restingEnergyKcal.append(IntervalSample(start: start, end: end, value: 70))
            batch.distance.append(IntervalSample(start: start, end: end, value: steps * 0.74))
        }

        for index in 0..<96 {
            let date = dayStart.addingTimeInterval(TimeInterval(index * 900))
            guard date <= now else { break }
            let daytime: Double = (9...18).contains(index / 4) ? 14 : 0
            let value = 26 + 14 * sin(Double(index) / 5) + daytime + Double(index % 7)
            batch.stress.append(PointSample(date: date, value: min(max(value, 0), 100)))
        }

        for index in 0..<16 {
            let hoursAwake = Double(index) / 2
            let date = at(6 + hoursAwake)
            guard date <= now else { break }
            batch.bodyBattery.append(PointSample(date: date, value: max(15, 88 - 2.2 * hoursAwake)))
        }

        batch.spo2 = series([0.97, 0.98, 0.96, 0.98, 0.97], every: 3)
        batch.respirationRate = series((0..<12).map { 13.5 + 1.8 * sin(Double($0) / 2) }, every: 1)
        batch.hrv = (0..<7).map { PointSample(date: at(7, day: -$0), value: Double(48 + ($0 * 17) % 23)) }

        let stages: [(minutes: Double, stage: SleepStage)] = [
            (4, .awake), (34, .light), (58, .deep), (38, .light), (26, .rem), (22, .light), (44, .deep),
            (31, .light), (40, .rem), (6, .awake), (55, .light), (24, .rem), (48, .light), (12, .awake), (18, .light),
        ]
        var cursor = at(-0.95)
        var intervals: [SleepInterval] = []
        for stage in stages {
            let end = cursor.addingTimeInterval(stage.minutes * 60)
            intervals.append(SleepInterval(start: cursor, end: end, stage: stage.stage))
            cursor = end
        }
        batch.sleep = [SleepSession(start: at(-0.95), end: cursor, intervals: intervals, score: 82)]

        batch.activities = [
            run(start: calendar.date(byAdding: .day, value: -1, to: dayStart)!.addingTimeInterval(18 * 3600 + 300)),
            ride(start: calendar.date(byAdding: .day, value: -3, to: dayStart)!.addingTimeInterval(9 * 3600 + 1200)),
        ]
        return batch
    }

    private static func run(start: Date) -> Activity {
        let duration: TimeInterval = 1560
        let laps = (0..<5).map { index in
            ActivityLap(start: start.addingTimeInterval(Double(index) * 312),
                        end: start.addingTimeInterval(Double(index + 1) * 312),
                        distance: 1040, calories: 82, averageHeartRate: 146 + index * 4)
        }
        return Activity(
            id: "run-\(Int(start.timeIntervalSince1970))", sport: .running, name: "Tiergarten loop",
            start: start, end: start.addingTimeInterval(duration), duration: duration,
            distance: 5200, activeCalories: 412, averageHeartRate: 152, maxHeartRate: 171,
            totalAscent: 38, totalDescent: 36, averageSpeed: 5200 / duration, averageCadence: 168,
            trainingEffect: 3.2, laps: laps,
            records: records(start: start, duration: duration, distance: 5200,
                             latRadius: 0.0075, lonRadius: 0.0125, heartRange: 146...174))
    }

    private static func ride(start: Date) -> Activity {
        let duration: TimeInterval = 4920
        return Activity(
            id: "ride-\(Int(start.timeIntervalSince1970))", sport: .cycling, name: "Grunewald climb",
            start: start, end: start.addingTimeInterval(duration), duration: duration,
            distance: 27_400, activeCalories: 690, averageHeartRate: 138, maxHeartRate: 162,
            totalAscent: 212, totalDescent: 208, averageSpeed: 27_400 / duration, averageCadence: 84,
            averagePower: 165, trainingEffect: 2.8,
            records: records(start: start, duration: duration, distance: 27_400,
                             latRadius: 0.035, lonRadius: 0.05, heartRange: 122...160))
    }

    /// A closed loop around the centre of Berlin, so the route map has a real shape.
    private static func records(start: Date, duration: TimeInterval, distance: Double,
                                latRadius: Double, lonRadius: Double, heartRange: ClosedRange<Int>) -> [ActivityRecord] {
        let centre = (latitude: 52.5145, longitude: 13.3501)
        let span = Double(heartRange.upperBound - heartRange.lowerBound)
        return (0..<120).map { index in
            let fraction = Double(index) / 119
            let angle = fraction * 2 * .pi
            return ActivityRecord(
                date: start.addingTimeInterval(duration * fraction),
                latitude: centre.latitude + latRadius * sin(angle),
                longitude: centre.longitude + lonRadius * cos(angle),
                altitude: 35 + 4 * sin(angle * 2) + 2 * fraction,
                heartRate: heartRange.lowerBound + Int(span * (0.5 + 0.5 * sin(angle * 3))),
                speed: distance / duration * (1 + 0.08 * sin(angle * 4)),
                distance: distance * fraction)
        }
    }
}
