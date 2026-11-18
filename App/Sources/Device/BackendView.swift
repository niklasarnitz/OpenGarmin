import SwiftUI
import GarminBackend

/// Signs in to the self-hosted backend and shows the upload status. Reached from the Device screen.
struct BackendView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(BackendSync.serverKey) private var server = BackendSync.defaultServer
    @AppStorage("backend.email") private var email = ""
    @State private var password = ""
    @State private var signedIn = BackendKeychain.token() != nil
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if signedIn { statusTile } else { signInTile }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Palette.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Backend")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var signInTile: some View {
        MetricTile("Sign in", symbol: "person.badge.key.fill", tint: Palette.dusk) {
            Text("Sign in to your backend account. The password is not stored; the session token is kept in the Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Server URL", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("Sign in", systemImage: "person.crop.circle.badge.checkmark") { authenticate(register: false) }
                    .buttonStyle(.glassProminent)
                Button("Create account", systemImage: "person.badge.plus") { authenticate(register: true) }
                    .buttonStyle(.glass)
            }
            .disabled(server.isEmpty || email.isEmpty || password.isEmpty || isBusy)
        }
    }

    private var statusTile: some View {
        MetricTile("Status", symbol: "icloud.and.arrow.up.fill", tint: Palette.glacier) {
            LabeledContent("Account", value: email)
            LabeledContent("Last upload", value: Formatting.lastSeen(app.backend.lastUpload))
            LabeledContent("Pending", value: "\(app.backend.pending)")
            if app.backend.isUploading {
                ProgressView("Uploading…")
            }
            if let error = app.backend.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Palette.ember)
            }
            if !app.backend.rejected.isEmpty {
                LabeledContent("Skipped", value: "\(app.backend.rejected.count)")
                ForEach(app.backend.rejected.sorted { $0.key < $1.key }, id: \.key) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.key)
                            .font(.footnote.weight(.medium))
                        Text(entry.value)
                            .font(.footnote)
                            .foregroundStyle(Palette.ember)
                    }
                }
                Text("The server refused these files. They are tried again after an app update or on Upload now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Uploaded after every import. Only what the server lacks is sent, and a failed upload is retried at the next import.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Upload now", systemImage: "arrow.up.circle.fill") { app.backend.requestUpload(retryRejected: true) }
                    .buttonStyle(.glassProminent)
                    .disabled(app.backend.isUploading)
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signOut() }
                    .buttonStyle(.glass)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }
    }

    private func authenticate(register: Bool) {
        let password = password
        self.password = ""
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                let client = try BackendClient(server: server)
                let session: BackendSession
                if register {
                    session = try await client.register(email: email, password: password)
                } else {
                    session = try await client.login(email: email, password: password)
                }
                try BackendKeychain.saveToken(session.token)
                signedIn = true
                app.backend.requestUpload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The token is removed at once; the server is told in the background, so sign-out works while it is unreachable.
    private func signOut() {
        let token = BackendKeychain.token()
        let server = server
        BackendKeychain.deleteToken()
        signedIn = false
        Task {
            guard let client = try? BackendClient(server: server, token: token) else { return }
            try? await client.logout()
        }
    }
}
