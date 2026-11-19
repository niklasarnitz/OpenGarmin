// Deterministic fixtures for mock mode (?mock or VITE_MOCK=1). Shapes match docs/backend-api.md. The data has
// a seasonal step count, a slowly falling resting heart rate, sleep that predicts next-day HRV and stress, a
// bedtime that drifts later, a Garmin gap in early 2022 (Apple Health fills it), and two step sources. Garmin
// samples are mirrored into HealthKit from the watch's arrival on, which the server marks as garmin-mirror. Before
// the watch and in the gap, Apple Health has nights without stages ("asleep") and Google Fit has walks and rides
// without heart rate, some with a route.

import type {
  ActivityDetail,
  ActivityPage,
  ActivityRecord,
  ActivitySummary,
  Aggregation,
  DailyPoint,
  Lap,
  MeResponse,
  MetricInfo,
  SleepInterval,
  SleepSession,
  SleepStage,
} from "./api/types";
import type { Insight } from "./api/types";
import { records, relate, trend, type Series } from "./lib/analytics";
import { addDays, dayMs, dayOf, dayOfYear, daysInclusive, parseDay, todayDay, weekdayIndex, type Day } from "./lib/time";

export const me: MeResponse = {
  id: "demo",
  email: "demo@opengarmin.local",
  createdAt: "2019-03-01T08:00:00Z",
  timeZone: "Europe/Berlin",
  workDays: [1, 2, 3, 4, 5],
  workStart: 9,
  workEnd: 17,
};

const START = "2019-03-01" as Day;
const WATCH_FROM = "2021-07-01" as Day;
const GAP = ["2022-02-10", "2022-03-05"] as [Day, Day];
const APPLE = "healthkit:com.apple.health";
const APPLE_WATCH = "healthkit:com.apple.health.5F3A1C2E-0D4B-4E7A-9C61-2B8D7E4F1A90";
const MIRROR = "healthkit:garmin-mirror";
const GOOGLE_FIT = "healthkit:com.google.android.apps.fitness";
const HEALTH_FROM = "2020-01-01" as Day;
const HK_STEPS = "HKQuantityTypeIdentifierStepCount";
const HK_RHR = "HKQuantityTypeIdentifierRestingHeartRate";
const HK_HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN";
const HK_WEIGHT = "HKQuantityTypeIdentifierBodyMass";
const HK_BMI = "HKQuantityTypeIdentifierBodyMassIndex";

const META: Record<string, { unit: string; aggregation: Aggregation }> = {
  steps: { unit: "count", aggregation: "sum" },
  activeEnergy: { unit: "kcal", aggregation: "sum" },
  intensityMinutes: { unit: "min", aggregation: "sum" },
  restingHeartRate: { unit: "bpm", aggregation: "avg" },
  hrv: { unit: "ms", aggregation: "avg" },
  stress: { unit: "score", aggregation: "avg" },
  bodyBattery: { unit: "score", aggregation: "avg" },
  sleepMinutes: { unit: "min", aggregation: "sum" },
  spo2: { unit: "%", aggregation: "avg" },
  respiration: { unit: "brpm", aggregation: "avg" },
  [HK_STEPS]: { unit: "count", aggregation: "sum" },
  [HK_RHR]: { unit: "bpm", aggregation: "avg" },
  [HK_HRV]: { unit: "ms", aggregation: "avg" },
  heartRate: { unit: "bpm", aggregation: "avg" },
  restingEnergy: { unit: "kcal", aggregation: "sum" },
  activityMinutes: { unit: "min", aggregation: "sum" },
  sleepDeepMinutes: { unit: "min", aggregation: "sum" },
  sleepLightMinutes: { unit: "min", aggregation: "sum" },
  sleepRemMinutes: { unit: "min", aggregation: "sum" },
  sleepAwakeMinutes: { unit: "min", aggregation: "sum" },
  [HK_WEIGHT]: { unit: "kg", aggregation: "avg" },
  [HK_BMI]: { unit: "count", aggregation: "avg" },
};

