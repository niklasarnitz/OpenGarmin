# OpenGarmin backend API (v1)

Self-hosted server that keeps every raw FIT file and all health data forever. Swift (Vapor) + PostgreSQL. Deployed at
`https://opengarmin.arnitz.org`. The app and the server share this contract; change it here first.

## Auth

Email + password accounts. Passwords hashed with Bcrypt. Sessions are opaque bearer tokens (random 32 bytes,
stored hashed), sent as `Authorization: Bearer <token>`. Registration is open only while no user exists, or when
`OPENGARMIN_ALLOW_SIGNUP=true`.

- `POST /api/v1/auth/register` `{email, password}` → `{token, user}`
- `POST /api/v1/auth/login` `{email, password}` → `{token, user}`
- `POST /api/v1/auth/logout` → 204
- `GET /api/v1/me` → `{id, email, createdAt}`

The web UI uses the same login (cookie session).

## Upload (idempotent)

Every upload carries a client key. Uploading the same key twice is a no-op that returns the existing record, so the
app can retry and re-sync freely.

- `POST /api/v1/fit-files` — multipart: `file` (the raw .fit), `key` (the app's file key, e.g.
  `<unit>-<index>-<timestamp>-<size>` or `<unit>-connect-<activityID>`), `source` (`watch` | `connect`),
  `deviceUnit` (optional). Also deduplicated by SHA-256 of the bytes. The server stores the bytes and decodes the
  file with GarminFIT (`FitDecoder` + `FitExtractor`) into the indexed tables. Response
  `{id, key, sha256, duplicate: Bool}`.
- `POST /api/v1/batches` — JSON `{key, source, batch: HealthBatch}` for data that has no FIT file (Garmin Connect
  daily stress and Body Battery). `HealthBatch` is GarminModels' Codable encoding (dates as ISO 8601).
- `GET /api/v1/sync/state` → `{keys: [String]}` of everything already stored, so the app uploads only the rest.

## Read

All ranges are `from`/`to` ISO 8601, inclusive start, exclusive end.

- `GET /api/v1/samples/{metric}?from&to&resolution=raw|minute|hour|day` — metric is one of `heartRate`,
  `restingHeartRate`, `steps`, `activeEnergy`, `restingEnergy`, `distance`, `floors`, `intensityMinutes`, `stress`,
  `bodyBattery`, `spo2`, `respiration`, `hrv`. Aggregated resolutions return avg/min/max (or sum for cumulative
  metrics) per bucket.
- `GET /api/v1/sleep?from&to` → sleep sessions with stages.
- `GET /api/v1/activities?from&to&limit&cursor` → activity summaries; `GET /api/v1/activities/{id}` with laps and
  records; `GET /api/v1/activities/{id}/fit` → the raw file.
- `GET /api/v1/days?from&to` → daily summaries (steps, energy, resting HR, avg stress, sleep minutes, activity count).
- `GET /api/v1/export/history?from&to` → a `HealthBatch` for the range, so the app can restore after a reinstall.

## Storage

- Raw FIT bytes in a `fit_files` table (`bytea`, or on disk under `OPENGARMIN_DATA_DIR` keyed by SHA-256) with
  key, source, sha256, size, uploaded/decoded timestamps, decode error.
- Samples in one narrow table per kind, all keyed `(user_id, metric, time)` with a unique constraint so re-imports
  upsert instead of duplicating. Range-partitioned by month (declarative partitioning, partitions created on
  demand) with BRIN on time inside each partition, so many years stay fast.
- `activities`, `activity_laps`, `activity_records` (records partitioned like samples), `sleep_sessions`,
  `sleep_stages`, `daily_summaries` (recomputed for the days an upload touches).
- Migrations through Fluent; partitioning DDL as raw SQL migrations.

## App behaviour

After every successful watch sync and every Garmin Connect import, the app uploads in the background: it fetches
`sync/state`, then uploads the FIT files from `Application Support/OpenGarmin/FIT/` and the non-FIT batches whose
keys the server lacks. Server URL, email and password are entered in Settings; the token is kept in the Keychain.
