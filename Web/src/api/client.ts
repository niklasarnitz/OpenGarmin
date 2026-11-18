import { z } from "zod";
import type { Day } from "../lib/time";
import * as mock from "../mock";
import * as S from "./schema";
import type { ActivityDetail, ActivityPage, DailyPoint, Insight, MeResponse, MetricInfo, SleepSession } from "./types";

export const isMock =
  import.meta.env.VITE_MOCK === "1" || new URLSearchParams(location.search).has("mock");

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

type Params = Record<string, string | number | undefined>;

/** Fails with the server's `reason` for an error status, and with the bad field's path when the body breaks the contract. */
async function request<T extends z.ZodType>(path: string, schema: T, init: RequestInit, params: Params = {}): Promise<z.output<T>> {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) query.set(key, String(value));
  }
  const qs = query.toString();
  const response = await fetch(`/api/v1${path}${qs ? `?${qs}` : ""}`, {
    ...init,
    credentials: "same-origin",
    headers: { Accept: "application/json", ...init.headers },
  });
  if (!response.ok) {
    const body = S.ErrorBody.safeParse(await response.json().catch(() => null));
    throw new ApiError(response.status, `${response.status} ${path}: ${body.success ? body.data.reason : response.statusText}`);
  }
  const parsed = schema.safeParse(await response.json());
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    throw new ApiError(0, `Unexpected response from ${path} at ${issue?.path.join(".") || "(root)"}: ${issue?.message}`);
  }
  return parsed.data;
}

const get = <T extends z.ZodType>(path: string, schema: T, params?: Params) => request(path, schema, {}, params);

/** Cookie session check. Throws ApiError(401) when signed out. */
export async function me(): Promise<MeResponse> {
  if (isMock) return mock.me;
  return get("/me", S.User);
}

export async function login(email: string, password: string): Promise<MeResponse> {
  if (isMock) return mock.me;
  const result = await request("/auth/login", S.TokenResponse, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  return result.user;
}

export async function logout(): Promise<void> {
  if (isMock) return;
  await fetch("/api/v1/auth/logout", { method: "POST", credentials: "same-origin" });
}

export async function fetchMetrics(): Promise<MetricInfo[]> {
  if (isMock) return mock.metrics();
  return get("/metrics", z.array(S.MetricInfo));
}

/** Daily values for the days `from` (inclusive) to `to` (exclusive). */
export async function fetchDaily(from: Day, to: Day, metrics: string[]): Promise<DailyPoint[]> {
  if (isMock) return mock.daily(from, to, metrics);
  return get("/metrics/daily", z.array(S.DailyPoint), { from, to, metrics: metrics.join(",") });
}

/** Sleep sessions starting on the days `from` (inclusive) to `to` (exclusive). */
export async function fetchSleep(from: Day, to: Day): Promise<SleepSession[]> {
  if (isMock) return mock.sleep(from, to);
  return get("/sleep", z.array(S.SleepSession), { from, to });
}

export async function fetchActivities(limit: number, cursor?: string): Promise<ActivityPage> {
  if (isMock) return mock.activities(limit, cursor);
  return get("/activities", S.ActivityPage, { limit, cursor });
}

export async function fetchActivity(id: string): Promise<ActivityDetail> {
  if (isMock) return mock.activity(id);
  return get(`/activities/${encodeURIComponent(id)}`, S.ActivityDetail);
}

/** Findings for the days `from` (inclusive) to `to` (exclusive). */
export async function fetchInsights(from: Day, to: Day, lang: "en" | "de"): Promise<Insight[]> {
  if (isMock) return mock.insights(from, to, lang);
  return get("/insights", z.array(S.Insight), { from, to, lang });
}
