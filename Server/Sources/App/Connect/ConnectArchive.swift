import FluentSQL
import Foundation
import Vapor

struct ConnectDiagnostics: Content {
    let nights: Int
    let mappingAgreement: [MappingShare]
    let mismatches: [ConnectMismatch]
}

/// How often a raw sleep code was assigned to a stage, over the checked nights.
struct MappingShare: Content {
    let code: Int
    let stage: String
    let nights: Int
    let share: Double
}

struct ConnectMismatch: Content {
    let day: String
    let minutesPerCode: [String: Double]
    let dtoTotals: [String: Double]
}

/// Garmin Connect responses as the app fetched them. Each is kept gzip-compressed in the blob store, and parsed on the
/// server into the same tables as the other data. Parsing can change and run again over the archive (see
/// `reprocessOutdated`), so Garmin never has to be asked again.
enum ConnectArchive {
    struct Upload {
        let key: String
        let endpoint: String
        let day: String?
        let activityId: Int64?
        let fetchedAt: Date
        /// The response JSON as the app sent it: a dictionary or an array.
        let body: Any
    }

    /// Reads the envelope `{key, endpoint, day?, activityId?, fetchedAt, body}`. The body is kept as JSON, not decoded
    /// into a fixed type, so any Garmin response is archived as it is.
    static func decode(_ req: Request) throws -> Upload {
        guard let buffer = req.body.data,
              let object = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any],
              let key = object["key"] as? String, let endpoint = object["endpoint"] as? String,
              let fetchedText = object["fetchedAt"] as? String, let fetchedAt = TimeCoding.parse(fetchedText),
              let body = object["body"], !(body is NSNull)
        else { throw Abort(.badRequest, reason: "Expected {key, endpoint, fetchedAt, body}.") }
        return Upload(
            key: key, endpoint: endpoint, day: object["day"] as? String,
            activityId: (object["activityId"] as? NSNumber)?.int64Value, fetchedAt: fetchedAt, body: body
        )
    }

    /// Stores the response once per key, and parses it in the same transaction. A repeated key returns the first result.
    static func archive(_ upload: Upload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        guard !upload.key.isEmpty, upload.key.count <= 200 else {
            throw Abort(.badRequest, reason: "`key` must be 1 to 200 characters.")
        }
        guard ConnectParser.endpoints.contains(upload.endpoint) else {
            throw Abort(.badRequest, reason: "`endpoint` must be one of \(ConnectParser.endpoints.sorted().joined(separator: ", ")).")
        }
        let calendar = user.calendar
        if let day = upload.day, ConnectParser.dayStart(day, calendar: calendar) == nil {
            throw Abort(.badRequest, reason: "`day` must be YYYY-MM-DD.")
        }
        if upload.endpoint == "usersummary", upload.day == nil {
            throw Abort(.badRequest, reason: "`day` is required for usersummary.")
        }
        let sql = try req.sql
        if let existing = try await find(upload.key, userID: user.id, sql: sql) { return existing }

        // Content-addressed, so a changed response for the same day is kept beside the old one rather than replacing it.
        let raw = try JSONSerialization.data(withJSONObject: upload.body, options: [.fragmentsAllowed, .sortedKeys])
        let sha = ContentHash.sha256Hex(raw)
        let storageKey = "connect-raw/\(upload.endpoint)/\(upload.day ?? upload.activityId.map(String.init) ?? "all")/\(sha).json.gz"
        let blobs = req.serverContext.blobs
        let stored = try await blobs.exists(storageKey)
        if !stored {
            try await blobs.put(storageKey, try Gzip.compress(raw))
        }

        let parsed = ConnectParser.parse(endpoint: upload.endpoint, day: upload.day, calendar: calendar, body: upload.body)
        let key = upload.key, endpoint = upload.endpoint, day = upload.day, activityId = upload.activityId
        let fetchedAt = upload.fetchedAt, size = Int64(raw.count), userID = user.id
        return try await req.db.transaction { tx in
            let sql = try tx.sql()
            try await Ingest.lock(sql)
            if let existing = try await find(key, userID: userID, sql: sql) { return existing }
            let row = try await sql.raw("""
                INSERT INTO connect_raw (user_id, key, endpoint, day, activity_id, fetched_at, storage_key, sha256, size, parser_version, parsed_at)
                VALUES (\(bind: userID), \(bind: key), \(bind: endpoint), \(bind: day)::date, \(bind: activityId), \(bind: fetchedAt),
                    \(bind: storageKey), \(bind: sha), \(bind: size), \(bind: ConnectParser.version), now())
                RETURNING id
                """).first(decoding: IDRow.self)
            guard let row else { throw Abort(.internalServerError) }
            try await write(parsed, userID: userID, sql: sql, calendar: calendar)
            return UploadResult(id: row.id, key: key, sha256: sha, duplicate: false)
        }
    }

    /// Parses again every archived response that was parsed by an older parser, at startup. Failures are logged per
    /// response, so one bad archive entry does not stop the others.
    static func reprocessOutdated(_ app: Application) async {
        do {
            let sql = try app.db.sql()
            let rows = try await sql.raw("""
                SELECT c.id AS "id", c.user_id AS "userID", c.endpoint AS "endpoint", to_char(c.day, 'YYYY-MM-DD') AS "day",
                    c.storage_key AS "storageKey", u.time_zone AS "timeZone"
                FROM connect_raw c JOIN users u ON u.id = c.user_id
                WHERE c.parser_version < \(bind: ConnectParser.version)
                ORDER BY c.fetched_at
                """).all(decoding: OutdatedRow.self)
            guard !rows.isEmpty else { return }
            app.logger.info("Parsing \(rows.count) archived Connect responses again")
            for row in rows {
                do {
                    guard let blob = try await app.serverContext.blobs.get(row.storageKey) else {
                        app.logger.warning("Archived Connect response is missing: \(row.storageKey)")
                        continue
                    }
                    let body = try JSONSerialization.jsonObject(with: Gzip.decompress(blob), options: [.fragmentsAllowed])
                    let calendar = userCalendar(row.timeZone)
                    let parsed = ConnectParser.parse(endpoint: row.endpoint, day: row.day, calendar: calendar, body: body)
                    try await app.db.transaction { tx in
                        let sql = try tx.sql()
                        try await Ingest.lock(sql)
                        try await write(parsed, userID: row.userID, sql: sql, calendar: calendar)
                        try await sql.raw("""
                            UPDATE connect_raw SET parser_version = \(bind: ConnectParser.version), parsed_at = now()
                            WHERE id = \(bind: row.id)
                            """).run()
                    }
                } catch {
                    app.logger.report(error: error)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// The stage mapping of every checked night, and the nights that disagree with Garmin's totals.
    static func diagnostics(_ req: Request, user: AuthenticatedUser) async throws -> ConnectDiagnostics {
        let rows = try await req.sql.raw("""
            SELECT to_char(day, 'YYYY-MM-DD') AS "day", mapping_json AS "mapping", minutes_json AS "minutes",
                dto_json AS "dto", agrees AS "agrees"
            FROM connect_sleep_checks WHERE user_id = \(bind: user.id) ORDER BY day DESC
            """).all(decoding: CheckRow.self)
        let decoder = JSONDecoder()
        var counts: [String: Int] = [:]
        var mismatches: [ConnectMismatch] = []
        for row in rows {
            let mapping = try decoder.decode([String: String].self, from: Data(row.mapping.utf8))
            for (code, stage) in mapping { counts["\(code)|\(stage)", default: 0] += 1 }
            if !row.agrees {
                mismatches.append(ConnectMismatch(
                    day: row.day,
                    minutesPerCode: try decoder.decode([String: Double].self, from: Data(row.minutes.utf8)),
                    dtoTotals: try decoder.decode([String: Double].self, from: Data(row.dto.utf8))
                ))
            }
        }
        let shares = counts.compactMap { entry -> MappingShare? in
            let parts = entry.key.split(separator: "|")
            guard parts.count == 2, let code = Int(parts[0]) else { return nil }
            return MappingShare(code: code, stage: String(parts[1]), nights: entry.value,
                                share: Double(entry.value) / Double(rows.count))
        }.sorted { ($0.code, $0.stage) < ($1.code, $1.stage) }
        return ConnectDiagnostics(nights: rows.count, mappingAgreement: shares, mismatches: mismatches)
    }

    private static func find(_ key: String, userID: UUID, sql: any SQLDatabase) async throws -> UploadResult? {
        let row = try await sql.raw("SELECT id, key, sha256 FROM connect_raw WHERE user_id = \(bind: userID) AND key = \(bind: key)")
            .first(decoding: ExistingRaw.self)
        return row.map { UploadResult(id: $0.id, key: $0.key, sha256: $0.sha256, duplicate: true) }
    }

    private static func write(_ parsed: ConnectParser.Parsed, userID: UUID, sql: any SQLDatabase, calendar: Calendar) async throws {
        try await Store.write(parsed.batch, fitFileID: nil, userID: userID, sql: sql, calendar: calendar)
        guard let check = parsed.sleepCheck else { return }
        let minutes = try text(Dictionary(uniqueKeysWithValues: check.minutesPerCode.map { (String($0.key), $0.value) }))
        let dto = try text(check.dtoMinutes)
        let mapping = try text(Dictionary(uniqueKeysWithValues: check.mapping.map { (String($0.key), $0.value.rawValue) }))
        try await sql.raw("""
            INSERT INTO connect_sleep_checks (user_id, day, parser_version, mapping_json, minutes_json, dto_json, error_minutes, agrees)
            VALUES (\(bind: userID), \(bind: check.day)::date, \(bind: ConnectParser.version), \(bind: mapping), \(bind: minutes),
                \(bind: dto), \(bind: check.errorMinutes), \(bind: check.agrees))
            ON CONFLICT (user_id, day) DO UPDATE SET parser_version = EXCLUDED.parser_version, mapping_json = EXCLUDED.mapping_json,
                minutes_json = EXCLUDED.minutes_json, dto_json = EXCLUDED.dto_json, error_minutes = EXCLUDED.error_minutes,
                agrees = EXCLUDED.agrees
            """).run()
    }

    private static func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private struct OutdatedRow: Decodable {
    let id: UUID
    let userID: UUID
    let endpoint: String
    let day: String?
    let storageKey: String
    let timeZone: String
}

private struct ExistingRaw: Decodable {
    let id: UUID
    let key: String
    let sha256: String?
}

private struct CheckRow: Decodable {
    let day: String
    let mapping: String
    let minutes: String
    let dto: String
    let agrees: Bool
}
