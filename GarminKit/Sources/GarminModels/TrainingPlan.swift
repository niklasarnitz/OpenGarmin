import Foundation

/// A workout due on a day of a training plan.
public struct PlannedWorkout: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    /// Any time on the due day, in the planning calendar.
    public var day: Date
    public var workout: WorkoutPlan
    public init(id: UUID = UUID(), day: Date, workout: WorkoutPlan) {
        self.id = id; self.day = day; self.workout = workout
    }
}

/// Workouts scheduled over several weeks. The next one is what gets sent to the watch.
public struct TrainingPlan: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var sessions: [PlannedWorkout]

    public init(id: UUID = UUID(), name: String, sessions: [PlannedWorkout]) {
        self.id = id; self.name = name; self.sessions = sessions
    }

    /// Repeats a weekly template for `weeks` weeks from the day of `start`. `weekdays` maps a calendar weekday
    /// (1 = Sunday ... 7 = Saturday) to the workout due that day.
    public init(name: String, start: Date, weeks: Int, weekdays: [Int: WorkoutPlan], calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: start)
        var sessions: [PlannedWorkout] = []
        for offset in 0..<max(weeks, 0) * 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                  let workout = weekdays[calendar.component(.weekday, from: day)] else { continue }
            sessions.append(PlannedWorkout(day: day, workout: workout))
        }
        self.init(name: name, sessions: sessions)
    }

    /// The first workout due today or later, which is the next one to send to the watch.
    public func nextSession(from now: Date, calendar: Calendar = .current) -> PlannedWorkout? {
        let today = calendar.startOfDay(for: now)
        return sessions
            .filter { calendar.startOfDay(for: $0.day) >= today }
            .min { $0.day < $1.day }
    }
}
