import { useMemo, useState } from "react";
import type { InsightKind } from "../api/types";
import { InsightCard, metricLabel } from "../components/Insight";
import { Notice, Section, Select } from "../components/ui";
import { useEarliestDay, useInsights } from "../data";
import { t, type Key } from "../i18n";
import { todayDay } from "../lib/time";

const KINDS: InsightKind[] = ["trend", "correlation", "changepoint", "anomaly", "pattern", "record"];

export function Insights() {
  const today = todayDay();
  const earliest = useEarliestDay();
  const found = useInsights(earliest ?? today, today);
  const [kind, setKind] = useState<InsightKind | "all">("all");
  const [metric, setMetric] = useState("all");

  const all = useMemo(() => found.data ?? [], [found.data]);
  const metrics = useMemo(() => [...new Set(all.flatMap((i) => i.metrics))].sort(), [all]);
  const shown = useMemo(
    () =>
      all.filter((i) => (kind === "all" || i.kind === kind) && (metric === "all" || i.metrics.includes(metric))),
    [all, kind, metric],
  );

  if (found.error) {
    return (
      <Notice action={t("retry")} onAction={found.retry}>
        {t("loadFailed")}
      </Notice>
    );
  }

  return (
    <Section title={t("insTitle")} lead={t("insLead")}>
      <div className="chips" role="group" aria-label={t("insKind")}>
        <button type="button" aria-pressed={kind === "all"} onClick={() => setKind("all")}>
          {t("insAllKinds")}
        </button>
        {KINDS.map((k) => (
          <button key={k} type="button" aria-pressed={kind === k} onClick={() => setKind(k)}>
            {t(`kind_${k}` as Key)}
          </button>
        ))}
      </div>
      <div className="controls">
        <Select
          label={t("insMetric")}
          value={metric}
          options={[
            { value: "all", label: t("insNoMetric") },
            ...metrics.map((m) => ({ value: m, label: metricLabel(m) })),
          ]}
          onChange={setMetric}
        />
      </div>

      {found.loading ? (
        <p className="muted">{t("loading")}…</p>
      ) : shown.length === 0 ? (
        <Notice>{t("insEmpty")}</Notice>
      ) : (
        <div className="feed">
          {shown.map((insight) => (
            <InsightCard key={insight.id} insight={insight} />
          ))}
        </div>
      )}
    </Section>
  );
}
