import Foundation
import GarminModels

/// Why a call to the backend failed. The descriptions are shown to the user.
public enum BackendError: Error, Equatable, Sendable, LocalizedError {
    case invalidServerURL
    /// The server does not accept the token, or refused the sign-in.
    case unauthorized
    case http(Int)
    /// A 4xx answer other than 401 and 403: the server refused this request, with its reason. A file it refuses is skipped.
    case rejected(status: Int, message: String)
    case transport(String)
    case malformedResponse
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "The server URL is not valid."
        case .unauthorized: "The server does not accept the sign-in. Sign in again."
        case let .http(status): "The server answered with HTTP \(status)."
        case let .rejected(status, message): "The server refused the request (HTTP \(status)): \(message)"
        case let .transport(message): "The server could not be reached: \(message)"
        case .malformedResponse: "The server sent a response OpenGarmin does not understand."
        case let .keychain(status): "The sign-in could not be saved to the Keychain (\(status))."
        }
    }
}

/// Where a file or batch came from, as the server records it.
public enum BackendSource: String, Sendable {
    case watch, connect

    /// Garmin Connect keys hold "connect" (`<unit>-connect-<id>`, `connect-daily-<time>`). The watch's keys do not.
    public init(key: String) {
        self = key.contains("connect") ? .connect : .watch
    }
}

public struct BackendUser: Sendable, Equatable, Decodable {
    public let email: String
}

public struct BackendSession: Sendable, Equatable, Decodable {
    public let token: String
    public let user: BackendUser
}

/// Calls the backend API (docs/backend-api.md). Each call returns the response body, or throws a `BackendError`.
public struct BackendClient: Sendable {
    /// Sends one request and returns its body and HTTP response. The app uses URLSession; tests replace it.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let baseURL: URL
    /// The session token, sent with every call except sign-in and registration.
    public let token: String?
    private let transport: Transport

    /// - Parameter server: the server's address, such as `https://opengarmin.arnitz.org`.
    public init(server: String, token: String? = nil, transport: @escaping Transport = BackendClient.urlSession) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, scheme == "http" || scheme == "https", url.host != nil else {
            throw BackendError.invalidServerURL
        }
        baseURL = url
        self.token = token
        self.transport = transport
    }

    public static let urlSession: Transport = { request in
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackendError.malformedResponse }
            return (data, http)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
    }

    // MARK: - Account

    public func register(email: String, password: String) async throws -> BackendSession {
        try Self.decode(BackendSession.self, await send(BackendRequests.register(baseURL, email: email, password: password)))
    }

    public func login(email: String, password: String) async throws -> BackendSession {
        try Self.decode(BackendSession.self, await send(BackendRequests.login(baseURL, email: email, password: password)))
    }

    public func logout() async throws {
        _ = try await send(BackendRequests.logout(baseURL, token: token))
    }

    public func me() async throws -> BackendUser {
        try Self.decode(BackendUser.self, await send(BackendRequests.me(baseURL, token: token)))
    }

    // MARK: - Upload

    /// The keys the server already holds, for FIT files and batches alike.
    public func syncState() async throws -> Set<String> {
        Set(try Self.decode(SyncState.self, await send(BackendRequests.syncState(baseURL, token: token))).keys)
    }

    public func uploadFIT(_ bytes: Data, key: String, source: BackendSource, deviceUnit: UInt32?) async throws {
        _ = try await send(BackendRequests.fitFile(baseURL, token: token, bytes: bytes, key: key, source: source,
                                                   deviceUnit: deviceUnit, boundary: UUID().uuidString))
    }

    public func uploadBatch(_ batch: HealthBatch, key: String, source: BackendSource) async throws {
        _ = try await send(BackendRequests.batch(baseURL, token: token, key: key, source: source, batch: batch))
    }

    /// A raw Garmin Connect response: `body` is its parsed JSON, which the server keeps as it arrived.
    public func uploadConnectRaw(_ body: Any, key: String, endpoint: String, day: String, fetchedAt: Date) async throws {
        _ = try await send(BackendRequests.connectRaw(baseURL, token: token, key: key, endpoint: endpoint, day: day,
                                                      fetchedAt: fetchedAt, body: body))
    }

    // MARK: - Apple Health

    public func uploadSamples(_ items: [BackendSample], key: String) async throws {
        _ = try await send(BackendRequests.healthKit(baseURL, token: token, path: "healthkit/samples", key: key, items: items))
    }

    public func uploadWorkouts(_ items: [BackendWorkout], key: String) async throws {
        _ = try await send(BackendRequests.healthKit(baseURL, token: token, path: "healthkit/workouts", key: key, items: items))
    }

    public func uploadElectrocardiograms(_ items: [BackendElectrocardiogram], key: String) async throws {
        _ = try await send(BackendRequests.healthKit(baseURL, token: token, path: "healthkit/electrocardiograms", key: key, items: items))
    }

    // MARK: - Transport

    /// The body of a response with a 2xx status. Other statuses throw.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        if let failure = Self.failure(status: response.statusCode, body: data) { throw failure }
        return data
    }

    static func failure(status: Int, body: Data) -> BackendError? {
        switch status {
        case 200..<300: nil
        case 401: .unauthorized
        case 400..<500 where status != 403: .rejected(status: status, message: reason(body) ?? "HTTP \(status)")
        default: .http(status)
        }
    }

    /// The server's reason for a refusal: the `reason` (Vapor's error format) or `message` field of a JSON body. The
    /// contract does not name an error format, so a body without either gives nil.
    private static func reason(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return (object["reason"] ?? object["message"]) as? String
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.malformedResponse
        }
    }

    private struct SyncState: Decodable {
        let keys: [String]
    }
}
