import SwiftUI
import GarminConnect
import GarminSession

/// Imports the watch's history from a Garmin Connect account: the original files of the activities and the daily data of
/// a range. Reached from the Device screen. The import runs in `ConnectImportModel`, which the app keeps.
struct ConnectImportView: View {
    let model: ConnectImportModel
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var days = 90

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
                Text("All").tag(0)
            }
            .pickerStyle(.segmented)
            .disabled(model.isImporting)
            if model.isImporting {
                Button("Cancel", systemImage: "xmark.circle", role: .cancel) {
                    model.cancelImport()
                }
                .buttonStyle(.glass)
            } else {
                Button("Import", systemImage: "arrow.down.circle.fill") {
                    model.importRange(days: days)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy)
            }
            if let progress = model.progress {
                progressDetails(progress)
            }
            if let summary = model.summary {
                Text(LocalizedStringKey(summary))
                    .font(.footnote)
            }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.signOut()
            }
            .buttonStyle(.glass)
            .disabled(model.isBusy || model.isImporting)
        }
    }

    @ViewBuilder
    private func progressDetails(_ progress: ConnectImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.total > 0 {
                ProgressView(value: Double(model.done), total: Double(model.total))
            }
            Text("Activities \(progress.activities.done) of \(progress.activityTotal)")
            Text("Days \(progress.days.done) of \(progress.dayTotal ?? 0)")
            Text("Imported \(model.imported) · Already there \(model.skipped) · Failed \(model.failed)")
            if let perMinute = model.itemsPerMinute {
                Text("\(Int(perMinute)) per minute")
            }
            if let left = model.timeLeft {
                Text("Time left: \(left)")
            }
            if let failure = progress.lastFailure {
                Text("Last failure: \(failure)")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Drives the Garmin Connect import: sign-in, the verification code, and the import of a range of days. The import runs
/// in the app's environment, so it goes on when the user leaves the screen. Its days and activities go to the watch's
/// import stage, which reaches Health and the backend the same way the watch's own files do.
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
    private(set) var isImporting = false
    /// The counts of the last import, and of the one running.
    private(set) var progress: ConnectImportProgress?
    private(set) var summary: String?
    private(set) var errorMessage: String?
    private var startedAt: Date?

    @ObservationIgnored private let client: GarminConnectClient
    @ObservationIgnored private let watch: GarminWatchService
    @ObservationIgnored private let backend: BackendSync
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(watch: GarminWatchService, raw: ConnectRawStore, backend: BackendSync) {
        self.watch = watch
        self.backend = backend
        client = GarminConnectClient(raw: raw)
    }

    // MARK: - Progress

    /// Activities and days together, done and in all.
    var done: Int { counts { $0.done } }
    var total: Int { (progress?.activityTotal ?? 0) + (progress?.dayTotal ?? 0) }
    var imported: Int { counts { $0.imported } }
    var skipped: Int { counts { $0.skipped } }
    var failed: Int { counts { $0.failed } }

    /// Fraction of the import done, 0 to 1.
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// Items per minute since the import started. Nil before the first item is done.
    var itemsPerMinute: Double? {
        guard isImporting, let startedAt, done > 0 else { return nil }
        let minutes = Date.now.timeIntervalSince(startedAt) / 60
        return minutes > 0 ? Double(done) / minutes : nil
    }

    /// The time left at the pace so far, as text. Nil until there is a pace and something is left.
    var timeLeft: String? {
        guard isImporting, let startedAt, done > 0, total > done else { return nil }
        let left = Date.now.timeIntervalSince(startedAt) / Double(done) * Double(total - done)
        return Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    private func counts(_ value: (ConnectImportProgress.Counts) -> Int) -> Int {
        guard let progress else { return 0 }
        return value(progress.activities) + value(progress.days)
    }

    // MARK: - Sign-in

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

    /// Runs one sign-in step and shows its failure. A `notSignedIn` failure returns the phase to signed out.
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
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

    // MARK: - Import

    /// Starts an import of the range, in the background. Does nothing while one runs.
    func importRange(days: Int) {
        guard !isImporting else { return }
        isImporting = true
        startedAt = .now
        progress = nil
        summary = nil
        errorMessage = nil
        importTask = Task {
            defer {
                isImporting = false
                importTask = nil
                // The raw responses and the imported days go to the backend, which the import stage does not signal for
                // responses it only archived.
                backend.requestUpload()
            }
            do {
                let unit = watch.pairedWatch?.info?.unitNumber ?? 0
                _ = try await ConnectImport.run(days: days, unit: unit, source: client, sink: watch) { self.progress = $0 }
                summary = Task.isCancelled ? "Import cancelled." : "Import finished."
            } catch {
                if let connectError = error as? GarminConnectError, connectError == .notSignedIn {
                    phase = .signedOut
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }
}

/// The watch's import stage as the Connect import sees it. A key is imported, checked empty, or missing.
extension GarminWatchService: @retroactive ConnectImportSink {
    public func importState(of key: String) async -> ConnectKeyState {
        if await hasImported(key) { return .imported }
        return await wasChecked(key) ? .checkedEmpty : .missing
    }
}
