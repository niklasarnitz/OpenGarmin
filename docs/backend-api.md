# OpenGarmin backend API (v1)

Self-hosted server that keeps every raw FIT file and all health data forever. Swift (Vapor) + PostgreSQL. Deployed at
`https://opengarmin.arnitz.org`. The app, the dashboard and the server share this contract; change it here first.

Times are ISO 8601. Ranges are `from` (inclusive) and `to` (exclusive) unless a field says otherwise. Days are
`YYYY-MM-DD` in the user's time zone.

## Auth

Email + password accounts. Passwords are hashed with Bcrypt. A session is an opaque token (random 32 bytes, stored
only as a SHA-256 hash, valid for a year). The same token works two ways:

- Apps send `Authorization: Bearer <token>`.
- The dashboard gets it as an `HttpOnly; Secure; SameSite=Lax` cookie named `opengarmin_session`.

Registration is open only while no user exists, or when `OPENGARMIN_ALLOW_SIGNUP=true`. Failed sign-ins are counted
per client address and email: after 10 failures in 15 minutes, further attempts get `429` for the rest of the window.
The count is kept in memory, per server process.

- `POST /api/v1/auth/register` `{email, password}` → `{token, user}`. Sets the session cookie.
- `POST /api/v1/auth/login` `{email, password}` → `{token, user}`. Sets the session cookie.
- `POST /api/v1/auth/logout` → 204. Clears the session cookie.
- `GET /api/v1/me` → `{id, email, createdAt, timeZone, workDays, workStart, workEnd}`.
- `PATCH /api/v1/me` `{timeZone?, workDays?, workStart?, workEnd?}` → the updated user. `timeZone` is an IANA name
  (default `Europe/Berlin`). Changing it rebuilds every daily value, because day boundaries move. `workDays` lists ISO
  weekdays, `1` = Monday … `7` = Sunday (default `[1,2,3,4,5]`). `workStart` and `workEnd` are whole hours, start before
  end (defaults `9` and `17`). They define working hours for stress by context and the insights.

### CSRF for cookie sessions

A cookie is sent by the browser on every request, so a request that authenticates only by cookie and is not `GET`,
`HEAD` or `OPTIONS` must carry the header `X-Requested-With: <any value>`. Otherwise the response is `403`. A
cross-site page cannot add this header without a CORS preflight, and the server never grants CORS. Bearer-token
requests are not affected.

## Upload (idempotent)

Every upload carries a client key. Uploading the same key again is a no-op that returns the existing record, so the
app can retry and re-sync freely. Keys are unique per user.

- `POST /api/v1/fit-files`: multipart with `file` (the raw .fit), `key`, `source` (`watch` | `connect`) and
  `deviceUnit` (optional). Also deduplicated by SHA-256 of the bytes: the same bytes under a new key share one stored
  file and are not decoded again. The server stores the bytes and decodes them with GarminFIT into the indexed
  tables. Response `{id, key, sha256, duplicate}`.
- `POST /api/v1/batches`: JSON `{key, source, batch: HealthBatch}` for Garmin data that has no FIT file (daily stress
  and Body Battery, and the other daily values). `HealthBatch` is GarminModels' Codable encoding (dates as ISO 8601).
  Response `{id, key, sha256, duplicate}`.
- `GET /api/v1/sync/state` → `{keys: [String]}`: every key already stored, of all kinds (FIT files, batches, Apple
  Health chunks, Connect archive entries). The app uploads only what is missing.

### Apple Health import

Each request is one key, and rows are upserted by their HealthKit `uuid`, so overlapping requests with different keys
do not duplicate either. Responses are `{id, key, sha256, duplicate}`. The request body may be up to 512 MB.

