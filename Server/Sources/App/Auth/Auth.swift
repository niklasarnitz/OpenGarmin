import FluentSQL
import Foundation
import Vapor

/// Session tokens: 32 random bytes, handed to the client once, stored only as a SHA-256 hash. The same token works as
/// a bearer token (apps) or as an HttpOnly cookie (the dashboard).
enum SessionToken {
    static let cookieName = "opengarmin_session"
    static let cookieMaxAge = 60 * 60 * 24 * 365

    static func generate() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        ContentHash.sha256Hex(Data(token.utf8))
    }

    /// Secure, HttpOnly, SameSite=Lax. Expiring it with an epoch date and zero max age clears it.
    static func cookie(_ value: String, expires: Date, maxAge: Int) -> HTTPCookies.Value {
        HTTPCookies.Value(string: value, expires: expires, maxAge: maxAge, path: "/", isSecure: true, isHTTPOnly: true, sameSite: .lax)
    }
}

struct UserDTO: Content {
    let id: UUID
    let email: String
    let createdAt: Date
    /// IANA name, such as Europe/Berlin. Day boundaries for every daily value follow it.
    let timeZone: String
    /// ISO weekdays of the working week, 1 = Monday … 7 = Sunday. Stress by context and social jetlag use them.
    let workDays: [Int]
    /// Working hours as whole hours: start (0…23) and end (1…24, exclusive).
    let workStart: Int
    let workEnd: Int
}

struct TokenResponse: Content {
    let token: String
    let user: UserDTO

    /// The JSON body plus the session cookie, so the same login serves apps and the dashboard.
    func sessionResponse() throws -> Response {
        let response = try Response.json(self)
        response.cookies[SessionToken.cookieName] = SessionToken.cookie(
            token, expires: Date().addingTimeInterval(TimeInterval(SessionToken.cookieMaxAge)), maxAge: SessionToken.cookieMaxAge
        )
        return response
    }
}

struct Credentials: Content {
    let email: String
    let password: String
}

struct MePatch: Content {
    let timeZone: String?
    let workDays: [Int]?
    let workStart: Int?
    let workEnd: Int?
}

/// The user behind a token, read straight from SQL.
struct AuthenticatedUser: Decodable, Sendable {
    let id: UUID
    let email: String
    let createdAt: Date
    let timeZone: String
    let workDays: [Int]
    let workStart: Int
    let workEnd: Int

    var dto: UserDTO {
        UserDTO(id: id, email: email, createdAt: createdAt, timeZone: timeZone,
                workDays: workDays, workStart: workStart, workEnd: workEnd)
    }

    /// Gregorian calendar in the user's time zone: the day boundaries of every daily value.
    var calendar: Calendar { userCalendar(timeZone) }
}

func userCalendar(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
    return calendar
}

struct CountRow: Decodable {
    let count: Int
}

extension Request {
    /// The bearer token, or the session cookie.
    func presentedToken() -> String? {
        headers.bearerAuthorization?.token ?? cookies[SessionToken.cookieName]?.string
    }

    /// The user behind the presented token, or nil. Tokens expire after a year.
    func currentUser() async throws -> AuthenticatedUser? {
        guard let token = presentedToken() else { return nil }
        return try await sql.raw("""
            SELECT u.id, u.email, u.created_at AS "createdAt", u.time_zone AS "timeZone",
                   u.work_days AS "workDays", u.work_start AS "workStart", u.work_end AS "workEnd"
            FROM access_tokens t JOIN users u ON u.id = t.user_id
            WHERE t.token_hash = \(bind: SessionToken.hash(token)) AND t.created_at > now() - interval '365 days'
            """).first(decoding: AuthenticatedUser.self)
    }

    func requireUser() async throws -> AuthenticatedUser {
        guard let user = try await currentUser() else { throw Abort(.unauthorized) }
        return user
    }
}

/// A cookie is sent by the browser on every request, so a mutating request that authenticates only by cookie must
/// also carry `X-Requested-With`. A cross-site page cannot add that header without a CORS preflight, and this server
/// never grants CORS. Bearer-token requests are not affected.
struct CookieCSRFGuard: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let mutating = req.method != .GET && req.method != .HEAD && req.method != .OPTIONS
        let cookieOnly = req.headers.bearerAuthorization == nil && req.cookies[SessionToken.cookieName] != nil
        if mutating, cookieOnly, req.headers.first(name: "X-Requested-With") == nil {
            throw Abort(.forbidden, reason: "Requests authenticated by cookie must send the X-Requested-With header.")
        }
        return try await next.respond(to: req)
    }
}

enum Accounts {
    static let minimumPasswordLength = 8
    static let defaultTimeZone = "Europe/Berlin"

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The first account is always allowed; later ones only with `OPENGARMIN_ALLOW_SIGNUP=true`.
    static func signupOpen(_ sql: any SQLDatabase, allowSignup: Bool) async throws -> Bool {
        if allowSignup { return true }
        return try await sql.raw("SELECT count(*) AS count FROM users").first(decoding: CountRow.self)?.count == 0
    }

