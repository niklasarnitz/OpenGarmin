import Foundation
import GarminModels

/// The requests of the backend API (docs/backend-api.md). Pure: nothing is sent here, so the builders are tested against
/// the contract.
enum BackendRequests {
    static func register(_ base: URL, email: String, password: String) throws -> URLRequest {
        try json("POST", base, "auth/register", token: nil, Credentials(email: email, password: password))
    }

    static func login(_ base: URL, email: String, password: String) throws -> URLRequest {
        try json("POST", base, "auth/login", token: nil, Credentials(email: email, password: password))
    }

    static func logout(_ base: URL, token: String?) -> URLRequest {
        request("POST", base, "auth/logout", token: token)
    }

    static func me(_ base: URL, token: String?) -> URLRequest {
        request("GET", base, "me", token: token)
    }

    static func syncState(_ base: URL, token: String?) -> URLRequest {
        request("GET", base, "sync/state", token: token)
    }

    /// A multipart form with the raw file as `file`, and the key, source and (when known) the watch's unit number.
    static func fitFile(_ base: URL, token: String?, bytes: Data, key: String, source: BackendSource, deviceUnit: UInt32?,
                        boundary: String) -> URLRequest {
        var fields = [(name: "key", value: key), (name: "source", value: source.rawValue)]
        if let deviceUnit {
            fields.append((name: "deviceUnit", value: String(deviceUnit)))
        }
        var body = Data()
        for field in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(key).fit\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n")
        body.append(bytes)
        body.append("\r\n--\(boundary)--\r\n")
        return request("POST", base, "fit-files", token: token, body: body,
                       contentType: "multipart/form-data; boundary=\(boundary)")
    }

    static func batch(_ base: URL, token: String?, key: String, source: BackendSource, batch: HealthBatch) throws -> URLRequest {
        try json("POST", base, "batches", token: token, Batch(key: key, source: source.rawValue, batch: batch))
    }

    /// A raw Garmin Connect response, sent unchanged as the `body` of `{key, endpoint, day, fetchedAt, body}`.
    static func connectRaw(_ base: URL, token: String?, key: String, endpoint: String, day: String, fetchedAt: Date,
                           body: Any) throws -> URLRequest {
        let payload: [String: Any] = [
            "key": key, "endpoint": endpoint, "day": day,
            "fetchedAt": ISO8601DateFormatter().string(from: fetchedAt), "body": body,
        ]
        return request("POST", base, "connect/raw", token: token, body: try JSONSerialization.data(withJSONObject: payload),
                       contentType: "application/json")
    }

    /// A chunk of Apple Health items under its key, as `{key, items}`.
    static func healthKit<T: Encodable>(_ base: URL, token: String?, path: String, key: String, items: [T]) throws -> URLRequest {
        try json("POST", base, path, token: token, HealthKitChunk(key: key, items: items))
    }

    // MARK: - Building blocks

    private struct HealthKitChunk<T: Encodable>: Encodable {
        let key: String
        let items: [T]
    }

    private struct Credentials: Encodable {
        let email: String
        let password: String
    }

    private struct Batch: Encodable {
        let key: String
        let source: String
        let batch: HealthBatch
    }

    /// Dates go out as ISO 8601, as the server decodes them.
    private static func json<T: Encodable>(_ method: String, _ base: URL, _ path: String, token: String?,
                                           _ value: T) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return request(method, base, path, token: token, body: try encoder.encode(value), contentType: "application/json")
    }

    private static func request(_ method: String, _ base: URL, _ path: String, token: String?, body: Data? = nil,
                                contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: base.appending(path: "api/v1/" + path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }
}

private extension Data {
    mutating func append(_ text: String) {
        append(Data(text.utf8))
    }
}
