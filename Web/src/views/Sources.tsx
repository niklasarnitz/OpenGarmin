import { useMemo } from "react";
import { Notice, Section, Select } from "../components/ui";
import { updatePrefs, useCatalog, usePrefs } from "../data";
import { t } from "../i18n";
import { fmtDay } from "../lib/format";
import { CONCEPT_IDS, conceptOf, type ConceptId } from "../lib/concepts";
import { conceptName, sourceLabel } from "./shared";

export function Sources() {
  const catalog = useCatalog();
  const prefs = usePrefs();

  const rows = useMemo(
    () =>
      CONCEPT_IDS.flatMap((id) => {
        const metrics = (catalog.data ?? []).filter((m) => conceptOf(m.metric) === id);
        return metrics.length > 0 ? [{ id, metrics }] : [];
      }),
    [catalog.data],
  );

  if (catalog.error) {
    return (
      <Notice action={t("retry")} onAction={catalog.retry}>
        {t("loadFailed")}
      </Notice>
    );
  }
  if (catalog.loading) return <p className="muted">{t("loading")}…</p>;

  function setPreferred(id: ConceptId, source: string) {
    const preferred = { ...prefs.preferred };
    if (source) preferred[id] = source;
    else delete preferred[id];
    updatePrefs({ preferred });
  }

  return (
    <Section title={t("srTitle")} lead={t("srLead")}>
      <label className="check">
        <input
          type="checkbox"
          checked={prefs.includeMirror}
          onChange={(e) => updatePrefs({ includeMirror: e.target.checked })}
        />
        {t("srMirrorOn")}
      </label>
      <p className="lead">{t("srMirrorNote")}</p>

      <table className="sources">
        <thead>
          <tr>
            <th>{t("srTitle")}</th>
            <th>{t("xpSource")}</th>
            <th>{t("srPreferred")}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(({ id, metrics }) => {
            const sources = [...new Set(metrics.map((m) => m.source))].sort();
            return (
              <tr key={id}>
                <th scope="row">{conceptName(id)}</th>
                <td>
                  {metrics.map((m) => (
                    <div key={m.source}>
                      {sourceLabel(m.source)}{" "}
                      <span className="muted">
                        {fmtDay(m.first)} – {fmtDay(m.last)}
                      </span>
                    </div>
                  ))}
                </td>
                <td>
                  {sources.length > 1 ? (
                    <Select
                      label={t("srPreferred")}
                      value={prefs.preferred[id] ?? ""}
                      options={[
                        { value: "", label: t("srAuto") },
                        ...sources.map((s) => ({ value: s, label: sourceLabel(s) })),
                      ]}
                      onChange={(source) => setPreferred(id, source)}
                    />
                  ) : (
                    <span className="muted">{t("srAuto")}</span>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <p className="stat-note">{t("srSaved")}</p>
    </Section>
  );
}
