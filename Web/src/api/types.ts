// Wire types for the OpenGarmin backend (docs/backend-api.md). Activities and sleep sessions mirror
// GarminModels' Codable encoding: optional values are omitted when nil, dates are ISO 8601.

export type Aggregation = "sum" | "avg";

/** One (metric, source) pair the server holds data for. */
export interface MetricInfo {
  metric: string;
  source: string;
  unit: string;
  aggregation: Aggregation;
  first: string;
  last: string;
  count: number;
}

/** One local day of one (metric, source) pair. */
export interface DailyPoint {
  day: string;
  metric: string;
  source: string;
  value: number;
  min?: number;
  max?: number;
}

export interface Lap {
  start: string;
  end: string;
  distance?: number | null;
  calories?: number | null;
  averageHeartRate?: number | null;
}

export interface ActivityRecord {
  date: string;
  latitude?: number | null;
  longitude?: number | null;
  altitude?: number | null;
  heartRate?: number | null;
  speed?: number | null;
  distance?: number | null;
  cadence?: number | null;
  power?: number | null;
  temperature?: number | null;
}

export interface Activity {
  id: string;
  sport: number;
  subSport?: number | null;
  name?: string | null;
  start: string;
  end: string;
  duration: number;
  distance?: number | null;
  activeCalories?: number | null;
  averageHeartRate?: number | null;
  maxHeartRate?: number | null;
  totalAscent?: number | null;
  totalDescent?: number | null;
  averageSpeed?: number | null;
  averageCadence?: number | null;
  averagePower?: number | null;
  trainingEffect?: number | null;
  laps?: Lap[];
  records?: ActivityRecord[];
}

export type SleepStage = "awake" | "light" | "deep" | "rem" | "unmeasurable";

export interface SleepInterval {
  start: string;
  end: string;
  stage: SleepStage;
}

export interface SleepSession {
  start: string;
  end: string;
  intervals: SleepInterval[];
  score?: number | null;
}

export interface MeResponse {
  id: string;
  email: string;
  createdAt: string;
}

export type InsightKind = "trend" | "correlation" | "changepoint" | "anomaly" | "pattern" | "record";

export interface InsightSeries {
  name: string;
  /** [x, y]. x is a "YYYY-MM-DD" day, an ISO 8601 instant, or a plain number. */
  points: [number | string, number][];
}

/** A curated finding from GET /api/v1/insights. Summaries are already written in the requested language. */
export interface Insight {
  id: string;
  kind: InsightKind;
  title: string;
  summary: string;
  detail?: string;
  /** Metric keys as /api/v1/metrics names them. */
  metrics: string[];
  /** 0…1 */
  strength: number;
  /** 0…1 */
  confidence: number;
  n: number;
  period: { from: string; to: string };
  chart?: { type: "line" | "scatter" | "bar"; series: InsightSeries[] };
}