// MARK: - Random numbers

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const clamp = (x: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, x));
const round1 = (x: number) => Math.round(x * 10) / 10;

// MARK: - Nights and days

interface Row {
  day: Day;
  watch: boolean;
  steps: number;
  appleSteps: number;
  activeEnergy: number;
  intensity: number;
  rhr: number;
  appleRhr?: number;
  hrv: number;
  appleHrv: number;
  stress: number;
  stressRange: [number, number];
  bbRange: [number, number];
  spo2: number;
  resp: number;
  sleepMin: number;
  sleep?: SleepSession;
  weight?: number;
}

interface Summary {
  activity: ActivitySummary;
  seed: number;
  speed: number;
  /** Undefined for a Health workout, which has no heart rate and no laps. */
  hr: number | undefined;
  cadence: number | undefined;
  /** False for a Health workout recorded without a route. */
  route: boolean;
}

interface Dataset {
  rows: Row[];
  points: DailyPoint[];
  summaries: Summary[];
}

const SPORTS = [
  { sport: 1, weight: 0.5, speed: [2.5, 3.6], hr: [150, 168], dur: [1800, 4200], ascent: [20, 200], calPerMin: 11 },
  { sport: 2, weight: 0.25, speed: [6, 8.5], hr: [125, 145], dur: [3600, 7200], ascent: [40, 500], calPerMin: 8 },
  { sport: 11, weight: 0.15, speed: [1.2, 1.5], hr: [95, 110], dur: [2400, 3600], ascent: [5, 60], calPerMin: 5 },
  { sport: 17, weight: 0.1, speed: [0.9, 1.3], hr: [120, 135], dur: [7200, 14400], ascent: [300, 900], calPerMin: 7 },
];

let cache: Dataset | undefined;

