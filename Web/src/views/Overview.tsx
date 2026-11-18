import { useMemo } from "react";
import { InsightCard } from "../components/Insight";
import { Notice, Section, Sparkline, Stat } from "../components/ui";
import { useEarliestDay, useInsights, useSeries } from "../data";
import { t } from "../i18n";
import { fmt, fmtDay, fmtSigned } from "../lib/format";
import { latest, recentVsBaseline, rolling, type Series } from "../lib/analytics";
import { CONCEPTS, type ConceptId } from "../lib/concepts";
import { addDays, daysBetween, daysInclusive, todayDay, weekdayIndex, yearOf, type Day } from "../lib/time";
import { conceptName } from "./shared";

const HERO_ORDER: ConceptId[] = ["restingHeartRate", "hrv", "sleepMinutes", "steps"];
const TILES: ConceptId[] = ["steps", "restingHeartRate", "hrv", "sleepMinutes", "stress", "bodyBattery", "activeEnergy", "spo2"];

export function Overview() {
  const today = todayDay();
  const { series, loading, error, retry } = useSeries(TILES, addDays(today, -4000), today);
  const earliest = useEarliestDay();
  const hasAny = TILES.some((id) => series[id].size > 0);

  const hero = useMemo(() => {
    for (const id of HERO_ORDER) {
      const s = series[id];
      const day = latest(s)?.day;
      const c = day ? recentVsBaseline(s, day) : null;
      if (c && c.usual !== 0) return { id, ...c, delta: c.recent - c.usual };
    }
    return null;
  }, [series]);

  if (loading) return <p className="muted">{t("loading")}…</p>;
  if (error) return <Notice action={t("retry")} onAction={retry}>{t("loadFailed")}</Notice>;
  if (!hasAny) return <Notice>{t("noData")}</Notice>;

  const headline = (() => {
    if (!hero) return t("ovHeadlineNone");
    const d = CONCEPTS[hero.id].decimals;
    const amount = `${fmt(Math.abs(hero.delta), d)}${CONCEPTS[hero.id].unit ? ` ${CONCEPTS[hero.id].unit}` : ""}`;
    if (Math.abs(hero.delta / hero.usual) < 0.03) return t("ovHeadlineFlat", { metric: conceptName(hero.id) });
    return t(hero.delta > 0 ? "ovHeadlineUp" : "ovHeadlineDown", { metric: conceptName(hero.id), delta: amount });
  })();

  return (
    <>
      <p className="headline">{headline}</p>

      <div className="stats">
        {TILES.map((id) => {
          const s = series[id];
          const last = latest(s);
          if (!last) return null;
          const c = recentVsBaseline(s, last.day);
          const d = CONCEPTS[id].decimals;
          const delta = c ? c.recent - c.usual : 0;
          const tone = !c || Math.abs(delta) < 1e-9 || CONCEPTS[id].higherIsBetter === null
            ? "flat"
            : (delta > 0) === (CONCEPTS[id].higherIsBetter ?? true) ? "up" : "down";
          return (
            <Stat
              key={id}
              label={`${conceptName(id)} · ${fmtDay(last.day, { day: "numeric", month: "short" })}`}
              value={fmt(last.value, d)}
              unit={CONCEPTS[id].unit || undefined}
              note={c ? `${fmtSigned(delta, d)} · ${fmt(c.usual, d)} ${t("ovUsualShort")}` : undefined}
              tone={tone}
            />
          );
        })}
      </div>

      <Findings from={earliest ?? today} to={today} />

      <Section title={t("ovSpark")}>
        <div className="sparks">
          {TILES.slice(0, 4).map((id) => (
            <div key={id} className="spark-row">
              <span className="spark-name">{conceptName(id)}</span>
              <Sparkline values={lastDays(rolling(series[id], 7), today, 120)} width={300} height={44} />
            </div>
          ))}
        </div>
      </Section>

      <YearStrip steps={series.steps} />
    </>
  );
}

function lastDays(s: Series, end: Day, n: number): (number | null)[] {
  return daysInclusive(addDays(end, -(n - 1)), end).map((d) => s.get(d) ?? null);
}

/** One row per year, one square per day, shaded by how that day's steps compare with the year's median. */
function YearStrip({ steps }: { steps: Series }) {
  const years = useMemo(() => {
    const byYear = new Map<number, number[]>();
    for (const [day, v] of steps) byYear.set(yearOf(day), [...(byYear.get(yearOf(day)) ?? []), v]);
    return [...byYear].sort(([a], [b]) => a - b).map(([year, values]) => {
      const sorted = [...values].sort((a, b) => a - b);
      return { year, median: sorted[Math.floor(sorted.length / 2)] ?? 1 };
    });
  }, [steps]);
  if (years.length === 0) return null;

  const cell = 9;
  const gap = 2;
  const labelWidth = 44;
  const rowHeight = 7 * (cell + gap) + 10;
  const width = labelWidth + 53 * (cell + gap);
  const height = years.length * rowHeight;

  return (
    <Section title={t("ovYears", { from: years[0]?.year ?? "" })} lead={t("ovYearsNote")}>
      <div className="year-strip">
        <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={t("ovYears", { from: years[0]?.year ?? "" })}>
          {years.map(({ year, median }, row) => {
            const top = row * rowHeight;
            const jan1 = `${year}-01-01`;
            const offset = weekdayIndex(jan1);
            return (
              <g key={year} transform={`translate(0 ${top})`}>
                <text x="0" y={cell} className="year-label">{year}</text>
                {daysInclusive(jan1, `${year}-12-31`).map((day) => {
                  const v = steps.get(day);
                  if (v === undefined) return null;
                  const col = Math.floor((daysBetween(jan1, day) + offset) / 7);
                  const row7 = weekdayIndex(day);
                  const ratio = v / median;
                  const q = ratio < 0.7 ? "q0" : ratio < 1 ? "q1" : ratio < 1.3 ? "q2" : "q3";
                  return (
                    <rect
                      key={day}
                      x={labelWidth + col * (cell + gap)}
                      y={row7 * (cell + gap)}
                      width={cell}
                      height={cell}
                      rx="1.5"
                      className={q}
                    >
                      <title>{`${fmtDay(day)}: ${fmt(v)}`}</title>
                    </rect>
                  );
                })}
              </g>
            );
          })}
        </svg>
      </div>
    </Section>
  );
}

/** The strongest server findings, three at a time, with the full list one click away. */
function Findings({ from, to }: { from: Day; to: Day }) {
  const found = useInsights(from, to);
  const top = (found.data ?? []).slice(0, 3);
  if (top.length === 0) return null;
  return (
    <Section title={t("insFeed")} lead={t("insFeedLead")} aside={<a href="#/insights">{t("insAllLink")}</a>}>
      <div className="feed feed-top">
        {top.map((insight) => (
          <InsightCard key={insight.id} insight={insight} compact />
        ))}
      </div>
    </Section>
  );
}
