import type { Activity, DailyPoint, Insight, MeResponse, MetricInfo, SleepSession } from "./types";
import * as mock from "../mock";

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

async function getJSON<T>(path: string, params: Record<string, string | number | undefined> = {}): Promise<T> {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) query.set(key, String(value));
  }
  const qs = query.toString();
  const suffix = qs ? `?${qs}` : "";
  const response = await fetch(`/api/v1${path}${suffix}`, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new ApiError(response.status, `${response.status} ${path}`);
  return (await response.json()) as T;
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new ApiError(response.status, `${response.status} ${path}`);
  return (await response.json()) as T;
}

/** Cookie session check. Throws ApiError(401) when signed out. */
export async function me(): Promise<MeResponse> {
  if (isMock) return mock.me;
  return getJSON<MeResponse>("/me");
}

export async function login(email: string, password: string): Promise<MeResponse> {
  if (isMock) return mock.me;
  const result = await postJSON<{ user: MeResponse }>("/auth/login", { email, password });
  return result.user;
}

export async function logout(): Promise<void> {
  if (isMock) return;
  await fetch("/api/v1/auth/logout", { method: "POST", credentials: "same-origin" });
}

export async function fetchMetrics(): Promise<MetricInfo[]> {
  if (isMock) return mock.metrics();
  return getJSON<MetricInfo[]>("/metrics");
}

export async function fetchDaily(from: string, to: string, metrics: string[]): Promise<DailyPoint[]> {
  if (isMock) return mock.daily(from, to, metrics);
  return getJSON<DailyPoint[]>("/metrics/daily", { from, to, metrics: metrics.join(",") });
}

export async function fetchSleep(from: string, to: string): Promise<SleepSession[]> {
  if (isMock) return mock.sleep(from, to);
  return getJSON<SleepSession[]>("/sleep", { from, to });
}

export interface ActivityPage {
  items: Activity[];
  nextCursor: string | null;
}

export async function fetchActivities(limit: number, cursor?: string): Promise<ActivityPage> {
  if (isMock) return mock.activities(limit, cursor);
  return getJSON<ActivityPage>("/activities", { limit, cursor });
}

export async function fetchActivity(id: string): Promise<Activity> {
  if (isMock) return mock.activity(id);
  return getJSON<Activity>(`/activities/${encodeURIComponent(id)}`);
}

export async function fetchInsights(from: string, to: string, lang: "en" | "de"): Promise<Insight[]> {
  if (isMock) return mock.insights(from, to, lang);
  return getJSON<Insight[]>("/insights", { from, to, lang });
}
