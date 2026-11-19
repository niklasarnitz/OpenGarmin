import { useMemo, useState, type CSSProperties } from "react";
import type { EChartsCoreOption } from "echarts/core";
import { Chart } from "../components/Chart";
import { palette, useDark } from "../components/theme";
import { Notice, Section, Segmented, Stat } from "../components/ui";
import { useEarliestDay, useHeldConcepts, useSeries } from "../data";
import { t } from "../i18n";
import { fmt } from "../lib/format";
import { correlationMatrix, relate } from "../lib/analytics";
import { CONCEPT_IDS, type ConceptId } from "../lib/concepts";
import { fmtDay } from "../lib/format";
import { presetStart, todayDay, type Preset } from "../lib/time";
import { PRESETS, conceptName, rangeFromQuery } from "./shared";

/** Selected at first; every concept with data can be added. */
const DEFAULT: ConceptId[] = ["sleepMinutes", "restingHeartRate", "hrv", "stress", "bodyBattery", "steps", "activeEnergy"];
const ORDER: ConceptId[] = [...DEFAULT, ...CONCEPT_IDS.filter((id) => !DEFAULT.includes(id))];

const LAGS = [
  { value: "0", label: t("coLag0") },
  { value: "1", label: t("coLag1") },
  { value: "2", label: t("coLagN", { n: 2 }) },
  { value: "3", label: t("coLagN", { n: 3 }) },
];

function strengthText(r: number): string {
  const a = Math.abs(r);
  return t(a < 0.1 ? "coStrengthNone" : a < 0.3 ? "coStrengthWeak" : a < 0.5 ? "coStrengthModerate" : "coStrengthStrong");
}

function lagText(lag: number): string {
  if (lag === 0) return t("coLagSameText");
  if (lag === 1) return t("coLagNextText");
  return t("coLagN", { n: lag });
}

/** Background for a matrix cell: teal for positive, rust for negative, stronger with |r|. */
function cellStyle(r: number | null): CSSProperties {
  if (r === null) return {};
  const alpha = Math.min(Math.abs(r), 1) * 0.85;
  return { background: `rgba(var(${r >= 0 ? "--pos-rgb" : "--neg-rgb"}), ${alpha.toFixed(2)})` };
}

const LAG_KEYS = ["0", "1", "2", "3"];

function conceptParam(query: URLSearchParams, key: string, fallback: ConceptId): ConceptId {
  const v = query.get(key);
  return v && (CONCEPT_IDS as string[]).includes(v) ? (v as ConceptId) : fallback;
}

