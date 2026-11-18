import Foundation
import GarminCore
import GarminModels

/// Encodes a `WorkoutPlan` as a FIT workout file (file type 5), laid out as Gadgetbridge's `GarminWorkoutFitEncoder`:
/// file_id, file_creator, the workout message, then one workout_step per step. A repeat is a step whose duration
/// jumps back to `fromStep` until it has run `count` times.
public enum WorkoutFitEncoder {
    private static let workoutFileType: Int64 = 5
    private static let capabilities: Int64 = 32
    /// Heart rate targets and durations are offset by +100 bpm in a workout step.
    private static let heartRateOffset: Int64 = 100
    /// Custom power targets are offset by +1000 watts.
    private static let powerOffset: Int64 = 1000
    /// FIT exercise weight is kilograms times 100, and its display unit is kilograms.
    private static let weightScale = 100.0
    private static let kilogramUnit: Int64 = 1

    public static func encode(_ plan: WorkoutPlan) -> Data {
        var messages = [fileId(), fileCreator(), workout(plan)]
        for (index, step) in plan.steps.enumerated() {
            messages.append(stepMessage(step, index: index, sport: plan.sport))
        }
        messages += exerciseTitles(plan)
        return FitEncoder.encodeFile(messages)
    }

    /// One exercise_title per distinct exercise, in the order the steps first use them, as Gadgetbridge writes them.
    private static func exerciseTitles(_ plan: WorkoutPlan) -> [FitEncodeMessage] {
        var exercises: [WorkoutExercise] = []
        for exercise in plan.steps.compactMap(\.exercise) where !exercises.contains(exercise) {
            exercises.append(exercise)
        }
        return exercises.enumerated().map { index, exercise in
            var fields = [field(0, .uint16, Int64(exercise.category))]
            if let code = exercise.code {
                fields.append(field(1, .uint16, Int64(code)))
            }
            fields += [text(2, exercise.name), field(254, .uint16, Int64(index))]
            return FitEncodeMessage(globalNumber: 264, fields: fields)
        }
    }

    private static func fileId() -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 0, fields: [
            field(0, .enumeration, workoutFileType),
            field(1, .uint16, 1), // Garmin
            field(2, .uint16, 65534), // Connect
            field(3, .uint32z, 1),
            field(4, .uint32, Int64(GarminTime.garminSeconds(from: Date()))),
            field(5, .uint16, 1),
        ])
    }

    private static func fileCreator() -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 49, fields: [field(0, .uint16, 1)])
    }

    private static func workout(_ plan: WorkoutPlan) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 26, fields: [
            field(254, .uint16, 0),
            text(8, plan.name),
            field(4, .enumeration, Int64(plan.sport.rawValue)),
            field(11, .enumeration, Int64(plan.subSport ?? 0)),
            field(5, .uint32z, capabilities),
            field(6, .uint16, Int64(plan.steps.count)),
        ])
    }

    private static func stepMessage(_ step: WorkoutStep, index: Int, sport: Sport) -> FitEncodeMessage {
        var fields = [field(254, .uint16, Int64(index))]
        if let name = step.name {
            fields.append(text(0, name))
        }
        if case .repeatUntilStepsComplete(let fromStep, let count) = step.duration {
            fields += [
                field(1, .enumeration, 6),
                field(2, .uint32, Int64(fromStep)),
                field(4, .uint32, Int64(count)),
            ]
            return FitEncodeMessage(globalNumber: 27, fields: fields)
        }
        fields.append(field(7, .enumeration, Int64(step.intensity.rawValue)))
        if let notes = step.notes {
            fields.append(text(8, notes))
        }
        fields += durationFields(step.duration)
        fields += targetFields(step.target, sport: sport)
        fields += exerciseFields(step)
        return FitEncodeMessage(globalNumber: 27, fields: fields)
    }

    /// The exercise, and its weight in kilograms, of a strength step.
    private static func exerciseFields(_ step: WorkoutStep) -> [FitEncodeField] {
        var fields: [FitEncodeField] = []
        if let exercise = step.exercise {
            fields.append(field(10, .uint16, Int64(exercise.category)))
            if let code = exercise.code {
                fields.append(field(11, .uint16, Int64(code)))
            }
        }
        if let kilograms = step.weightKg {
            fields.append(field(12, .uint16, Int64((kilograms * weightScale).rounded())))
            fields.append(field(13, .uint16, kilogramUnit))
        }
        return fields
    }

    private static func durationFields(_ duration: WorkoutDurationType) -> [FitEncodeField] {
        switch duration {
        case .open:
            [field(1, .enumeration, 5)]
        case .time(let seconds):
            // Time durations are in milliseconds.
            [field(1, .enumeration, 0), field(2, .uint32, Int64(seconds) * 1000)]
        case .distance(let meters):
            // Distance durations are in centimetres.
            [field(1, .enumeration, 1), field(2, .uint32, Int64(meters) * 100)]
        case .calories(let kcal):
            [field(1, .enumeration, 4), field(2, .uint32, Int64(kcal))]
        case .heartRateLessThan(let bpm):
            [field(1, .enumeration, 2), field(2, .uint32, Int64(bpm) + heartRateOffset)]
        case .heartRateGreaterThan(let bpm):
            [field(1, .enumeration, 3), field(2, .uint32, Int64(bpm) + heartRateOffset)]
        case .reps(let count):
            // Reps have no unit of their own; the count is the value.
            [field(1, .enumeration, 29), field(2, .uint32, Int64(count))]
        case .repeatUntilStepsComplete:
            // Written by `stepMessage`, which is the only place a repeat is encoded.
            []
        }
    }

    private static func targetFields(_ target: WorkoutTarget, sport: Sport) -> [FitEncodeField] {
        switch target {
        case .none:
            [field(3, .enumeration, 2), field(4, .uint32, 0)]
        case .heartRateZone(let zone):
            [field(3, .enumeration, 1), field(4, .uint32, Int64(zone))]
        case .heartRateRange(let low, let high):
            [
                field(3, .enumeration, 1),
                field(5, .uint32, Int64(low) + heartRateOffset),
                field(6, .uint32, Int64(high) + heartRateOffset),
            ]
        case .paceRange(let lowSeconds, let highSeconds):
            // Speed in mm/s. The slower pace is the lower speed.
            [
                field(3, .enumeration, 0),
                field(5, .uint32, speedMmPerS(secondsPerKm: max(lowSeconds, highSeconds))),
                field(6, .uint32, speedMmPerS(secondsPerKm: min(lowSeconds, highSeconds))),
            ]
        case .cadenceRange(let low, let high):
            // A running cadence is stored per foot, half the steps per minute.
            [
                field(3, .enumeration, 3),
                field(5, .uint32, Int64(low / (sport == .running ? 2 : 1))),
                field(6, .uint32, Int64(high / (sport == .running ? 2 : 1))),
            ]
        case .powerRange(let low, let high):
            [
                field(3, .enumeration, 7),
                field(5, .uint32, Int64(low) + powerOffset),
                field(6, .uint32, Int64(high) + powerOffset),
            ]
        }
    }

    private static func speedMmPerS(secondsPerKm: Int) -> Int64 {
        Int64((1_000_000 / Double(max(secondsPerKm, 1))).rounded())
    }

    private static func field(_ number: UInt8, _ baseType: FitBaseType, _ value: Int64) -> FitEncodeField {
        FitEncodeField(number, baseType, .int(value))
    }

    private static func text(_ number: UInt8, _ value: String) -> FitEncodeField {
        FitEncodeField(number, .string, .string(value))
    }
}