function dataset(): Dataset {
  if (cache) return cache;
  const rand = mulberry32(20190301);
  const gauss = () => Math.sqrt(-2 * Math.log(Math.max(rand(), 1e-9))) * Math.cos(2 * Math.PI * rand());
  const between = (lo: number, hi: number) => lo + (hi - lo) * rand();
  const rows: Row[] = [];
  const summaries: Summary[] = [];

  daysInclusive(START, todayDay()).forEach((day, i) => {
    const prev = rows[i - 1];
    const years = i / 365.25;
    const season = Math.cos((2 * Math.PI * (dayOfYear(day) - 190)) / 365.25); // +1 around 9 July
    const weekend = weekdayIndex(day) >= 5 ? 1 : 0;
    const watch = day >= WATCH_FROM && (day < GAP[0] || day > GAP[1]);
    const prevSleep = prev?.sleepMin ?? 430;
    const illness = rand() < 0.03;

    const sleepMin = clamp(Math.round(425 + 22 * weekend + 35 * gauss()), 300, 580);
    const steps = clamp(Math.round(8200 + 1600 * season + 300 * years + (weekend ? -700 : 300) + 2000 * gauss()), 800, 26000);
    const rhr = clamp(63 - 0.9 * years - 1.6 * season + 0.04 * (430 - prevSleep) + 1.3 * gauss() + (illness ? 6 : 0), 42, 85);
    const inGap = day >= GAP[0] && day <= GAP[1];
    const appleRhr = day >= "2020-01-01" && (rand() < 0.6 || inGap) ? round1(rhr + 2 + 1.5 * gauss()) : undefined;
    const hrv = clamp(50 + 1.0 * years + 0.05 * (prevSleep - 430) + 4 * gauss() - (illness ? 12 : 0), 15, 120);
    const stress = clamp(34 - 0.025 * (prevSleep - 430) + 6 * gauss() + (weekend ? -2 : 0), 5, 95);
    const bbMax = clamp(60 + 0.22 * (prevSleep - 400) + 6 * gauss(), 20, 100);
    const bbMin = clamp(bbMax - 38 + 5 * gauss(), 3, 60);

    const row: Row = {
      day,
      watch,
      steps,
      appleSteps: Math.round(watch ? steps * 1.04 + 350 * gauss() : 6200 + 1300 * season + 1200 * gauss()),
      activeEnergy: clamp(Math.round(steps * 0.042 + 60 * gauss()), 20, 2500),
      intensity: clamp(Math.round(22 + 14 * season + 14 * gauss()), 0, 120),
      rhr,
      appleRhr,
      hrv,
      appleHrv: round1(hrv * 0.92 + 4 + 2 * gauss()),
      stress,
      stressRange: [clamp(stress - 12 - 4 * rand(), 0, 100), clamp(stress + 18 + 6 * rand(), 0, 100)],
      bbRange: [bbMin, bbMax],
      spo2: clamp(96.5 + 0.9 * gauss(), 90, 100),
      resp: clamp(14.6 + 0.6 * gauss(), 10, 22),
      sleepMin,
      weight: day >= HEALTH_FROM && rand() < 0.3 ? round1(82 - 1.2 * years + 0.8 * season + 0.6 * gauss()) : undefined,
    };

    if (watch) {
      // The night that ends on this morning, starting the evening before.
      const bedMin = Math.round(23 * 60 + 15 + 14 * years + 25 * gauss());
      const [y = 2019, m = 1, d = 1] = day.split("-").map(Number);
      const start = new Date(y, m - 1, d - 1, 0, bedMin);
      row.sleep = {
        start: start.toISOString(),
        end: new Date(start.getTime() + sleepMin * 60_000).toISOString(),
        stages: stages(start, sleepMin, rand),
        score: clamp(Math.round(60 + (sleepMin - 380) / 6 + 5 * gauss()), 40, 98),
        source: "garmin",
      };
    } else if (day >= HEALTH_FROM && rand() < 0.7) {
      // An Apple Watch night: asleep or awake, no stages, no score.
      const bedMin = Math.round(23 * 60 + 25 + 25 * gauss());
      const start = new Date(y0(day), m0(day) - 1, d0(day) - 1, 0, bedMin);
      const asleepEnd = start.getTime() + sleepMin * 60_000;
      const awake = Math.round(5 + 10 * rand());
      row.sleep = {
        start: start.toISOString(),
        end: new Date(asleepEnd + awake * 60_000).toISOString(),
        stages: [
          { start: start.toISOString(), end: new Date(asleepEnd).toISOString(), stage: "asleep" },
          { start: new Date(asleepEnd).toISOString(), end: new Date(asleepEnd + awake * 60_000).toISOString(), stage: "awake" },
        ],
        source: APPLE_WATCH,
      };
    }
    rows.push(row);

    if (!watch && rand() < 0.2) {
      // A Google Fit walk or ride; about half carry a route.
      const ride = rand() < 0.3;
      const index = summaries.length + 1;
      const duration = Math.round(ride ? between(1800, 5400) : between(1200, 3600));
      const speed = ride ? between(4.5, 6.5) : between(1.2, 1.5);
      const start = new Date(y0(day), m0(day) - 1, d0(day), 8 + Math.floor(between(0, 11)), Math.floor(between(0, 60)));
      summaries.push({
        activity: {
          id: `hk-${String(index).padStart(4, "0")}`,
          externalId: `hk-uuid-${index}`,
          source: GOOGLE_FIT,
          sport: ride ? 2 : 11,
          start: start.toISOString(),
          end: new Date(start.getTime() + duration * 1000).toISOString(),
          duration,
          distance: Math.round(speed * duration),
          activeCalories: Math.round((duration / 60) * (ride ? 7 : 4)),
          averageSpeed: Math.round(speed * 100) / 100,
        },
        seed: index * 977 + 13,
        speed,
        hr: undefined,
        cadence: undefined,
        route: rand() < 0.5,
      });
    }

    if (watch && rand() < 0.38) {
      let pick = rand();
      const spec = SPORTS.find((s) => (pick -= s.weight) < 0) ?? SPORTS[0]!;
      const index = summaries.length + 1;
      const duration = Math.round(between(spec.dur[0] ?? 0, spec.dur[1] ?? 0));
      const speed = between(spec.speed[0] ?? 0, spec.speed[1] ?? 0);
      const hr = Math.round(between(spec.hr[0] ?? 0, spec.hr[1] ?? 0));
      const start = new Date(y0(day), m0(day) - 1, d0(day), 7 + Math.floor(between(0, 12)), Math.floor(between(0, 60)));
      const end = new Date(start.getTime() + duration * 1000);
      summaries.push({
        activity: {
          id: `act-${String(index).padStart(4, "0")}`,
          externalId: `mock-${index}`,
          source: "garmin",
          sport: spec.sport,
          start: start.toISOString(),
          end: end.toISOString(),
          duration,
          distance: Math.round(speed * duration),
          activeCalories: Math.round((duration / 60) * spec.calPerMin),
          averageHeartRate: hr,
          maxHeartRate: hr + Math.round(between(18, 30)),
          averageSpeed: round1(speed * 100) / 100,
          totalAscent: Math.round(between(spec.ascent[0] ?? 0, spec.ascent[1] ?? 0)),
          trainingEffect: round1(between(1, 4.5)),
        },
        seed: index * 977 + 13,
        speed,
        hr,
        cadence: spec.sport === 1 ? Math.round(between(165, 176)) : spec.sport === 2 ? Math.round(between(85, 95)) : undefined,
        route: true,
      });
    }
  });

  const points: DailyPoint[] = [];
  const add = (day: Day, metric: string, source: string, value: number, range?: [number, number]) => {
    const point: DailyPoint = { day, metric, source, value: round1(value), count: 1 };
    if (range) {
      point.min = round1(range[0]);
      point.max = round1(range[1]);
    }
    points.push(point);
  };
  const activityMinutes = new Map<Day, { source: string; minutes: number }>();
  for (const { activity } of summaries) {
    const day = dayOfIso(activity.start);
    const prior = activityMinutes.get(day)?.minutes ?? 0;
    activityMinutes.set(day, { source: activity.source, minutes: prior + activity.duration / 60 });
  }
  for (const row of rows) {
    const { day } = row;
    const night = row.sleep && sleepMinutesByStage(row.sleep);
    if (row.sleep?.source === "garmin" && night) {
      add(day, "sleepDeepMinutes", "garmin", night.deep);
      add(day, "sleepLightMinutes", "garmin", night.light);
      add(day, "sleepRemMinutes", "garmin", night.rem);
      add(day, "sleepAwakeMinutes", "garmin", night.awake);
    } else if (row.sleep && night) {
      add(day, "sleepMinutes", row.sleep.source, night.asleep);
      add(day, "sleepAwakeMinutes", row.sleep.source, night.awake);
    }
    const workouts = activityMinutes.get(day);
    if (workouts) add(day, "activityMinutes", workouts.source, workouts.minutes);
    if (row.weight !== undefined) {
      add(day, HK_WEIGHT, APPLE, row.weight);
      add(day, HK_BMI, APPLE, row.weight / (1.78 * 1.78));
    }
    if (row.watch) {
      add(day, "heartRate", "garmin", row.rhr + 16 + 2 * Math.sin(dayOfYear(day)));
      add(day, "restingEnergy", "garmin", 1720 - 4 * (row.rhr - 55));
      add(day, "steps", "garmin", row.steps);
      add(day, "activeEnergy", "garmin", row.activeEnergy);
      add(day, "intensityMinutes", "garmin", row.intensity);
      add(day, "restingHeartRate", "garmin", row.rhr);
      add(day, "hrv", "garmin", row.hrv);
      add(day, "stress", "garmin", row.stress, row.stressRange);
      add(day, "bodyBattery", "garmin", (row.bbRange[0] + row.bbRange[1]) / 2, row.bbRange);
      add(day, "spo2", "garmin", row.spo2);
      add(day, "respiration", "garmin", row.resp);
      add(day, "sleepMinutes", "garmin", row.sleepMin);
      add(day, HK_STEPS, MIRROR, row.steps);
    }
    add(day, HK_STEPS, APPLE, row.appleSteps);
    if (row.appleRhr !== undefined) add(day, HK_RHR, APPLE, row.appleRhr);
    if (day >= "2020-01-01") add(day, HK_HRV, APPLE, row.appleHrv);
  }
  cache = { rows, points, summaries };
  return cache;
}