/** Reads ?x=&y=&lag=&from=&to= so a finding can open this view on its own pair and period. */
export function Correlations({ query }: { query: URLSearchParams }) {
  const x0 = conceptParam(query, "x", "sleepMinutes");
  const y0 = conceptParam(query, "y", "hrv");
  const lagParam = query.get("lag");
  const [picked, setPicked] = useState<ConceptId[]>(() => ORDER.filter((id) => DEFAULT.includes(id) || id === x0 || id === y0));
  const [preset, setPreset] = useState<Preset>("all");
  const [custom, setCustom] = useState(() => rangeFromQuery(query));
  const [lagKey, setLagKey] = useState(lagParam && LAG_KEYS.includes(lagParam) ? lagParam : "1");
  const [pair, setPair] = useState<[ConceptId, ConceptId]>([x0, y0]);
  const lag = Number(lagKey);

  const p = palette(useDark());
  const today = todayDay();
  const earliest = useEarliestDay();
  const held = useHeldConcepts();
  const choices = ORDER.filter((id) => held.includes(id) || picked.includes(id));
  const range = custom ?? { from: presetStart(preset, today, earliest), to: today };
  const { series, loading, error, retry } = useSeries(picked, range.from, range.to);

  const matrix = useMemo(
    () => correlationMatrix(Object.fromEntries(picked.map((id) => [id, series[id]])), lag),
    [picked, series, lag],
  );
  const rel = useMemo(() => relate(series[pair[0]], series[pair[1]], lag), [series, pair, lag]);

  const scatter = useMemo((): EChartsCoreOption | null => {
    if (!rel) return null;
    const xs = rel.pairs.map((x) => x.x);
    const lo = Math.min(...xs);
    const hi = Math.max(...xs);
    const fit = rel.fit;
    const axis = {
      axisLabel: { color: p.muted },
      axisLine: { lineStyle: { color: p.rule } },
      splitLine: { lineStyle: { color: p.grid } },
    };
    return {
      grid: { left: 60, right: 16, top: 16, bottom: 40 },
      tooltip: { trigger: "item" },
      xAxis: { type: "value", scale: true, name: conceptName(pair[0]), nameLocation: "middle", nameGap: 28, ...axis, splitLine: { show: false } },
      yAxis: { type: "value", scale: true, name: conceptName(pair[1]), nameGap: 44, ...axis },
      series: [
        {
          type: "scatter" as const,
          data: rel.pairs.map((x) => [x.x, x.y]),
          symbolSize: 5,
          itemStyle: { color: p.garmin, opacity: 0.45 },
        },
        ...(fit
          ? [
              {
                type: "line" as const,
                data: [
                  [lo, fit.intercept + fit.slope * lo],
                  [hi, fit.intercept + fit.slope * hi],
                ],
                showSymbol: false,
                lineStyle: { color: p.signal, width: 2 },
                itemStyle: { color: p.signal },
              },
            ]
          : []),
      ],
    };
  }, [rel, pair, p]);

  const toggle = (id: ConceptId) =>
    setPicked((cur) => {
      if (cur.includes(id)) return cur.length > 2 ? cur.filter((x) => x !== id) : cur;
      return ORDER.filter((x) => x === id || cur.includes(x));
    });

  if (error) return <Notice action={t("retry")} onAction={retry}>{t("loadFailed")}</Notice>;

  return (
    <Section title={t("coTitle")} lead={t("coLead")}>
      <div className="chips" role="group" aria-label={t("coSelect")}>
        {choices.map((id) => (
          <button key={id} type="button" aria-pressed={picked.includes(id)} onClick={() => toggle(id)}>
            {conceptName(id)}
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
        <Segmented label={t("coLag")} value={lagKey} options={LAGS} onChange={setLagKey} />
      </div>

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
      ) : (
        <>
          <div className="matrix-wrap">
            <table className="matrix">
              <thead>
                <tr>
                  <th />
                  {matrix.ids.map((id) => (
                    <th key={id} scope="col">
                      {conceptName(id as ConceptId)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {matrix.ids.map((row, i) => (
                  <tr key={row}>
                    <th scope="row">{conceptName(row as ConceptId)}</th>
                    {matrix.ids.map((col, j) => {
                      if (row === col) {
                        return (
                          <td key={col}>
                            <span className="diag">—</span>
                          </td>
                        );
                      }
                      const r = matrix.r[i]?.[j] ?? null;
                      const selected = pair[0] === row && pair[1] === col;
                      return (
                        <td key={col}>
                          <button
                            type="button"
                            aria-pressed={selected}
                            style={cellStyle(r)}
                            onClick={() => setPair([row as ConceptId, col as ConceptId])}
                            aria-label={`${conceptName(row as ConceptId)} – ${conceptName(col as ConceptId)}: ${r === null ? "–" : fmt(r, 2)}`}
                          >
                            {r === null ? "–" : fmt(r, 2)}
                          </button>
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h3 className="pair-title">
            {conceptName(pair[0])} <span className="muted">and</span> {conceptName(pair[1])}
          </h3>
          {rel && scatter ? (
            <>
              <p className="finding">
                {t("coSentence", {
                  x: conceptName(pair[0]),
                  y: conceptName(pair[1]),
                  lag: lagText(lag),
                  r: fmt(rel.r, 2),
                  n: rel.n,
                  strength: strengthText(rel.r),
                })}
              </p>
              <div className="stats">
                <Stat label="r" value={fmt(rel.r, 2)} />
                <Stat label="n" value={String(rel.n)} note={t("coNNote")} />
                <Stat label="p" value={rel.p < 0.001 ? "< 0.001" : fmt(rel.p, 3)} note={t("coPNote")} />
              </div>
              <Chart option={scatter} height={320} label={t("coTitle")} />
            </>
          ) : (
            <Notice>{t("coNoPairs")}</Notice>
          )}
        </>
      )}
    </Section>
  );
}
