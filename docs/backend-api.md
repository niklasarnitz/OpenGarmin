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

## Garmin Connect archive

Raw Garmin Connect responses are archived on the server, so parsing mistakes are fixed by parsing again, not by asking Garmin again.

- `POST /api/v1/connect/raw` — JSON `{key, endpoint, day?, activityId?, fetchedAt, body}`. `endpoint` is one of `dailySleepData`, `dailyStress`, `dailySummaryChart`, `usersummary`, `hrv`, `activityList`. `day` is `YYYY-MM-DD` (required for `usersummary`). `activityId` is set for activity responses. `body` is the response JSON exactly as Garmin sent it. Idempotent by `key`: a repeated key returns the first result with `duplicate: true`. Response `{id, key, sha256, duplicate}`.
- The body is stored gzip-compressed under `connect-raw/<endpoint>/<day or activityId>/<sha256>.json.gz` in the blob store (S3 or `OPENGARMIN_DATA_DIR`), with a metadata row in `connect_raw`. The key appears in `GET /api/v1/sync/state`.
- The server parses the body into the same tables as the other data, with source `connect`: sleep sessions with stages and score, stress, Body Battery, steps, resting heart rate and HRV. `activityList` is archived but not parsed yet.
- Every archived response records the parser version it was parsed with. At startup the server parses again each response whose version is older, so a parser fix applies to the whole archive.
- `GET /api/v1/connect/diagnostics` → `{nights, mappingAgreement: [{code, stage, nights, share}], mismatches: [{day, minutesPerCode, dtoTotals}]}`.
  - For each night with sleep levels and `dailySleepDTO` stage totals, the server assigns raw sleep codes 0 to 3 to stages (deep, light, REM, awake) in the way that best matches Garmin's own totals (`deepSleepSeconds` and the others). The default is 0 deep, 1 light, 2 awake, 3 REM, and another assignment is used only when it fits the totals better.
  - `mappingAgreement` counts, for each code and stage, the nights that assignment was chosen for. `share` is `nights` divided by the number of checked nights.
  - The server also serves a plain page with these results at `/connect.html`, for the same signed-in session. The dashboard can replace it.
  - `mismatches` lists the nights where the best assignment is more than 5 minutes off in total. `minutesPerCode` gives the minutes of each raw code (keys `"0"` to `"3"`), and `dtoTotals` gives Garmin's minutes per stage (keys `deep`, `light`, `rem`, `awake`).

## Insights

- `GET /api/v1/insights?from&to&lang=en|de` → `[Insight]`, sorted by `strength × confidence`, highest first. `lang` defaults to `en`.
- `Insight` = `{id, kind, title, summary, detail, metrics, strength, confidence, n, period, lagDays?, chart?}`.
  - `kind` is one of `trend`, `correlation`, `changepoint`, `anomaly`, `pattern`, `record`.
  - `title`, `summary` and `detail` are full sentences in the requested language. They describe associations and changes over time and never claim causation.
  - `metrics` uses the same keys as `GET /api/v1/metrics`. `strength` and `confidence` are in 0 to 1. `n` is the number of days or pairs the finding is based on.
  - `period` is `{from, to}` as `YYYY-MM-DD` days, inclusive at both ends. This differs from the `from`/`to` query ranges, where `to` is exclusive.
  - `lagDays` is an integer from 0 to 3, present only on `correlation` insights. It is the lag the finding is about: `metrics[0]` on day d is paired with `metrics[1]` on day d + `lagDays`. Lag 0 pairs the same day. Other kinds omit it.
  - `chart`, when present, is `{type: "line" | "scatter" | "bar", series: [{name, points: [[x, y]]}]}`. An `x` is a day string, an ISO 8601 instant or a number.
