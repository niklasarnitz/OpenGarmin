import Foundation
import Testing
import GarminFIT
import GarminModels

@Test func encodesWorkoutStepsRepeatsAndTargets() throws {
    let plan = WorkoutPlan(name: "Intervals", sport: .running, steps: [
        WorkoutStep(name: "Warm up", intensity: .warmup, duration: .time(seconds: 600)),
        WorkoutStep(intensity: .interval, duration: .distance(meters: 400),
                    target: .paceRange(lowSecondsPerKm: 300, highSecondsPerKm: 270), notes: "Fast"),
        WorkoutStep(intensity: .rest, duration: .time(seconds: 90), target: .heartRateRange(low: 130, high: 150)),
        WorkoutStep(intensity: .active, duration: .repeatUntilStepsComplete(fromStep: 1, count: 4)),
        WorkoutStep(intensity: .cooldown, duration: .open),
    ])

    let file = try FitDecoder.decode(WorkoutFitEncoder.encode(plan))

    // file_id: type 5 is a workout file.
    #expect(file.messages(0).first?[0]?.int == 5)

    let workout = try #require(file.messages(26).first)
    #expect(workout[4]?.int == 1) // sport: running
    #expect(workout[6]?.int == 5) // num_valid_steps
    #expect(workout[8]?.string == "Intervals")

    let steps = file.messages(27)
    #expect(steps.count == 5)
    #expect(steps.map { $0[254]?.int } == [0, 1, 2, 3, 4])

    // Time durations are milliseconds; intensity 2 is warmup.
    #expect(steps[0][0]?.string == "Warm up")
    #expect(steps[0][1]?.int == 0)
    #expect(steps[0][2]?.int == 600_000)
    #expect(steps[0][7]?.int == 2)
    #expect(steps[0][3]?.int == 2) // no target: open

    // Distance durations are centimetres. Pace range: the slower pace is the low speed (mm/s).
    #expect(steps[1][1]?.int == 1)
    #expect(steps[1][2]?.int == 40_000)
    #expect(steps[1][3]?.int == 0)
    #expect(steps[1][5]?.int == 3333)
    #expect(steps[1][6]?.int == 3704)
    #expect(steps[1][8]?.string == "Fast")

    // Heart rate range offset by +100 bpm.
    #expect(steps[2][3]?.int == 1)
    #expect(steps[2][5]?.int == 230)
    #expect(steps[2][6]?.int == 250)
    #expect(steps[2][7]?.int == 1)

    // Repeat: duration type 6 jumps back to step 1 and runs four times (target value).
    #expect(steps[3][1]?.int == 6)
    #expect(steps[3][2]?.int == 1)
    #expect(steps[3][4]?.int == 4)

    #expect(steps[4][1]?.int == 5)
    #expect(steps[4][7]?.int == 3)
}

@Test func encodesStrengthStepsWithExerciseWeightAndRepsExactly() throws {
    let bench = WorkoutExercise(id: "bench_press/barbell_bench_press", name: "Barbell Bench Press", category: 0, code: 3)
    let plank = WorkoutExercise(id: "plank/generic", name: "Plank", category: 19, code: nil)
    let plan = WorkoutPlan(name: "Strength A", sport: .training, subSport: 20, steps: [
        WorkoutStep(intensity: .active, duration: .reps(count: 10), exercise: bench, weightKg: 62.5),
        WorkoutStep(intensity: .rest, duration: .time(seconds: 90)),
        WorkoutStep(intensity: .active, duration: .reps(count: 8), exercise: bench, weightKg: 65),
        WorkoutStep(name: "Hold", intensity: .active, duration: .time(seconds: 45), exercise: plank),
    ])

    let file = try FitDecoder.decode(WorkoutFitEncoder.encode(plan))

    let workout = try #require(file.messages(26).first)
    #expect(workout[4]?.int == 10) // sport: training
    #expect(workout[11]?.int == 20) // sub_sport: strength training
    #expect(workout[6]?.int == 4) // num_valid_steps

    let steps = file.messages(27)
    #expect(steps.count == 4)
    // Reps: duration type 29 with the count as the value. Bench press is category 0, name 3. 62.5 kg is 6250 in
    // hundredths of a kilogram, and the display unit is kilograms (1).
    #expect(steps[0][1]?.int == 29)
    #expect(steps[0][2]?.int == 10)
    #expect(steps[0][10]?.int == 0)
    #expect(steps[0][11]?.int == 3)
    #expect(steps[0][12]?.int == 6250)
    #expect(steps[0][13]?.int == 1)
    // Rest: 90 seconds in milliseconds, no exercise and no weight.
    #expect(steps[1][1]?.int == 0)
    #expect(steps[1][2]?.int == 90_000)
    #expect(steps[1][7]?.int == 1)
    #expect(steps[1][10] == nil)
    #expect(steps[1][12] == nil)
    // 65 kg is 6500.
    #expect(steps[2][12]?.int == 6500)
    // Without a name code the step carries only the category.
    #expect(steps[3][10]?.int == 19)
    #expect(steps[3][11] == nil)

    // One exercise_title per distinct exercise, in the order the steps first use them.
    let titles = file.messages(264)
    #expect(titles.count == 2)
    #expect(titles[0][0]?.int == 0)
    #expect(titles[0][1]?.int == 3)
    #expect(titles[0][2]?.string == "Barbell Bench Press")
    #expect(titles[0][254]?.int == 0)
    #expect(titles[1][0]?.int == 19)
    #expect(titles[1][1] == nil)
    #expect(titles[1][2]?.string == "Plank")
    #expect(titles[1][254]?.int == 1)
}
