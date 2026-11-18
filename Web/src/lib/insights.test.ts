import { describe, expect, it } from "vitest";
import type { Insight } from "../api/types";
import { insightHrefs } from "./insights";

const base: Insight = {
  id: "x",
  kind: "correlation",
  title: "",
  summary: "",
  metrics: ["sleepMinutes", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"],
  strength: 0.4,
  confidence: 0.9,
  n: 300,
  period: { from: "2024-01-01", to: "2024-06-30" },
};

describe("insightHrefs", () => {
  it("opens the correlation view for both metrics over the finding's period", () => {
    const h = insightHrefs(base);
    expect(h.correlation).toBe("#/correlations?x=sleepMinutes&y=hrv&lag=0&from=2024-01-01&to=2024-06-30");
    expect(insightHrefs({ ...base, lagDays: 2 }).correlation).toContain("&lag=2&");
  });

  it("does not offer a correlation link for other kinds", () => {
    expect(insightHrefs({ ...base, kind: "trend" }).correlation).toBeUndefined();
  });

  it("links each charted metric to the explorer and skips metrics it does not chart", () => {
    const h = insightHrefs({ ...base, kind: "trend", metrics: ["restingHeartRate", "unknownThing", "steps"] });
    expect(h.metrics.map((m) => m.id)).toEqual(["restingHeartRate", "steps"]);
    expect(h.metrics[0]?.href).toBe("#/metrics?m=restingHeartRate&from=2024-01-01&to=2024-06-30");
  });

  it("drops duplicate metric names", () => {
    const h = insightHrefs({ ...base, kind: "pattern", metrics: ["steps", "HKQuantityTypeIdentifierStepCount"] });
    expect(h.metrics).toHaveLength(1);
  });
});
