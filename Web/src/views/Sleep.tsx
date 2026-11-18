import { useMemo, useState } from "react";
import type { EChartsCoreOption } from "echarts/core";
import type { SleepSession, SleepStage } from "../api/types";
import { Chart } from "../components/Chart";
import { palette, useDark } from "../components/theme";
import { Notice, Section, Segmented, Stat } from "../components/ui";
import { useEarliestDay, useSleep } from "../data";
import { t, type Key } from "../i18n";
import { bedtimeMinutes, fmt, fmtDay, fmtHM, fmtMinuteOfDay, fmtSigned } from "../lib/format";
import { mean, median, stdev, theilSen } from "../lib/stats";
import { dayOf, presetStart, todayDay, type Day, type Preset } from "../lib/time";
import { PRESETS } from "./shared";

const STAGES: SleepStage[] = ["deep", "light", "rem", "awake"];
const COLOR: Record<SleepStage, string> = {
  deep: "#4b5bc4",
  light: "#9bbcd6",
  rem: "#2f9c8a",
  awake: "#c77d3a",
  unmeasurable: "#9aa29c",
};

type Minutes = Record<SleepStage, number>;

function minutesByStage(session: SleepSession): Minutes {
  const out: Minutes = { awake: 0, light: 0, deep: 0, rem: 0, unmeasurable: 0 };
  for (const iv of session.stages) out[iv.stage] += (Date.parse(iv.end) - Date.parse(iv.start)) / 60_000;
  return out;
}

const asleepMinutes = (m: Minutes) => m.light + m.deep + m.rem;

function clockMinutes(iso: string): number {
  const d = new Date(iso);
  return d.getHours() * 60 + d.getMinutes();
}

export function Sleep() {
  const [preset, setPreset] = useState<Preset>("month");
  const p = palette(useDark());
  const today = todayDay();
  const earliest = useEarliestDay();
  const sleep = useSleep(presetStart(preset, today, earliest), today);
  const nights = useMemo(() => sleep.data ?? [], [sleep.data]);

  const stats = useMemo(() => {
    const totals: Minutes = { awake: 0, light: 0, deep: 0, rem: 0, unmeasurable: 0 };
    for (const n of nights) {
      const m = minutesByStage(n);
      for (const k of Object.keys(totals) as SleepStage[]) totals[k] += m[k];
    }
    const bed = nights.map((n) => bedtimeMinutes(n.start));
    const starts = nights.map((n) => Date.parse(n.start));
    const origin = starts.length ? Math.min(...starts) : 0;
    const spanYears = starts.length ? (Math.max(...starts) - origin) / (365.25 * 86_400_000) : 0;
    const years = starts.map((s) => (s - origin) / (365.25 * 86_400_000));
    return {
      totals,
      asleepAvg: mean(nights.map((n) => asleepMinutes(minutesByStage(n)))),
      bedMedian: median(bed),
      bedSd: stdev(bed),
      wakeMedian: median(nights.map((n) => clockMinutes(n.end))),
      // A drift per year needs at least a year of nights; a month of nights fits noise.
      drift: nights.length >= 30 && spanYears >= 1 ? theilSen(years, bed) : null,
      score: mean(nights.flatMap((n) => (n.score != null ? [n.score] : []))),
    };
  }, [nights]);

  const chart = useMemo((): EChartsCoreOption => {
    const axis = { color: p.muted };
    return {
      grid: { left: 44, right: 8, top: 40, bottom: 28 },
      legend: {
        top: 0,
        itemWidth: 10,
        itemHeight: 10,
        textStyle: { color: p.muted },
        data: STAGES.map((s) => t(`slStage_${s}` as Key)),
      },
      tooltip: { trigger: "axis", axisPointer: { type: "shadow" } },
      xAxis: {
        type: "category",
        data: nights.map((n) => dayOf(new Date(n.end))),
        axisLabel: { color: axis.color, formatter: (v: string) => fmtDay(v as Day, { day: "numeric", month: "short" }) },
        axisLine: { lineStyle: { color: p.rule } },
      },
      yAxis: {
        type: "value",
        axisLabel: { color: axis.color, formatter: (v: number) => `${fmt(v / 60)} h` },
        splitLine: { lineStyle: { color: p.grid } },
      },
      series: STAGES.map((stage) => ({
        name: t(`slStage_${stage}` as Key),
        type: "bar" as const,
        stack: "night",
        barMaxWidth: 18,
        itemStyle: { color: COLOR[stage] },
        data: nights.map((n) => Math.round(minutesByStage(n)[stage])),
      })),
    };
  }, [nights, p]);

  if (sleep.error) return <Notice action={t("retry")} onAction={sleep.retry}>{t("loadFailed")}</Notice>;

  const { totals } = stats;
  const asleepTotal = asleepMinutes(totals);
  const control = <Segmented label={t("xpRange")} value={preset} options={PRESETS} onChange={setPreset} />;

  return (
    <Section title={t("slTitle")} lead={t("slLead")} aside={control}>
      {sleep.loading ? (
        <p className="muted">{t("loading")}…</p>
      ) : nights.length === 0 ? (
        <Notice>{t("noData")}</Notice>
      ) : (
        <>
          <div className="stats">
            <Stat
              label={t("slAvg")}
              value={stats.asleepAvg === null ? "–" : fmtHM(stats.asleepAvg)}
              note={`${t("slNights")}: ${nights.length}`}
            />
            <Stat label={t("slBedtime")} value={stats.bedMedian === null ? "–" : fmtMinuteOfDay(stats.bedMedian)} />
            <Stat label={t("slWake")} value={stats.wakeMedian === null ? "–" : fmtMinuteOfDay(stats.wakeMedian)} />
            <Stat
              label={t("slConsistency")}
              value={stats.bedSd === null ? "–" : `${fmt(stats.bedSd)} ${t("slMinutes")}`}
            />
            <Stat label={t("slScore")} value={stats.score === null ? "–" : fmt(stats.score)} />
          </div>

          <Chart option={chart} height={320} label={t("slStages")} />

          <div className="stats">
            {(["deep", "rem", "light"] as SleepStage[]).map((stage) => (
              <Stat
                key={stage}
                label={t(`slStage_${stage}` as Key)}
                value={asleepTotal > 0 ? `${fmt((100 * totals[stage]) / asleepTotal)} %` : "–"}
                note={fmtHM(totals[stage] / nights.length)}
              />
            ))}
          </div>

          {stats.drift !== null && (
            <p className="finding">
              {t("slDriftLine", { amount: `${fmtSigned(stats.drift, 0)} ${t("slMinutes")}` })}
            </p>
          )}
        </>
      )}
    </Section>
  );
}
