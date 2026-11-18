import Foundation

/// The app's key pair for Garmin's OAuth, downloaded from the public consumer file garth uses.
struct ConnectConsumer: Codable, Sendable, Equatable {
    var key: String
    var secret: String

    enum CodingKeys: String, CodingKey {
        case key = "consumer_key"
        case secret = "consumer_secret"
    }
}

/// The long-lived OAuth1 token. Garth exchanges it for an OAuth2 access token whenever that expires, so the password
/// is needed only for the sign-in itself.
struct ConnectOAuth1Token: Codable, Sendable, Equatable {
    var token: String
    var secret: String
    /// Garmin sends it when the account needs MFA; the token exchange takes it along.
    var mfaToken: String?
}

struct ConnectAccessToken: Codable, Sendable, Equatable {
    var value: String
    var type: String
    var expiresAt: Date
}

/// What the account keeps in the Keychain.
struct ConnectCredentials: Codable, Sendable, Equatable {
    var consumer: ConnectConsumer
    var oauth1: ConnectOAuth1Token
    var access: ConnectAccessToken
}
