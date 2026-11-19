import type { Series } from "./analytics";
import type { Day } from "./time";

/** What Garmin Connect or OpenGarmin wrote into Apple Health: a copy of Garmin data. */
export const MIRROR_SOURCE = "healthkit:garmin-mirror";
/** Every iPhone and Apple Watch, which the server lists one by one as `healthkit:com.apple.health.<device>`. */
export const APPLE_SOURCE = "healthkit:apple";
/** Google Fit, imported from a Takeout export: like Apple's devices, it counts with the phone's and watch's sensors. */
export const GOOGLE_FIT_SOURCE = "healthkit:com.google.android.apps.fitness";

export interface SourcedValue {
  day: Day;
  source: string;
  value: number;
  /** Readings behind the value; of two sources of the same rank on a day, the fuller one wins. */
  count: number;
}

/** The source a value is shown and chosen under: all of Apple's own devices are one source. */
export function sourceGroup(source: string): string {
  return /^healthkit:com\.apple\.health/i.test(source) ? APPLE_SOURCE : source;
}

const rank = (group: string, preferred: string | undefined) =>
  group === preferred ? 0 : group === "garmin" ? 1 : group === MIRROR_SOURCE ? 2 : group === APPLE_SOURCE || group === GOOGLE_FIT_SOURCE ? 3 : 4;

/**
 * Exactly one value per day, never a sum of sources, because Garmin data also reaches Apple Health (through Garmin
 * Connect and OpenGarmin) and an iPhone and an Apple Watch both count the same steps. The preferred source wins, then
 * Garmin, then Garmin's copy in Apple Health, then Apple's devices and Google Fit, then other apps. Within one of these, the source
 * with the most readings that day wins. A lower-ranked source fills the days the better ones lack.
 */
export function resolveSeries(values: readonly SourcedValue[], preferred: string | undefined): Series {
  const best = new Map<Day, { rank: number; count: number; value: number }>();
  for (const v of values) {
    const r = rank(sourceGroup(v.source), preferred);
    const current = best.get(v.day);
    if (!current || r < current.rank || (r === current.rank && v.count > current.count)) {
      best.set(v.day, { rank: r, count: v.count, value: v.value });
    }
  }
  return new Map([...best].map(([day, b]) => [day, b.value]));
}

/** Every source group that reports a value, for the settings screen. */
export function sourcesOf(values: readonly SourcedValue[]): string[] {
  return [...new Set(values.map((v) => sourceGroup(v.source)))].sort((a, b) => a.localeCompare(b));
}
