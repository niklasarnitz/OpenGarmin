import { useSyncExternalStore } from "react";

const query = "(prefers-color-scheme: dark)";

/** Follows the system colour scheme. Canvas charts cannot read CSS variables, so they take colours from here. */
export function useDark(): boolean {
  return useSyncExternalStore(
    (notify) => {
      const media = matchMedia(query);
      media.addEventListener("change", notify);
      return () => media.removeEventListener("change", notify);
    },
    () => matchMedia(query).matches,
  );
}

export interface Palette {
  paper: string;
  ink: string;
  muted: string;
  rule: string;
  grid: string;
  garmin: string;
  apple: string;
  signal: string;
  tooltip: string;
}

// Mirrors the CSS variables in styles/app.css.
const light: Palette = {
  paper: "#eef0ea",
  ink: "#16201c",
  muted: "#5f6b64",
  rule: "#cdd5cc",
  grid: "#dde3da",
  garmin: "#0b6b5c",
  apple: "#4150a8",
  signal: "#c8452a",
  tooltip: "#f8faf6",
};

const dark: Palette = {
  paper: "#0d1411",
  ink: "#e7ebe4",
  muted: "#8a968e",
  rule: "#26322c",
  grid: "#1c2620",
  garmin: "#43b9a3",
  apple: "#8f9be3",
  signal: "#ff7150",
  tooltip: "#131c18",
};

export const palette = (isDark: boolean): Palette => (isDark ? dark : light);

/** Colour of a source in charts and badges. */
export function sourceColor(source: string, p: Palette): string {
  if (source === "garmin") return p.garmin;
  if (source === "healthkit:garmin-mirror") return p.muted;
  return p.apple;
}
