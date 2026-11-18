import { locale, t } from "../i18n";
import type { Day } from "./time";

export function fmt(value: number, decimals = 0): string {
  return new Intl.NumberFormat(locale, { minimumFractionDigits: decimals, maximumFractionDigits: decimals }).format(value);
}

/** Signed, for changes: "+3" or "−2.5". */
export function fmtSigned(value: number, decimals = 0): string {
  const s = fmt(Math.abs(value), decimals);
  return value < 0 ? `−${s}` : `+${s}`;
}

export function fmtDay(day: Day, options: Intl.DateTimeFormatOptions = { day: "numeric", month: "short", year: "numeric" }): string {
  const [y = 2000, m = 1, d = 1] = day.split("-").map(Number);
  return new Intl.DateTimeFormat(locale, options).format(new Date(y, m - 1, d));
}

export function fmtMonth(day: Day): string {
  return fmtDay(day, { month: "short", year: "numeric" });
}

/** Hours and minutes from a count of minutes: "7 h 12 min". */
export function fmtHM(minutes: number): string {
  const total = Math.round(minutes);
  const h = Math.floor(total / 60);
  const m = total % 60;
  return h > 0 ? `${h}${t("unitH")} ${m}${t("unitMin")}` : `${m}${t("unitMin")}`;
}

export function fmtKm(meters: number): string {
  return `${fmt(meters / 1000, 2)} km`;
}

export function fmtClock(iso: string): string {
  return new Date(iso).toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

/** Minutes after midnight, with times before 6 a.m. counted as late evening, so bedtimes sort correctly. */
export function bedtimeMinutes(iso: string): number {
  const d = new Date(iso);
  const m = d.getHours() * 60 + d.getMinutes();
  return m < 360 ? m + 1440 : m;
}

export function fmtMinuteOfDay(minutes: number): string {
  const m = ((Math.round(minutes) % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
}
