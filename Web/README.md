# OpenGarmin web

The personal health dashboard served at `https://opengarmin.arnitz.org`. A static single-page app: Vite, React and TypeScript, with Bun as the package manager. The build is `Web/dist`, which the Vapor server serves from `Public/` with SPA fallback. All API paths are relative (`/api/v1/...`), and asset paths are relative (`base: "./"`).

## Commands

```sh
bun install
bun run dev         # http://localhost:5173; add ?mock to run without a server
bun run build       # type check, then static build to dist/
bun run test        # vitest: analytics, stats, source resolution, insight links
bun run typecheck
```

Mock mode needs no server: open `?mock` (or build with `VITE_MOCK=1`). The fixtures in `src/mock.ts` cover March 2019 to today: seasonal steps, a slowly falling resting heart rate, sleep that predicts next-day HRV and stress, a bedtime that drifts later, a Garmin gap in early 2022 that Apple Health fills, two step sources, Apple Health nights without stages and Google Fit walks and rides without heart rate before the watch, about a thousand Garmin activities with records and laps, and the server's insight findings, computed from the same data.

## Charts and maps

- **Apache ECharts** (canvas renderer, tree-shaken to the parts used). The series are long daily runs with thousands of points, which SVG handles poorly. ECharts gives time axes, mark lines for changepoints, scatter with regression lines, stacked bars for sleep stages, and a year-over-year overlay without custom code.
- **Leaflet** with OpenStreetMap tiles for the route map. It is small, has no framework coupling, and the attribution is shown on the map.
- The year-by-day strip and the correlation matrix are plain SVG and HTML, because they are fixed-size grids.

## Analytics

Plain TypeScript in `src/lib/`, with no UI dependencies:

- `stats.ts`: mean, median, sample SD, OLS, Theil–Sen, Mann–Kendall, Pearson with a normal-approximation p-value.
- `analytics.ts`: aggregation by day, week, month or year; trailing means that skip missing days; baselines that never include the day itself; per-calendar-month fixed effects with a Theil–Sen slope for trends; a single level-shift changepoint; lagged relations; the correlation matrix.
- `sources.ts`: one value per day from the preferred source, Garmin first, falling back to Apple Health. Mirrored samples (`healthkit:garmin-mirror`) are dropped unless the user opts in.
- `insights.ts`: maps a server finding to the explorer and correlation links that show its metrics and period.

The server's insights (`/api/v1/insights`) are the curated layer. The overview shows the three strongest, and the Findings page filters them by kind and metric. The explorer and the correlation view are the interactive layer on top.

## Endpoints relied on

| Endpoint | Used for |
| --- | --- |
| `GET /api/v1/me` | session check |
| `POST /api/v1/auth/login`, `POST /api/v1/auth/logout` | cookie session; the response is read as `{user}` |
| `GET /api/v1/metrics` | catalogue of metric and source pairs, including first and last day |
| `GET /api/v1/metrics/daily?from&to&metrics=` | daily values; `to` is exclusive |
| `GET /api/v1/sleep?from&to` | sleep sessions with stages |
| `GET /api/v1/activities?limit&cursor`, `GET /api/v1/activities/{id}` | list with cursor paging; detail with laps and records |
| `GET /api/v1/insights?from&to&lang` | curated findings, already sorted by interest |

## Contract with the server

Every response is parsed with the zod schemas in `src/api/schema.ts`, which mirror the server's Swift types; the
TypeScript types in `src/api/types.ts` are derived from them. A response that breaks the contract fails with the path
of the bad field instead of rendering wrong data. `src/api/schema.test.ts` checks server-shaped bodies and every mock
response against the schemas, so mock mode cannot drift from the server. Days are the branded `Day` type: only
`parseDay`, the schemas and day arithmetic produce one, and ranges are sent as `YYYY-MM-DD` with `to` exclusive.

- HealthKit types are named by their identifier (`HKQuantityTypeIdentifier...`); the dashboard matches both those and the Garmin names.
- An insight's `period` uses `YYYY-MM-DD` days, inclusive at both ends. Line chart x values are epoch milliseconds; bar and scatter x values are used as they are.
- Correlation insights carry an optional `lagDays` (0–3). The link opens the correlation view at that lag, or at lag 0 without it.

## Decisions for the owner

- Source preferences (which source wins per metric, and whether mirrored samples show) are stored in this browser's `localStorage`. Syncing them to the server would need an endpoint.
