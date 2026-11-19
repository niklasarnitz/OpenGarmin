import { describe, expect, it } from "vitest";
import { resolveSeries, type SourcedValue } from "./sources";
import { parseDay, type Day } from "./time";

/** A day literal, checked. */
const day = (text: string): Day => parseDay(text) ?? (() => { throw new Error(text); })();

const v = (d: string, source: string, value: number, count = 1): SourcedValue => ({ day: day(d), source, value, count });

const values: SourcedValue[] = [
  // Garmin, its copy in Apple Health and two Apple devices on one day: only Garmin counts.
  v("2024-01-01", "garmin", 5000),
  v("2024-01-01", "healthkit:garmin-mirror", 5000),
  v("2024-01-01", "healthkit:com.apple.health.PHONE", 4000, 300),
  // No Garmin: its Apple Health copy wins over the phone.
  v("2024-01-02", "healthkit:garmin-mirror", 7000),
  v("2024-01-02", "healthkit:com.apple.health.PHONE", 6000, 300),
  // Only Apple: the watch has more readings than the phone, and the two are not added.
  v("2024-01-03", "healthkit:com.apple.health.PHONE", 3000, 100),
  v("2024-01-03", "healthkit:com.apple.health.WATCH", 3500, 900),
  v("2024-01-03", "healthkit:com.yazio.ios.YAZIO", 9999, 2000),
];

describe("resolveSeries", () => {
  it("takes one source per day, never a sum: Garmin, its mirror, then the fullest Apple device", () => {
    expect(Object.fromEntries(resolveSeries(values, undefined))).toEqual({
      "2024-01-01": 5000,
      "2024-01-02": 7000,
      "2024-01-03": 3500,
    });
  });

  it("lets a chosen source win where it has a value; Apple devices are chosen as one source", () => {
    const s = resolveSeries(values, "healthkit:apple");
    expect(s.get(day("2024-01-01"))).toBe(4000);
    expect(s.get(day("2024-01-03"))).toBe(3500);
  });
});