- `POST /api/v1/healthkit/samples`: `{key, items: [Sample]}`, at most 5,000 items.
  `Sample` = `{uuid, type, start, end, value?, unit?, categoryValue?, sourceBundle, sourceName, device?, metadata?}`.
  `type` is the HealthKit identifier (`HKQuantityTypeIdentifierHeartRate`, `HKCategoryTypeIdentifierSleepAnalysis`).
  Quantity samples carry `value` and `unit` (`HKUnit.unitString`); category samples carry `categoryValue`. Blood
  pressure arrives as its two quantity samples.
  `device` = `{name?, manufacturer?, model?, hardwareVersion?, softwareVersion?}`. `metadata` = `{String: String}`.
- `POST /api/v1/healthkit/workouts`: `{key, items: [Workout]}`, at most 200 items.
  `Workout` = `{uuid, activityType, start, end, duration, totalEnergyKcal?, totalDistanceMeters?, sourceBundle,
  sourceName, device?, metadata?, events?: [{type, start, end}], route?: [{t, lat, lon, alt?, hAcc?, vAcc?, speed?,
  course?}]}`. `activityType` is the `HKWorkoutActivityType` raw value. A repeated workout replaces its route.
- `POST /api/v1/healthkit/electrocardiograms`: `{key, items: [ECG]}`, at most 500 items.
  `ECG` = `{uuid, start, end, classification, averageHeartRate?, samplingFrequency?, voltages?: [Double], sourceBundle,
  sourceName, device?}`. `voltages` are lead I values in µV.
- `GET /api/v1/healthkit/types` → `[{type, count, first, last}]` for every type stored, workouts and ECGs included.
- `GET /api/v1/healthkit/quantities/{type}?from&to&resolution=minute|hour|day` → buckets (see Read).

## Read

- `GET /api/v1/samples/{metric}?from&to&resolution=raw|minute|hour|day&limit&cursor`. Metric is one of `heartRate`,
  `restingHeartRate`, `steps`, `activeEnergy`, `restingEnergy`, `distance`, `floors`, `intensityMinutes`, `stress`,
  `bodyBattery`, `spo2`, `respiration`, `hrv`.
  - `resolution=raw` (the default) returns full-resolution points, one page at a time:
    `{items: [{start, end, value}], nextCursor}`. `end` is set for interval metrics. A page has `limit` points (default
    and maximum 50,000). `nextCursor` is the start of the first point not returned yet; pass it as `cursor` to get the
    next page, or stop when it is `null`.
  - `minute`, `hour` and `day` return buckets, bucketed in the user's time zone:
    `[{start, count, avg, min, max, sum}]`. `sum` applies to intervals and `avg`, `min`, `max` to readings.
- `GET /api/v1/metrics` → `[{metric, source, unit, aggregation, first, last, count}]`: one entry per metric and
  source. `aggregation` is `sum` for amounts per day and `avg` for readings. `first` and `last` are days.
- `GET /api/v1/metrics/daily?from&to&metrics=a,b,c` → `[{day, metric, source, value, min?, max?, count}]` (`count`: samples behind the value), one row per day,
  metric and source. `to` is exclusive. `value` is the day's sum for `sum` metrics and the average for readings, with
  `min` and `max`. Metrics are the Garmin names above, plus `sleepMinutes`, `sleepDeepMinutes`, `sleepLightMinutes`,
  `sleepRemMinutes`, `sleepAwakeMinutes`, `activityMinutes`, and every Apple Health quantity type by its identifier.
  `source` is `garmin` or `healthkit:<bundleID>`. Apple Health samples whose source bundle is
  `com.niklasarnitz.opengarmin` or starts with `com.garmin` are reported as `healthkit:garmin-mirror`, because they
  copy Garmin data. Apple Health sleep (`HKCategoryTypeIdentifierSleepAnalysis`) adds `sleep*Minutes` rows under its
  source, each sample on the day 12 hours before it, so a night counts on the evening it starts. Apple Health workouts
  that overlap no Garmin activity add `activityMinutes`.
- `GET /api/v1/sleep?from&to` → `[{start, end, score?, breakdown?, stages: [{start, end, stage}], source}]`. Stages are
  `awake`, `light`, `deep`, `rem`, `unmeasurable`, or `asleep` (Health sleep without a stage). `source` is `garmin` or a
  Health source as above. Health sleep samples of one app become a night where they are at most 2 hours apart; a Health
  night that overlaps a Garmin night is left out, and of overlapping Health nights the Garmin mirror wins, then the one
  with the most sleep.
