import Fluent
import FluentSQL
import Foundation
import GarminFIT
import GarminModels
import Vapor

struct FitUpload: Content {
    var file: File
    var key: String
    var source: String
    var deviceUnit: UInt32?
}

struct BatchUpload: Content {
    var key: String
    var source: String
    var batch: HealthBatch
}

struct UploadResult: Content {
    let id: UUID
    let key: String
    let sha256: String?
    let duplicate: Bool
}

struct SyncState: Content {
    let keys: [String]
}

struct IDRow: Decodable {
    let id: UUID
}

/// Uploads. Raw FIT bytes go to the blob store, decoded data to the indexed tables. Both are keyed, so repeating an
/// upload changes nothing.
enum Ingest {
    static let sources: Set<String> = ["watch", "connect"]

    /// Serialises uploads and account creation, so partitions and daily summaries are never built twice at once.
    static func lock(_ sql: any SQLDatabase) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(7001)").run()
    }

    static func fit(_ upload: FitUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        try validate(upload.key, source: upload.source)
        let bytes = Data(upload.file.data.readableBytesView)
        guard !bytes.isEmpty else { throw Abort(.badRequest, reason: "The file is empty.") }
        let sha = ContentHash.sha256Hex(bytes)
        let sql = try req.sql
        if let existing = try await find(upload.key, userID: user.id, sql: sql) { return existing }

        // Bytes this user already has under another key: the new row points at the same blob and nothing is decoded again.
        let sameBytes = try await sql.raw("""
            SELECT storage_key AS "storageKey" FROM fit_files
            WHERE user_id = \(bind: user.id) AND sha256 = \(bind: sha) AND storage_key IS NOT NULL
            LIMIT 1
            """).first(decoding: StorageRef.self)
        if let sameBytes {
            return try await persist(NewUpload(
                key: upload.key, source: upload.source, sha256: sha, size: bytes.count,
                storageKey: sameBytes.storageKey, deviceUnit: upload.deviceUnit,
                decodeError: nil, batch: nil, duplicate: true
            ), user: user, on: req)
        }

        let storageKey = BlobKey.fit(sha256: sha)
        let blobs = req.serverContext.blobs
        let stored = try await blobs.exists(storageKey)
        if !stored {
            try await blobs.put(storageKey, bytes)
        }

        var batch: HealthBatch?
        var decodeError: String?
        do {
            batch = FitExtractor.extract(try FitDecoder.decode(bytes), unitNumber: upload.deviceUnit)
        } catch {
            decodeError = String(describing: error)
        }
        return try await persist(NewUpload(
            key: upload.key, source: upload.source, sha256: sha, size: bytes.count,
            storageKey: storageKey, deviceUnit: upload.deviceUnit,
            decodeError: decodeError, batch: batch, duplicate: false
        ), user: user, on: req)
    }

    static func batch(_ upload: BatchUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        try validate(upload.key, source: upload.source)
        if let existing = try await find(upload.key, userID: user.id, sql: try req.sql) { return existing }
        return try await persist(NewUpload(
            key: upload.key, source: upload.source, sha256: nil, size: 0,
            storageKey: nil, deviceUnit: nil, decodeError: nil, batch: upload.batch, duplicate: false
        ), user: user, on: req)
    }

    /// Runs `write` once per key, in one transaction with the key's row. A repeated key returns the first result.
    static func once(
        _ key: String,
        kind: String,
        user: AuthenticatedUser,
        on req: Request,
        write: @escaping @Sendable (any SQLDatabase) async throws -> Void
    ) async throws -> UploadResult {
        guard !key.isEmpty, key.count <= 200 else { throw Abort(.badRequest, reason: "`key` must be 1 to 200 characters.") }
        return try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await lock(sql)
            if let existing = try await find(key, userID: user.id, sql: sql) { return existing }
            let row = try await sql.raw("""
                INSERT INTO fit_files (user_id, kind, key, source, uploaded_at, decoded_at)
                VALUES (\(bind: user.id), \(bind: kind), \(bind: key), \(bind: kind), now(), now())
                RETURNING id
                """).first(decoding: IDRow.self)
            guard let row else { throw Abort(.internalServerError) }
            try await write(sql)
            return UploadResult(id: row.id, key: key, sha256: nil, duplicate: false)
        }
    }

    private static func validate(_ key: String, source: String) throws {
        guard !key.isEmpty, key.count <= 200 else { throw Abort(.badRequest, reason: "`key` must be 1 to 200 characters.") }
        guard sources.contains(source) else { throw Abort(.badRequest, reason: "`source` must be watch or connect.") }
    }

    private static func persist(_ new: NewUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        let calendar = user.calendar
        let unit = new.deviceUnit.map { Int64($0) }
        let decodedAt: Date? = new.batch == nil ? nil : Date()
        return try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await lock(sql)
            if let existing = try await find(new.key, userID: user.id, sql: sql) { return existing }
            let kind = new.sha256 == nil ? "batch" : "fit"
            let row = try await sql.raw("""
                INSERT INTO fit_files (user_id, kind, key, source, sha256, size, storage_key, device_unit, uploaded_at, decoded_at, decode_error)
                VALUES (\(bind: user.id), \(bind: kind), \(bind: new.key), \(bind: new.source), \(bind: new.sha256), \(bind: Int64(new.size)), \(bind: new.storageKey), \(bind: unit), now(), \(bind: decodedAt), \(bind: new.decodeError))
                RETURNING id
                """).first(decoding: IDRow.self)
            guard let row else { throw Abort(.internalServerError) }
            if let batch = new.batch {
                try await Store.write(batch, fitFileID: row.id, userID: user.id, sql: sql, calendar: calendar)
            }
            return UploadResult(id: row.id, key: new.key, sha256: new.sha256, duplicate: new.duplicate)
        }
    }

    private static func find(_ key: String, userID: UUID, sql: any SQLDatabase) async throws -> UploadResult? {
        let row = try await sql.raw("SELECT id, key, sha256 FROM fit_files WHERE user_id = \(bind: userID) AND key = \(bind: key)")
            .first(decoding: ExistingRow.self)
        return row.map { UploadResult(id: $0.id, key: $0.key, sha256: $0.sha256, duplicate: true) }
    }
}

private struct NewUpload {
    let key: String
    let source: String
    let sha256: String?
    let size: Int
    let storageKey: String?
    let deviceUnit: UInt32?
    let decodeError: String?
    let batch: HealthBatch?
    let duplicate: Bool
}

private struct StorageRef: Decodable {
    let storageKey: String
}

private struct ExistingRow: Decodable {
    let id: UUID
    let key: String
    let sha256: String?
}
