import Fluent
import FluentSQL

/// Accounts, sessions, uploads, activities, sleep, and daily summaries. Plain SQL, one statement each.
struct CreateTables: AsyncMigration {
    let name = "CreateTables"

    static let statements: [String] = [
        """
        CREATE TABLE users (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            email text NOT NULL UNIQUE,
            password_hash text NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE access_tokens (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token_hash text NOT NULL UNIQUE,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        // One row per client key. kind is 'fit' (raw file, storage_key set) or 'batch' (JSON, no file).
        // Rows with the same sha256 share one stored file.
        """
        CREATE TABLE fit_files (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind text NOT NULL,
            key text NOT NULL,
            source text NOT NULL,
            sha256 text,
            size bigint NOT NULL DEFAULT 0,
            storage_key text,
            device_unit bigint,
            uploaded_at timestamptz NOT NULL DEFAULT now(),
            decoded_at timestamptz,
            decode_error text,
            UNIQUE (user_id, key)
        )
        """,
        "CREATE INDEX fit_files_sha256 ON fit_files (user_id, sha256)",
        """
        CREATE TABLE activities (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            external_id text NOT NULL,
            fit_file_id uuid REFERENCES fit_files(id) ON DELETE SET NULL,
            sport integer NOT NULL,
            sub_sport integer,
            name text,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            duration double precision NOT NULL,
            distance double precision,
            active_calories double precision,
            avg_hr integer,
            max_hr integer,
            total_ascent double precision,
            total_descent double precision,
            avg_speed double precision,
            avg_cadence integer,
            avg_power integer,
            training_effect double precision,
            UNIQUE (user_id, external_id)
        )
        """,
        "CREATE INDEX activities_user_start ON activities (user_id, start_ts)",
        """
        CREATE TABLE activity_laps (
            activity_id uuid NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
            idx integer NOT NULL,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            distance double precision,
            calories double precision,
            avg_hr integer,
            PRIMARY KEY (activity_id, idx)
        )
        """,
        """
        CREATE TABLE sleep_sessions (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            score integer,
            breakdown jsonb,
            UNIQUE (user_id, start_ts)
        )
        """,
        """
        CREATE TABLE sleep_stages (
            session_id uuid NOT NULL REFERENCES sleep_sessions(id) ON DELETE CASCADE,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            stage text NOT NULL,
            PRIMARY KEY (session_id, start_ts)
        )
        """,
        """
        CREATE TABLE daily_summaries (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            day date NOT NULL,
            steps double precision NOT NULL DEFAULT 0,
            active_energy double precision NOT NULL DEFAULT 0,
            resting_heart_rate double precision,
            average_stress double precision,
            sleep_minutes double precision NOT NULL DEFAULT 0,
            activity_count integer NOT NULL DEFAULT 0,
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
        for table in ["daily_summaries", "sleep_stages", "sleep_sessions", "activity_laps", "activities", "fit_files", "access_tokens", "users"] {
            try await sql.raw(SQLQueryString("DROP TABLE IF EXISTS \(table)")).run()
        }
    }
}

/// The two high-volume tables, range-partitioned by month on their timestamp. Partitions are created by `Partitions`
/// when data first lands in a month. A BRIN index on the timestamp stays small across many years of data.
struct CreateTimeSeries: AsyncMigration {
    let name = "CreateTimeSeries"

    static let statements: [String] = [
        """
        CREATE TABLE samples (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            metric text NOT NULL,
            ts timestamptz NOT NULL,
            end_ts timestamptz,
            value double precision NOT NULL,
            PRIMARY KEY (user_id, metric, ts)
        ) PARTITION BY RANGE (ts)
        """,
        "CREATE INDEX samples_ts_brin ON samples USING brin (ts)",
        """
        CREATE TABLE activity_records (
            activity_id uuid NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
            ts timestamptz NOT NULL,
            latitude double precision,
            longitude double precision,
            altitude double precision,
            heart_rate integer,
            speed double precision,
            distance double precision,
            cadence integer,
            power integer,
            temperature double precision,
            PRIMARY KEY (activity_id, ts)
        ) PARTITION BY RANGE (ts)
        """,
        "CREATE INDEX activity_records_ts_brin ON activity_records USING brin (ts)",
    ]

    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        for statement in Self.statements {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.raw("DROP TABLE IF EXISTS activity_records").run()
        try await sql.raw("DROP TABLE IF EXISTS samples").run()
    }
}