- `GET /api/v1/activities?from&to&limit&cursor` → `{items, nextCursor}`, newest first, `limit` up to 200. Items carry
  `source`: Garmin activities, plus Apple Health workouts (Google Fit and others) that overlap no Garmin activity, with
  the activity type mapped to the nearest FIT sport.
  `GET /api/v1/activities/{id}` → `{activity, laps, records}`; a Health workout has no laps and its route as records.
  `GET /api/v1/activities/{id}/fit` → the raw file (Garmin only).
- `GET /api/v1/days?from&to` → daily summaries: steps, active energy, resting heart rate, average stress, sleep
  minutes and activity count.
- `GET /api/v1/export/history?from&to` → a `HealthBatch` for the range, so the app can restore after a reinstall.

## Storage

Nothing is pruned or downsampled. Every decoded sample (per-minute heart rate, stress, Body Battery, SpO2,
respiration, step intervals), every activity and record, every Apple Health sample and route point, and every raw FIT
file and Connect response is kept at full resolution for as long as the server runs. Daily rollups are an additional
derived table only.

- Raw bytes: S3 when `OPENGARMIN_S3_ENDPOINT` is set, otherwise files under `OPENGARMIN_DATA_DIR`. Keys are derived from
  the content: `fit/<sha256[0..2]>/<sha256>.fit` for FIT files and `connect-raw/<endpoint>/<day or activityId>/<sha256>.json.gz`
  for Connect responses. An upload skips the write when the object already exists. The S3 path uses path-style
  addressing, so versitygw, MinIO and other self-hosted stores work.
- Metadata in `fit_files` (one row per client key: kind, source, sha256, size, storage key, decode status) and
  `connect_raw` (one row per Connect response, with its parser version).
- Samples: one table keyed `(user_id, metric, ts)` with a unique constraint, so re-imports upsert. Range-partitioned by
  month, partitions created on demand, with BRIN on time inside each partition.
- Apple Health: `healthkit_samples`, `healthkit_workouts`, `healthkit_route_points` and ECGs. Samples and route points
  are range-partitioned by month like the Garmin series. Unique on `(user_id, uuid, start)`.
- `activities`, `activity_laps`, `activity_records` (partitioned by month), `sleep_sessions`, `sleep_stages`,
  `daily_summaries` (recomputed for the days an upload touches), `metric_daily` (the rollup), `insight_runs` and `insights`.
- Migrations run through Fluent. Partitioning and rollups are plain SQL.

## Connect archive

Raw Garmin Connect responses are archived on the server, so a parsing mistake is fixed by parsing again, not by asking
Garmin again.

- `POST /api/v1/connect/raw`: JSON `{key, endpoint, day?, activityId?, fetchedAt, body}`. `endpoint` is one of
  `dailySleepData`, `dailyStress`, `dailySummaryChart`, `usersummary`, `hrv`, `activityList`. `day` is `YYYY-MM-DD`
  (required for `usersummary`). `activityId` is set for activity responses. `body` is the response JSON exactly as Garmin
  sent it. Idempotent by `key`: a repeated key returns the first result with `duplicate: true`. Response
  `{id, key, sha256, duplicate}`.
- The body is stored gzip-compressed under the storage key in the Storage section. The key appears in `GET /api/v1/sync/state`.
- The server parses the body into the same tables as the FIT and Apple Health data: sleep sessions with stages and
  score, stress, Body Battery, steps, resting heart rate, HRV and, from `activityList`, activity summaries. The sample
  tables have no source column, so a Connect-derived value is not separable from a FIT-derived one except through
  `connect_raw`. `/api/v1/metrics` reports these values as `garmin`. An activity
  summary is replaced by the FIT file of the same run when one starts within a minute of it.
