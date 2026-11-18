import SwiftUI
import GarminModels

/// Edits the profile the watch uses for calories, heart zones and sleep. It starts from Apple Health and is sent on Save.
struct ProfileEditorView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -35, to: .now)!
    @State private var gender: UserProfile.Gender?
    @State private var heightCm = 178.0
    @State private var weightKg = 75.0
    @State private var restingHeartRate: Int?
    @State private var maxHeartRate: Int?
    @State private var usesMetricUnits = true
    @State private var uses24HourTime = true
    @State private var sleepTime = Calendar.current.date(from: DateComponents(hour: 23)) ?? .now
    @State private var wakeTime = Calendar.current.date(from: DateComponents(hour: 7)) ?? .now
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveCount = 0

    var body: some View {
        Form {
            Section("Body") {
                DatePicker("Birthday", selection: $birthDate, displayedComponents: .date)
                Picker("Sex", selection: $gender) {
                    Text("Not set").tag(UserProfile.Gender?.none)
                    Text("Female").tag(UserProfile.Gender?.some(.female))
                    Text("Male").tag(UserProfile.Gender?.some(.male))
                }
                Stepper("Height \(Int(heightCm)) cm", value: $heightCm, in: 120...220)
                Stepper("Weight \(Int(weightKg)) kg", value: $weightKg, in: 30...250)
                TextField("Resting heart rate", value: $restingHeartRate, format: .number)
                    .keyboardType(.numberPad)
                TextField("Max heart rate", value: $maxHeartRate, format: .number)
                    .keyboardType(.numberPad)
            }
            Section("Watch") {
                Toggle("Metric units", isOn: $usesMetricUnits)
                Toggle("24-hour clock", isOn: $uses24HourTime)
                DatePicker("Sleep", selection: $sleepTime, displayedComponents: .hourAndMinute)
                DatePicker("Wake up", selection: $wakeTime, displayedComponents: .hourAndMinute)
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(isSaving)
            }
        }
        .task {
            let defaults = await HealthStore.profileDefaults()
            if let birthDate = defaults.birthDate { self.birthDate = birthDate }
            if let gender = defaults.gender { self.gender = gender }
            if let heightCm = defaults.heightCm { self.heightCm = heightCm }
            if let weightKg = defaults.weightKg { self.weightKg = weightKg }
        }
        .sensoryFeedback(.success, trigger: saveCount)
        .alert("Couldn't send the profile", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })
        ) {} message: {
            Text(saveError ?? "")
        }
    }

    private var profile: UserProfile {
        let calendar = Calendar.current
        return UserProfile(birthDate: birthDate, gender: gender, heightCm: heightCm, weightKg: weightKg,
                           restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate,
                           usesMetricUnits: usesMetricUnits, uses24HourTime: uses24HourTime,
                           sleepTime: calendar.dateComponents([.hour, .minute], from: sleepTime),
                           wakeTime: calendar.dateComponents([.hour, .minute], from: wakeTime))
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await app.watch.updateProfile(profile)
                saveCount += 1
            } catch {
                saveError = String(localized: "\(error.localizedDescription) It is saved and goes to the watch when it next connects.")
            }
            isSaving = false
        }
    }
}
