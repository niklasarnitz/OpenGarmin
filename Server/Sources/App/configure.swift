import Fluent
import FluentPostgresDriver
import FluentSQL
import Foundation
import SotoS3
import Vapor

/// What request handlers need besides the database.
struct AppContext: Sendable {
    let config: ServerConfig
    let blobs: any BlobStore
    let throttle: LoginThrottle
}

private struct AppContextKey: StorageKey {
    typealias Value = AppContext
}

extension Application {
    var serverContext: AppContext {
        get { storage[AppContextKey.self]! }
        set { storage[AppContextKey.self] = newValue }
    }
}

extension Request {
    var serverContext: AppContext { application.serverContext }

    /// The SQL view of the request's database.
    var sql: any SQLDatabase {
        get throws { try db.sql() }
    }
}

extension Database {
    /// The SQL view of this database. Postgres always provides one.
    func sql() throws -> any SQLDatabase {
        guard let sql = self as? any SQLDatabase else { throw Abort(.internalServerError, reason: "No SQL database") }
        return sql
    }
}

func configure(_ app: Application, config: ServerConfig) async throws {
    try app.databases.use(.postgres(url: config.databaseURL), as: .psql)
    app.migrations.add(CreateTables())
    app.migrations.add(CreateTimeSeries())
    app.migrations.add(CreateHealthKit())
    app.migrations.add(CreateRollups())
    app.migrations.add(CreateConnectArchive())
    app.migrations.add(CreateInsights())
    app.migrations.add(AddRollupVersion())

    app.routes.defaultMaxBodySize = "512mb"
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = config.port
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    ContentConfiguration.global.use(decoder: TimeCoding.decoder, for: .json)
    ContentConfiguration.global.use(encoder: TimeCoding.encoder, for: .json)

    app.serverContext = AppContext(
        config: config,
        blobs: try makeBlobStore(config, app),
        throttle: LoginThrottle()
    )
    try registerAPIRoutes(app)
    app.get("healthz") { req async throws -> [String: String] in
        _ = try await req.sql.raw("SELECT 1").run()
        return ["status": "ok"]
    }
    // Last: the catch-all for the dashboard's client-side routes.
    registerStaticRoutes(app)
}

/// S3 when an endpoint is configured, otherwise the data directory.
private func makeBlobStore(_ config: ServerConfig, _ app: Application) throws -> any BlobStore {
    guard let s3 = config.s3 else {
        return FileSystemBlobStore(root: URL(fileURLWithPath: config.dataDirectory, isDirectory: true))
    }
    let client = AWSClient(credentialProvider: .static(accessKeyId: s3.accessKey, secretAccessKey: s3.secretKey))
    app.lifecycle.use(AWSClientShutdown(client: client))
    let service = S3(client: client, region: .init(rawValue: s3.region), endpoint: s3.endpoint)
    return S3BlobStore(service: service, bucket: s3.bucket)
}

private struct AWSClientShutdown: LifecycleHandler {
    let client: AWSClient

    func shutdownAsync(_ application: Application) async {
        try? await client.shutdown()
    }
}