- Every archived response records the parser version it was parsed with. At startup, the server parses again each
  response whose version is older, so a parser fix applies to the whole archive.
- `GET /api/v1/connect/diagnostics` → `{nights, mappingAgreement: [{code, stage, nights, share}], mismatches: [{day, minutesPerCode, dtoTotals}]}`.
  - For each night with sleep levels and `dailySleepDTO` stage totals, the server assigns raw sleep codes 0 to 3 to
    stages (deep, light, REM, awake) in the way that best matches Garmin's totals (`deepSleepSeconds` and the others).
    The default is 0 deep, 1 light, 2 awake, 3 REM. Another assignment is used only when it fits the totals better.
  - `mappingAgreement` counts, for each code and stage, the nights that assignment was chosen for. `share` is `nights`
    divided by the number of checked nights.
  - `mismatches` lists the nights where the best assignment is more than 5 minutes off in total. `minutesPerCode` gives
    the minutes of each raw code (keys `"0"` to `"3"`), and `dtoTotals` gives Garmin's minutes per stage (keys `deep`,
    `light`, `rem`, `awake`).
  - The server also serves a plain page with these results at `/connect.html`, for the same signed-in session. The
    dashboard can replace it.

## Insights

- `GET /api/v1/insights?from&to&lang=en|de` → `[Insight]`, sorted by `strength × confidence`, highest first. `from` and
  `to` are days or ISO 8601 instants; `to` is exclusive. Without them the range is all of history up to and including today.
  `lang` defaults to `en`.
- `Insight` = `{id, kind, title, summary, detail, metrics, strength, confidence, n, period, lagDays?, chart?}`.
  - `kind` is one of `trend`, `correlation`, `changepoint`, `anomaly`, `pattern`, `record`.
  - `title`, `summary` and `detail` are full sentences in the requested language. They describe associations and changes
    over time and never claim causation. `detail` may be empty.
  - `metrics` uses the same keys as `GET /api/v1/metrics`. `strength` and `confidence` are in 0 to 1. `n` is the number
    of days, nights or pairs the finding is based on.
  - `period` is `{from, to}` as `YYYY-MM-DD` days, inclusive at both ends. This differs from the query ranges, where `to`
    is exclusive.
  - `lagDays` is an integer from 0 to 3, present only on `correlation` insights. It is the lag the finding is about:
    `metrics[0]` on day d is paired with `metrics[1]` on day d + `lagDays`. Lag 0 pairs the same day. Other kinds omit it.
  - `chart`, when present, is `{type: "line" | "scatter" | "bar", series: [{name, points: [[x, y]]}]}`. An `x` is a day
    string, an ISO 8601 instant or a number. Trend charts use epoch milliseconds for the first of each month.
- Algorithms: Theil–Sen slope with Mann–Kendall significance for trends; binary segmentation for changepoints, reported
  with before and after means; Spearman correlations at lags 0 to 3 with Benjamini–Hochberg correction, a minimum of 30
  pairs and bootstrap intervals; conditional comparisons (after days with more than 10,000 steps, deep sleep is …) with
  Welch tests; robust z-scores against a 28-day median and MAD for anomalies, merged into episodes; Kruskal–Wallis for
  weekday patterns; summer against winter; bedtime and wake-up variability; social jetlag between free days and workdays;
  stress by context; and personal bests and streaks.
- Computation: a background job recomputes a user's cached runs once their data has been quiet for five minutes after
  an upload, a settings change or a time zone change. Every night at 03:00 UTC it recomputes all of them. A run that is not
  cached is computed by the GET itself. If that takes longer than 20 seconds, the GET returns `504` and the computation
  finishes in the background, so the next GET finds it. Runs not requested for 30 days are dropped.

## Garmin Connect uploads (the app)

After every successful watch sync and every Garmin Connect import, the app uploads in the background: it fetches
`sync/state`, then uploads the FIT files and the non-FIT batches whose keys the server lacks. Server URL, email and
password are entered in Settings; the token is kept in the Keychain.
