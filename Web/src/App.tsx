import { useEffect, useState, useSyncExternalStore } from "react";
import { isMock, logout, me } from "./api/client";
import type { MeResponse } from "./api/types";
import { t, type Key } from "./i18n";
import { Login } from "./views/Login";
import { Overview } from "./views/Overview";
import { Metrics } from "./views/Metrics";
import { Trends } from "./views/Trends";
import { Correlations } from "./views/Correlations";
import { Sleep } from "./views/Sleep";
import { ActivityDetail, Activities } from "./views/Activities";
import { Sources } from "./views/Sources";
import { Insights } from "./views/Insights";

const SECTIONS = [
  { id: "overview", label: "navOverview" },
  { id: "insights", label: "navInsights" },
  { id: "metrics", label: "navExplore" },
  { id: "trends", label: "navTrends" },
  { id: "correlations", label: "navCorrelations" },
  { id: "sleep", label: "navSleep" },
  { id: "activities", label: "navActivities" },
  { id: "sources", label: "navSources" },
] as const satisfies readonly { id: string; label: Key }[];

type SectionId = (typeof SECTIONS)[number]["id"];

interface Route {
  section: SectionId;
  id: string | undefined;
  query: URLSearchParams;
  /** Changes with each link, so a view opened from a finding starts fresh. */
  search: string;
}

/** Routes live in the hash: #/metrics?m=steps, #/activities/<id>. */
function parseRoute(hash: string): Route {
  const [path = "", search = ""] = hash.replace(/^#\/?/, "").split("?", 2);
  const parts = path.split("/").filter(Boolean);
  const section = SECTIONS.find((s) => s.id === parts[0]);
  return {
    section: section?.id ?? "overview",
    id: parts[1] ? decodeURIComponent(parts[1]) : undefined,
    query: new URLSearchParams(search),
    search,
  };
}

function useRoute(): Route {
  const hash = useSyncExternalStore(
    (notify) => {
      addEventListener("hashchange", notify);
      return () => removeEventListener("hashchange", notify);
    },
    () => location.hash,
  );
  return parseRoute(hash);
}

export function App() {
  const [user, setUser] = useState<MeResponse | null | undefined>(undefined);

  useEffect(() => {
    me().then(setUser, () => setUser(null));
  }, []);

  if (user === undefined) return <div className="boot">{t("loading")}…</div>;
  if (user === null) return <Login onSignedIn={setUser} />;
  return <Shell onSignOut={() => void logout().then(() => setUser(null))} />;
}

function Shell({ onSignOut }: { onSignOut: () => void }) {
  const route = useRoute();
  return (
    <div className="shell">
      <header className="masthead">
        <a className="brand" href="#/overview">
          {t("appName")}
          <i>.</i>
        </a>
        <nav className="main" aria-label="Main">
          {SECTIONS.map((s) => (
            <a key={s.id} href={`#/${s.id}`} aria-current={route.section === s.id ? "page" : undefined}>
              {t(s.label)}
            </a>
          ))}
        </nav>
        <div className="masthead-end">
          {isMock && <span className="badge">{t("demoBadge")}</span>}
          <button type="button" className="ghost" onClick={onSignOut}>
            {t("signOut")}
          </button>
        </div>
      </header>
      <main>{renderRoute(route)}</main>
    </div>
  );
}

function renderRoute(route: Route) {
  switch (route.section) {
    case "overview":
      return <Overview />;
    case "insights":
      return <Insights />;
    case "metrics":
      return <Metrics key={route.search} query={route.query} />;
    case "trends":
      return <Trends />;
    case "correlations":
      return <Correlations key={route.search} query={route.query} />;
    case "sleep":
      return <Sleep />;
    case "activities":
      return route.id ? <ActivityDetail id={route.id} /> : <Activities />;
    case "sources":
      return <Sources />;
  }
}
