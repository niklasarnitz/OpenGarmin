import { useMemo } from "react";
import type { EChartsCoreOption } from "echarts/core";
import type { Insight, InsightKind } from "../api/types";
import { Chart } from "./Chart";
import { palette, useDark } from "./theme";
import { t, type Key } from "../i18n";
import { fmt } from "../lib/format";
import { insightHrefs } from "../lib/insights";
import { dayMs } from "../lib/time";
import { conceptName } from "../views/shared";
import { conceptOf } from "../lib/concepts";
import type { Day } from "../lib/time";

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** Small chart that goes with a finding. Time values are days or ISO instants; numbers pass through. */
export function InsightChart({ insight, height }: { insight: Insight; height: number }) {
  const p = palette(useDark());
  const chart = insight.chart;
  const option = useMemo((): EChartsCoreOption | null => {
    if (!chart) return null;
    const toX = (x: number | string): number => (typeof x === "number" ? x : DAY.test(x) ? dayMs(x as Day) : Date.parse(x));
    const kind = chart.type;
    const colors = [p.garmin, p.signal, p.apple];
    const timeAxis = kind !== "scatter" && chart.series.some((s) => s.points.some(([x]) => typeof x === "string"));
    const axis = {
      axisLabel: { color: p.muted },
      axisLine: { lineStyle: { color: p.rule } },
      splitLine: { lineStyle: { color: p.grid } },
    };
    return {
      grid: { left: 40, right: 10, top: chart.series.length > 1 ? 26 : 10, bottom: 24 },
      legend: chart.series.length > 1 ? { top: 0, textStyle: { color: p.muted } } : undefined,
      tooltip: { trigger: kind === "scatter" ? "item" : "axis" },
      xAxis: { type: timeAxis ? "time" : "value", scale: true, axisLabel: { color: p.muted }, axisLine: { lineStyle: { color: p.rule } }, splitLine: { show: false } },
      yAxis: { type: "value", scale: kind !== "bar", ...axis },
      series: chart.series.map((s, i) => ({
        name: s.name,
        type: kind,
        data: s.points.map(([x, y]) => [toX(x), y]),
        showSymbol: kind === "scatter",
        symbolSize: 4,
        barMaxWidth: 14,
        lineStyle: { color: colors[i % colors.length], width: 1.8 },
        itemStyle: { color: colors[i % colors.length], opacity: kind === "scatter" ? 0.5 : 1 },
      })),
    };
  }, [chart, p]);

  if (!option) return null;
  return <Chart option={option} height={height} label={insight.title} />;
}

const kindLabel = (kind: InsightKind) => t(`kind_${kind}` as Key);

/** One finding: the sentence the server wrote, its chart when it has one, and links into the explorer. */
export function InsightCard({ insight, compact = false }: { insight: Insight; compact?: boolean }) {
  const links = insightHrefs(insight);
  const period = `${insight.period.from} – ${insight.period.to}`;
  return (
    <article className="insight">
      <h3>{insight.title}</h3>
      <p className="finding">{insight.summary}</p>
      {insight.chart && <InsightChart insight={insight} height={compact ? 120 : 220} />}
      {!compact && insight.detail && (
        <details className="insight-detail">
          <summary>{t("insDetail")}</summary>
          <p className="lead">{insight.detail}</p>
        </details>
      )}
      <p className="insight-meta">
        {kindLabel(insight.kind)} · {period} · {t("coN", { n: insight.n })} · {t("insStrength")}{" "}
        {fmt(insight.strength * 100)} % · {t("insConfidence")} {fmt(insight.confidence * 100)} %
      </p>
      <p className="insight-links">
        {links.correlation && <a href={links.correlation}>{t("insOpenCorr")}</a>}
        {links.metrics.map((m) => (
          <a key={m.id} href={m.href}>
            {t("insOpenMetric")}: {conceptName(m.id)}
          </a>
        ))}
      </p>
    </article>
  );
}

/** The metric a finding names, as a label for filters. Metrics the dashboard does not chart keep their key. */
export function metricLabel(key: string): string {
  const id = conceptOf(key);
  return id ? conceptName(id) : key;
}
