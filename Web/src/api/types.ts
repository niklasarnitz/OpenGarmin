// Wire types for the OpenGarmin backend (docs/backend-api.md), derived from the runtime schemas in schema.ts.
import type { z } from "zod";
import type * as S from "./schema";

export type User = z.infer<typeof S.User>;
export type MeResponse = User;
export type MetricInfo = z.infer<typeof S.MetricInfo>;
export type Aggregation = MetricInfo["aggregation"];
export type DailyPoint = z.infer<typeof S.DailyPoint>;
export type ActivitySummary = z.infer<typeof S.ActivitySummary>;
export type ActivityPage = z.infer<typeof S.ActivityPage>;
export type Lap = z.infer<typeof S.Lap>;
export type ActivityRecord = z.infer<typeof S.ActivityRecord>;
export type ActivityDetail = z.infer<typeof S.ActivityDetail>;
export type SleepStage = z.infer<typeof S.SleepStage>;
export type SleepSession = z.infer<typeof S.SleepSession>;
export type SleepInterval = SleepSession["stages"][number];
export type Insight = z.infer<typeof S.Insight>;
export type InsightKind = Insight["kind"];
export type InsightSeries = NonNullable<Insight["chart"]>["series"][number];
