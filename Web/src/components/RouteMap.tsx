import { useEffect, useRef } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { t } from "../i18n";

export function RouteMap({ track, signal }: { track: [number, number][]; signal: string }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || track.length === 0) return;
    const map = L.map(el, { scrollWheelZoom: false, attributionControl: true });
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 18,
      attribution: t("acMapAttribution"),
    }).addTo(map);
    const line = L.polyline(track, { color: signal, weight: 4, opacity: 0.9 }).addTo(map);
    L.circleMarker(track[0] ?? [0, 0], { radius: 5, color: signal, fillColor: signal, fillOpacity: 1 }).addTo(map);
    map.fitBounds(line.getBounds(), { padding: [24, 24] });
    return () => {
      map.remove();
    };
  }, [track, signal]);

  return <div ref={ref} className="route-map" role="img" aria-label={t("acRoute")} />;
}
