import { addDays, dayOfYear, daysBetween, daysInclusive, weekdayIndex, weekStart, yearOf, type Day } from "./time";
import { kendall, linearFit, mean, median, pearson, stdev, theilSen, twoSidedP, type Correlation, type LinearFit } from "./stats";

/** Daily values keyed by local calendar day. Missing days are absent, never zero. */
export type Series = Map<Day, number>;
export type Gran = "day" | "week" | "month" | "year";
export type Reduce = "avg" | "sum";

const sum = (xs: readonly number[]) => xs.reduce((a, b) => a + b, 0);

export interface Bucket {
  start: Day;
  value: number;
  n: number;
  min: number;
  max: number;
}

function bucketStart(day: Day, gran: Gran): Day {
  switch (gran) {
    case "day":
      return day;
    case "week":
      return weekStart(day);
    case "month":
      return `${day.slice(0, 7)}-01` as Day;
    case "year":
      return `${day.slice(0, 4)}-01-01` as Day;
  }
}

/** Groups days into buckets. "avg" is the mean of the daily values, "sum" their total. */
export function aggregate(series: Series, gran: Gran, how: Reduce): Bucket[] {
  const groups = new Map<Day, number[]>();
  for (const day of [...series.keys()].sort()) {
    const start = bucketStart(day, gran);
    const values = groups.get(start) ?? [];
    values.push(series.get(day) ?? 0);
    groups.set(start, values);
  }
  return [...groups].map(([start, values]) => ({
    start,
    value: how === "sum" ? sum(values) : (mean(values) ?? 0),
    n: values.length,
    min: Math.min(...values),
    max: Math.max(...values),
  }));
}

/** Trailing mean over the last `window` calendar days. Days without a value are skipped, not counted as zero. */
export function rolling(series: Series, window: number): Series {
  const out: Series = new Map();
  const days = [...series.keys()].sort();
  const first = days[0];
  const last = days.at(-1);
  if (first === undefined || last === undefined) return out;
  const calendar = daysInclusive(first, last);
  const values = calendar.map((day) => series.get(day));
  let total = 0;
  let count = 0;
  calendar.forEach((day, i) => {
    const entering = values[i];
    if (entering !== undefined) {
      total += entering;
      count++;
    }
    const leaving = i >= window ? values[i - window] : undefined;
    if (leaving !== undefined) {
      total -= leaving;
      count--;
    }
    if (count > 0) out.set(day, total / count);
  });
  return out;
}

export interface Baseline {
  mean: number;
  sd: number | null;
  n: number;
}

/** Mean of the `days` days before `day`. `day` itself is excluded. Null with fewer than a week of values. */
export function baseline(series: Series, day: Day, days = 56): Baseline | null {
  const values: number[] = [];
  for (let i = 1; i <= days; i++) {
    const v = series.get(addDays(day, -i));
    if (v !== undefined) values.push(v);
  }
  if (values.length < 7) return null;
  return { mean: mean(values) ?? 0, sd: stdev(values), n: values.length };
}

export function latest(series: Series): { day: Day; value: number } | null {
  const day = [...series.keys()].sort().at(-1);
  if (day === undefined) return null;
  const value = series.get(day);
  return value === undefined ? null : { day, value };
}

/** Each calendar year as [day of year, value] pairs, to overlay years on one axis. */
export function byYear(series: Series): Map<number, [number, number][]> {
  const out = new Map<number, [number, number][]>();
  for (const day of [...series.keys()].sort()) {
    const value = series.get(day);
    if (value === undefined) continue;
    const year = yearOf(day);
    const points = out.get(year) ?? [];
    points.push([dayOfYear(day), value]);
    out.set(year, points);
  }
  return out;
}

export const monthOf = (day: Day) => Number(day.slice(5, 7)) - 1;
export const weekdayOf = (day: Day) => weekdayIndex(day);

