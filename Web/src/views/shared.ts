import { t, type Key } from "../i18n";
import { CONCEPTS, type ConceptId } from "../lib/concepts";
import { fmt } from "../lib/format";
import type { Day, Preset } from "../lib/time";

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** A custom period from the URL (?from=&to=), as the findings link to. Null when absent or malformed. */
export function rangeFromQuery(query: URLSearchParams): { from: Day; to: Day } | null {
  const from = query.get("from");
  const to = query.get("to");
  return from && to && DAY.test(from) && DAY.test(to) && from <= to ? { from, to } : null;
}

export const PRESETS: { value: Preset; label: string }[] = [
  { value: "week", label: t("rangeWeek") },
  { value: "month", label: t("rangeMonth") },
  { value: "year", label: t("rangeYear") },
  { value: "five", label: t("rangeFive") },
  { value: "all", label: t("rangeAll") },
];

export const conceptName = (id: ConceptId) => t(`c_${id}` as Key);

/** A value with its unit and the concept's precision: "7,412", "58.2 bpm". */
export function valueText(id: ConceptId, value: number): string {
  const { unit, decimals } = CONCEPTS[id];
  return unit ? `${fmt(value, decimals)} ${unit}` : fmt(value, decimals);
}

export function sourceLabel(source: string): string {
  if (source === "garmin") return t("src_garmin");
  if (source === "healthkit:garmin-mirror") return t("src_mirror");
  if (source.startsWith("healthkit:")) return t("src_apple");
  return source;
}
