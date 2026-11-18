import GarminModels

/// Garmin's strength exercise catalog, from Gadgetbridge's `garmin.json` (see `scripts/generate_exercise_catalog.py`).
public enum GarminExerciseCatalog {
    private static let entries: [(exercise: WorkoutExercise, isStrength: Bool)] = GarminExerciseCatalogData.rows
        .split(separator: "\n")
        .map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            let exercise = WorkoutExercise(
                id: String(fields[0]),
                name: String(fields[1]),
                category: Int(fields[2]) ?? 0,
                code: Int(fields[3])
            )
            return (exercise, fields[4] == "1")
        }

    /// Every exercise of the catalog, in Gadgetbridge's order.
    public static let all: [WorkoutExercise] = entries.map(\.exercise)

    /// The exercises of Garmin's strength list, which is what a strength step offers.
    public static let strength: [WorkoutExercise] = entries.filter(\.isStrength).map(\.exercise)

    public static func exercise(id: String) -> WorkoutExercise? {
        entries.first { $0.exercise.id == id }?.exercise
    }
}
