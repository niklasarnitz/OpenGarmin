import AppIntents
import GarminModels

struct SendWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Send workout"
    static let description = IntentDescription("Sends a saved workout to your Garmin watch.")
    static let openAppWhenRun = true

    @Parameter(title: "Workout")
    var workout: WorkoutEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await WatchCommands.sendWorkout(workout.plan)
        return .result(dialog: "Sent \(workout.plan.name) to your watch.")
    }
}

struct WorkoutEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout"
    static let defaultQuery = WorkoutQuery()

    let plan: WorkoutPlan

    var id: UUID { plan.id }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(plan.name)", subtitle: "\(plan.sport.title), \(plan.steps.count) steps")
    }
}

struct WorkoutQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WorkoutEntity] {
        WorkoutLibrary.plans.filter { identifiers.contains($0.id) }.map { WorkoutEntity(plan: $0) }
    }

    func suggestedEntities() async throws -> [WorkoutEntity] {
        WorkoutLibrary.plans.map { WorkoutEntity(plan: $0) }
    }
}