    static func register(email rawEmail: String, password: String, on req: Request) async throws -> TokenResponse {
        let email = normalize(rawEmail)
        guard email.contains("@"), password.count >= minimumPasswordLength else {
            throw Abort(.badRequest, reason: "Enter an email and a password of at least \(minimumPasswordLength) characters.")
        }
        let hash = try Bcrypt.hash(password)
        let allowSignup = req.serverContext.config.allowSignup
        let user: UserDTO = try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await Ingest.lock(sql)
            guard try await signupOpen(sql, allowSignup: allowSignup) else {
                throw Abort(.forbidden, reason: "Sign-up is closed on this server.")
            }
            guard let user = try await sql.raw("""
                INSERT INTO users (email, password_hash, time_zone) VALUES (\(bind: email), \(bind: hash), \(bind: defaultTimeZone))
                ON CONFLICT (email) DO NOTHING
                RETURNING id, email, created_at AS "createdAt", time_zone AS "timeZone",
                    work_days AS "workDays", work_start AS "workStart", work_end AS "workEnd"
                """).first(decoding: UserDTO.self)
            else {
                throw Abort(.conflict, reason: "That email is already registered.")
            }
            return user
        }
        return TokenResponse(token: try await issueToken(for: user.id, on: req), user: user)
    }

    /// Checks the password against the login throttle, then issues a new token.
    static func signIn(email rawEmail: String, password: String, on req: Request) async throws -> TokenResponse {
        let email = normalize(rawEmail)
        let key = "\(req.remoteAddress?.ipAddress ?? "-")|\(email)"
        let throttle = req.serverContext.throttle
        let blocked = await throttle.isBlocked(key)
        guard !blocked else {
            throw Abort(.tooManyRequests, reason: "Too many failed sign-in attempts. Try again in 15 minutes.")
        }
        let record = try await req.sql.raw("""
            SELECT id, email, created_at AS "createdAt", time_zone AS "timeZone", password_hash AS "passwordHash",
                work_days AS "workDays", work_start AS "workStart", work_end AS "workEnd"
            FROM users WHERE email = \(bind: email)
            """).first(decoding: UserRecord.self)
        guard let record, (try? Bcrypt.verify(password, created: record.passwordHash)) == true else {
            await throttle.recordFailure(key)
            throw Abort(.unauthorized, reason: "Wrong email or password.")
        }
        await throttle.reset(key)
        let user = record.dto
        return TokenResponse(token: try await issueToken(for: user.id, on: req), user: user)
    }

    static func signOut(token: String, on req: Request) async throws {
        try await req.sql.raw("DELETE FROM access_tokens WHERE token_hash = \(bind: SessionToken.hash(token))").run()
    }

    /// Changes the user's time zone and rebuilds every daily value, because day boundaries move.
    static func setTimeZone(_ identifier: String, user: AuthenticatedUser, on req: Request) async throws {
        try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await Ingest.lock(sql)
            try await sql.raw("""
                UPDATE users SET time_zone = \(bind: identifier), insights_dirty_at = now() WHERE id = \(bind: user.id)
                """).run()
            try await Rollup.rebuild(userID: user.id, calendar: userCalendar(identifier), sql: sql)
        }
    }

    /// Sets any of the working days and hours that the request names. Insights are computed again afterwards.
    static func setWorkingHours(_ body: MePatch, user: AuthenticatedUser, on req: Request) async throws {
        let days = body.workDays ?? user.workDays
        let start = body.workStart ?? user.workStart
        let end = body.workEnd ?? user.workEnd
        guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }), Set(days).count == days.count,
              (0..<24).contains(start), (1...24).contains(end), start < end else {
            throw Abort(.badRequest, reason: "Working days are 1 (Monday) to 7 (Sunday), each once. Hours are whole hours with the start before the end.")
        }
        try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await Ingest.lock(sql)
            try await sql.raw("""
                UPDATE users SET work_days = \(bind: days)::integer[], work_start = \(bind: start), work_end = \(bind: end),
                    insights_dirty_at = now()
                WHERE id = \(bind: user.id)
                """).run()
        }
    }

    private static func issueToken(for userID: UUID, on req: Request) async throws -> String {
        let token = SessionToken.generate()
        try await req.sql.raw("""
            INSERT INTO access_tokens (user_id, token_hash) VALUES (\(bind: userID), \(bind: SessionToken.hash(token)))
            """).run()
        return token
    }
}

private struct UserRecord: Decodable {
    let id: UUID
    let email: String
    let createdAt: Date
    let timeZone: String
    let workDays: [Int]
    let workStart: Int
    let workEnd: Int
    let passwordHash: String

    var dto: UserDTO {
        UserDTO(id: id, email: email, createdAt: createdAt, timeZone: timeZone,
                workDays: workDays, workStart: workStart, workEnd: workEnd)
    }
}

/// Counts failed sign-ins per client address and email. After 10 failures in 15 minutes the pair is blocked.
actor LoginThrottle {
    private var failures: [String: [Date]] = [:]
    private let limit = 10
    private let window: TimeInterval = 15 * 60

    func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        let recent = (failures[key] ?? []).filter { now.timeIntervalSince($0) < window }
        failures[key] = recent.isEmpty ? nil : recent
        return recent.count >= limit
    }

    func recordFailure(_ key: String, now: Date = Date()) {
        failures[key, default: []].append(now)
    }

    func reset(_ key: String) {
        failures[key] = nil
    }
}
