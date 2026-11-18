import Fluent
import FluentSQL

/// The user's time zone, and the daily rollup the dashboard reads.
struct CreateRollups: AsyncMigration {
    let name = "CreateRollups"

    static let statements: [String] = [
        "ALTER TABLE users ADD COLUMN time_zone text NOT NULL DEFAULT 'Europe/Berlin'",
        """
        CREATE TABLE metric_daily (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            day date NOT NULL,
            metric text NOT NULL,
            source text NOT NULL,
            unit text,
            value double precision NOT NULL,
            min double precision,
            max double precision,
            count integer NOT NULL,
            PRIMARY KEY (user_id, day, metric, source)
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
        try await sql.raw("DROP TABLE IF EXISTS metric_daily").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS time_zone").run()
    }
}
