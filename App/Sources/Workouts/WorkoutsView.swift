import SwiftUI
import GarminModels

struct WorkoutsView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var plans = WorkoutLibrary.plans
    @State private var trainingPlans: [TrainingPlan] = []
    @State private var isBuilding = false
    @State private var isPlanning = false
    @State private var sendingPlanID: UUID?
    @State private var sentPlanID: UUID?
    @State private var sendCount = 0
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Group {
                if plans.isEmpty && trainingPlans.isEmpty {
                    ContentUnavailableView {
                        Label("No workouts", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("Build a workout and send it to your watch.")
                    } actions: {
                        Button("New workout") { isBuilding = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !trainingPlans.isEmpty {
                            Section("Training plans") {
                                ForEach(trainingPlans) { plan in
                                    NavigationLink(plan.name) { TrainingPlanView(plan: plan) }
                                }
                            }
                        }
                        if !plans.isEmpty {
                            Section("Workouts") {
                                ForEach(plans) { plan in
                                    row(plan)
                                }
                                .onDelete { plans.remove(atOffsets: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New training plan", systemImage: "calendar.badge.plus") { isPlanning = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New workout", systemImage: "plus") { isBuilding = true }
                }
            }
            .sheet(isPresented: $isBuilding) {
                WorkoutBuilderView { plans.append($0) }
            }
            .sheet(isPresented: $isPlanning) {
                TrainingPlanEditor(workouts: plans) { trainingPlans.append($0) }
            }
            .onChange(of: plans) { _, new in WorkoutLibrary.plans = new }
            .sensoryFeedback(.success, trigger: sendCount)
            .alert("Couldn't send the workout", isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } })
            ) {} message: {
                Text(sendError ?? "")
            }
        }
    }

    private func row(_ plan: WorkoutPlan) -> some View {
        HStack(spacing: 14) {
            Image(systemName: plan.sport.symbol)
                .font(.title3)
                .foregroundStyle(plan.sport.tint)
                .frame(width: 44, height: 44)
                .background(plan.sport.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name)
                    .font(.headline)
                Text("\(plan.sport.title), \(plan.steps.count) steps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                send(plan)
            } label: {
                if sendingPlanID == plan.id {
                    ProgressView()
                } else if sentPlanID == plan.id {
                    Image(systemName: "checkmark")
                        .symbolEffect(.bounce, value: sendCount)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(sendingPlanID != nil)
            .accessibilityLabel("Send \(plan.name) to the watch")
        }
        .padding(.vertical, 4)
    }

    private func send(_ plan: WorkoutPlan) {
        sendingPlanID = plan.id
        Task {
            do {
                try await app.watch.sendWorkout(plan)
                sentPlanID = plan.id
                sendCount += 1
            } catch {
                sendError = error.localizedDescription
            }
            sendingPlanID = nil
        }
    }
}
