// Calendar days are "YYYY-MM-DD" strings in the user's local calendar, as the server returns them.
// Arithmetic goes through UTC so DST changes never shift a day.

export type Day = string;

const pad = (n: number) => String(n).padStart(2, "0");

export function dayOf(date: Date): Day {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function todayDay(): Day {
  return dayOf(new Date());
}

function parts(day: Day): [number, number, number] {
  const [y = 0, m = 1, d = 1] = day.split("-").map(Number);
  return [y, m, d];
}

/** Local midnight of a day, for chart time axes. */
export function dayMs(day: Day): number {
  const [y, m, d] = parts(day);
  return new Date(y, m - 1, d).getTime();
}

export function addDays(day: Day, n: number): Day {
  const [y, m, d] = parts(day);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

/** Whole days from `a` to `b` (negative when b is earlier). */
export function daysBetween(a: Day, b: Day): number {
  const [ay, am, ad] = parts(a);
  const [by, bm, bd] = parts(b);
  return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / 86_400_000);
}

/** Every day from `from` to `to`, both inclusive. */
export function daysInclusive(from: Day, to: Day): Day[] {
  const out: Day[] = [];
  for (let day = from; day <= to; day = addDays(day, 1)) out.push(day);
  return out;
}

/** Monday = 0 … Sunday = 6. */
export function weekdayIndex(day: Day): number {
  const [y, m, d] = parts(day);
  return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
}

export function weekStart(day: Day): Day {
  return addDays(day, -weekdayIndex(day));
}

export function yearOf(day: Day): number {
  return Number(day.slice(0, 4));
}

export function dayOfYear(day: Day): number {
  return daysBetween(`${yearOf(day)}-01-01`, day);
}

export type Preset = "week" | "month" | "year" | "five" | "all";

/** First day of a range that ends today. "All" starts at the earliest day the server holds. */
export function presetStart(preset: Preset, today: Day, earliest?: Day): Day {
  switch (preset) {
    case "week":
      return addDays(today, -6);
    case "month":
      return addDays(today, -29);
    case "year":
      return addDays(today, -364);
    case "five":
      return addDays(today, -1826);
    case "all":
      return earliest ?? addDays(today, -364);
  }
}
