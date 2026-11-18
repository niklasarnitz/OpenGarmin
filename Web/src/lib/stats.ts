// Plain statistics. No dependencies; every function documents what it returns for too little data.

export function mean(xs: readonly number[]): number | null {
  if (xs.length === 0) return null;
  let sum = 0;
  for (const x of xs) sum += x;
  return sum / xs.length;
}

/** Sample standard deviation (n - 1). */
export function stdev(xs: readonly number[]): number | null {
  if (xs.length < 2) return null;
  const m = mean(xs) ?? 0;
  let ss = 0;
  for (const x of xs) ss += (x - m) ** 2;
  return Math.sqrt(ss / (xs.length - 1));
}

export function median(xs: readonly number[]): number | null {
  if (xs.length === 0) return null;
  const sorted = [...xs].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? (sorted[mid] ?? null) : ((sorted[mid - 1] ?? 0) + (sorted[mid] ?? 0)) / 2;
}

export interface LinearFit {
  slope: number;
  intercept: number;
  r: number;
  n: number;
}

/** Ordinary least squares. Null when x has no spread. */
export function linearFit(xs: readonly number[], ys: readonly number[]): LinearFit | null {
  const n = Math.min(xs.length, ys.length);
  if (n < 2) return null;
  const mx = mean(xs.slice(0, n)) ?? 0;
  const my = mean(ys.slice(0, n)) ?? 0;
  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (let i = 0; i < n; i++) {
    const dx = (xs[i] ?? 0) - mx;
    const dy = (ys[i] ?? 0) - my;
    sxy += dx * dy;
    sxx += dx * dx;
    syy += dy * dy;
  }
  if (sxx === 0) return null;
  const r = syy === 0 ? 0 : sxy / Math.sqrt(sxx * syy);
  const slope = sxy / sxx;
  return { slope, intercept: my - slope * mx, r, n };
}

/** Theil–Sen estimator: median of all pairwise slopes. Robust against outliers. */
export function theilSen(xs: readonly number[], ys: readonly number[]): number | null {
  const slopes: number[] = [];
  const n = Math.min(xs.length, ys.length);
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      const dx = (xs[j] ?? 0) - (xs[i] ?? 0);
      if (dx !== 0) slopes.push(((ys[j] ?? 0) - (ys[i] ?? 0)) / dx);
    }
  }
  return median(slopes);
}

/** Standard normal cumulative distribution (Abramowitz & Stegun 7.1.26, error below 1.5e-7). */
export function normalCdf(z: number): number {
  const x = Math.abs(z) / Math.SQRT2;
  const t = 1 / (1 + 0.3275911 * x);
  const poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
  const erf = 1 - poly * Math.exp(-x * x);
  return z >= 0 ? (1 + erf) / 2 : (1 - erf) / 2;
}

/** Two-sided p-value of a standard normal statistic. */
export function twoSidedP(z: number): number {
  return 2 * (1 - normalCdf(Math.abs(z)));
}

export interface Correlation {
  r: number;
  n: number;
  /** Two-sided p-value, normal approximation of the t statistic. Reliable from about n = 30. */
  p: number;
}

/** Pearson correlation of paired values. Null for fewer than 3 pairs or no variance. */
export function pearson(xs: readonly number[], ys: readonly number[]): Correlation | null {
  const fit = linearFit(xs, ys);
  if (!fit || fit.n < 3) return null;
  const r = Math.max(-1, Math.min(1, fit.r));
  const n = fit.n;
  if (Math.abs(r) === 1) return { r, n, p: 0 };
  const t = r * Math.sqrt((n - 2) / (1 - r * r));
  return { r, n, p: twoSidedP(t) };
}

export interface KendallResult {
  tau: number;
  z: number;
  p: number;
}

/** Mann–Kendall trend test on a sequence (ties ignored). Tau is in -1..1; p uses the normal approximation. */
export function kendall(ys: readonly number[]): KendallResult | null {
  const n = ys.length;
  if (n < 4) return null;
  let s = 0;
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      s += Math.sign((ys[j] ?? 0) - (ys[i] ?? 0));
    }
  }
  const varS = (n * (n - 1) * (2 * n + 5)) / 18;
  const z = s === 0 ? 0 : (s - Math.sign(s)) / Math.sqrt(varS);
  return { tau: s / ((n * (n - 1)) / 2), z, p: twoSidedP(z) };
}
