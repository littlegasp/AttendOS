"use client";

import { useEffect, useRef, useState } from "react";
import type * as Leaflet from "leaflet";
import "leaflet/dist/leaflet.css";

export interface MapOffice {
  id: string;
  name: string;
  lat: number;
  lng: number;
  radius_m: number;
  active: boolean;
}

/**
 * Interactive office map (OpenStreetMap tiles via Leaflet, loaded only in the browser).
 * Editable mode: click the map or drag the pin to move the office point; the circle is the
 * check-in area. Overview mode: every office with its area.
 * The map is a helper: the typed coordinates stay the source of truth, so the form still
 * works if the map tiles can't load.
 */
export function LocationMap({
  offices = [],
  point,
  radius,
  onPick,
  height = 320,
  label,
}: {
  offices?: MapOffice[];
  point?: { lat: number; lng: number } | null;
  radius?: number;
  onPick?: (lat: number, lng: number) => void;
  height?: number;
  label: string;
}) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<Leaflet.Map | null>(null);
  const L = useRef<typeof Leaflet | null>(null);
  const layer = useRef<Leaflet.LayerGroup | null>(null);
  const pick = useRef(onPick);
  pick.current = onPick;
  const [ready, setReady] = useState(false);
  const [tilesFailed, setTilesFailed] = useState(false);

  // Create the map once.
  useEffect(() => {
    let live = true;
    import("leaflet").then((mod) => {
      if (!live || !el.current || map.current) return;
      const lf = (mod.default ?? mod) as typeof Leaflet;
      L.current = lf;
      const m = lf.map(el.current, { zoomControl: true, attributionControl: true, scrollWheelZoom: false }).setView([20.59, 78.96], 4);
      const tiles = lf.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      });
      let errors = 0;
      tiles.on("tileerror", () => {
        errors += 1;
        if (errors > 3) setTilesFailed(true);
      });
      tiles.on("tileload", () => setTilesFailed(false));
      tiles.addTo(m);
      layer.current = lf.layerGroup().addTo(m);
      m.on("click", (e: Leaflet.LeafletMouseEvent) => pick.current?.(+e.latlng.lat.toFixed(6), +e.latlng.lng.toFixed(6)));
      map.current = m;
      setReady(true);
    });
    return () => {
      live = false;
      map.current?.remove();
      map.current = null;
    };
  }, []);

  // Draw offices / the point being edited.
  useEffect(() => {
    const lf = L.current;
    const m = map.current;
    const g = layer.current;
    if (!ready || !lf || !m || !g) return;
    g.clearLayers();
    const css = getComputedStyle(document.documentElement);
    const primary = css.getPropertyValue("--color-primary").trim() || "orange";
    const muted = css.getPropertyValue("--color-text-muted").trim() || "grey";
    const pin = (cls: string) => lf.divIcon({ className: "", html: `<span class="map-pin ${cls}"></span>`, iconSize: [22, 22], iconAnchor: [11, 11] });
    const bounds: Leaflet.LatLngExpression[] = [];

    for (const o of offices) {
      const color = o.active ? primary : muted;
      lf.circle([o.lat, o.lng], { radius: o.radius_m, color, weight: 2, fillColor: color, fillOpacity: 0.12 }).addTo(g);
      lf.marker([o.lat, o.lng], { icon: pin(o.active ? "" : "off"), keyboard: false, title: o.name }).bindTooltip(`${o.name} · ${o.radius_m} m${o.active ? "" : " (not in use)"}`).addTo(g);
      bounds.push([o.lat, o.lng]);
    }
    if (point && Number.isFinite(point.lat) && Number.isFinite(point.lng)) {
      lf.circle([point.lat, point.lng], { radius: radius ?? 150, color: primary, weight: 2, fillColor: primary, fillOpacity: 0.15 }).addTo(g);
      const mk = lf.marker([point.lat, point.lng], { icon: pin("edit"), draggable: Boolean(pick.current), title: "Office point (drag to move)" }).addTo(g);
      mk.on("dragend", () => {
        const p = mk.getLatLng();
        pick.current?.(+p.lat.toFixed(6), +p.lng.toFixed(6));
      });
      bounds.push([point.lat, point.lng]);
    }
    // Editing: centre on the point being edited. Overview: show every office.
    if (point && Number.isFinite(point.lat) && Number.isFinite(point.lng)) m.setView([point.lat, point.lng], Math.max(m.getZoom(), 16));
    else if (bounds.length === 1) m.setView(bounds[0]!, 15);
    else if (bounds.length > 1) m.fitBounds(lf.latLngBounds(bounds as Leaflet.LatLngTuple[]).pad(0.3));
  }, [ready, offices, point, radius]);

  return (
    <div className="map-wrap">
      <div ref={el} className="map" style={{ height }} role="application" aria-label={label} />
      {tilesFailed ? <p className="map-note meta">Map pictures couldn&apos;t load on this connection. The office point and area are still shown and saved from the numbers.</p> : null}
    </div>
  );
}

export interface Place {
  label: string;
  lat: number;
  lng: number;
}

/**
 * Address search using OpenStreetMap's Nominatim service. Only the typed address is sent;
 * no personal data. One search per button press (their usage policy allows 1 per second).
 */
export function AddressSearch({ onPick }: { onPick: (p: Place) => void }) {
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<Place[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function search() {
    if (q.trim().length < 3) return setErr("Type at least 3 characters.");
    setBusy(true);
    setErr(null);
    try {
      const r = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&accept-language=en&q=${encodeURIComponent(q.trim())}`, { headers: { Accept: "application/json" } });
      if (!r.ok) throw new Error(String(r.status));
      const rows = (await r.json()) as { display_name: string; lat: string; lon: string }[];
      setResults(rows.map((x) => ({ label: x.display_name, lat: +(+x.lat).toFixed(6), lng: +(+x.lon).toFixed(6) })));
    } catch {
      setErr("Address search isn't reachable right now. Click the map or type the coordinates instead.");
      setResults(null);
    }
    setBusy(false);
  }

  return (
    <div className="addr-search">
      <div className="addr-row">
        <label className="sr-only" htmlFor="addr-q">Search an address</label>
        <input
          id="addr-q"
          className="input"
          type="search"
          placeholder="Search an address or place…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              search();
            }
          }}
        />
        <button type="button" className="btn secondary md" onClick={search} disabled={busy} aria-busy={busy || undefined}>
          {busy ? <span className="spinner" aria-hidden="true" /> : null}
          <span>Search</span>
        </button>
      </div>
      {err ? <p className="field-msg error" role="alert">{err}</p> : null}
      {results ? (
        results.length === 0 ? (
          <p className="meta">No matches. Try a shorter address or a landmark.</p>
        ) : (
          <ul className="addr-results" aria-label="Search results">
            {results.map((r) => (
              <li key={`${r.lat},${r.lng}`}>
                <button
                  type="button"
                  onClick={() => {
                    onPick(r);
                    setResults(null);
                  }}
                >
                  {r.label}
                </button>
              </li>
            ))}
          </ul>
        )
      ) : null}
      <p className="meta">Search by OpenStreetMap — only the address you type is sent.</p>
    </div>
  );
}
