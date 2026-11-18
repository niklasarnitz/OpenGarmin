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
