import Fluent
import FluentSQL

/// Working hours on the user, and the cache of computed insights. A run is one range and language; its findings are
/// stored as JSON in `insights`, in the order they were sorted.
struct CreateInsights: AsyncMigration {
    let name = "CreateInsights"

    static let statements: [String] = [
        "ALTER TABLE users ADD COLUMN work_days integer[] NOT NULL DEFAULT '{1,2,3,4,5}'",
        "ALTER TABLE users ADD COLUMN work_start integer NOT NULL DEFAULT 9",
        "ALTER TABLE users ADD COLUMN work_end integer NOT NULL DEFAULT 17",
        // Set when the user's data or settings change; cleared once the insights are computed again.
        "ALTER TABLE users ADD COLUMN insights_dirty_at timestamptz",
        // Ranges are day indexes (CivilDay), `to` exclusive.
        """
        CREATE TABLE insight_runs (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            range_from integer NOT NULL,
            range_to integer NOT NULL,
            lang text NOT NULL,
            computed_at timestamptz NOT NULL,
            PRIMARY KEY (user_id, range_from, range_to, lang)
        )
        """,
        """
        CREATE TABLE insights (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            range_from integer NOT NULL,
            range_to integer NOT NULL,
            lang text NOT NULL,
            position integer NOT NULL,
            body text NOT NULL,
            PRIMARY KEY (user_id, range_from, range_to, lang, position)
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
        try await sql.raw("DROP TABLE IF EXISTS insights").run()
        try await sql.raw("DROP TABLE IF EXISTS insight_runs").run()
        for column in ["insights_dirty_at", "work_end", "work_start", "work_days"] {
            try await sql.raw(SQLQueryString("ALTER TABLE users DROP COLUMN IF EXISTS \(column)")).run()
        }
    }
}
