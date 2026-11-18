import GarminModels

/// What the App Intents run against the watch. The app sets these at launch. Intents that need the watch open the
/// app first, so their `perform` runs in the app process, where the Bluetooth link lives.
@MainActor
enum WatchCommands {
    static var syncNow: @MainActor () async -> Void = {}
    static var findMyWatch: @MainActor () async throws -> Void = {}
    static var sendWorkout: @MainActor (WorkoutPlan) async throws -> Void = { _ in }
}
