import { useEffect, useMemo, useState } from "react";
import type { EChartsCoreOption } from "echarts/core";
import { fetchActivities, fetchActivity } from "../api/client";
import type { ActivityRecord, ActivitySummary } from "../api/types";
import { Chart } from "../components/Chart";
import { palette, useDark } from "../components/theme";
import { RouteMap } from "../components/RouteMap";
import { Notice, Section, Select, Stat } from "../components/ui";
import { useAsync, useEarliestDay } from "../data";
import { locale, sportKey, t, type Key } from "../i18n";
import { fmt, fmtHM, fmtKm } from "../lib/format";
import { todayDay, yearOf } from "../lib/time";
import { sourceLabel } from "./shared";

const MAX_HR = 190;
/** The server caps a page at 200. A larger page keeps years of history a few clicks away. */
const PAGE = 100;

const stamp = (iso: string) =>
  new Date(iso).toLocaleString(locale, {
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

const mmss = (seconds: number) => {
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

const sportName = (n: number) => t(sportKey(n));

function zoneIndex(bpm: number): number {
  const share = bpm / MAX_HR;
  return share < 0.6 ? 0 : share < 0.7 ? 1 : share < 0.8 ? 2 : share < 0.9 ? 3 : 4;
}

/** Seconds spent in each of the five zones. A sample counts for the time until the next one, capped at a minute. */
function zoneSeconds(records: ActivityRecord[]): number[] {
  const out = [0, 0, 0, 0, 0];
  records.forEach((r, i) => {
    const next = records[i + 1];
    if (r.heartRate == null || !next) return;
    const seconds = Math.min(60, (Date.parse(next.date) - Date.parse(r.date)) / 1000);
    const z = zoneIndex(r.heartRate);
    out[z] = (out[z] ?? 0) + seconds;
  });
  return out;
}

export function Activities() {
  const [items, setItems] = useState<ActivitySummary[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [year, setYear] = useState("");
  const current = yearOf(todayDay());
  const earliest = useEarliestDay();
  const years = Array.from({ length: current - (earliest ? yearOf(earliest) : current) + 1 }, (_, i) => String(current - i));

  /** A page before `cursor`, appended; without one, the newest page, replacing the list. */
  function load(cursor?: string, append = cursor !== undefined) {
    setBusy(true);
    setFailed(false);
    fetchActivities(PAGE, cursor).then(
      (page) => {
        setItems((prev) => (append ? [...prev, ...page.items] : page.items));
        setNext(page.nextCursor ?? null);
        setLoaded(true);
        setBusy(false);
      },
      () => {
        setFailed(true);
        setBusy(false);
      },
    );
  }

  useEffect(() => {
    load();
  }, []);

  // The server reads a day as the cursor too: activities that start before 1 January of the next year.
  function jump(value: string) {
    setYear(value);
    load(value ? `${Number(value) + 1}-01-01` : undefined, false);
  }

  if (failed && items.length === 0) {
    return (
      <Notice action={t("retry")} onAction={() => load()}>
        {t("loadFailed")}
      </Notice>
    );
  }

  return (
    <Section
      title={t("acTitle")}
      aside={
        years.length > 1 ? (
          <Select
            label={t("acFromYear")}
            value={year}
            options={[{ value: "", label: t("acNewest") }, ...years.map((y) => ({ value: y, label: y }))]}
            onChange={jump}
          />
        ) : undefined
      }
    >
      {loaded && items.length === 0 ? (
        <Notice>{t("acNone")}</Notice>
      ) : (
        <>
          <table>
            <thead>
              <tr>
                <th>{t("acDate")}</th>
                <th>{t("acSport")}</th>
                <th>{t("xpSource")}</th>
                <th className="num">{t("acDistance")}</th>
                <th className="num">{t("acDuration")}</th>
                <th className="num">{t("acHr")}</th>
              </tr>
            </thead>
            <tbody>
              {items.map((a) => (
                <tr key={a.id}>
                  <td>
                    <a href={`#/activities/${encodeURIComponent(a.id)}`}>{stamp(a.start)}</a>
                  </td>
                  <td>{a.name || sportName(a.sport)}</td>
                  <td className="muted">{sourceLabel(a.source)}</td>
                  <td className="num">{a.distance ? fmtKm(a.distance) : "–"}</td>
                  <td className="num">{fmtHM(a.duration / 60)}</td>
                  <td className="num">{a.averageHeartRate ? `${a.averageHeartRate} bpm` : "–"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {next && (
            <p>
              <button type="button" className="ghost" disabled={busy} onClick={() => load(next)}>
                {t("acLoad")}
              </button>
            </p>
          )}
        </>
      )}
    </Section>
  );
}

export function ActivityDetail({ id }: { id: string }) {
  const activity = useAsync(() => fetchActivity(id), `activity|${id}`);
  const p = palette(useDark());
  const data = activity.data?.activity;
  const records = useMemo(() => activity.data?.records ?? [], [activity.data]);
  const laps = useMemo(() => activity.data?.laps ?? [], [activity.data]);

  const track = useMemo(
    () =>
      records.flatMap((r): [number, number][] =>
        r.latitude != null && r.longitude != null ? [[r.latitude, r.longitude]] : [],
      ),
    [records],
  );
  const zones = useMemo(() => zoneSeconds(records), [records]);
  // Apple Health workouts carry a route at most, without heart rate.
  const hasHeartRate = useMemo(() => records.some((r) => r.heartRate != null), [records]);

  const hrChart = useMemo((): EChartsCoreOption => {
    const axis = {
      axisLabel: { color: p.muted },
      axisLine: { lineStyle: { color: p.rule } },
      splitLine: { lineStyle: { color: p.grid } },
    };
    return {
      grid: { left: 44, right: 12, top: 12, bottom: 26 },
      tooltip: { trigger: "axis", valueFormatter: (v: unknown) => `${Math.round(Number(v))} bpm` },
      xAxis: { type: "time", axisLabel: { color: p.muted }, axisLine: { lineStyle: { color: p.rule } }, splitLine: { show: false } },
      yAxis: { type: "value", scale: true, ...axis },
      series: [
        {
          type: "line" as const,
          data: records.flatMap((r): [number, number][] =>
            r.heartRate != null ? [[Date.parse(r.date), r.heartRate]] : [],
          ),
          showSymbol: false,
          lineStyle: { color: p.signal, width: 1.4 },
          itemStyle: { color: p.signal },
          areaStyle: { color: p.signal, opacity: 0.08 },
        },
      ],
    };
  }, [records, p]);

  if (activity.error) {
    return (
      <Notice action={t("retry")} onAction={activity.retry}>
        {t("loadFailed")}
      </Notice>
    );
  }
  if (!data) return <p className="muted">{t("loading")}…</p>;

  const zoneTotal = zones.reduce((sum, s) => sum + s, 0);

  return (
    <>
      <p className="back">
        <a href="#/activities">{t("acBack")}</a>
      </p>

      <Section title={data.name || sportName(data.sport)} lead={`${sportName(data.sport)} · ${stamp(data.start)} · ${sourceLabel(data.source)}`}>
        <div className="stats">
          {data.distance ? <Stat label={t("acDistance")} value={fmtKm(data.distance)} /> : null}
          <Stat label={t("acDuration")} value={fmtHM(data.duration / 60)} />
          {data.averageHeartRate ? <Stat label={t("acHr")} value={String(data.averageHeartRate)} unit="bpm" /> : null}
          {data.maxHeartRate ? <Stat label={t("acHrMax")} value={String(data.maxHeartRate)} unit="bpm" /> : null}
          {data.averageSpeed ? <Stat label={t("acPace")} value={fmt(data.averageSpeed * 3.6, 1)} unit="km/h" /> : null}
          {data.totalAscent ? <Stat label={t("acAscent")} value={fmt(data.totalAscent)} unit="m" /> : null}
          {data.activeCalories ? <Stat label={t("acCalories")} value={fmt(data.activeCalories)} unit="kcal" /> : null}
          {data.trainingEffect ? <Stat label={t("acEffect")} value={fmt(data.trainingEffect, 1)} /> : null}
        </div>
      </Section>

      <Section title={t("acRoute")}>
        {track.length > 1 ? (
          <RouteMap track={track} signal={p.signal} />
        ) : (
          <Notice>{t("acRouteNone")}</Notice>
        )}
      </Section>

      {records.length > 0 && !hasHeartRate && (
        <Section title={t("acHrChart")}>
          <Notice>{t("acNoHr")}</Notice>
        </Section>
      )}

      {hasHeartRate && (
        <Section title={t("acHrChart")}>
          <Chart option={hrChart} height={220} label={t("acHrChart")} />
          <div className="zones">
            {zones.map((seconds, i) => (
              <div key={i} className="zone">
                <span>{t(`acZone${i + 1}` as Key)}</span>
                <div className="zone-track">
                  <div className="zone-fill" style={{ width: `${zoneTotal > 0 ? (100 * seconds) / zoneTotal : 0}%` }} />
                </div>
                <span className="zone-time">{fmtHM(seconds / 60)}</span>
              </div>
            ))}
          </div>
          <p className="lead">{t("acZonesNote")}</p>
        </Section>
      )}

      {laps.length > 0 && (
        <Section title={t("acLaps")}>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th className="num">{t("acDistance")}</th>
                <th className="num">{t("acDuration")}</th>
                <th className="num">{t("acHr")}</th>
              </tr>
            </thead>
            <tbody>
              {laps.map((lap, i) => (
                <tr key={lap.start}>
                  <td>{i + 1}</td>
                  <td className="num">{lap.distance ? fmtKm(lap.distance) : "–"}</td>
                  <td className="num">{mmss((Date.parse(lap.end) - Date.parse(lap.start)) / 1000)}</td>
                  <td className="num">{lap.averageHeartRate ?? "–"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}
    </>
  );
}
