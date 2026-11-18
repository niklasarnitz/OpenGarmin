import Fluent
import FluentSQL

/// Garmin Connect responses as archived, and the per-night check of the sleep stage mapping.
struct CreateConnectArchive: AsyncMigration {
    let name = "CreateConnectArchive"

    static let statements: [String] = [
        // One row per response the app sent. The body is gzip JSON in the blob store, under storage_key.
        """
        CREATE TABLE connect_raw (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            key text NOT NULL,
            endpoint text NOT NULL,
            day date,
            activity_id bigint,
            fetched_at timestamptz NOT NULL,
            storage_key text NOT NULL,
            sha256 text NOT NULL,
            size bigint NOT NULL,
            parser_version integer NOT NULL,
            parsed_at timestamptz NOT NULL,
            UNIQUE (user_id, key)
        )
        """,
        "CREATE INDEX connect_raw_endpoint_day ON connect_raw (user_id, endpoint, day)",
        // One row per night the DTO totals could be compared with the sleep levels.
        """
        CREATE TABLE connect_sleep_checks (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            day date NOT NULL,
            parser_version integer NOT NULL,
            mapping_json text NOT NULL,
            minutes_json text NOT NULL,
            dto_json text NOT NULL,
            error_minutes double precision NOT NULL,
            agrees boolean NOT NULL,
            PRIMARY KEY (user_id, day)
        )
        """,
    ]

    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        for statement in Self.statements {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.raw("DROP TABLE IF EXISTS connect_sleep_checks").run()
        try await sql.raw("DROP TABLE IF EXISTS connect_raw").run()
    }
}
