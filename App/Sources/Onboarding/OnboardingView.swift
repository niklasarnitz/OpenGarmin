import SwiftUI
import GarminModels
import GarminSession

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(AppEnvironment.self) private var app
    @State private var step: Step = .welcome
    @State private var permissions = PermissionCenter()
    @State private var chosen: NearbyWatch?
    @State private var ringProgress = 0.0
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -35, to: .now)!
    @State private var gender: UserProfile.Gender?
    @State private var heightCm = 178.0
    @State private var weightKg = 75.0
    @State private var profileError: String?

    enum Step: Int, CaseIterable {
        case welcome, sync, permissions, search, pair, profile, firstSync, done
    }

    private struct Feature: Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private let features = [
        Feature(title: "Heart and recovery", detail: "Heart rate, stress, body battery, SpO2, HRV and respiration.",
                symbol: "heart.fill", tint: Palette.ember),
        Feature(title: "Sleep", detail: "Stages, hypnogram and sleep score from last night.",
                symbol: "bed.double.fill", tint: Palette.dusk),
        Feature(title: "Steps and activities", detail: "Daily totals, runs and rides with routes, laps and metrics.",
                symbol: "figure.run", tint: Palette.blaze),
        Feature(title: "Workouts to the watch", detail: "Build intervals on your phone and send them to the watch.",
                symbol: "paperplane.fill", tint: Palette.glacier),
    ]

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.bottom, 28)
            page
                .id(step)
                .transition(.push(from: .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(24)
        .background(Color.canvas.ignoresSafeArea())
        .animation(.smooth, value: step)
        .interactiveDismissDisabled()
    }

    // MARK: - Chrome

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Palette.blaze : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .sensoryFeedback(.selection, trigger: step)

            if step != .welcome && step != .firstSync && step != .done {
                Button("Back") { go(-1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if step == .profile && profileError != nil {
                Button("Continue anyway") { go(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .pair:
            app.watch.pairedWatch == nil ? "Pair \(Formatting.deviceName(chosen?.catalogID))" : "Continue"
        case .profile: "Save profile"
        case .done: "Open OpenGarmin"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .search: chosen != nil
        case .pair: chosen != nil && !isPairing
        case .firstSync: !app.watch.state.isSyncing
        default: true
        }
    }

    private var isPairing: Bool {
        if case .pairing = app.watch.state { return true }
        return false
    }

    private func primaryAction() {
        switch step {
        case .done:
            onFinish()
        case .pair where app.watch.pairedWatch == nil:
            guard let chosen else { return }
            Task { try? await app.watch.pair(chosen) }
        case .profile:
            Task {
                do {
                    try await app.watch.updateProfile(profile)
                    profileError = nil
                    go(1)
                } catch {
                    profileError = "Couldn't send the profile to the watch: \(error.localizedDescription) It is saved and goes to the watch when it next connects."
                }
            }
        default:
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }

    private var profile: UserProfile {
        UserProfile(birthDate: birthDate, gender: gender, heightCm: heightCm, weightKg: weightKg)
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcome
        case .sync: syncExplanation
        case .permissions: permissionList
        case .search: searchList
        case .pair: pairing
        case .profile: profileForm
        case .firstSync: firstSync
        case .done: finished
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.screenTitle)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(spacing: 32) {
            Spacer()
            RingGauge(progress: ringProgress, tint: Palette.blaze, lineWidth: 26)
                .frame(width: 220, height: 220)
                .overlay {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(Palette.glacier)
                }
            VStack(spacing: 10) {
                Text("OpenGarmin")
                    .font(.screenTitle)
                Text("Connect your Garmin watch directly. Health data, activities and notifications sync without Garmin Connect.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onAppear {
            withAnimation(.smooth(duration: 1.6).delay(0.2)) { ringProgress = 0.78 }
        }
    }

    private var syncExplanation: some View {
        VStack(alignment: .leading, spacing: 24) {
            header("What gets synced", "Your watch sends data to the iPhone. Apple Health keeps the history.")
            VStack(spacing: 12) {
                ForEach(features) { feature in
                    HStack(spacing: 14) {
                        Image(systemName: feature.symbol)
                            .font(.title3)
                            .foregroundStyle(feature.tint)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .tile()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionList: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Permissions", "Each one unlocks a feature. Change them later in Settings.")
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(AppPermission.allCases) { permission in
                        HStack(spacing: 14) {
                            Image(systemName: permission.symbol)
                                .font(.title3)
                                .foregroundStyle(Palette.blaze)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.title).font(.headline)
                                Text(permission.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if permissions.answered.contains(permission) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Palette.lichen)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Button("Allow") {
                                    Task { await permissions.request(permission) }
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        .tile()
                    }
                }
            }
        }
    }

    private var searchList: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Find your watch", "Keep the watch awake and near the iPhone. Garmin watches in pairing mode show up here.")
            if app.watch.nearby.isEmpty {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Searching")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(app.watch.nearby) { watch in
                            Button { chosen = watch } label: { watchRow(watch) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { app.watch.startScanning() }
        .onDisappear { app.watch.stopScanning() }
    }

    private func watchRow(_ watch: NearbyWatch) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "applewatch")
                .font(.title2)
                .foregroundStyle(Palette.blaze)
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatting.deviceName(watch.catalogID)).font(.headline)
                Text(watch.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "cellularbars", variableValue: min(max(Double(watch.rssi + 100) / 60, 0), 1))
                .foregroundStyle(Palette.glacier)
            if chosen == watch {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.blaze)
            }
        }
        .tile()
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Pair \(Formatting.deviceName(chosen?.catalogID))",
                   "iOS shows a pairing request. Confirm the code on the watch and on the phone.")
            if case .pairing(let hint) = app.watch.state {
                Label(hint ?? "Waiting for confirmation", systemImage: "lock.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.glacier)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Notifications arrive through iOS", systemImage: "bell.fill")
                    .font(.headline)
                Text("Once the watch is paired, iPhone notifications reach it through Apple's notification service. In Settings, open Bluetooth, tap the info button next to the watch and turn on Share System Notifications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .tile()
            Spacer(minLength: 0)
        }
    }

    private var profileForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Your profile", "Used for calories, heart zones and sleep. Prefilled from Apple Health.")
            Form {
                DatePicker("Birthday", selection: $birthDate, displayedComponents: .date)
                Picker("Sex", selection: $gender) {
                    Text("Not set").tag(UserProfile.Gender?.none)
                    Text("Female").tag(UserProfile.Gender?.some(.female))
                    Text("Male").tag(UserProfile.Gender?.some(.male))
                }
                Stepper("Height \(Int(heightCm)) cm", value: $heightCm, in: 120...220)
                Stepper("Weight \(Int(weightKg)) kg", value: $weightKg, in: 30...250)
            }
            .scrollContentBackground(.hidden)
            .task {
                let defaults = await HealthStore.profileDefaults()
                if let birthDate = defaults.birthDate { self.birthDate = birthDate }
                if let gender = defaults.gender { self.gender = gender }
                if let heightCm = defaults.heightCm { self.heightCm = heightCm }
                if let weightKg = defaults.weightKg { self.weightKg = weightKg }
            }
            if let profileError {
                Text(profileError)
                    .font(.footnote)
                    .foregroundStyle(Palette.ember)
            }
        }
    }

    private var firstSync: some View {
        VStack(spacing: 28) {
            Spacer()
            if case .syncing(let progress, let detail) = app.watch.state {
                RingGauge(progress: progress, tint: Palette.blaze, lineWidth: 22)
                    .frame(width: 220, height: 220)
                    .overlay {
                        MetricFigure(value: "\(Int(progress * 100))", unit: "%", size: 48)
                    }
                Text(detail)
                    .font(.headline)
                    .contentTransition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Starting sync")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .task { await app.watch.syncNow() }
    }

    private var finished: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(Palette.lichen)
                .symbolEffect(.bounce, value: step)
            Text("\(Formatting.deviceName(app.watch.pairedWatch?.catalogID)) is ready")
                .font(.screenTitle)
                .multilineTextAlignment(.center)
            Text("Today shows your latest data. Workouts and notifications sync from now on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
