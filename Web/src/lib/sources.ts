import type { Series } from "./analytics";
import type { Day } from "./time";

/** Samples OpenGarmin wrote into HealthKit from Garmin data. They duplicate Garmin and are hidden by default. */
export const MIRROR_SOURCE = "healthkit:garmin-mirror";

export interface SourcedValue {
  day: Day;
  source: string;
  value: number;
}

/**
 * One value per day from the best available source. The preferred source wins, then Garmin, then the others in
 * name order. A lower-ranked source fills the days the better one lacks, so a Garmin gap shows Apple Health.
 */
export function resolveSeries(values: readonly SourcedValue[], preferred: string | undefined, includeMirror: boolean): Series {
  const rank = (source: string) => (source === preferred ? 0 : source === "garmin" ? 1 : 2);
  const out: Series = new Map();
  values
    .filter((v) => includeMirror || v.source !== MIRROR_SOURCE)
    .sort((a, b) => rank(a.source) - rank(b.source) || a.source.localeCompare(b.source))
    .forEach((v) => {
      if (!out.has(v.day)) out.set(v.day, v.value);
    });
  return out;
}

/** Every source that reports a value, mirror included, for the settings screen. */
export function sourcesOf(values: readonly SourcedValue[]): string[] {
  return [...new Set(values.map((v) => v.source))].sort((a, b) => a.localeCompare(b));
}
