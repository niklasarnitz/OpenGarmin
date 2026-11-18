import { useMemo, useState } from "react";
import type { EChartsCoreOption } from "echarts/core";
import { Chart } from "../components/Chart";
import { palette, useDark } from "../components/theme";
import { Notice, Section, Segmented, Stat } from "../components/ui";
import { useEarliestDay, useSeries } from "../data";
import { locale, t } from "../i18n";
import { fmtDay } from "../lib/format";
import { aggregate, byYear, monthOf, profile, records, rolling, weekdayOf, type Gran } from "../lib/analytics";
import { CONCEPTS, CONCEPT_IDS, type ConceptId } from "../lib/concepts";
import { mean } from "../lib/stats";
import { dayMs, presetStart, todayDay, type Preset } from "../lib/time";
import { PRESETS, conceptName, rangeFromQuery, valueText } from "./shared";

type Mode = "series" | "years" | "season" | "weekday";
type Smooth = "0" | "7" | "28";

const isConcept = (v: string | null): v is ConceptId => v !== null && (CONCEPT_IDS as string[]).includes(v);

const GRANS: { value: Gran; label: string }[] = [
  { value: "day", label: t("gDay") },
  { value: "week", label: t("gWeek") },
  { value: "month", label: t("gMonth") },
  { value: "year", label: t("gYear") },
];
const MODES: { value: Mode; label: string }[] = [
  { value: "series", label: t("modeSeries") },
  { value: "years", label: t("xpYoy") },
  { value: "season", label: t("xpSeasonal") },
  { value: "weekday", label: t("xpWeekday") },
];
const SMOOTHS: { value: Smooth; label: string }[] = [
  { value: "0", label: t("xpRollingNone") },
  { value: "7", label: t("xpRolling7") },
  { value: "28", label: t("xpRolling28") },
];

const monthLabels = Array.from({ length: 12 }, (_, i) =>
  new Intl.DateTimeFormat(locale, { month: "short" }).format(new Date(2001, i, 1)),
);
// 1 January 2001 was a Monday, so index 0 is Monday, as weekdayOf expects.
const weekdayLabels = Array.from({ length: 7 }, (_, i) =>
  new Intl.DateTimeFormat(locale, { weekday: "short" }).format(new Date(2001, 0, 1 + i)),
);
const dayOfYearLabel = (v: number) =>
  new Intl.DateTimeFormat(locale, { month: "short", day: "numeric" }).format(new Date(2001, 0, 1 + Math.round(v)));

