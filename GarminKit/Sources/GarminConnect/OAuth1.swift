import CommonCrypto
import Foundation

/// OAuth 1.0a request signing with HMAC-SHA1, the way garth's requests_oauthlib session signs Garmin's ticket and token
/// requests. The query items of the URL and the form fields of the body are part of the signature.
struct OAuth1Signer: Sendable {
    let consumerKey: String
    let consumerSecret: String
    var token: String?
    var tokenSecret: String?
    var nonce = OAuth1Signer.randomNonce()
    var timestamp = String(Int(Date.now.timeIntervalSince1970))

    /// The Authorization header for a request to `url` with the given form fields (empty for GET).
    func authorization(method: String, url: URL, form: [(String, String)] = []) -> String {
        var oauth: [(String, String)] = [
            ("oauth_consumer_key", consumerKey),
            ("oauth_nonce", nonce),
            ("oauth_signature_method", "HMAC-SHA1"),
            ("oauth_timestamp", timestamp),
            ("oauth_version", "1.0"),
        ]
        if let token, !token.isEmpty { oauth.append(("oauth_token", token)) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let parameters = query.map { ($0.name, $0.value ?? "") } + form + oauth
        let signature = Self.signature(method: method, url: url, parameters: parameters,
                                       consumerSecret: consumerSecret, tokenSecret: tokenSecret)
        oauth.append(("oauth_signature", signature))
        return "OAuth " + oauth.map { "\(Self.encode($0.0))=\"\(Self.encode($0.1))\"" }.joined(separator: ", ")
    }

    static func signature(method: String, url: URL, parameters: [(String, String)],
                          consumerSecret: String, tokenSecret: String?) -> String {
        var baseURL = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        baseURL.query = nil
        baseURL.fragment = nil
        let encoded: [(name: String, value: String)] = parameters.map { (name: encode($0.0), value: encode($0.1)) }
        let sorted = encoded.sorted { $0.name != $1.name ? $0.name < $1.name : $0.value < $1.value }
        let normalized: String = sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        let urlPart: String = encode(baseURL.string ?? "")
        let base: String = [method.uppercased(), urlPart, encode(normalized)].joined(separator: "&")
        let secret: String = encode(consumerSecret) + "&" + encode(tokenSecret ?? "")
        return hmacSHA1(key: secret, message: base).base64EncodedString()
    }

    /// RFC 3986 percent-encoding: only unreserved characters stay as they are.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Decodes `name=value&name=value` bodies such as Garmin's OAuth1 token response.
    static func formFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]) else { continue }
            fields[name] = parts.count > 1 ? decode(parts[1]) ?? "" : ""
        }
        return fields
    }

    /// The body of a form-encoded request.
    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func decode(_ part: Substring) -> String? {
        part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func randomNonce() -> String {
        String(UUID().uuidString.filter { $0.isLetter || $0.isNumber })
    }

    private static func hmacSHA1(key: String, message: String) -> Data {
        let keyBytes = Array(key.utf8)
        let messageBytes = Array(message.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes, keyBytes.count, messageBytes, messageBytes.count, &digest)
        return Data(digest)
    }
}
