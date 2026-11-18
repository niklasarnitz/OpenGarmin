import Foundation
import GarminFIT
import GarminModels

extension GFDISession {
    /// Pushes the user profile to the watch as a settings file, the way Gadgetbridge writes its settings files.
    func sendProfile(_ profile: UserProfile, now: Date = .now) async throws {
        try await transferFile(UserProfileFitEncoder.encode(profile, now: now), subType: 2)
    }
}
