import Foundation
import GarminModels

/// Errors of the Garmin Connect client. The descriptions are shown to the user.
public enum GarminConnectError: Error, Equatable, Sendable, LocalizedError {
    /// Garmin refused the sign-in, with its status type, e.g. INVALID_USERNAME_PASSWORD.
    case signInRejected(String)
    case notSignedIn
    case malformedResponse
    case http(Int)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .signInRejected(type): "Garmin refused the sign-in (\(type))."
        case .notSignedIn: "Sign in to Garmin Connect first."
        case .malformedResponse: "Garmin sent a response OpenGarmin does not understand."
        case let .http(status): "Garmin Connect answered with HTTP \(status)."
        case let .keychain(status): "The sign-in could not be saved to the Keychain (\(status))."
        }
    }
}

/// Signs in to Garmin Connect and reads the account's data, the way garth does. The password goes to Garmin's SSO once
/// and is not kept. The OAuth tokens are kept in the Keychain, and the OAuth2 access token is renewed when it expires.
public actor GarminConnectClient {
    public enum SignIn: Equatable, Sendable {
        case signedIn
        /// Garmin sent a code by this method, e.g. "email". Finish the sign-in with `submitMFA`.
        case mfaRequired(method: String)
    }

    private var session = URLSession(configuration: .ephemeral)
    private var credentials: ConnectCredentials?
    private var mfaMethod: String?

    public init() {
        credentials = ConnectKeychain.load()
    }

    public var isSignedIn: Bool { credentials != nil }

    // MARK: - Sign-in

    public func signIn(email: String, password: String) async throws -> SignIn {
        // A new session per sign-in, so the SSO cookies of an earlier attempt do not leak into this one.
        session = URLSession(configuration: .ephemeral)
        _ = try await send(ConnectRequests.ssoPage())
        let data = try await send(ConnectRequests.login(email: email, password: password))
        switch try ConnectParsing.sso(data) {
        case let .ticket(ticket):
            try await completeSignIn(ticket: ticket)
            return .signedIn
        case let .mfaRequired(method):
            mfaMethod = method
            return .mfaRequired(method: method)
        case let .rejected(type):
            throw GarminConnectError.signInRejected(type)
        }
    }

    public func submitMFA(code: String) async throws {
        guard let method = mfaMethod else { throw GarminConnectError.notSignedIn }
        let data = try await send(ConnectRequests.verifyMFA(code: code, method: method))
        switch try ConnectParsing.sso(data) {
        case let .ticket(ticket):
            mfaMethod = nil
            try await completeSignIn(ticket: ticket)
        case let .rejected(type):
            throw GarminConnectError.signInRejected(type)
        case .mfaRequired:
            throw GarminConnectError.signInRejected("MFA_REQUIRED")
        }
    }

    public func signOut() {
        credentials = nil
        mfaMethod = nil
        ConnectKeychain.delete()
    }

    // MARK: - Data

    /// One page of the activity list between two calendar days, newest first.
    public func activities(start: Int, limit: Int, from: Date, to: Date, calendar: Calendar = .current) async throws
        -> [ConnectActivity] {
        let query = ConnectRequests.activitiesQuery(start: start, limit: limit, from: from, to: to, calendar: calendar)
        return try ConnectParsing.activities(await get(ConnectRequests.activitiesPath, query: query))
    }

    /// The FIT file in an activity's original download, a zip archive. Nil when the archive holds no FIT file.
    public func originalFIT(id: Int64) async throws -> Data? {
        let archive = try await get(ConnectRequests.originalActivityPath(id), query: [])
        return try ZipArchive.entries(archive).first { $0.name.lowercased().hasSuffix(".fit") }?.data
    }

    /// Stress and Body Battery of one calendar day, as a batch that holds only those two.
    public func dailyBatch(day: Date, calendar: Calendar = .current) async throws -> HealthBatch {
        let path = ConnectRequests.dailyStressPath(ConnectRequests.day(day, calendar: calendar))
        let (stress, bodyBattery) = try ConnectParsing.dailyStress(await get(path, query: []))
        var batch = HealthBatch()
        batch.stress = stress
        batch.bodyBattery = bodyBattery
        return batch
    }

    // MARK: - Tokens

    private func completeSignIn(ticket: String) async throws {
        // Garth loads this page so Garmin's backend pinning cookie is set. Failing here is harmless.
        _ = try? await send(ConnectRequests.portalEmbed())
        let consumer = try ConnectParsing.consumer(await send(URLRequest(url: ConnectRequests.consumerURL)))
        let signer = OAuth1Signer(consumerKey: consumer.key, consumerSecret: consumer.secret)
        let oauth1 = try ConnectParsing.oauth1Token(
            await send(ConnectRequests.preauthorized(ticket: ticket, signer: signer)))
        let access = try await exchange(oauth1: oauth1, consumer: consumer, login: true)
        let saved = ConnectCredentials(consumer: consumer, oauth1: oauth1, access: access)
        try ConnectKeychain.save(saved)
        credentials = saved
    }

    private func exchange(oauth1: ConnectOAuth1Token, consumer: ConnectConsumer, login: Bool) async throws
        -> ConnectAccessToken {
        let signer = OAuth1Signer(consumerKey: consumer.key, consumerSecret: consumer.secret,
                                  token: oauth1.token, tokenSecret: oauth1.secret)
        let request = ConnectRequests.exchange(oauth1: oauth1, signer: signer, login: login)
        return try ConnectParsing.accessToken(await send(request), now: .now)
    }

    /// The access token, renewed first when it is about to expire.
    private func accessToken() async throws -> ConnectAccessToken {
        guard var saved = credentials else { throw GarminConnectError.notSignedIn }
        if saved.access.expiresAt > Date.now.addingTimeInterval(60) { return saved.access }
        saved.access = try await exchange(oauth1: saved.oauth1, consumer: saved.consumer, login: false)
        try ConnectKeychain.save(saved)
        credentials = saved
        return saved.access
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        let access = try await accessToken()
        return try await send(ConnectRequests.apiRequest(path, query: query, accessToken: access))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GarminConnectError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw GarminConnectError.http(http.statusCode) }
        return data
    }
}
