import Foundation
import Vapor

/// ISO 8601 dates in both directions. Parsing accepts fractional seconds or not, so the app's `.iso8601` payloads
/// and plain timestamps both work.
enum TimeCoding {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(TimeCoding.string(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let text = try dec.singleValueContainer().decode(String.self)
            guard let date = TimeCoding.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}

extension Response {
    /// A JSON response, encoded with `TimeCoding`.
    static func json(_ value: some Encodable) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: try TimeCoding.encoder.encode(value)))
    }
}
