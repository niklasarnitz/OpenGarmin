import Foundation
import GarminModels

/// What the session keeps between launches: the paired watch and the user's profile, in UserDefaults. The history and
/// the raw FIT files live in `directory`, owned by the import stage (`HistoryStore`).
@MainActor
public final class SessionStore {
    private static let pairedWatchKey = "garmin.pairedWatch"
    private static let userProfileKey = "garmin.userProfile"

    public let directory: URL
    private let defaults: UserDefaults

    public init(directory: URL, defaults: UserDefaults = .standard) throws {
        self.directory = directory
        self.defaults = defaults
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The store in the app's Application Support directory.
    public static func standard() throws -> SessionStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try SessionStore(directory: support.appendingPathComponent("OpenGarmin", isDirectory: true))
    }

    public var pairedWatch: PairedWatch? {
        get {
            defaults.data(forKey: Self.pairedWatchKey).flatMap { try? JSONDecoder().decode(PairedWatch.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.pairedWatchKey)
            } else {
                defaults.removeObject(forKey: Self.pairedWatchKey)
            }
        }
    }

    /// The profile the user last saved. It is sent to the watch after every handshake.
    public var userProfile: UserProfile? {
        get {
            defaults.data(forKey: Self.userProfileKey).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.userProfileKey)
            } else {
                defaults.removeObject(forKey: Self.userProfileKey)
            }
        }
    }
}
