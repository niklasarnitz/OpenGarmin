import { t, type Key } from "../i18n";
import { CONCEPTS, type ConceptId } from "../lib/concepts";
import { fmt } from "../lib/format";
import { parseDay, type Day, type Preset } from "../lib/time";
import { APPLE_SOURCE, GOOGLE_FIT_SOURCE, MIRROR_SOURCE, sourceGroup } from "../lib/sources";

/** A custom period from the URL (?from=&to=), as the findings link to. Null when absent or malformed. */
export function rangeFromQuery(query: URLSearchParams): { from: Day; to: Day } | null {
  const from = parseDay(query.get("from"));
  const to = parseDay(query.get("to"));
  return from && to && from <= to ? { from, to } : null;
}

export const PRESETS: { value: Preset; label: string }[] = [
  { value: "week", label: t("rangeWeek") },
  { value: "month", label: t("rangeMonth") },
  { value: "year", label: t("rangeYear") },
  { value: "five", label: t("rangeFive") },
  { value: "ten", label: t("rangeTen") },
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
  if (source === MIRROR_SOURCE) return t("src_mirror");
  if (sourceGroup(source) === APPLE_SOURCE) return t("src_apple");
  if (source === GOOGLE_FIT_SOURCE) return "Google Fit";
  // Another app that writes into Apple Health: its bundle ID.
  return source.replace(/^healthkit:/, "");
}
