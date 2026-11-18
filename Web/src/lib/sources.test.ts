import { describe, expect, it } from "vitest";
import { resolveSeries, type SourcedValue } from "./sources";
import { parseDay, type Day } from "./time";

/** A day literal, checked. */
const day = (text: string): Day => parseDay(text) ?? (() => { throw new Error(text); })();

const v = (day: Day, source: string, value: number): SourcedValue => ({ day, source, value });

const values: SourcedValue[] = [
  v(day("2024-01-01"), "healthkit:com.apple.health", 9),
  v(day("2024-01-01"), "garmin", 5),
  v(day("2024-01-02"), "healthkit:com.apple.health", 7),
  v(day("2024-01-03"), "healthkit:garmin-mirror", 11),
  v(day("2024-01-03"), "garmin", 4),
  v(day("2024-01-04"), "healthkit:garmin-mirror", 8),
];

describe("resolveSeries", () => {
  it("prefers Garmin and fills gaps from Apple Health, dropping mirrored samples", () => {
    expect(Object.fromEntries(resolveSeries(values, undefined, false))).toEqual({
      "2024-01-01": 5,
      "2024-01-02": 7,
      "2024-01-03": 4,
    });
  });

  it("lets a chosen source win over Garmin where both exist", () => {
    const s = resolveSeries(values, "healthkit:com.apple.health", false);
    expect(s.get(day("2024-01-01"))).toBe(9);
    expect(s.get(day("2024-01-03"))).toBe(4);
  });

  it("uses the mirror only when asked, and then still ranks Garmin above it", () => {
    const s = resolveSeries(values, undefined, true);
    expect(s.get(day("2024-01-03"))).toBe(4);
    expect(s.get(day("2024-01-04"))).toBe(8);
  });

  it("hides a mirror-only day unless mirrored samples are included", () => {
    expect(resolveSeries(values, undefined, false).has(day("2024-01-04"))).toBe(false);
  });
});
