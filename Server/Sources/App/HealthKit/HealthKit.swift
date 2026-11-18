import FluentSQL
import Foundation
import Vapor

struct HealthDevice: Codable, Sendable {
    let name: String?
    let manufacturer: String?
    let model: String?
    let hardwareVersion: String?
    let softwareVersion: String?
}

struct HealthSampleDTO: Codable, Sendable {
    let uuid: UUID
    /// The HealthKit identifier, such as `HKQuantityTypeIdentifierHeartRate`.
    let type: String
    let start: Date
    let end: Date
    let value: Double?
    /// HKUnit.unitString of `value`.
    let unit: String?
    let categoryValue: Int?
    let sourceBundle: String
    let sourceName: String
    let device: HealthDevice?
    let metadata: [String: String]?
}

struct HealthSamplesUpload: Content {
    let key: String
    let items: [HealthSampleDTO]
}

struct WorkoutEventDTO: Codable, Sendable {
    let type: String
    let start: Date
    let end: Date
}

struct RoutePointDTO: Codable, Sendable {
    let t: Date
    let lat: Double
    let lon: Double
    let alt: Double?
    let hAcc: Double?
    let vAcc: Double?
    let speed: Double?
    let course: Double?
}

struct WorkoutDTO: Codable, Sendable {
    let uuid: UUID
    /// HKWorkoutActivityType rawValue.
    let activityType: Int
    let start: Date
    let end: Date
    let duration: Double
    let totalEnergyKcal: Double?
    let totalDistanceMeters: Double?
    let sourceBundle: String
    let sourceName: String
    let device: HealthDevice?
    let metadata: [String: String]?
    let events: [WorkoutEventDTO]?
    let route: [RoutePointDTO]?
}

struct HealthWorkoutsUpload: Content {
    let key: String
    let items: [WorkoutDTO]
}

struct ElectrocardiogramDTO: Codable, Sendable {
    let uuid: UUID
    let start: Date
    let end: Date
    let classification: String
    let averageHeartRate: Double?
    let samplingFrequency: Double?
    /// Lead I voltages in µV.
    let voltages: [Double]?
    let sourceBundle: String
    let sourceName: String
    let device: HealthDevice?
}

struct HealthElectrocardiogramsUpload: Content {
    let key: String
    let items: [ElectrocardiogramDTO]
}

struct HealthTypeSummary: Content {
    let type: String
    let count: Int
    let first: Date?
    let last: Date?
}

/// Apple Health import. Each request is one key, so a repeated request changes nothing. Within a request, rows are
/// upserted by their HealthKit uuid, so overlapping requests with different keys also do not duplicate.
enum HealthKitImport {
    static let maxSamples = 5_000
    static let maxWorkouts = 200
    static let maxElectrocardiograms = 500

    static func samples(_ upload: HealthSamplesUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        guard upload.items.count <= maxSamples else { throw Abort(.badRequest, reason: "At most \(maxSamples) items per request.") }
        let items = upload.items
        let calendar = user.calendar
        return try await Ingest.once(upload.key, kind: "healthkit", user: user, on: req) { sql in
            try await writeSamples(items, userID: user.id, calendar: calendar, sql: sql)
        }
    }

    static func workouts(_ upload: HealthWorkoutsUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        guard upload.items.count <= maxWorkouts else { throw Abort(.badRequest, reason: "At most \(maxWorkouts) items per request.") }
        let items = upload.items
        return try await Ingest.once(upload.key, kind: "healthkit", user: user, on: req) { sql in
            try await writeWorkouts(items, userID: user.id, sql: sql)
        }
    }

    static func electrocardiograms(_ upload: HealthElectrocardiogramsUpload, user: AuthenticatedUser, on req: Request) async throws -> UploadResult {
        guard upload.items.count <= maxElectrocardiograms else {
            throw Abort(.badRequest, reason: "At most \(maxElectrocardiograms) items per request.")
        }
        let items = upload.items
        return try await Ingest.once(upload.key, kind: "healthkit", user: user, on: req) { sql in
            try await writeElectrocardiograms(items, userID: user.id, sql: sql)
        }
    }

