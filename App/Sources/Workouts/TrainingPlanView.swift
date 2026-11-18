import SwiftUI
import GarminModels

/// The sessions of a training plan. The next one is the workout sent to the watch.
struct TrainingPlanView: View {
    @Environment(AppEnvironment.self) private var app
    let plan: TrainingPlan

    @State private var sending = false
    @State private var sendError: String?

    private var next: PlannedWorkout? { plan.nextSession(from: .now) }

    var body: some View {
        List {
            Section {
                if let next {
                    Button {
                        send(next.workout)
                    } label: {
                        Label("Send \(next.workout.name) to watch", systemImage: "paperplane.fill")
                    }
                    .disabled(sending)
                } else {
                    Text("No sessions left in this plan.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let next {
                    Text(next.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                }
            }
            Section("Sessions") {
                ForEach(plan.sessions) { session in
                    LabeledContent(session.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) {
                        Text(session.workout.name)
                    }
                }
            }
        }
        .navigationTitle(plan.name)
        .alert("Couldn't send the workout", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } })
        ) {} message: {
            Text(sendError ?? "")
        }
    }

    private func send(_ workout: WorkoutPlan) {
        sending = true
        Task {
            do {
                try await app.watch.sendWorkout(workout)
            } catch {
                sendError = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Creates a plan: a weekly schedule of saved workouts, repeated for some weeks from a start date.
struct TrainingPlanEditor: View {
    let workouts: [WorkoutPlan]
    let onSave: (TrainingPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "Training plan"
    @State private var start = Date.now
    @State private var weeks = 4
    /// Calendar weekday (1 = Sunday) to the saved workout due that day. A missing day is a rest day.
    @State private var assignments: [Int: UUID] = [:]

    /// Calendar weekdays in the order a week is usually planned: Monday first.
    private static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    Stepper("\(weeks) weeks", value: $weeks, in: 1...12)
                }
                Section("Weekly schedule") {
                    ForEach(Self.weekdays, id: \.self) { weekday in
                        Picker(Calendar.current.weekdaySymbols[weekday - 1], selection: choice(weekday)) {
                            Text("Rest").tag(UUID?.none)
                            ForEach(workouts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
            }
            .navigationTitle("New training plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let schedule = assignments.compactMapValues { id in workouts.first { $0.id == id } }
                        onSave(TrainingPlan(name: name, start: start, weeks: weeks, weekdays: schedule))
                        dismiss()
                    }
                    .disabled(assignments.isEmpty)
                }
            }
        }
    }

    private func choice(_ weekday: Int) -> Binding<UUID?> {
        Binding(get: { assignments[weekday] }, set: { assignments[weekday] = $0 })
    }
}