/** Mean value per bucket of `key` (for example 12 calendar months or 7 weekdays). Null where empty. */
export function profile(series: Series, key: (day: Day) => number, size: number): (number | null)[] {
  const groups: number[][] = Array.from({ length: size }, () => []);
  for (const [day, value] of series) groups[key(day)]?.push(value);
  return groups.map((values) => mean(values));
}

export function records(series: Series): { max: { day: Day; value: number }; min: { day: Day; value: number } } | null {
  let max: { day: Day; value: number } | null = null;
  let min: { day: Day; value: number } | null = null;
  for (const [day, value] of series) {
    if (!max || value > max.value) max = { day, value };
    if (!min || value < min.value) min = { day, value };
  }
  return max && min ? { max, min } : null;
}

export interface Trend {
  /** Monthly means of the raw series. */
  months: { day: Day; value: number }[];
  /** The trend line, in the same units, with the seasonal pattern added back. */
  fitted: number[];
  /** Theil–Sen slope of the deseasonalised monthly means, per year. */
  slopePerYear: number;
  /** Mann–Kendall tau and its two-sided p-value on the deseasonalised means. */
  tau: number;
  p: number;
  /** A single level shift in the detrended residuals, when one is significant. */
  changepoint: { day: Day; before: number; after: number; p: number } | null;
}

/** Long-term change: monthly means, seasonal pattern removed, robust slope, and at most one level shift. */
export function trend(series: Series, minMonths = 24): Trend | null {
  const months = aggregate(series, "month", "avg");
  const origin = months[0]?.start;
  if (origin === undefined || months.length < minMonths) return null;
  const t = months.map((m) => daysBetween(origin, m.start) / 365.25);
  const values = months.map((m) => m.value);
  const monthIdx = months.map((m) => monthOf(m.start));
  // Fixed effects per calendar month: the seasonal level and the average time of each month are removed, so the
  // slope comes only from year-to-year change within a month and is not biased by where a month sits in its year.
  const climatology = Array.from({ length: 12 }, (_, k) => mean(values.filter((_, i) => monthIdx[i] === k)) ?? 0);
  const meanTime = Array.from({ length: 12 }, (_, k) => mean(t.filter((_, i) => monthIdx[i] === k)) ?? 0);
  const seasonalPart = monthIdx.map((k) => climatology[k] ?? 0);
  const x = t.map((tv, i) => tv - (meanTime[monthIdx[i] ?? 0] ?? 0));
  const deseasonal = values.map((v, i) => v - (seasonalPart[i] ?? 0));
  const slope = theilSen(x, deseasonal);
  if (slope === null) return null;
  const intercept = median(deseasonal.map((y, i) => y - slope * (x[i] ?? 0))) ?? 0;
  const residual = deseasonal.map((y, i) => y - slope * (x[i] ?? 0) - intercept);
  const mk = kendall(deseasonal);
  const cp = changepoint(residual, 12);
  return {
    months: months.map((m) => ({ day: m.start, value: m.value })),
    fitted: values.map((_, i) => (seasonalPart[i] ?? 0) + intercept + slope * (x[i] ?? 0)),
    slopePerYear: slope,
    tau: mk?.tau ?? 0,
    p: mk?.p ?? 1,
    changepoint: cp
      ? {
          day: months[cp.index]?.start ?? origin,
          before: mean(values.slice(0, cp.index)) ?? 0,
          after: mean(values.slice(cp.index)) ?? 0,
          p: cp.p,
        }
      : null,
  };
}

/** The split that best separates two level means (Welch t), if it is significant at p < 0.001. */
export function changepoint(values: readonly number[], minSeg: number): { index: number; p: number } | null {
  let best: { index: number; t: number } | null = null;
  for (let k = minSeg; k <= values.length - minSeg; k++) {
    const a = values.slice(0, k);
    const b = values.slice(k);
    const se = Math.hypot((stdev(a) ?? 0) / Math.sqrt(a.length), (stdev(b) ?? 0) / Math.sqrt(b.length));
    const diff = Math.abs((mean(a) ?? 0) - (mean(b) ?? 0));
    const t = se === 0 ? (diff === 0 ? 0 : Infinity) : diff / se;
    if (!best || t > best.t) best = { index: k, t };
  }
  if (!best) return null;
  const p = best.t === Infinity ? 0 : twoSidedP(best.t);
  return p < 0.001 ? { index: best.index, p } : null;
}