const dayOfIso = (iso: string): Day => dayOf(new Date(iso));

function sleepMinutesByStage(session: SleepSession): Record<SleepStage, number> {
  const out: Record<SleepStage, number> = { awake: 0, light: 0, deep: 0, rem: 0, asleep: 0, unmeasurable: 0 };
  for (const iv of session.stages) out[iv.stage] += (Date.parse(iv.end) - Date.parse(iv.start)) / 60_000;
  return out;
}

const y0 = (day: Day) => Number(day.slice(0, 4));
const m0 = (day: Day) => Number(day.slice(5, 7));
const d0 = (day: Day) => Number(day.slice(8, 10));

/** Alternates light, deep, light and REM in cycles of about 90 minutes, with deep sleep shrinking through the night. */
function stages(start: Date, total: number, rand: () => number): SleepInterval[] {
  const out: SleepInterval[] = [];
  let t = start.getTime();
  let left = total;
  let cycle = 0;
  const push = (stage: SleepStage, minutes: number) => {
    const m = Math.min(minutes, left);
    if (m <= 0) return;
    const end = t + m * 60_000;
    out.push({ start: new Date(t).toISOString(), end: new Date(end).toISOString(), stage });
    t = end;
    left -= m;
  };
  while (left > 0) {
    push("light", 15 + 10 * rand());
    push("deep", Math.max(3, 30 - 6 * cycle) + 5 * rand());
    push("light", 10 + 10 * rand());
    push("rem", 10 + 3 * cycle + 10 * rand());
    if (rand() < 0.15) push("awake", 2 + 4 * rand());
    cycle++;
  }
  return out;
}