export function Metrics({ query }: { query: URLSearchParams }) {
  const [id, setId] = useState<ConceptId>(() => {
    const m = query.get("m");
    return isConcept(m) ? m : "steps";
  });
  const [preset, setPreset] = useState<Preset>("year");
  const [custom, setCustom] = useState(() => rangeFromQuery(query));
  const [gran, setGran] = useState<Gran>("week");
  const [smooth, setSmooth] = useState<Smooth>("0");
  const [mode, setMode] = useState<Mode>("series");

  const p = palette(useDark());
  const today = todayDay();
  const earliest = useEarliestDay();
  const range = custom ?? { from: presetStart(preset, today, earliest), to: today };
  const { series, loading, error, retry } = useSeries([id], range.from, range.to);
  const concept = CONCEPTS[id];
  const daily = series[id];
  const days = useMemo(() => (smooth === "0" ? daily : rolling(daily, Number(smooth))), [daily, smooth]);
  const rec = useMemo(() => records(daily), [daily]);
  const average = useMemo(() => mean([...daily.values()]), [daily]);

  const option = useMemo((): EChartsCoreOption => {
    const fmtTip = (v: unknown) => valueText(id, Number(v));
    const axisStyle = {
      axisLabel: { color: p.muted },
      axisLine: { lineStyle: { color: p.rule } },
      splitLine: { lineStyle: { color: p.grid } },
    };
    const grid = { left: 56, right: 12, top: 28, bottom: 28 };

    if (mode === "season" || mode === "weekday") {
      const groups = mode === "season" ? profile(days, monthOf, 12) : profile(days, weekdayOf, 7);
      return {
        grid,
        tooltip: { trigger: "axis", valueFormatter: fmtTip },
        xAxis: {
          type: "category",
          data: mode === "season" ? monthLabels : weekdayLabels,
          axisLabel: { color: p.muted },
          axisLine: { lineStyle: { color: p.rule } },
        },
        yAxis: { type: "value", scale: true, ...axisStyle },
        series: [
          {
            type: "bar" as const,
            data: groups,
            itemStyle: { color: p.garmin },
            barMaxWidth: 36,
          },
        ],
      };
    }

    if (mode === "years") {
      const groups = [...byYear(days)];
      const last = groups.length - 1;
      return {
        grid,
        legend: { top: 0, type: "scroll", textStyle: { color: p.muted } },
        tooltip: { trigger: "axis", valueFormatter: fmtTip },
        xAxis: {
          type: "value",
          min: 0,
          max: 365,
          interval: 30.4,
          axisLabel: { color: p.muted, formatter: (v: number) => dayOfYearLabel(v) },
          axisLine: { lineStyle: { color: p.rule } },
          splitLine: { show: false },
        },
        yAxis: { type: "value", scale: true, ...axisStyle },
        series: groups.map(([year, points], i) => ({
          name: String(year),
          type: "line" as const,
          data: points,
          showSymbol: false,
          lineStyle: {
            width: i === last ? 2.4 : 1.2,
            color: i === last ? p.signal : p.garmin,
            opacity: 0.18 + (0.82 * (i + 1)) / Math.max(groups.length, 1),
          },
          itemStyle: { color: i === last ? p.signal : p.garmin },
        })),
      };
    }

    const buckets = aggregate(days, gran, concept.agg);
    const bar = concept.agg === "sum";
    return {
      grid,
      tooltip: { trigger: "axis", valueFormatter: fmtTip },
      xAxis: {
        type: "time",
        axisLabel: { color: p.muted },
        axisLine: { lineStyle: { color: p.rule } },
        splitLine: { show: false },
      },
      yAxis: { type: "value", scale: !bar, ...axisStyle },
      series: [
        {
          type: bar ? ("bar" as const) : ("line" as const),
          data: buckets.map((b) => [dayMs(b.start), b.value]),
          showSymbol: false,
          barMaxWidth: 10,
          lineStyle: { color: p.garmin, width: 1.6 },
          itemStyle: { color: p.garmin },
          areaStyle: bar ? undefined : { color: p.garmin, opacity: 0.08 },
        },
      ],
    };
  }, [days, gran, concept.agg, id, mode, p]);

  if (error) return <Notice action={t("retry")} onAction={retry}>{t("loadFailed")}</Notice>;

  const lead = mode === "years" ? t("xpYoyLead") : mode === "season" ? t("xpSeasonalLead") : undefined;

  return (
    <>
      <div className="chips" role="group" aria-label={t("xpTitle")}>
        {CONCEPT_IDS.map((c) => (
          <button key={c} type="button" aria-pressed={c === id} onClick={() => setId(c)}>
            {conceptName(c)}
          </button>
        ))}
      </div>
      <div className="controls">
        <Segmented
          label={t("xpRange")}
          value={preset}
          options={PRESETS}
          onChange={(v) => {
            setPreset(v);
            setCustom(null);
          }}
        />
        <Segmented label={t("xpGran")} value={gran} options={GRANS} onChange={setGran} />
        <Segmented label={t("xpRolling")} value={smooth} options={SMOOTHS} onChange={setSmooth} />
        <Segmented label={t("xpSeries")} value={mode} options={MODES} onChange={setMode} />
      </div>

      <Section title={conceptName(id)} lead={lead}>
        {custom && (
          <p className="stat-note">
            {t("xpCustom", { from: fmtDay(custom.from), to: fmtDay(custom.to) })}{" "}
            <button type="button" className="ghost" onClick={() => setCustom(null)}>
              {t("xpStandard")}
            </button>
          </p>
        )}
        {loading ? (
          <p className="muted">{t("loading")}…</p>
        ) : daily.size === 0 ? (
          <Notice>{t("noData")}</Notice>
        ) : (
          <>
            <Chart option={option} height={340} label={conceptName(id)} />
            <div className="stats">
              <Stat label={t("average")} value={average === null ? "–" : valueText(id, average)} note={t("xpShown", { n: daily.size })} />
              {rec && <Stat label={t("xpHighest")} value={valueText(id, rec.max.value)} note={fmtDay(rec.max.day)} />}
              {rec && <Stat label={t("xpLowest")} value={valueText(id, rec.min.value)} note={fmtDay(rec.min.day)} />}
            </div>
          </>
        )}
      </Section>
    </>
  );
}

