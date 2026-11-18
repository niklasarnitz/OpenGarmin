import type { ReactNode } from "react";

export function Section({ title, lead, children, aside }: { title: string; lead?: string; children: ReactNode; aside?: ReactNode }) {
  return (
    <section className="section">
      <header className="section-head">
        <div>
          <h2>{title}</h2>
          {lead && <p className="lead">{lead}</p>}
        </div>
        {aside && <div className="section-aside">{aside}</div>}
      </header>
      {children}
    </section>
  );
}

export function Stat({ label, value, unit, note, tone }: { label: string; value: string; unit?: string; note?: string; tone?: "up" | "down" | "flat" }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value">
        {value}
        {unit && <span className="stat-unit">{unit}</span>}
      </div>
      {note && <div className={`stat-note ${tone ?? ""}`}>{note}</div>}
    </div>
  );
}

/** A small line of recent values. Missing values break the line instead of dropping to zero. */
export function Sparkline({ values, width = 220, height = 48 }: { values: (number | null)[]; width?: number; height?: number }) {
  const present = values.flatMap((v, i) => (v === null ? [] : [{ i, v }]));
  if (present.length < 2) return <svg className="spark" width={width} height={height} aria-hidden="true" />;
  const lo = Math.min(...present.map((p) => p.v));
  const hi = Math.max(...present.map((p) => p.v));
  const span = hi - lo || 1;
  const x = (i: number) => (i / Math.max(values.length - 1, 1)) * width;
  const y = (v: number) => height - 4 - ((v - lo) / span) * (height - 8);
  let d = "";
  let pen = false;
  values.forEach((v, i) => {
    if (v === null) {
      pen = false;
      return;
    }
    d += `${pen ? "L" : "M"}${x(i).toFixed(1)} ${y(v).toFixed(1)} `;
    pen = true;
  });
  const last = present[present.length - 1];
  return (
    <svg className="spark" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
      {last && <circle cx={x(last.i)} cy={y(last.v)} r="2.6" fill="var(--signal)" />}
    </svg>
  );
}

export function Segmented<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
}) {
  return (
    <div className="segmented" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={o.value === value}
          className={o.value === value ? "on" : ""}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Select<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
}) {
  return (
    <label className="select">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value as T)}>
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

export function Notice({ children, action, onAction }: { children: ReactNode; action?: string; onAction?: () => void }) {
  return (
    <div className="notice" role="status">
      <p>{children}</p>
      {action && onAction && (
        <button type="button" className="ghost" onClick={onAction}>
          {action}
        </button>
      )}
    </div>
  );
}
