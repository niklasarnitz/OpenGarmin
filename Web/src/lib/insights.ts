import type { Insight } from "../api/types";
import { conceptOf, type ConceptId } from "./concepts";

/**
 * Where a finding links: a correlation opens the correlation view for its two metrics, and every finding opens
 * the explorer for each metric it names. Metrics the dashboard does not chart are skipped. Both links keep the
 * finding's period. A correlation opens at its `lagDays`, or at lag 0 when the server sends none.
 */
export function insightHrefs(insight: Insight): { correlation?: string; metrics: { id: ConceptId; href: string }[] } {
  const period = `from=${encodeURIComponent(insight.period.from)}&to=${encodeURIComponent(insight.period.to)}`;
  const concepts = insight.metrics.flatMap((m) => {
    const id = conceptOf(m);
    return id ? [id] : [];
  });
  const unique = [...new Set(concepts)];
  const metrics = unique.map((id) => ({ id, href: `#/metrics?m=${id}&${period}` }));
  const [x, y] = unique;
  const correlation =
    insight.kind === "correlation" && x && y ? `#/correlations?x=${x}&y=${y}&lag=${insight.lagDays ?? 0}&${period}` : undefined;
  return { correlation, metrics };
}