    static func writeSamples(_ items: [HealthSampleDTO], userID: UUID, calendar: Calendar, sql: any SQLDatabase) async throws {
        var unique: [UUID: HealthSampleDTO] = [:]
        for item in items { unique[item.uuid] = item }
        let rows = unique.values.sorted { $0.start < $1.start }
        try await Partitions.ensure(sql, parent: "healthkit_samples", covering: rows.map(\.start))
        for chunk in batched(rows, 1_000) {
            let values = try chunk.map { item -> Row in
                [userID, item.uuid, item.type, item.start, item.end, item.value, item.unit, item.categoryValue,
                 item.sourceBundle, item.sourceName, try json(item.device), try json(item.metadata)]
            }
            try await bulkInsert(sql, """
                INSERT INTO healthkit_samples (user_id, uuid, type, start, end_ts, value, unit, category_value, source_bundle, source_name, device_json, metadata_json) VALUES
                """, values, tail: """
                ON CONFLICT (user_id, uuid, start) DO UPDATE SET type = EXCLUDED.type, end_ts = EXCLUDED.end_ts, value = EXCLUDED.value,
                    unit = EXCLUDED.unit, category_value = EXCLUDED.category_value, source_bundle = EXCLUDED.source_bundle,
                    source_name = EXCLUDED.source_name, device_json = EXCLUDED.device_json, metadata_json = EXCLUDED.metadata_json
                """)
        }
        try await Rollup.recompute(over: rows.map(\.start), userID: userID, sql: sql, calendar: calendar)
    }

    static func writeWorkouts(_ items: [WorkoutDTO], userID: UUID, sql: any SQLDatabase) async throws {
        var unique: [UUID: WorkoutDTO] = [:]
        for item in items { unique[item.uuid] = item }
        let workouts = unique.values.sorted { $0.start < $1.start }
        try await Partitions.ensure(sql, parent: "healthkit_route_points", covering: workouts.flatMap { ($0.route ?? []).map(\.t) })

        for workout in workouts {
            let device = try json(workout.device)
            let metadata = try json(workout.metadata)
            let events = try json(workout.events)
            guard let row = try await sql.raw("""
                INSERT INTO healthkit_workouts (user_id, uuid, activity_type, start_ts, end_ts, duration, total_energy_kcal, total_distance_m,
                    source_bundle, source_name, device_json, metadata_json, events_json)
                VALUES (\(bind: userID), \(bind: workout.uuid), \(bind: workout.activityType), \(bind: workout.start), \(bind: workout.end),
                    \(bind: workout.duration), \(bind: workout.totalEnergyKcal), \(bind: workout.totalDistanceMeters),
                    \(bind: workout.sourceBundle), \(bind: workout.sourceName), \(bind: device), \(bind: metadata), \(bind: events))
                ON CONFLICT (user_id, uuid) DO UPDATE SET activity_type = EXCLUDED.activity_type, start_ts = EXCLUDED.start_ts,
                    end_ts = EXCLUDED.end_ts, duration = EXCLUDED.duration, total_energy_kcal = EXCLUDED.total_energy_kcal,
                    total_distance_m = EXCLUDED.total_distance_m, source_bundle = EXCLUDED.source_bundle, source_name = EXCLUDED.source_name,
                    device_json = EXCLUDED.device_json, metadata_json = EXCLUDED.metadata_json, events_json = EXCLUDED.events_json
                RETURNING id
                """).first(decoding: IDRow.self) else { continue }

            // The route is replaced with its workout, the same way activity records are.
            try await sql.raw("DELETE FROM healthkit_route_points WHERE workout_id = \(bind: row.id)").run()
            for chunk in batched(workout.route ?? [], 1_000) {
                try await bulkInsert(sql, """
                    INSERT INTO healthkit_route_points (workout_id, ts, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy, speed, course) VALUES
                    """, chunk.map { point -> Row in
                        [row.id, point.t, point.lat, point.lon, point.alt, point.hAcc, point.vAcc, point.speed, point.course]
                    }, tail: " ON CONFLICT (workout_id, ts) DO NOTHING")
            }
        }
    }

