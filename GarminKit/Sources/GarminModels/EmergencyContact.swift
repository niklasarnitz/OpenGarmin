import Foundation

/// A person the watch can show as an emergency contact for incident detection. Picked from the phone's contacts.
public struct EmergencyContact: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var phoneNumber: String

    public init(id: UUID = UUID(), name: String, phoneNumber: String) {
        self.id = id; self.name = name; self.phoneNumber = phoneNumber
    }
}