/** Re-creates the records and laps of an activity from its seed, so the list stays small. */
function expand(summary: Summary): { records: ActivityRecord[]; laps: Lap[] } {
  const rand = mulberry32(summary.seed);
  const { activity, speed, hr, cadence } = summary;
  if (!summary.route) return { records: [], laps: [] };
  const startMs = Date.parse(activity.start);
  let lat = 52.5 + (rand() - 0.5) * 0.12;
  let lon = 13.4 + (rand() - 0.5) * 0.2;
  let heading = rand() * 2 * Math.PI;
  let dist = 0;
  let lapStart = startMs;
  let lapDistance = 0;
  let lapHeartRates: number[] = [];
  const records: ActivityRecord[] = [];
  const laps: Lap[] = [];
  for (let t = 0; t < activity.duration; t += 10) {
    const v = speed * (0.9 + 0.2 * rand());
    heading += (rand() - 0.5) * 0.25;
    dist += v * 10;
    lat += (v * 10 * Math.cos(heading)) / 111_320;
    lon += (v * 10 * Math.sin(heading)) / (111_320 * Math.cos((lat * Math.PI) / 180));
    const date = new Date(startMs + t * 1000).toISOString();
    if (hr === undefined) {
      // A Health route point: position, altitude and speed only.
      records.push({
        date,
        latitude: Math.round(lat * 1e6) / 1e6,
        longitude: Math.round(lon * 1e6) / 1e6,
        altitude: round1(60 + 25 * Math.sin(t / 900) + 4 * (rand() - 0.5)),
        speed: round1(v * 100) / 100,
      });
      continue;
    }
    const heartRate = Math.round(hr + 8 * Math.sin(t / 300) + 4 * (rand() - 0.5));
    records.push({
      date,
      latitude: Math.round(lat * 1e6) / 1e6,
      longitude: Math.round(lon * 1e6) / 1e6,
      altitude: round1(60 + 25 * Math.sin(t / 900) + 4 * (rand() - 0.5)),
      heartRate,
      speed: round1(v * 100) / 100,
      distance: Math.round(dist),
      cadence,
    });
    lapHeartRates.push(heartRate);
    if (dist >= (laps.length + 1) * 1000) {
      const avg = lapHeartRates.reduce((a, b) => a + b, 0) / lapHeartRates.length;
      laps.push({
        start: new Date(lapStart).toISOString(),
        end: date,
        distance: Math.round(dist - lapDistance),
        calories: Math.round(((activity.activeCalories ?? 0) * (dist - lapDistance)) / Math.max(dist, 1)),
        averageHeartRate: Math.round(avg),
      });
      lapStart = Date.parse(date);
      lapDistance = dist;
      lapHeartRates = [];
    }
  }
  return { records, laps };
}

