import { describe, expect, it } from "vitest";
import { resolveSeries, type SourcedValue } from "./sources";

const v = (day: string, source: string, value: number): SourcedValue => ({ day, source, value });

const values: SourcedValue[] = [
  v("2024-01-01", "healthkit:com.apple.health", 9),
  v("2024-01-01", "garmin", 5),
  v("2024-01-02", "healthkit:com.apple.health", 7),
  v("2024-01-03", "healthkit:garmin-mirror", 11),
  v("2024-01-03", "garmin", 4),
  v("2024-01-04", "healthkit:garmin-mirror", 8),
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
    expect(s.get("2024-01-01")).toBe(9);
    expect(s.get("2024-01-03")).toBe(4);
  });

  it("uses the mirror only when asked, and then still ranks Garmin above it", () => {
    const s = resolveSeries(values, undefined, true);
    expect(s.get("2024-01-03")).toBe(4);
    expect(s.get("2024-01-04")).toBe(8);
  });

  it("hides a mirror-only day unless mirrored samples are included", () => {
    expect(resolveSeries(values, undefined, false).has("2024-01-04")).toBe(false);
  });
});
