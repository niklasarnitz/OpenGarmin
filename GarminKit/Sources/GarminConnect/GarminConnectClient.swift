import Foundation
import GarminModels

/// Errors of the Garmin Connect client. The descriptions are shown to the user.
public enum GarminConnectError: Error, Equatable, Sendable, LocalizedError {
    /// Garmin refused the sign-in, with its status type, e.g. INVALID_USERNAME_PASSWORD.
    case signInRejected(String)
    case notSignedIn
    case malformedResponse
    case http(Int)
    /// Garmin answered HTTP 429. `retryAfter` is the Retry-After header in seconds, when it sent one.
    case rateLimited(retryAfter: Double?)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .signInRejected(type): "Garmin refused the sign-in (\(type))."
        case .notSignedIn: "Sign in to Garmin Connect first."
        case .malformedResponse: "Garmin sent a response OpenGarmin does not understand."
        case let .http(status): "Garmin Connect answered with HTTP \(status)."
        case .rateLimited: "Garmin Connect is limiting requests. The import waits and tries again."
        case let .keychain(status): "The sign-in could not be saved to the Keychain (\(status))."
        }
    }
}

/// Signs in to Garmin Connect and reads the account's data, the way garth does. The password goes to Garmin's SSO once
/// and is not kept. The OAuth tokens are kept in the Keychain, and the OAuth2 access token is renewed when it expires.
///
/// Every Connect API call takes one of three request slots, so the import never has more than three requests in flight,
/// and it waits out Garmin's rate limit. Each response is kept in the raw store before it is parsed.
public actor GarminConnectClient {
    public enum SignIn: Equatable, Sendable {
        case signedIn
        /// Garmin sent a code by this method, e.g. "email". Finish the sign-in with `submitMFA`.
        case mfaRequired(method: String)
    }

    private var session: URLSession
    private var credentials: ConnectCredentials?
    private var mfaMethod: String?
    private let raw: ConnectRawStore
    private let limiter = ConnectRequestLimiter(limit: 3)

    public init(raw: ConnectRawStore) {
        self.init(raw: raw, session: URLSession(configuration: .ephemeral), credentials: ConnectKeychain.load())
    }

    init(raw: ConnectRawStore, session: URLSession, credentials: ConnectCredentials?) {
        self.raw = raw
        self.session = session
        self.credentials = credentials
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

    /// One page of the activity list between two calendar days, newest first. nil days list every activity.
    public func activities(start: Int, limit: Int, from: Date?, to: Date?, calendar: Calendar = .current) async throws
        -> [ConnectActivity] {
        let query = ConnectRequests.activitiesQuery(start: start, limit: limit, from: from, to: to, calendar: calendar)
        let body = try await get(ConnectRequests.activitiesPath, query: query)
        let range = [from, to].map { $0.map { ConnectRequests.day($0, calendar: calendar) } ?? "all" }
        try raw.save(body, endpoint: "activities", name: "\(range[0])_\(range[1])_\(start)")
        return try ConnectParsing.activities(body)
    }

    /// The FIT file in an activity's original download, a zip archive. Nil when the archive holds no FIT file.
    public func originalFIT(id: Int64) async throws -> Data? {
        let archive = try await get(ConnectRequests.originalActivityPath(id), query: [])
        return try ZipArchive.entries(archive).first { $0.name.lowercased().hasSuffix(".fit") }?.data
    }

    /// The kinds asked for from one calendar day. A response already in the raw store is parsed from there, when
    /// `useArchive` is set; otherwise Garmin is asked, and each non-empty response is kept before it is parsed. A kind
    /// Garmin has no data for comes back empty.
    public func dailyData(day: Date, kinds: Set<ConnectDayKind>, useArchive: Bool, calendar: Calendar = .current) async throws
        -> [ConnectDayKind: HealthBatch] {
        let date = ConnectRequests.day(day, calendar: calendar)
        return try await ConnectDaily.resolve(kinds, day: day, calendar: calendar) { endpoint in
            if useArchive, let body = self.raw.load(endpoint: endpoint, name: date) { return body }
            let body = try await self.fetchDay(endpoint, date: date)
            if !body.isEmpty { try self.raw.save(body, endpoint: endpoint, name: date) }
            return body
        }
    }

    /// The body of one daily endpoint for a date "yyyy-MM-dd". Garmin answers a day without data with 404, which reads as
    /// an empty body.
    private func fetchDay(_ endpoint: String, date: String) async throws -> Data {
        let dayItem = [URLQueryItem(name: "date", value: date)]
        switch endpoint {
        case "dailyStress":
            return try await dayData(ConnectRequests.dailyStressPath(date), query: [])
        case "dailySleepData":
            return try await dayData(ConnectRequests.dailySleepPath(try await displayName()),
                                     query: dayItem + [URLQueryItem(name: "nonSleepBufferMinutes", value: "60")])
        case "dailySummaryChart":
            return try await dayData(ConnectRequests.stepsChartPath(try await displayName()), query: dayItem)
        case "usersummary":
            return try await dayData(ConnectRequests.dailySummaryPath(try await displayName()),
                                     query: [URLQueryItem(name: "calendarDate", value: date)])
        case "hrv":
            return try await dayData(ConnectRequests.hrvPath(date), query: [])
        default:
            throw GarminConnectError.malformedResponse
        }
    }

    /// The display name of the account, read once and kept with the credentials.
    private func displayName() async throws -> String {
        if let name = credentials?.displayName { return name }
        let name = try ConnectParsing.displayName(await get(ConnectRequests.socialProfilePath, query: []))
        // Read the credentials again: the call above may have renewed the access token.
        guard var saved = credentials else { throw GarminConnectError.notSignedIn }
        saved.displayName = name
        try ConnectKeychain.save(saved)
        credentials = saved
        return name
    }

    /// The body of a per-day endpoint. Garmin answers a day without data with 404, which reads as an empty body.
    private func dayData(_ path: String, query: [URLQueryItem]) async throws -> Data {
        do {
            return try await get(path, query: query)
        } catch GarminConnectError.http(404) {
            return Data()
        }
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

    /// One Connect API call: it holds a request slot, and waits out a rate limit before it is sent again.
    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        try await limiter.run {
            try await retryingWhenRateLimited {
                let access = try await self.accessToken()
                return try await self.send(ConnectRequests.apiRequest(path, query: query, accessToken: access))
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GarminConnectError.malformedResponse }
        if http.statusCode == 429 {
            throw GarminConnectError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        guard (200..<300).contains(http.statusCode) else { throw GarminConnectError.http(http.statusCode) }
        return data
    }
}
