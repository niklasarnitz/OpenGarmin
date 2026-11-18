import { describe, expect, it } from "vitest";
import { aggregate, baseline, changepoint, correlationMatrix, latest, recentVsBaseline, relate, rolling, trend, type Series } from "./analytics";
import { kendall, linearFit, mean, median, pearson, theilSen } from "./stats";
import { addDays, daysBetween, daysInclusive } from "./time";

const series = (start: string, values: number[]): Series => new Map(values.map((v, i) => [addDays(start, i), v]));

/** Park–Miller generator, centred on zero: deterministic noise for the tests. */
function noise(seed: number): () => number {
  let s = seed;
  return () => {
    s = (s * 48271) % 2147483647;
    return s / 2147483647 - 0.5;
  };
}

describe("aggregate", () => {
  it("averages and totals by month", () => {
    const s = series("2024-01-30", [1, 2, 3, 4]); // Jan 30, Jan 31, Feb 1, Feb 2
    expect(aggregate(s, "month", "avg")).toMatchObject([
      { start: "2024-01-01", value: 1.5, n: 2 },
      { start: "2024-02-01", value: 3.5, n: 2 },
    ]);
    expect(aggregate(s, "month", "sum").map((b) => b.value)).toEqual([3, 7]);
  });

  it("starts weeks on Monday", () => {
    // 2024-01-07 is a Sunday, so it closes the week that began on Monday 2024-01-01.
    const s = series("2024-01-07", [5, 7]);
    expect(aggregate(s, "week", "avg").map((b) => [b.start, b.value])).toEqual([
      ["2024-01-01", 5],
      ["2024-01-08", 7],
    ]);
  });
});

describe("rolling", () => {
  it("averages the trailing window", () => {
    const r = rolling(series("2024-03-01", [1, 2, 6, 8]), 2);
    expect(r.get("2024-03-01")).toBe(1);
    expect(r.get("2024-03-02")).toBe(1.5);
    expect(r.get("2024-03-03")).toBe(4);
    expect(r.get("2024-03-04")).toBe(7);
  });

  it("skips missing days instead of counting them as zero", () => {
    const s: Series = new Map([
      ["2024-03-01", 4],
      ["2024-03-03", 8],
    ]);
    expect(rolling(s, 3).get("2024-03-03")).toBe(6);
  });
});

describe("baseline and latest", () => {
  it("compares a day with the days before it, never with itself", () => {
    const s = series("2024-01-01", [10, 10, 10, 10, 10, 10, 10, 100]);
    expect(baseline(s, "2024-01-08", 56)).toMatchObject({ mean: 10, sd: 0, n: 7 });
  });

  it("needs a week of history", () => {
    expect(baseline(series("2024-01-01", [1, 2, 3]), "2024-01-04")).toBeNull();
  });

  it("returns the last day with a value", () => {
    expect(latest(series("2024-01-01", [1, 9]))).toEqual({ day: "2024-01-02", value: 9 });
  });
});

describe("lagged correlation", () => {
  const a = series("2024-01-01", Array.from({ length: 120 }, noise(7)));
  // b on day D equals a on day D - 2, so b reaches a's values two days later.
  const b: Series = new Map([...a].map(([day, v]) => [addDays(day, 2), v]));

  it("finds the lag where the values line up", () => {
    expect(relate(a, b, 2)?.r).toBeCloseTo(1, 10);
    expect(Math.abs(relate(a, b, 0)?.r ?? 1)).toBeLessThan(0.5);
  });

  it("counts only days where both values exist", () => {
    expect(relate(a, b, 0)?.n).toBe(118);
    expect(relate(a, b, 2)?.n).toBe(120);
  });

  it("is directional in the matrix", () => {
    const m = correlationMatrix({ a, b }, 2);
    expect(m.ids).toEqual(["a", "b"]);
    expect(m.r[0]?.[1]).toBeCloseTo(1, 10);
    expect(Math.abs(m.r[1]?.[0] ?? 1)).toBeLessThan(0.5);
  });
});

describe("trend", () => {
  const seasonal = [0, 3, 5, 2, -1, -4, -6, -3, 1, 4, 2, -2];
  const days = daysInclusive("2019-01-01", "2023-12-31");
  const monthOf = (d: string) => Number(d.slice(5, 7)) - 1;
  const years = (d: string) => daysBetween("2019-01-01", d) / 365.25;

  it("recovers a 2-per-year slope through a seasonal swing", () => {
    const s: Series = new Map(days.map((d) => [d, 2 * years(d) + (seasonal[monthOf(d)] ?? 0)]));
    const tr = trend(s);
    expect(tr?.slopePerYear).toBeCloseTo(2, 1);
    expect(tr?.tau).toBeGreaterThan(0.7); // one value per month, but a year shares one level: ties lower tau
    expect(tr?.changepoint).toBeNull();
  });

  it("finds a level shift that a pure trend does not produce", () => {
    const next = noise(11);
    const s: Series = new Map(
      days.map((d) => {
        const step = d >= "2021-07-01" ? 10 : 0;
        return [d, 2 * years(d) + (seasonal[monthOf(d)] ?? 0) + step + next() * 0.8];
      }),
    );
    expect(trend(s)?.changepoint?.day).toBe("2021-07-01");
  });

  it("reports no level shift on a steady trend with noise", () => {
    const next = noise(3);
    const s: Series = new Map(days.map((d) => [d, 2 * years(d) + next() * 0.8]));
    expect(trend(s)?.changepoint).toBeNull();
  });

  it("needs two years of months", () => {
    expect(trend(series("2024-01-01", [1, 2, 3]))).toBeNull();
  });
});

describe("changepoint", () => {
  it("splits two clearly different levels at the right index", () => {
    const next = noise(5);
    const values = Array.from({ length: 40 }, (_, i) => (i < 20 ? 0 : 10) + next());
    expect(changepoint(values, 6)?.index).toBe(20);
  });
});

describe("stats", () => {
  it("fits a line exactly", () => {
    expect(linearFit([0, 1, 2, 3], [1, 3, 5, 7])).toMatchObject({ slope: 2, intercept: 1, r: 1 });
  });

  it("ignores an outlier in Theil–Sen but not in least squares", () => {
    const xs = [0, 1, 2, 3, 4];
    const ys = [0, 1, 2, 3, 100];
    expect(theilSen(xs, ys)).toBe(1);
    expect(linearFit(xs, ys)?.slope).toBeCloseTo(20.2, 10);
  });

  it("gives tau -1 for a strictly falling sequence", () => {
    expect(kendall([5, 4, 3, 2, 1, 0])?.tau).toBe(-1);
  });

  it("takes the middle of an even-length median", () => {
    expect(median([3, 1, 2, 10])).toBe(2.5);
    expect(mean([3, 1, 2, 10])).toBe(4);
  });

  it("reports a perfect negative correlation", () => {
    expect(pearson([1, 2, 3], [3, 2, 1])).toMatchObject({ r: -1, n: 3 });
  });
});

describe("recentVsBaseline", () => {
  it("compares the last week with the weeks before it, not with itself", () => {
    // 56 days at 10, then 7 days at 13: the recent week is 13 against a usual of 10.
    const s = series("2024-01-01", [...Array(56).fill(10), ...Array(7).fill(13)]);
    expect(recentVsBaseline(s, "2024-03-03", 7, 56)).toEqual({ recent: 13, usual: 10, n: 7 });
  });

  it("refuses to compare with too few days", () => {
    expect(recentVsBaseline(series("2024-01-01", [1, 2, 3, 4, 5]), "2024-01-05")).toBeNull();
  });
});
