import { describe, expect, it } from "vitest";
import { z } from "zod";
import * as mock from "../mock";
import { addDays, todayDay } from "../lib/time";
import * as S from "./schema";

// Bodies as the server encodes them (Server/Sources/App, TimeCoding.encoder): nil optionals left out, dates with
// fractional seconds, sleep stages under `stages`, an activity detail nested under `activity`.
describe("server responses", () => {
  it("parse sleep sessions with stages and no score", () => {
    const [night] = S.SleepSession.array().parse([
      {
        start: "2026-11-17T22:41:00.000Z",
        end: "2026-11-18T06:02:00.000Z",
        stages: [{ start: "2026-11-17T22:41:00.000Z", end: "2026-11-17T23:10:00.000Z", stage: "light" }],
      },
    ]);
    expect(night?.stages[0]?.stage).toBe("light");
    expect(night?.score).toBeUndefined();
  });

  it("parse an activity detail with its summary nested", () => {
    const detail = S.ActivityDetail.parse({
      activity: {
        id: "6c1e4f9a-0000-4000-8000-000000000001",
        externalId: "fit-123",
        sport: 1,
        start: "2026-11-18T07:00:00.000Z",
        end: "2026-11-18T07:40:00.000Z",
        duration: 2400,
        averageHeartRate: 151,
      },
      laps: [],
      records: [{ date: "2026-11-18T07:00:01.000Z", heartRate: 120 }],
    });
    expect(detail.activity.averageHeartRate).toBe(151);
    expect(detail.records[0]?.latitude).toBeUndefined();
  });

  it("parse a metric without a unit and daily values without min and max", () => {
    expect(S.MetricInfo.parse({ metric: "floors", source: "garmin", aggregation: "sum", first: "2024-01-01", last: "2026-11-18", count: 3 }).unit).toBeUndefined();
    expect(S.DailyPoint.parse({ day: "2026-11-18", metric: "steps", source: "garmin", value: 9000, count: 96 }).min).toBeUndefined();
  });

  it("parse a trend insight whose chart x values are epoch milliseconds", () => {
    const insight = S.Insight.parse({
      id: "trend:restingHeartRate", kind: "trend", title: "t", summary: "s", detail: "", metrics: ["restingHeartRate"],
      strength: 0.4, confidence: 0.9, n: 30, period: { from: "2024-01-01", to: "2026-11-18" },
      chart: { type: "line", series: [{ name: "m", points: [[1_704_067_200_000, 52.1]] }] },
    });
    expect(insight.lagDays).toBeUndefined();
  });

  it("reject a shape that drifted, such as sleep under the old `intervals` name", () => {
    expect(S.SleepSession.safeParse({ start: "2026-11-17T22:41:00Z", end: "2026-11-18T06:02:00Z", intervals: [] }).success).toBe(false);
    expect(S.DailyPoint.safeParse({ day: "2026-11-31", metric: "steps", source: "garmin", value: 1, count: 1 }).success).toBe(false);
    expect(S.DailyPoint.safeParse({ day: "18.11.2026", metric: "steps", source: "garmin", value: 1, count: 1 }).success).toBe(false);
  });
});

// Mock mode stands in for the server, so its data must have the server's shape too.
describe("mock data", () => {
  const to = todayDay();
  const from = addDays(to, -400);
  const check = <T extends z.ZodType>(schema: T, value: unknown) => expect(schema.safeParse(value).error?.issues).toBeUndefined();

  it("matches every response schema", () => {
    check(S.User, mock.me);
    const metrics = mock.metrics();
    check(z.array(S.MetricInfo), metrics);
    check(z.array(S.DailyPoint), mock.daily(from, to, metrics.map((m) => m.metric)));
    check(z.array(S.SleepSession), mock.sleep(from, to));
    const page = mock.activities(5);
    check(S.ActivityPage, page);
    check(S.ActivityDetail, mock.activity(page.items[0]!.id));
    check(z.array(S.Insight), mock.insights(from, to, "en"));
  });
});