// MARK: - API

export function metrics(): MetricInfo[] {
  const groups = new Map<string, MetricInfo>();
  for (const p of dataset().points) {
    const key = `${p.metric}\u0000${p.source}`;
    const meta = META[p.metric] ?? { unit: "", aggregation: "avg" as const };
    const info = groups.get(key);
    if (!info) {
      groups.set(key, { metric: p.metric, source: p.source, unit: meta.unit, aggregation: meta.aggregation, first: p.day, last: p.day, count: 1 });
    } else {
      info.last = p.day;
      info.count++;
    }
  }
  return [...groups.values()];
}

export function daily(from: Day, to: Day, wanted: string[]): DailyPoint[] {
  const keys = new Set(wanted);
  return dataset().points.filter((p) => keys.has(p.metric) && p.day >= from && p.day < to);
}

export function sleep(from: Day, to: Day): SleepSession[] {
  const lo = dayMs(from);
  const hi = dayMs(to);
  return dataset()
    .rows.flatMap((r) => (r.sleep ? [r.sleep] : []))
    .filter((s) => Date.parse(s.start) >= lo && Date.parse(s.start) < hi);
}

/** Newest first. Like the server, the cursor is an instant or a day, and a page holds the activities that start before it. */
export function activities(limit: number, cursor?: string): ActivityPage {
  const day = parseDay(cursor);
  const before = cursor === undefined ? Infinity : day ? dayMs(day) : Date.parse(cursor);
  const sorted = dataset()
    .summaries.map((s) => s.activity)
    .filter((a) => Date.parse(a.start) < before)
    .reverse();
  const items = sorted.slice(0, limit);
  return { items, nextCursor: sorted.length > limit ? items.at(-1)?.start : undefined };
}

export function activity(id: string): ActivityDetail {
  const summary = dataset().summaries.find((s) => s.activity.id === id);
  if (!summary) throw new Error(`404 activity ${id}`);
  const { records, laps } = expand(summary);
  return { activity: summary.activity, laps, records };
}

// MARK: - Insights

