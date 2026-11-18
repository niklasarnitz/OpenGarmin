import SwiftUI
import GarminConnect
import GarminSession

/// Imports the watch's history from a Garmin Connect account: the original files of the activities and the daily stress
/// and Body Battery of a range. Reached from the Device screen.
struct ConnectImportView: View {
    @State private var model: ConnectImportModel
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var days = 90

    init(watch: GarminWatchService) {
        _model = State(initialValue: ConnectImportModel(watch: watch))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch model.phase {
                case .signedOut: signInTile
                case let .mfa(method): verificationTile(method: method)
                case .signedIn: importTile
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Palette.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Garmin Connect")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }

    private var signInTile: some View {
        MetricTile("Sign in", symbol: "person.badge.key.fill", tint: Palette.dusk) {
            Text("Your password goes to Garmin once and is not stored. OpenGarmin keeps the sign-in tokens in the Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            Button("Sign in", systemImage: "person.crop.circle.badge.checkmark") {
                model.signIn(email: email, password: password)
                password = ""
            }
            .buttonStyle(.glassProminent)
            .disabled(email.isEmpty || password.isEmpty || model.isBusy)
        }
    }

    private func verificationTile(method: String) -> some View {
        MetricTile("Verification code", symbol: "key.fill", tint: Palette.dusk) {
            Text("Garmin sent a code by \(method). Enter it to finish signing in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            Button("Verify", systemImage: "checkmark") {
                model.submitMFA(code: code)
                code = ""
            }
            .buttonStyle(.glassProminent)
            .disabled(code.isEmpty || model.isBusy)
        }
    }

    private var importTile: some View {
        MetricTile("Import", symbol: "icloud.and.arrow.down", tint: Palette.glacier) {
            Text("Downloads the original files of your activities and the daily stress and Body Battery of the range. Data Garmin Connect already wrote to Health is not written again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Range", selection: $days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
            .pickerStyle(.segmented)
            Button("Import", systemImage: "arrow.down.circle.fill") {
                model.importRange(days: days)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isBusy)
            if let progress = model.progress {
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let summary = model.summary {
                Text(summary)
                    .font(.footnote)
            }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.signOut()
            }
            .buttonStyle(.glass)
            .disabled(model.isBusy)
        }
    }
}

/// Drives the Garmin Connect import: sign-in, the verification code, and the import of a range of days into the watch's
/// import stage, which reaches Health through the same path as the watch's own files.
@MainActor
@Observable
final class ConnectImportModel {
    enum Phase: Equatable {
        case signedOut
        case mfa(method: String)
        case signedIn
    }

    private(set) var phase = Phase.signedOut
    private(set) var isBusy = false
    private(set) var progress: String?
    private(set) var summary: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let client = GarminConnectClient()
    @ObservationIgnored private let watch: GarminWatchService

    init(watch: GarminWatchService) {
        self.watch = watch
    }

    func refresh() async {
        guard !isBusy else { return }
        phase = await client.isSignedIn ? .signedIn : .signedOut
    }

    func signIn(email: String, password: String) {
        perform {
            switch try await self.client.signIn(email: email, password: password) {
            case .signedIn: self.phase = .signedIn
            case let .mfaRequired(method): self.phase = .mfa(method: method)
            }
        }
    }

    func submitMFA(code: String) {
        perform {
            try await self.client.submitMFA(code: code)
            self.phase = .signedIn
        }
    }

    func signOut() {
        perform {
            await self.client.signOut()
            self.phase = .signedOut
            self.summary = nil
        }
    }

    func importRange(days: Int) {
        perform {
            self.summary = try await self.runImport(days: days)
        }
    }

    /// Runs one work item at a time and shows its failure. A sign-out failure is the only one that leaves the user signed
    /// in, so a `notSignedIn` failure returns the phase to signed out.
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer {
                isBusy = false
                progress = nil
            }
            do {
                try await work()
            } catch {
                if let connectError = error as? GarminConnectError, connectError == .notSignedIn {
                    phase = .signedOut
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Activities first, newest first, then the stress and Body Battery of each day up to yesterday. Today is left out
    /// because Body Battery is still changing; a day that was imported is skipped on the next run.
    private func runImport(days: Int) async throws -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dates = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = dates.first else { return "" }
        // Activities stored under the watch's unit number replace the watch's copy of the same activity in the history.
        let unit = watch.pairedWatch?.info?.unitNumber ?? 0

        let activities = try await listActivities(from: first, to: today, calendar: calendar)
        var importedActivities = 0
        for (index, activity) in activities.enumerated() {
            progress = "Activity \(index + 1) of \(activities.count)"
            let key = "\(unit)-connect-\(activity.id)"
            if await watch.hasImported(key) { continue }
            guard let fit = try await client.originalFIT(id: activity.id) else { continue }
            try await watch.importFITFile(fit, key: key)
            importedActivities += 1
        }

        var importedDays = 0
        for (index, date) in dates.enumerated() where date != today {
            progress = "Stress and Body Battery, day \(index + 1) of \(dates.count)"
            let key = "connect-daily-\(Int(date.timeIntervalSince1970))"
            if await watch.hasImported(key) { continue }
            let batch = try await client.dailyBatch(day: date, calendar: calendar)
            if batch.isEmpty { continue }
            try await watch.importBatch(batch, key: key)
            importedDays += 1
        }
        return "Imported \(importedActivities) activities and \(importedDays) days of stress and Body Battery."
    }

    /// Every activity between two calendar days, in pages of 100.
    private func listActivities(from first: Date, to last: Date, calendar: Calendar) async throws -> [ConnectActivity] {
        var all: [ConnectActivity] = []
        var start = 0
        while true {
            let page = try await client.activities(start: start, limit: 100, from: first, to: last, calendar: calendar)
            all += page
            if page.count < 100 { return all }
            start += 100
        }
    }
}
