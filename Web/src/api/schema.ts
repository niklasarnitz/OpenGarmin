// Runtime schemas for every response the dashboard reads, mirroring the server's Swift types (Server/Sources/App:
// Auth/Auth.swift, API/Reads.swift, Analytics/Rollup.swift, Analytics/Insight.swift). The client parses each response
// with them, so a server change that breaks the contract fails with the path of the bad field instead of rendering
// garbage, and the TypeScript types below are derived from them, never written separately.
// Swift's encoder leaves out nil optionals, so those fields are optional; null is accepted as well.
import { z } from "zod";
import { parseDay, type Day } from "../lib/time";

const day = z.string().refine((s) => parseDay(s) !== null, "expected a YYYY-MM-DD date").transform((s) => s as Day);
const instant = z.iso.datetime({ offset: true });
const opt = <T extends z.ZodType>(schema: T) => schema.nullable().transform((v) => v ?? undefined).optional();

export const User = z.object({
  id: z.string(),
  email: z.string(),
  createdAt: instant,
  timeZone: z.string(),
  workDays: z.array(z.number().int()),
  workStart: z.number().int(),
  workEnd: z.number().int(),
});

export const TokenResponse = z.object({ token: z.string(), user: User });

export const MetricInfo = z.object({
  metric: z.string(),
  source: z.string(),
  unit: opt(z.string()),
  aggregation: z.enum(["sum", "avg"]),
  first: day,
  last: day,
  count: z.number().int(),
});

export const DailyPoint = z.object({
  day,
  metric: z.string(),
  source: z.string(),
  value: z.number(),
  min: opt(z.number()),
  max: opt(z.number()),
  /** Readings behind the value. */
  count: z.number().int(),
});

export const ActivitySummary = z.object({
  id: z.string(),
  externalId: z.string(),
  sport: z.number().int(),
  subSport: opt(z.number().int()),
  name: opt(z.string()),
  start: instant,
  end: instant,
  duration: z.number(),
  distance: opt(z.number()),
  activeCalories: opt(z.number()),
  averageHeartRate: opt(z.number()),
  maxHeartRate: opt(z.number()),
  totalAscent: opt(z.number()),
  totalDescent: opt(z.number()),
  averageSpeed: opt(z.number()),
  averageCadence: opt(z.number()),
  averagePower: opt(z.number()),
  trainingEffect: opt(z.number()),
});

export const ActivityPage = z.object({
  items: z.array(ActivitySummary),
  nextCursor: opt(z.string()),
});

export const Lap = z.object({
  start: instant,
  end: instant,
  distance: opt(z.number()),
  calories: opt(z.number()),
  averageHeartRate: opt(z.number()),
});

export const ActivityRecord = z.object({
  date: instant,
  latitude: opt(z.number()),
  longitude: opt(z.number()),
  altitude: opt(z.number()),
  heartRate: opt(z.number()),
  speed: opt(z.number()),
  distance: opt(z.number()),
  cadence: opt(z.number()),
  power: opt(z.number()),
  temperature: opt(z.number()),
});

export const ActivityDetail = z.object({
  activity: ActivitySummary,
  laps: z.array(Lap),
  records: z.array(ActivityRecord),
});

export const SleepStage = z.enum(["awake", "light", "deep", "rem", "unmeasurable"]);

export const SleepSession = z.object({
  start: instant,
  end: instant,
  score: opt(z.number().int()),
  stages: z.array(z.object({ start: instant, end: instant, stage: SleepStage })),
});

export const Insight = z.object({
  id: z.string(),
  kind: z.enum(["trend", "correlation", "changepoint", "anomaly", "pattern", "record"]),
  title: z.string(),
  summary: z.string(),
  detail: opt(z.string()),
  metrics: z.array(z.string()),
  strength: z.number(),
  confidence: z.number(),
  n: z.number().int(),
  period: z.object({ from: day, to: day }),
  lagDays: opt(z.number().int().min(0).max(3)),
  chart: opt(
    z.object({
      type: z.enum(["line", "scatter", "bar"]),
      // [x, y]: x is epoch milliseconds for line charts, the value or index otherwise.
      series: z.array(z.object({ name: z.string(), points: z.array(z.tuple([z.number(), z.number()])) })),
    }),
  ),
});

/** The body of a failed request: Vapor's `{error, reason}`. */
export const ErrorBody = z.object({ reason: z.string() });
