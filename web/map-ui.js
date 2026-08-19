/**
 * Map View — offline Leaflet + map/tiles/{z}/{x}/{y}.jpg
 * Coordinates: hand-edit map/sites.json
 * Live data: hostname prefix → site, alarms from Gateway cache (no extra OSSI).
 * Light: any MAJOR or DOWN → red; else any MINOR → yellow; WARNING counts as green.
 */

import { openGatewayDetail } from "./gateway-ui.js";

function apiUrlMap(path) {
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + "api/" + String(path).replace(/^\//, "");
}

function siteUrlMap(path) {
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + String(path).replace(/^\//, "");
}

async function fetchJsonMap(url, opts = {}) {
  const res = await fetch(url, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }
  if (!res.ok) throw new Error((body && (body.error || body.Error)) || res.statusText);
  return body && typeof body === "object" ? body : {};
}

const MAP = {
  connected: false,
  tabActive: false,
  cfg: { center: [22.35, 114.15], zoom: 11, minZoom: 10, maxZoom: 14, sites: [] },
  gateways: [],
  gwUpdated: null,
  selected: null,
  query: "",
  map: null,
  layer: null,
  markers: {},
  resetAdded: false,
};

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function siteCodeFromHostname(hostname) {
  const h = String(hostname || "").trim();
  const i = h.indexOf("-");
  return (i > 0 ? h.slice(0, i) : h).toUpperCase();
}

function siteLight(site) {
  const down = Number(site.down || 0);
  const mj = Number(site.mj || 0);
  const mn = Number(site.mn || 0);
  if (mj > 0 || down > 0) return "red";
  if (mn > 0) return "yellow";
  return "green";
}

function lightLabel(light) {
  if (light === "red") return "Critical";
  if (light === "yellow") return "Minor";
  return "Healthy";
}

function fmtGwTs(s) {
  if (!s) return "—";
  return String(s).replace("T", " ").replace("Z", "").slice(0, 19);
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function buildSiteRows() {
  const byCode = new Map();
  for (const s of MAP.cfg.sites || []) {
    const code = String(s.code || "").trim().toUpperCase();
    if (!code) continue;
    const lat = Number(s.lat);
    const lng = Number(s.lng);
    byCode.set(code, {
      code,
      name: String(s.name || "").trim(),
      lat: Number.isFinite(lat) ? lat : null,
      lng: Number.isFinite(lng) ? lng : null,
      dummy: !!s.dummy,
      dummyMj: Number(s.dummyMj || 0),
      dummyMn: Number(s.dummyMn || 0),
      gws: [],
      mj: 0,
      mn: 0,
      wn: 0,
      down: 0,
      live: false,
    });
  }

  for (const g of MAP.gateways || []) {
    const code = siteCodeFromHostname(g.hostname);
    if (!code) continue;
    if (!byCode.has(code)) {
      byCode.set(code, {
        code,
        name: "",
        lat: null,
        lng: null,
        dummy: false,
        dummyMj: 0,
        dummyMn: 0,
        gws: [],
        mj: 0,
        mn: 0,
        wn: 0,
        down: 0,
        live: false,
      });
    }
    const row = byCode.get(code);
    row.live = true;
    row.gws.push(g);
    row.mj += Number(g.mj || 0);
    row.mn += Number(g.mn || 0);
    row.wn += Number(g.wn || 0);
    if (String(g.node || "").toUpperCase() !== "UP") row.down += 1;
  }

  const out = [...byCode.values()].map((row) => {
    if (!row.live) {
      row.mj = row.dummyMj;
      row.mn = row.dummyMn;
    }
    row.light = siteLight(row);
    row.gwCount = row.gws.length;
    return row;
  });
  out.sort((a, b) => a.code.localeCompare(b.code));
  return out;
}

function filteredSites(rows) {
  const q = (MAP.query || "").trim().toLowerCase();
  if (!q) return rows;
  return rows.filter((s) => {
    const hay = [s.code, s.name, ...s.gws.map((g) => g.hostname), ...s.gws.map((g) => g.ip)]
      .map((x) => String(x || "").toLowerCase())
      .join(" ");
    return hay.includes(q);
  });
}

function paintMapStats(rows) {
  const gws = MAP.gateways || [];
  const online = gws.filter((g) => String(g.node || "").toUpperCase() === "UP").length;
  const healthy = rows.filter((s) => s.light === "green").length;
  setText("map-stat-sites", `${healthy} / ${rows.length}`);
  setText("map-stat-gws", `${online} / ${gws.length}`);
  setText("map-stat-critical", String(rows.filter((s) => s.light === "red").length));
  setText("map-stat-minor", String(rows.filter((s) => s.light === "yellow").length));
  setText("map-stat-updated", fmtGwTs(MAP.gwUpdated));
  const gwCard = document.getElementById("map-stat-gws-card");
  if (gwCard) {
    gwCard.classList.remove("accent-red", "accent-green");
    if (gws.length && online === gws.length) gwCard.classList.add("accent-green");
    else if (gws.length && online < gws.length) gwCard.classList.add("accent-red");
  }
}

function paintUnmapped(rows) {
  const el = document.getElementById("map-unmapped");
  if (!el) return;
  const miss = rows.filter((s) => s.lat == null || s.lng == null);
  if (!miss.length) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  el.hidden = false;
  el.textContent = `No coordinates (add to map/sites.json): ${miss.map((s) => s.code).join(", ")}`;
}

function renderSide(site) {
  const empty = document.getElementById("map-side-empty");
  const body = document.getElementById("map-side-body");
  if (!empty || !body) return;
  if (!site) {
    empty.hidden = false;
    body.hidden = true;
    body.classList.remove("is-red", "is-yellow", "is-green");
    return;
  }
  empty.hidden = true;
  body.hidden = false;
  body.classList.remove("is-red", "is-yellow", "is-green");
  body.classList.add(`is-${site.light}`);
  const title = document.getElementById("map-side-title");
  const sub = document.getElementById("map-side-sub");
  const light = document.getElementById("map-side-light");
  const meta = document.getElementById("map-side-meta");
  if (title) title.textContent = site.code;
  if (sub) {
    sub.textContent = site.name || (site.dummy ? "Dummy coordinate — edit map/sites.json" : "—");
  }
  if (light) {
    light.className = `map-light ${site.light}`;
    light.textContent = lightLabel(site.light).toUpperCase();
  }
  if (meta) {
    meta.innerHTML = [
      { k: "Gateways", v: site.gwCount },
      { k: "Down", v: site.down },
      { k: "Major", v: site.mj },
      { k: "Minor", v: site.mn },
    ]
      .map(
        (it) => `<div class="cdr-kpi"><div class="cdr-kpi-v">${escapeHtml(String(it.v))}</div>
        <div class="cdr-kpi-k">${escapeHtml(it.k)}</div></div>`
      )
      .join("");
  }
  const tbody = document.getElementById("map-side-tbody");
  if (!tbody) return;
  if (!site.gws.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="6">${
      MAP.connected ? "No live GW for this code yet." : "Login to load live GW / alarms."
    }</td></tr>`;
    return;
  }
  tbody.innerHTML = site.gws
    .slice()
    .sort((a, b) => Number(a.mg) - Number(b.mg))
    .map((g) => {
      const node = String(g.node || "").toUpperCase() === "DOWN" ? "DOWN" : "UP";
      const nodeCls = node === "UP" ? "node-up" : "node-down";
      const host = g.hostname || "—";
      const ip = g.ip || "—";
      return `<tr>
        <td class="mono">${escapeHtml(String(g.mg ?? "—"))}</td>
        <td><button type="button" class="gw-host-btn" data-mg="${escapeHtml(String(g.mg ?? ""))}" title="Open Media Gateway Status">${escapeHtml(host)}</button></td>
        <td class="map-ip" title="${escapeHtml(ip)}">${escapeHtml(ip)}</td>
        <td><span class="badge-node ${nodeCls}">${node}</span></td>
        <td class="mono">${g.mj || 0}</td>
        <td class="mono">${g.mn || 0}</td>
      </tr>`;
    })
    .join("");
}

function selectSite(code) {
  const rows = buildSiteRows();
  const site = rows.find((s) => s.code === code) || null;
  MAP.selected = site ? site.code : null;
  renderSide(site);
  for (const [k, mk] of Object.entries(MAP.markers)) {
    const el = mk.getElement && mk.getElement();
    if (el) el.classList.toggle("is-selected", k === MAP.selected);
    if (mk.setZIndexOffset) mk.setZIndexOffset(k === MAP.selected ? 800 : 0);
  }
  if (site && site.lat != null && site.lng != null && MAP.map) {
    const z = Math.max(MAP.map.getZoom(), 13);
    MAP.map.setView([site.lat, site.lng], z, { animate: true });
  }
}

function markerHtml(site) {
  const dummy = site.dummy ? " is-dummy" : "";
  const pulse = site.light === "green" ? "" : " is-pulse";
  return `<div class="map-pin map-pin-${site.light}${dummy}${pulse}">
    <span class="map-pin-code">${escapeHtml(site.code)}</span>
    <span class="map-pin-dot"></span>
  </div>`;
}

function tooltipHtml(site) {
  const bits = [];
  if (site.down > 0) bits.push(`DOWN ${site.down}`);
  if (site.mj > 0) bits.push(`MJ ${site.mj}`);
  if (site.mn > 0) bits.push(`MN ${site.mn}`);
  const name = site.name
    ? `<div class="map-tip-name">${escapeHtml(site.name)}</div>`
    : "";
  const counts = bits.length ? `<div class="map-tip-alarms">${escapeHtml(bits.join(" · "))}</div>` : "";
  return `<div class="map-tip-inner">
    <div class="map-tip-code">${escapeHtml(site.code)}</div>
    ${name}
    <div class="map-tip-status map-tip-${site.light}">${escapeHtml(lightLabel(site.light))}</div>
    <div class="map-tip-row">Gateways ${escapeHtml(String(site.gwCount))}</div>
    ${counts}
  </div>`;
}

function redrawMarkers() {
  const L = window.L;
  if (!MAP.map || !L) return;
  if (MAP.layer) MAP.layer.clearLayers();
  else MAP.layer = L.layerGroup().addTo(MAP.map);
  MAP.markers = {};
  const rows = filteredSites(buildSiteRows());
  for (const site of rows) {
    if (site.lat == null || site.lng == null) continue;
    const icon = L.divIcon({
      className: "map-pin-wrap",
      html: markerHtml(site),
      iconSize: [58, 32],
      iconAnchor: [29, 32],
    });
    const mk = L.marker([site.lat, site.lng], { icon, keyboard: true, riseOnHover: true });
    mk.bindTooltip(tooltipHtml(site), {
      className: "map-tip",
      direction: "top",
      offset: [0, -10],
      opacity: 1,
      sticky: false,
    });
    mk.on("click", () => selectSite(site.code));
    mk.addTo(MAP.layer);
    MAP.markers[site.code] = mk;
  }
  if (MAP.selected) {
    const still = rows.find((s) => s.code === MAP.selected);
    renderSide(still || null);
    if (!still) MAP.selected = null;
    else {
      const el = MAP.markers[MAP.selected] && MAP.markers[MAP.selected].getElement && MAP.markers[MAP.selected].getElement();
      if (el) el.classList.add("is-selected");
      if (MAP.markers[MAP.selected] && MAP.markers[MAP.selected].setZIndexOffset) {
        MAP.markers[MAP.selected].setZIndexOffset(800);
      }
    }
  }
}

function resetMapView() {
  if (!MAP.map) return;
  const c = MAP.cfg.center || [22.35, 114.15];
  const z = Number(MAP.cfg.zoom || 11);
  MAP.map.setView(c, z, { animate: true });
}

function addResetControl() {
  const L = window.L;
  if (!MAP.map || !L || MAP.resetAdded) return;
  const Ctrl = L.Control.extend({
    options: { position: "topleft" },
    onAdd() {
      const bar = L.DomUtil.create("div", "leaflet-bar leaflet-control map-reset-control");
      const a = L.DomUtil.create("a", "", bar);
      a.href = "#";
      a.title = "Reset view";
      a.setAttribute("role", "button");
      a.setAttribute("aria-label", "Reset map view");
      a.innerHTML =
        '<svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><path fill="currentColor" d="M12 3.4 3.5 10.8h2.3V20h5.2v-5.6h2V20h5.2v-9.2h2.3L12 3.4z"/></svg>';
      L.DomEvent.disableClickPropagation(bar);
      L.DomEvent.disableScrollPropagation(bar);
      L.DomEvent.on(a, "click", (ev) => {
        L.DomEvent.preventDefault(ev);
        L.DomEvent.stopPropagation(ev);
        resetMapView();
      });
      return bar;
    },
  });
  MAP.map.addControl(new Ctrl());
  MAP.resetAdded = true;
}

function ensureMap() {
  const L = window.L;
  const host = document.getElementById("map-canvas");
  if (!host || !L) return false;
  if (MAP.map) {
    setTimeout(() => MAP.map.invalidateSize(), 80);
    return true;
  }
  const cfg = MAP.cfg;
  const maxZ = Number(cfg.maxZoom || 14);
  const minZ = Number(cfg.minZoom || 10);
  MAP.map = L.map(host, {
    center: cfg.center || [22.35, 114.15],
    zoom: Number(cfg.zoom || 11),
    minZoom: minZ,
    maxZoom: maxZ,
    zoomControl: true,
    attributionControl: true,
  });
  L.tileLayer("map/tiles/{z}/{x}/{y}.jpg", {
    minZoom: minZ,
    maxZoom: maxZ,
    maxNativeZoom: maxZ,
    errorTileUrl: "",
    attribution: "Tiles © Esri · offline cache",
  }).addTo(MAP.map);
  addResetControl();
  setTimeout(() => MAP.map.invalidateSize(), 120);
  return true;
}

function paintAll() {
  const all = buildSiteRows();
  paintMapStats(all);
  paintUnmapped(all);
  if (MAP.tabActive) {
    ensureMap();
    redrawMarkers();
  }
}

async function loadSitesFile() {
  const data = await fetchJsonMap(siteUrlMap("map/sites.json") + "?t=" + Date.now());
  const sites = Array.isArray(data.sites) ? data.sites : [];
  MAP.cfg = {
    center: Array.isArray(data.center) && data.center.length === 2 ? data.center : [22.35, 114.15],
    zoom: Number(data.zoom || 11),
    minZoom: Number(data.minZoom || 10),
    maxZoom: Number(data.maxZoom || 14),
    sites,
  };
}

async function loadGatewayCache() {
  let items = [];
  let updated = null;
  try {
    const data = await fetchJsonMap(apiUrlMap("gateways"));
    if (Array.isArray(data.items)) {
      items = data.items;
      updated = data.lastUpdate || null;
    }
  } catch {
    /* old DLL */
  }
  if (!items.length) {
    try {
      const td = await fetchJsonMap(apiUrlMap("trunk-data"));
      const inner = td.data || td;
      const gw = inner && inner.gateways;
      if (gw && Array.isArray(gw.items)) {
        items = gw.items;
        updated = gw.lastUpdate || inner.lastUpdate || null;
      }
    } catch {
      /* ignore */
    }
  }
  if (!items.length) {
    try {
      const data = await fetchJsonMap(siteUrlMap("gateways_cache.json") + "?t=" + Date.now());
      if (Array.isArray(data.items)) {
        items = data.items;
        updated = data.lastUpdate || null;
      }
    } catch {
      /* ignore */
    }
  }
  MAP.gateways = items;
  MAP.gwUpdated = updated;
}

export async function refreshMapFromCache() {
  try {
    await loadGatewayCache();
  } catch {
    /* keep last */
  }
  paintAll();
}

export async function onMapTabShow() {
  MAP.tabActive = true;
  try {
    await loadSitesFile();
  } catch (e) {
    console.warn("map/sites.json:", e?.message || e);
  }
  await refreshMapFromCache();
  ensureMap();
  redrawMarkers();
  setTimeout(() => {
    if (MAP.map) MAP.map.invalidateSize();
  }, 200);
}

export function setMapTabActive(active) {
  MAP.tabActive = !!active;
}

export function setMapSessionConnected(connected) {
  MAP.connected = !!connected;
  if (MAP.tabActive) refreshMapFromCache().catch(() => {});
}

export function initMapUi() {
  const search = document.getElementById("map-search");
  if (search) {
    search.addEventListener("input", () => {
      MAP.query = search.value || "";
      paintAll();
    });
  }
  const close = document.getElementById("map-side-close");
  if (close) {
    close.addEventListener("click", () => {
      MAP.selected = null;
      renderSide(null);
      for (const mk of Object.values(MAP.markers)) {
        const el = mk.getElement && mk.getElement();
        if (el) el.classList.remove("is-selected");
        if (mk.setZIndexOffset) mk.setZIndexOffset(0);
      }
    });
  }
  const tbody = document.getElementById("map-side-tbody");
  if (tbody) {
    tbody.addEventListener("click", (ev) => {
      const btn = ev.target && ev.target.closest && ev.target.closest(".gw-host-btn");
      if (!btn) return;
      ev.preventDefault();
      const mg = Number(btn.getAttribute("data-mg"));
      if (!mg) return;
      const tab = document.querySelector('.tab[data-tab="gateway"]');
      if (tab) tab.click();
      openGatewayDetail(mg, { showModal: true });
    });
  }
}
