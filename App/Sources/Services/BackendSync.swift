import Foundation
import GarminBackend
import Observation

/// Uploads what the backend lacks: the watch's FIT files and the Garmin Connect batches. It runs in the background after
/// every import, one run at a time. A request during a run starts one more run after it, so the newest data is always sent.
@MainActor
@Observable
final class BackendSync {
    static let serverKey = "backend.server"
    static let defaultServer = "https://opengarmin.arnitz.org"
    private static let lastUploadKey = "backend.lastUpload"
    private static let rejectionsKey = "backend.rejected"

    /// The files the server refused, kept with the app version they were refused under. A new version tries them again.
    private struct Rejections: Codable {
        var appVersion: String
        var files: [String: String]
    }

    private(set) var isUploading = false
    private(set) var lastUpload: Date? = UserDefaults.standard.object(forKey: BackendSync.lastUploadKey) as? Date
    private(set) var pending = 0
    /// The files the server refused, by key, with its reason. Automatic runs skip them.
    private(set) var rejected: [String: String] = BackendSync.storedRejections()
    private(set) var lastError: String?

    /// The one-time upload of the whole Apple Health history. It uses this sync's client factory.
    let healthKit: HealthKitBackfill
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var retryRequested = false

    /// - Parameter directory: the app's Application Support folder, where the import stage keeps the files.
    init(directory: URL) {
        self.directory = directory
        healthKit = HealthKitBackfill { try? BackendSync.client() }
    }

    /// Starts an upload run unless one is going. Does nothing until the user has signed in. Automatic runs skip the files
    /// the server refused; `retryRejected` tries them again too.
    func requestUpload(retryRejected: Bool = false) {
        retryRequested = retryRequested || retryRejected
        guard !isUploading else {
            rerun = true
            return
        }
        isUploading = true
        Task {
            repeat {
                rerun = false
                let retry = retryRequested
                retryRequested = false
                await upload(retryRejected: retry)
            } while rerun
            isUploading = false
        }
    }

    private func upload(retryRejected: Bool) async {
        do {
            guard let client = try Self.client() else { return }
            let report = await BackendUploader.run(directory: directory, client: client,
                                                   rejected: retryRejected ? [:] : rejected)
            pending = report.pending
            rejected = report.rejected
            saveRejections()
            lastError = report.failure?.localizedDescription
            if report.failure == nil {
                lastUpload = .now
                UserDefaults.standard.set(lastUpload, forKey: Self.lastUploadKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The client for the signed-in account, or nil when no one is signed in. Throws when the server URL is not valid.
    static func client() throws -> BackendClient? {
        guard let token = BackendKeychain.token() else { return nil }
        return try BackendClient(server: UserDefaults.standard.string(forKey: serverKey) ?? defaultServer, token: token)
    }

    private func saveRejections() {
        let stored = Rejections(appVersion: Self.appVersion, files: rejected)
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.rejectionsKey)
    }

    private static func storedRejections() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: rejectionsKey),
              let stored = try? JSONDecoder().decode(Rejections.self, from: data),
              stored.appVersion == appVersion else { return [:] }
        return stored.files
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }
}