    static func writeElectrocardiograms(_ items: [ElectrocardiogramDTO], userID: UUID, sql: any SQLDatabase) async throws {
        var unique: [UUID: ElectrocardiogramDTO] = [:]
        for item in items { unique[item.uuid] = item }
        let rows = unique.values.sorted { $0.start < $1.start }
        for chunk in batched(rows, 500) {
            let values = try chunk.map { item -> Row in
                [userID, item.uuid, item.start, item.end, item.classification, item.averageHeartRate, item.samplingFrequency,
                 try json(item.voltages), item.sourceBundle, item.sourceName, try json(item.device)]
            }
            try await bulkInsert(sql, """
                INSERT INTO healthkit_electrocardiograms (user_id, uuid, start_ts, end_ts, classification, average_heart_rate, sampling_frequency, voltages_json, source_bundle, source_name, device_json) VALUES
                """, values, tail: """
                ON CONFLICT (user_id, uuid) DO UPDATE SET start_ts = EXCLUDED.start_ts, end_ts = EXCLUDED.end_ts,
                    classification = EXCLUDED.classification, average_heart_rate = EXCLUDED.average_heart_rate,
                    sampling_frequency = EXCLUDED.sampling_frequency, voltages_json = EXCLUDED.voltages_json,
                    source_bundle = EXCLUDED.source_bundle, source_name = EXCLUDED.source_name, device_json = EXCLUDED.device_json
                """)
        }
    }

    /// Per type: how many rows, and the first and last start. Workouts and ECGs are listed under their type names.
    static func types(_ req: Request, user: AuthenticatedUser) async throws -> [HealthTypeSummary] {
        try await req.sql.raw("""
            SELECT type, count(*) AS count, min(start) AS "first", max(start) AS "last"
            FROM healthkit_samples WHERE user_id = \(bind: user.id) GROUP BY type
            UNION ALL
            SELECT 'HKWorkoutType', count(*), min(start_ts), max(start_ts) FROM healthkit_workouts WHERE user_id = \(bind: user.id)
            UNION ALL
            SELECT 'HKElectrocardiogramType', count(*), min(start_ts), max(start_ts) FROM healthkit_electrocardiograms WHERE user_id = \(bind: user.id)
            ORDER BY type
            """).all(decoding: HealthTypeSummary.self)
    }

    /// Quantity samples of one type, bucketed by minute, hour or day in the server's time zone.
    static func quantities(_ req: Request, user: AuthenticatedUser, type: String, window: Reads.Window, resolution: String) async throws -> [SampleBucket] {
        guard ["minute", "hour", "day"].contains(resolution) else {
            throw Abort(.badRequest, reason: "`resolution` must be minute, hour or day.")
        }
        let zone = user.timeZone
        let bucket = "date_trunc('\(resolution)', start AT TIME ZONE '\(zone)') AT TIME ZONE '\(zone)'"
        return try await req.sql.raw("""
            SELECT \(unsafeRaw: bucket) AS start, count(*) AS count, avg(value) AS avg, min(value) AS min, max(value) AS max, sum(value) AS sum
            FROM healthkit_samples
            WHERE user_id = \(bind: user.id) AND type = \(bind: type) AND value IS NOT NULL
              AND start >= \(bind: window.from) AND start < \(bind: window.to)
            GROUP BY 1 ORDER BY 1
            """).all(decoding: SampleBucket.self)
    }

    private static func json<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return String(decoding: try TimeCoding.encoder.encode(value), as: UTF8.self)
    }
}