/** Findings computed from the same fixtures, in the server's shape. English and German summaries. */
export function insights(from: Day, to: Day, lang: "en" | "de"): Insight[] {
  const de = lang === "de";
  const rows = dataset().rows.filter((r) => r.day >= from && r.day < to);
  const series = (pick: (r: Row) => number | undefined): Series =>
    new Map(
      rows.flatMap((r): [Day, number][] => {
        const v = pick(r);
        return v === undefined ? [] : [[r.day, v]];
      }),
    );
  const sleep = series((r) => r.sleepMin);
  const hrv = series((r) => r.hrv);
  const rhr = series((r) => r.rhr);
  const steps = series((r) => (r.watch ? r.steps : undefined));
  const stress = series((r) => (r.watch ? r.stress : undefined));
  const period = { from, to: addDays(to, -1) };
  const num = (v: number, d = 1) => (de ? v.toFixed(d).replace(".", ",") : v.toFixed(d));
  const int = (v: number) => Math.round(v).toLocaleString(de ? "de-DE" : "en-US");
  const out: Insight[] = [];

  const rel = relate(sleep, hrv, 1);
  if (rel) {
    out.push({
      id: "corr-sleep-hrv-next",
      kind: "correlation",
      title: de ? "Schlaf und HRV am Folgetag" : "Sleep and next-day HRV",
      summary: de
        ? `Nächte mit mehr Schlaf gehen mit höherer HRV am nächsten Morgen einher (r = ${num(rel.r, 2)}).`
        : `Nights with more sleep go with higher HRV the next morning (r = ${num(rel.r, 2)}).`,
      detail: de
        ? "Berechnet über alle Tage mit beiden Werten, mit einem Tag Versatz. Das ist ein Zusammenhang, keine Ursache."
        : "Computed over all days where both values exist, with a one-day lag. This is an association, not a cause.",
      metrics: ["sleepMinutes", "hrv"],
      strength: Math.min(1, Math.abs(rel.r) * 2),
      confidence: Math.max(0, 1 - rel.p),
      n: rel.n,
      period,
      chart: { type: "scatter", series: [{ name: de ? "Nächte" : "Nights", points: rel.pairs.map((p): [number, number] => [p.x, p.y]) }] },
    });
  }

  const tr = trend(rhr);
  if (tr) {
    const falling = tr.slopePerYear < 0;
    const amount = num(Math.abs(tr.slopePerYear));
    out.push({
      id: "trend-rhr",
      kind: "trend",
      title: de ? "Ruhepuls" : "Resting heart rate",
      summary: de
        ? `Dein Ruhepuls ${falling ? "sinkt" : "steigt"} um etwa ${amount} bpm pro Jahr, nach Abzug der Jahreszeiten.`
        : `Your resting heart rate ${falling ? "falls" : "rises"} about ${amount} bpm per year, with the seasons removed.`,
      metrics: ["restingHeartRate"],
      strength: Math.min(1, Math.abs(tr.tau)),
      confidence: Math.max(0, 1 - tr.p),
      n: tr.months.length,
      period,
      chart: {
        type: "line",
        series: [
          { name: de ? "Monatsmittel" : "Monthly mean", points: tr.months.map((m): [number, number] => [dayMs(m.day), m.value]) },
          { name: de ? "Trend" : "Trend", points: tr.months.map((m, i): [number, number] => [dayMs(m.day), tr.fitted[i] ?? m.value]) },
        ],
      },
    });
    if (tr.changepoint) {
      const cp = tr.changepoint;
      out.push({
        id: "changepoint-rhr",
        kind: "changepoint",
        title: de ? "Ruhepuls: Niveauwechsel" : "Resting heart rate: level shift",
        summary: de
          ? `Ab ${cp.day} lag dein Ruhepuls im Schnitt bei ${num(cp.after)} bpm statt ${num(cp.before)} bpm.`
          : `From ${cp.day} your resting heart rate averaged ${num(cp.after)} bpm instead of ${num(cp.before)} bpm.`,
        metrics: ["restingHeartRate"],
        strength: Math.min(1, Math.abs(cp.after - cp.before) / 10),
        confidence: Math.max(0, 1 - cp.p),
        n: tr.months.length,
        period,
      });
    }
  }

  const rec = records(steps);
  if (rec) {
    out.push({
      id: "record-steps",
      kind: "record",
      title: de ? "Schrittrekord" : "Step record",
      summary: de
        ? `Dein höchster Schritttag war der ${rec.max.day} mit ${int(rec.max.value)} Schritten.`
        : `Your highest step day was ${rec.max.day} with ${int(rec.max.value)} steps.`,
      metrics: ["steps"],
      strength: 0.5,
      confidence: 1,
      n: steps.size,
      period,
    });
  }

  const highStress = [...stress].filter(([, v]) => v >= 60);
  if (highStress.length >= 5) {
    const peak = highStress.reduce((best, cur) => (cur[1] > best[1] ? cur : best));
    out.push({
      id: "anomaly-stress",
      kind: "anomaly",
      title: de ? "Stressspitzen" : "Stress spikes",
      summary: de
        ? `An ${highStress.length} Tagen lag dein Stress bei 60 oder darüber. Die stärkste Spitze war am ${peak[0]} mit ${int(peak[1])}.`
        : `On ${highStress.length} days your stress reached 60 or more. The sharpest spike was on ${peak[0]} at ${int(peak[1])}.`,
      metrics: ["stress"],
      strength: Math.min(1, highStress.length / 60),
      confidence: 0.7,
      n: stress.size,
      period,
    });
  }

  return out.sort((a, b) => b.strength - a.strength);
}