export interface LaggedPair {
  day: Day;
  x: number;
  y: number;
}

/** Moves every value `lag` days back, so day D of the result holds the value from day D + lag. */
function shift(y: Series, lag: number): Series {
  return new Map<Day, number>([...y].map(([day, value]): [Day, number] => [addDays(day, -lag), value]));
}

function pairsOn(x: Series, shifted: Series): LaggedPair[] {
  const pairs: LaggedPair[] = [];
  for (const [day, xv] of x) {
    const yv = shifted.get(day);
    if (yv !== undefined) pairs.push({ day, x: xv, y: yv });
  }
  return pairs;
}

export interface Relation extends Correlation {
  pairs: LaggedPair[];
  fit: LinearFit | null;
}

/** Correlation of x on day D with y on day D + lag. Only days where both exist count. */
export function relate(x: Series, y: Series, lag: number): Relation | null {
  const pairs = pairsOn(x, shift(y, lag));
  const xs = pairs.map((p) => p.x);
  const ys = pairs.map((p) => p.y);
  const corr = pearson(xs, ys);
  return corr ? { ...corr, pairs, fit: linearFit(xs, ys) } : null;
}

/** r[i][j] correlates row i on day D with column j on day D + lag, so the matrix is not symmetric for lag > 0. */
export function correlationMatrix(
  series: Record<string, Series>,
  lag: number,
): { ids: string[]; r: (number | null)[][]; n: number[][] } {
  const ids = Object.keys(series);
  const shifted = new Map(ids.map((id) => [id, shift(series[id] ?? new Map(), lag)]));
  const r: (number | null)[][] = [];
  const n: number[][] = [];
  for (const a of ids) {
    const rowR: (number | null)[] = [];
    const rowN: number[] = [];
    for (const b of ids) {
      const pairs = pairsOn(series[a] ?? new Map(), shifted.get(b) ?? new Map());
      const corr = pearson(pairs.map((p) => p.x), pairs.map((p) => p.y));
      rowR.push(corr?.r ?? null);
      rowN.push(corr?.n ?? 0);
    }
    r.push(rowR);
    n.push(rowN);
  }
  return { ids, r, n };
}

/** Mean of the `days` days ending on `day`, against the mean of the `baselineDays` days before them. Null when either side is thin. */
export function recentVsBaseline(
  series: Series,
  day: Day,
  days = 7,
  baselineDays = 56,
): { recent: number; usual: number; n: number } | null {
  const recent: number[] = [];
  const usual: number[] = [];
  for (let i = 0; i < days + baselineDays; i++) {
    const v = series.get(addDays(day, -i));
    if (v === undefined) continue;
    (i < days ? recent : usual).push(v);
  }
  if (recent.length < 3 || usual.length < 7) return null;
  return { recent: mean(recent) ?? 0, usual: mean(usual) ?? 0, n: recent.length };
}

export interface YearRow<K extends string> {
  year: number;
  /** Mean of the year's daily values per key; absent when the year has no day for it. */
  means: Partial<Record<K, number>>;
}

/**
 * One row per calendar year with any data, newest first, from the earliest year with data to `current`.
 * The first year may be partial; its mean still describes the days it has. A value is the mean of that year's days that have one, so a year with half
 * its days recorded is not half as large.
 */
export function yearlyMeans<K extends string>(series: Record<K, Series>, keys: readonly K[], current: number): YearRow<K>[] {
  const rows = new Map<number, Partial<Record<K, number>>>();
  for (const key of keys) {
    for (const bucket of aggregate(series[key], "year", "avg")) {
      const year = yearOf(bucket.start);
      if (year > current) continue;
      rows.set(year, { ...rows.get(year), [key]: bucket.value });
    }
  }
  return [...rows].sort(([a], [b]) => b - a).map(([year, means]) => ({ year, means }));
}
