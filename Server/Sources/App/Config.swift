import Foundation

/// Server settings. Read from the environment only (see `fromEnvironment`).
struct ServerConfig: Sendable {
    struct S3: Sendable {
        var endpoint: String
        var region: String
        var bucket: String
        var accessKey: String
        var secretKey: String
    }

    var databaseURL: String
    /// Raw FIT files when no S3 endpoint is set. Keyed by SHA-256 under `fit/`.
    var dataDirectory: String
    var allowSignup: Bool
    var port: Int
    var s3: S3?

    init(databaseURL: String, dataDirectory: String = "./data", allowSignup: Bool = false, port: Int = 8080, s3: S3? = nil) {
        self.databaseURL = databaseURL
        self.dataDirectory = dataDirectory
        self.allowSignup = allowSignup
        self.port = port
        self.s3 = s3
    }

    static func fromEnvironment(_ env: [String: String]) throws -> ServerConfig {
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw ConfigError.missing(name) }
            return value
        }
        var s3: S3?
        if let endpoint = env["OPENGARMIN_S3_ENDPOINT"], !endpoint.isEmpty {
            s3 = S3(
                endpoint: endpoint,
                region: env["OPENGARMIN_S3_REGION"] ?? "us-east-1",
                bucket: try required("OPENGARMIN_S3_BUCKET"),
                accessKey: try required("OPENGARMIN_S3_ACCESS_KEY"),
                secretKey: try required("OPENGARMIN_S3_SECRET_KEY")
            )
        }
        return try ServerConfig(
            databaseURL: required("DATABASE_URL"),
            dataDirectory: env["OPENGARMIN_DATA_DIR"] ?? "./data",
            allowSignup: env["OPENGARMIN_ALLOW_SIGNUP"]?.lowercased() == "true",
            port: Int(env["PORT"] ?? "") ?? 8080,
            s3: s3
        )
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let name): "Missing required environment variable \(name)"
        }
    }
}
