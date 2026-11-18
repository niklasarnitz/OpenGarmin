import Foundation
import GarminModels

/// The saved workouts. Shown in the Workouts tab and offered to Shortcuts. Until the user saves any, the sample plans.
enum WorkoutLibrary {
    private static let key = "workoutPlans"

    static var plans: [WorkoutPlan] {
        get {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WorkoutPlan].self, from: $0) }
                ?? PreviewData.plans
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}
