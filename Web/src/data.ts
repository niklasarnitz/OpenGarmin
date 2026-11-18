import { useMemo, useState, useSyncExternalStore, useEffect } from "react";
import { fetchDaily, fetchInsights, fetchMetrics, fetchSleep } from "./api/client";
import type { Insight, MetricInfo, SleepSession } from "./api/types";
import { lang } from "./i18n";
import type { Series } from "./lib/analytics";
import { CONCEPTS, CONCEPT_IDS, conceptOf, type ConceptId } from "./lib/concepts";
import { resolveSeries, sourcesOf, type SourcedValue } from "./lib/sources";
import { addDays, dayMs, type Day } from "./lib/time";

// MARK: - Source preferences, kept on this device

export interface SourcePrefs {
  preferred: Partial<Record<ConceptId, string>>;
  includeMirror: boolean;
}

const PREFS_KEY = "opengarmin.sources";
const readPrefs = (): SourcePrefs => {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (raw) return { preferred: {}, includeMirror: false, ...(JSON.parse(raw) as Partial<SourcePrefs>) };
  } catch {
    // Unreadable storage falls back to the defaults.
  }
  return { preferred: {}, includeMirror: false };
};

let prefs = readPrefs();
const listeners = new Set<() => void>();

export function usePrefs(): SourcePrefs {
  return useSyncExternalStore(
    (notify) => {
      listeners.add(notify);
      return () => {
        listeners.delete(notify);
      };
    },
    () => prefs,
  );
}

export function updatePrefs(patch: Partial<SourcePrefs>): void {
  prefs = { ...prefs, ...patch };
  localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  listeners.forEach((notify) => notify());
}

// MARK: - Loading

interface Loaded<T> {
  data?: T;
  error: boolean;
  loading: boolean;
  retry: () => void;
}

/** Runs `load` whenever `key` changes. Results for an older key are dropped. */
export function useAsync<T>(load: () => Promise<T>, key: string): Loaded<T> {
  const [state, setState] = useState<{ key: string; data?: T; error: boolean }>({ key: "", error: false });
  const [attempt, setAttempt] = useState(0);
  const fullKey = `${key}#${attempt}`;
  useEffect(() => {
    let live = true;
    load().then(
      (data) => {
        if (live) setState({ key: fullKey, data, error: false });
      },
      () => {
        if (live) setState({ key: fullKey, error: true });
      },
    );
    return () => {
      live = false;
    };
    // `load` is recreated on each render; the key says when a new request is due.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fullKey]);
  const current = state.key === fullKey;
  return {
    data: current ? state.data : undefined,
    error: current && state.error,
    loading: !current,
    retry: () => setAttempt((n) => n + 1),
  };
}

let catalogRequest: Promise<MetricInfo[]> | undefined;
/** The metrics the server holds, loaded once per page view. */
export function useCatalog(): Loaded<MetricInfo[]> {
  return useAsync(() => {
    catalogRequest ??= fetchMetrics().catch((error: unknown) => {
      catalogRequest = undefined;
      throw error;
    });
    return catalogRequest;
  }, "catalog");
}

/** The first day any metric has data, for the "All" range. */
export function useEarliestDay(): Day | undefined {
  const catalog = useCatalog();
  return catalog.data?.reduce<Day | undefined>((min, m) => (min === undefined || m.first < min ? m.first : min), undefined);
}

type Tagged = SourcedValue & { concept: ConceptId };

export interface Resolved {
  series: Record<ConceptId, Series>;
  /** Every source that reports each concept in this range, mirror included. */
  sources: Partial<Record<ConceptId, string[]>>;
  loading: boolean;
  error: boolean;
  retry: () => void;
}

/**
 * One resolved daily series per concept over the inclusive range [from, to]. Concepts not listed in `ids` come
 * back empty, so a view can ask for exactly what it draws.
 */
export function useSeries(ids: readonly ConceptId[], from: Day, to: Day): Resolved {
  const catalog = useCatalog();
  const held = new Set(catalog.data?.map((m) => m.metric) ?? []);
  const keys = ids.flatMap((id) => CONCEPTS[id].keys.filter((k) => held.has(k)));
  const raw = useAsync<Tagged[]>(
    () =>
      keys.length === 0
        ? Promise.resolve([])
        : fetchDaily(from, addDays(to, 1), keys).then((points) =>
            points.flatMap((p) => {
              const id = conceptOf(p.metric);
              return id ? [{ day: p.day, source: p.source, value: p.value, concept: id }] : [];
            }),
          ),
    `${keys.join(",")}|${from}|${to}|${catalog.data ? "ready" : "waiting"}`,
  );
  const current = usePrefs();

  const resolved = useMemo(() => {
    const byConcept = new Map<ConceptId, SourcedValue[]>();
    for (const v of raw.data ?? []) {
      byConcept.set(v.concept, [...(byConcept.get(v.concept) ?? []), { day: v.day, source: v.source, value: v.value }]);
    }
    const series = Object.fromEntries(CONCEPT_IDS.map((id) => [id, new Map()])) as Record<ConceptId, Series>;
    const sources: Partial<Record<ConceptId, string[]>> = {};
    for (const [id, values] of byConcept) {
      series[id] = resolveSeries(values, current.preferred[id], current.includeMirror);
      sources[id] = sourcesOf(values);
    }
    return { series, sources };
  }, [raw.data, current]);

  return {
    ...resolved,
    loading: catalog.loading || raw.loading,
    error: catalog.error || raw.error,
    retry: () => {
      catalog.retry();
      raw.retry();
    },
  };
}

/** Sleep sessions whose night starts in the inclusive day range [from, to]. */
export function useSleep(from: Day, to: Day): Loaded<SleepSession[]> {
  const iso = (day: Day) => new Date(dayMs(day)).toISOString();
  return useAsync(() => fetchSleep(iso(from), iso(addDays(to, 1))), `sleep|${from}|${to}`);
}

/** Curated findings for the inclusive day range [from, to], in the browser's language. */
export function useInsights(from: Day, to: Day): Loaded<Insight[]> {
  return useAsync(() => fetchInsights(from, addDays(to, 1), lang), `insights|${from}|${to}`);
}
