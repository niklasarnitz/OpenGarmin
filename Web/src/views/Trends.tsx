import { useMemo } from "react";
import type { EChartsCoreOption } from "echarts/core";
import { Chart } from "../components/Chart";
import { palette, useDark } from "../components/theme";
import { Notice, Section } from "../components/ui";
import { useEarliestDay, useSeries } from "../data";
import { t } from "../i18n";
import { fmtMonth } from "../lib/format";
import { trend, type Trend } from "../lib/analytics";
import type { ConceptId } from "../lib/concepts";
import { dayMs, todayDay } from "../lib/time";
import { conceptName, valueText } from "./shared";

const IDS: ConceptId[] = [
  "steps",
  "activeEnergy",
  "activityMinutes",
  "heartRate",
  "restingHeartRate",
  "hrv",
  "sleepMinutes",
  "stress",
  "bodyBattery",
  "spo2",
  "weight",
];

export function Trends() {
  const today = todayDay();
  const earliest = useEarliestDay();
  const { series, loading, error, retry } = useSeries(IDS, earliest ?? today, today);
  const found = useMemo(
    () =>
      IDS.flatMap((id) => {
        const tr = trend(series[id]);
        return tr ? [{ id, tr }] : [];
      }),
    [series],
  );

  if (error) return <Notice action={t("retry")} onAction={retry}>{t("loadFailed")}</Notice>;
  if (loading) return <p className="muted">{t("loading")}…</p>;

  return (
    <Section title={t("trTitle")} lead={t("trLead")}>
      {found.length === 0 ? (
        <Notice>{t("trNeedYears")}</Notice>
      ) : (
        <div className="trends">
          {found.map(({ id, tr }) => (
            <TrendCard key={id} id={id} tr={tr} />
          ))}
        </div>
      )}
    </Section>
  );
}

function TrendCard({ id, tr }: { id: ConceptId; tr: Trend }) {
  const p = palette(useDark());
  const name = conceptName(id);
  const significant = tr.p < 0.05;
  const amount = valueText(id, Math.abs(tr.slopePerYear));
  const finding = !significant
    ? t("trFlat", { name })
    : t(tr.slopePerYear > 0 ? "trRising" : "trFalling", { name, amount });
  const first = tr.months[0];
  const last = tr.months.at(-1);
  const cp = tr.changepoint;

  const option = useMemo((): EChartsCoreOption => {
    const axis = {
      axisLabel: { color: p.muted },
      axisLine: { lineStyle: { color: p.rule } },
      splitLine: { lineStyle: { color: p.grid } },
    };
    return {
      grid: { left: 56, right: 12, top: 12, bottom: 28 },
      tooltip: { trigger: "axis" },
      xAxis: { type: "time", axisLabel: { color: p.muted }, axisLine: { lineStyle: { color: p.rule } }, splitLine: { show: false } },
      yAxis: { type: "value", scale: true, ...axis },
      series: [
        {
          name,
          type: "line" as const,
          data: tr.months.map((m) => [dayMs(m.day), m.value]),
          showSymbol: true,
          symbolSize: 3,
          lineStyle: { width: 0 },
          itemStyle: { color: p.muted },
        },
        {
          name: "trend",
          type: "line" as const,
          data: tr.months.map((m, i) => [dayMs(m.day), tr.fitted[i] ?? null]),
          showSymbol: false,
          lineStyle: { color: p.signal, width: 2 },
          itemStyle: { color: p.signal },
          markLine: cp
            ? {
                symbol: "none",
                silent: true,
                label: { show: false },
                lineStyle: { color: p.ink, type: "dashed", width: 1 },
                data: [{ xAxis: dayMs(cp.day) }],
              }
            : undefined,
        },
      ],
    };
  }, [tr, name, p, cp]);

  return (
    <article className="trend">
      <header>
        <h3>{name}</h3>
        <p>{finding}</p>
      </header>
      {first && last && <p className="stat-note">{t("trFrom", { from: fmtMonth(first.day), to: fmtMonth(last.day) })}</p>}
      <Chart option={option} height={200} label={`${name}: ${finding}`} />
      <p className="stat-note">{significant ? t("trSignificant") : t("trNotSignificant")}</p>
      <p className="stat-note">
        {cp
          ? t("trShift", { when: fmtMonth(cp.day), before: valueText(id, cp.before), after: valueText(id, cp.after) })
          : t("trShiftNone")}
      </p>
    </article>
  );
}
