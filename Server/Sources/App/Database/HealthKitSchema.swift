import Fluent
import FluentSQL

/// Apple Health history: every quantity and category sample, workouts with their routes, and ECG recordings.
/// Samples and route points are range-partitioned by month like the Garmin time series. JSON columns are text, so
/// bulk inserts need no per-column casts.
struct CreateHealthKit: AsyncMigration {
    let name = "CreateHealthKit"

    static let statements: [String] = [
        // The partition key must be part of the primary key, so uniqueness is (user_id, uuid, start).
        """
        CREATE TABLE healthkit_samples (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            uuid uuid NOT NULL,
            type text NOT NULL,
            start timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            value double precision,
            unit text,
            category_value integer,
            source_bundle text NOT NULL,
            source_name text NOT NULL,
            device_json text,
            metadata_json text,
            PRIMARY KEY (user_id, uuid, start)
        ) PARTITION BY RANGE (start)
        """,
        "CREATE INDEX healthkit_samples_start_brin ON healthkit_samples USING brin (start)",
        "CREATE INDEX healthkit_samples_user_type_start ON healthkit_samples (user_id, type, start)",
        """
        CREATE TABLE healthkit_workouts (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            uuid uuid NOT NULL,
            activity_type integer NOT NULL,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            duration double precision NOT NULL,
            total_energy_kcal double precision,
            total_distance_m double precision,
            source_bundle text NOT NULL,
            source_name text NOT NULL,
            device_json text,
            metadata_json text,
            events_json text,
            UNIQUE (user_id, uuid)
        )
        """,
        "CREATE INDEX healthkit_workouts_user_start ON healthkit_workouts (user_id, start_ts)",
        """
        CREATE TABLE healthkit_route_points (
            workout_id uuid NOT NULL REFERENCES healthkit_workouts(id) ON DELETE CASCADE,
            ts timestamptz NOT NULL,
            latitude double precision NOT NULL,
            longitude double precision NOT NULL,
            altitude double precision,
            horizontal_accuracy double precision,
            vertical_accuracy double precision,
            speed double precision,
            course double precision,
            PRIMARY KEY (workout_id, ts)
        ) PARTITION BY RANGE (ts)
        """,
        "CREATE INDEX healthkit_route_points_ts_brin ON healthkit_route_points USING brin (ts)",
        """
        CREATE TABLE healthkit_electrocardiograms (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            uuid uuid NOT NULL,
            start_ts timestamptz NOT NULL,
            end_ts timestamptz NOT NULL,
            classification text NOT NULL,
            average_heart_rate double precision,
            sampling_frequency double precision,
            voltages_json text,
            source_bundle text NOT NULL,
            source_name text NOT NULL,
            device_json text,
            PRIMARY KEY (user_id, uuid)
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
        for table in ["healthkit_electrocardiograms", "healthkit_route_points", "healthkit_workouts", "healthkit_samples"] {
            try await sql.raw(SQLQueryString("DROP TABLE IF EXISTS \(table)")).run()
        }
    }
}
