import SwiftUI
import GarminModels

struct WorkoutBuilderView: View {
    let onSave: (WorkoutPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "New workout")
    @State private var sport: Sport = .running
    @State private var steps: [WorkoutStep] = []
    @State private var isAddingStep = false

    private static let sports: [Sport] = [.running, .cycling, .walking, .hiking, .swimming, .rowing, .training, .hiit, .fitnessEquipment]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Sport", selection: $sport) {
                        ForEach(Self.sports, id: \.self) { sport in
                            Label(sport.title, systemImage: sport.symbol).tag(sport)
                        }
                    }
                }
                Section {
                    ForEach(steps) { step in
                        StepRow(step: step)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add step", systemImage: "plus") { isAddingStep = true }
                } header: {
                    Text("Steps")
                } footer: {
                    if steps.isEmpty {
                        Text("A workout needs at least one step.")
                    }
                }
            }
            .navigationTitle("New workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(steps.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(WorkoutPlan(name: name, sport: sport, steps: steps))
                        dismiss()
                    }
                    .disabled(steps.isEmpty)
                }
            }
            .sheet(isPresented: $isAddingStep) {
                StepEditor(stepCount: steps.count) { steps.append($0) }
            }
        }
    }
}

/// Adds one step: intensity, how it ends, and an optional target. Repeats point back at an earlier step.
struct StepEditor: View {
    let stepCount: Int
    let onAdd: (WorkoutStep) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "Interval")
    @State private var intensity: WorkoutIntensity = .active
    @State private var ending: Ending = .time
    @State private var minutes = 5
    @State private var metres = 1000
    @State private var repeatFrom = 1
    @State private var repeatCount = 4
    @State private var targetKind: TargetKind = .off
    @State private var zone = 2
    @State private var fastestPace = 300
    @State private var slowestPace = 330

    enum Ending: CaseIterable, Identifiable {
        case time, distance, open, repeatSteps
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .time: "Time"
            case .distance: "Distance"
            case .open: "Open"
            case .repeatSteps: "Repeat"
            }
        }
    }

    enum TargetKind: CaseIterable, Identifiable {
        case off, heartRateZone, pace
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .off: "None"
            case .heartRateZone: "Heart rate zone"
            case .pace: "Pace"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Intensity", selection: $intensity) {
                        ForEach(WorkoutIntensity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("Ends by") {
                    Picker("Ends by", selection: $ending) {
                        ForEach(Ending.allCases) { Text($0.title).tag($0) }
                    }
                    switch ending {
                    case .time:
                        Stepper("\(minutes) min", value: $minutes, in: 1...180)
                    case .distance:
                        Stepper("\(metres) m", value: $metres, in: 100...10_000, step: 100)
                    case .open:
                        Text("Ends when you press lap on the watch.")
                            .foregroundStyle(.secondary)
                    case .repeatSteps:
                        Stepper("Repeat from step \(repeatFrom)", value: $repeatFrom, in: 1...max(stepCount, 1))
                        Stepper("\(repeatCount) times", value: $repeatCount, in: 2...20)
                    }
                }
                if ending != .repeatSteps {
                    Section("Target") {
                        Picker("Target", selection: $targetKind) {
                            ForEach(TargetKind.allCases) { Text($0.title).tag($0) }
                        }
                        switch targetKind {
                        case .off:
                            EmptyView()
                        case .heartRateZone:
                            Stepper("Zone \(zone)", value: $zone, in: 1...5)
                        case .pace:
                            Stepper("Fastest \(Formatting.pace(secondsPerKilometre: Double(fastestPace))) /km",
                                    value: $fastestPace, in: 180...600, step: 5)
                            Stepper("Slowest \(Formatting.pace(secondsPerKilometre: Double(slowestPace))) /km",
                                    value: $slowestPace, in: 180...600, step: 5)
                        }
                    }
                }
            }
            .navigationTitle("Add step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(WorkoutStep(name: name, intensity: intensity, duration: duration, target: target))
                        dismiss()
                    }
                }
            }
        }
    }

    private var duration: WorkoutDurationType {
        switch ending {
        case .time: .time(seconds: minutes * 60)
        case .distance: .distance(meters: metres)
        case .open: .open
        case .repeatSteps: .repeatUntilStepsComplete(fromStep: repeatFrom - 1, count: repeatCount)
        }
    }

    private var target: WorkoutTarget {
        guard ending != .repeatSteps else { return .none }
        switch targetKind {
        case .off: return .none
        case .heartRateZone: return .heartRateZone(zone)
        case .pace: return .paceRange(lowSecondsPerKm: fastestPace, highSecondsPerKm: slowestPace)
        }
    }
}

extension WorkoutIntensity {
    var title: String {
        switch self {
        case .active: String(localized: "Active")
        case .rest: String(localized: "Rest")
        case .warmup: String(localized: "Warm up")
        case .cooldown: String(localized: "Cool down")
        case .recovery: String(localized: "Recovery")
        case .interval: String(localized: "Interval")
        }
    }

    var tint: Color {
        switch self {
        case .active: Palette.blaze
        case .rest: .secondary
        case .warmup, .cooldown: Palette.lichen
        case .recovery: Palette.glacier
        case .interval: Palette.ember
        }
    }
}

extension WorkoutStep {
    var summary: String {
        let ending: String
        switch duration {
        case .time(let seconds): ending = String(localized: "\(seconds / 60) min")
        case .distance(let meters): ending = String(localized: "\(meters) m")
        case .open: ending = String(localized: "Open")
        case .repeatUntilStepsComplete(let from, let count):
            ending = String(localized: "Repeat \(count) times from step \(from + 1)")
        default: ending = String(localized: "Custom")
        }
        switch target {
        case .none: return ending
        case .heartRateZone(let zone): return "\(ending), zone \(zone)"
        case .heartRateRange(let low, let high): return "\(ending), \(low)–\(high) bpm"
        case .paceRange(let low, let high):
            return "\(ending), \(Formatting.pace(secondsPerKilometre: Double(low)))–\(Formatting.pace(secondsPerKilometre: Double(high))) /km"
        case .cadenceRange(let low, let high): return "\(ending), \(low)–\(high) spm"
        case .powerRange(let low, let high): return "\(ending), \(low)–\(high) W"
        }
    }
}

private struct StepRow: View {
    let step: WorkoutStep

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(step.intensity.tint)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name ?? step.intensity.title)
                    .font(.headline)
                Text(step.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
