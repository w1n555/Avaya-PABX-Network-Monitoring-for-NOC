/**
 * Media Gateway status — OSSI list media-gateway + Active alarm counts by MG Port.
 * First open / manual Refresh → progress popup %.
 * Session Auto 60s (Trunk checkbox) packs Trunk + Alarm + Gateway.
 */

import { showProgress, setProgress, finishProgress } from "./cdr-ui.js";

/** Magic TG for refresh/one when CmApi has no /gateways route. */
const TG_GATEWAY = 9995;
/** refresh/one tg = 990000 + MG → list configuration media-gateway N */
const TG_GW_CONFIG_BASE = 990000;

function apiUrlGw(path) {
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + "api/" + String(path).replace(/^\//, "");
}

function siteUrlGw(path) {
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + String(path).replace(/^\//, "");
}

async function fetchJsonGw(url, opts = {}) {
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

const GW = {
  data: { items: [], summary: {} },
  query: "",
  nextAt: 0,
  countdownTimer: null,
  tabActive: false,
  connected: false,
  loading: false,
  ossiBusy: false,
  pendingSilent: false,
  detailMg: null,
  configByMg: {},
};

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtUpdated(iso) {
  if (!iso) return "—";
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return String(iso).slice(0, 19);
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  } catch {
    return String(iso).slice(0, 19);
  }
}

function setGwStatus(msg) {
  const el = document.getElementById("gw-auto-status");
  if (!el) return;
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    el.removeAttribute("title");
    return;
  }
  el.hidden = false;
  el.textContent = msg;
  el.title = msg;
}

function paintGwUpdated() {
  const el = document.getElementById("gw-meta-updated");
  if (el) el.textContent = fmtUpdated(GW.data.lastUpdate);
}

function filteredGwRows() {
  const q = (GW.query || "").trim().toLowerCase();
  const items = GW.data.items || [];
  if (!q) return items;
  return items.filter((r) => {
    const host = String(r.hostname || "").toLowerCase();
    const ip = String(r.ip || "").toLowerCase();
    return host.includes(q) || ip.includes(q);
  });
}

function paintGwSummary() {
  const el = document.getElementById("gw-summary-kpi");
  if (!el) return;
  const s = GW.data.summary || {};
  const shown = filteredGwRows().length;
  const total = s.total ?? (GW.data.items || []).length;
  el.innerHTML = [
    { k: "Total", v: total },
    { k: "Showing", v: shown },
    { k: "UP", v: s.up ?? 0 },
    { k: "DOWN", v: s.down ?? 0 },
    { k: "Major", v: s.mj ?? 0 },
    { k: "Minor", v: s.mn ?? 0 },
    { k: "Warning", v: s.wn ?? 0 },
  ]
    .map(
      (it) => `<div class="cdr-kpi"><div class="cdr-kpi-v">${escapeHtml(String(it.v))}</div>
      <div class="cdr-kpi-k">${escapeHtml(it.k)}</div></div>`
    )
    .join("");
}

function rowClass(r) {
  if (String(r.node || "").toUpperCase() === "DOWN") return "sev-major";
  if (Number(r.mj) > 0) return "sev-major";
  if (Number(r.mn) > 0) return "sev-minor";
  if (Number(r.wn) > 0) return "sev-warn";
  return "";
}

function alarmCell(n, kind) {
  const v = Number(n) || 0;
  const hot = v > 0 ? ` gw-alarm-${kind}` : "";
  return `<td class="mono gw-alarm${hot}">${v}</td>`;
}

function renderGwTable() {
  const tbody = document.getElementById("gw-tbody");
  if (!tbody) return;
  if (GW.loading && !(GW.data.items || []).length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="7">Updating… (waiting for OSSI — Trunk update may be running)</td></tr>`;
    return;
  }
  const rows = filteredGwRows();
  if (!rows.length) {
    const q = (GW.query || "").trim();
    const msg = !GW.connected
      ? "Login required for live OSSI media gateways."
      : q
        ? `No hostname / IP contains “${q}”.`
        : "No media gateways.";
    tbody.innerHTML = `<tr class="empty"><td colspan="7">${escapeHtml(msg)}</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map((r) => {
      const node = String(r.node || "").toUpperCase() === "DOWN" ? "DOWN" : "UP";
      const nodeCls = node === "UP" ? "node-up" : "node-down";
      const host = r.hostname || "—";
      return `<tr class="${rowClass(r)}" data-mg="${escapeHtml(String(r.mg ?? ""))}">
        <td class="mono">${escapeHtml(String(r.mg ?? "—"))}</td>
        <td><button type="button" class="gw-host-btn" data-mg="${escapeHtml(String(r.mg ?? ""))}" title="Open gateway details">${escapeHtml(host)}</button></td>
        <td><span class="badge-node ${nodeCls}">${node}</span></td>
        <td class="mono">${escapeHtml(r.ip || "—")}</td>
        ${alarmCell(r.mj, "mj")}
        ${alarmCell(r.mn, "mn")}
        ${alarmCell(r.wn, "wn")}
      </tr>`;
    })
    .join("");
}

function paintGwCountdown() {
  const el = document.getElementById("gw-countdown");
  const det = document.getElementById("gw-detail-countdown");
  const setBoth = (txt) => {
    if (el) el.textContent = txt;
    if (det) det.textContent = txt;
  };
  if (!GW.connected) {
    setBoth("Next: —");
    return;
  }
  if (GW.loading) {
    setBoth("Updating…");
    return;
  }
  if (!GW.nextAt) {
    setBoth("Next: session Auto 60s");
    return;
  }
  const sec = Math.max(0, Math.ceil((GW.nextAt - Date.now()) / 1000));
  const extra = GW.detailMg && !document.getElementById("gw-detail-view")?.hidden
    ? ` · this GW + global`
    : "";
  setBoth(`Next: ${sec}s${extra}`);
}

export function getOpenGatewayDetailMg() {
  if (!GW.tabActive || !GW.detailMg) return null;
  const pane = document.getElementById("gw-detail-view");
  if (pane && pane.hidden) return null;
  return GW.detailMg;
}

function applyGwPayload(data) {
  if (!data || typeof data !== "object") return false;
  let d = data;
  if (d.gateways && typeof d.gateways === "object" && (d.gateways.items || d.gateways.summary)) {
    d = d.gateways;
  }
  if (d.data && typeof d.data === "object" && d.data.gateways) {
    d = d.data.gateways;
  }
  if (!Array.isArray(d.items) && !d.summary) return false;
  const incoming = Array.isArray(d.items) ? d.items : [];
  const prev = GW.data.items || [];
  // Incomplete list media-gateway (more? cut short) — keep fuller cache
  if (prev.length >= 20 && incoming.length > 0 && incoming.length < prev.length * 0.5) {
    console.warn("gateway payload looks truncated", incoming.length, "vs", prev.length);
    setGwStatus(`list media-gateway incomplete (${incoming.length}) — keeping last ${prev.length}`);
    return false;
  }
  GW.data = {
    ok: d.ok !== false,
    items: incoming,
    summary: d.summary || {},
    lastUpdate: d.lastUpdate || GW.data.lastUpdate,
    connected: d.connected,
  };
  paintGwSummary();
  renderGwTable();
  paintGwUpdated();
  return true;
}

async function forceOssiGateways() {
  const res = await fetchJsonGw(apiUrlGw("refresh/one"), {
    method: "POST",
    body: JSON.stringify({ tg: TG_GATEWAY }),
  });
  const payload = res && (res.gateways || (res.gatewayRefresh ? res : null));
  if (payload) {
    applyGwPayload(payload);
    const t = payload.timing || res.timing;
    const n = (GW.data.items || []).length;
    if (t && t.listSec != null) {
      setGwStatus(`list media-gateway ${t.listSec}s (${t.rows ?? n} GW)`);
    } else {
      setGwStatus(`${n} gateways`);
    }
    return true;
  }
  throw new Error((res && (res.error || res.Error)) || "refresh/one returned no gateway payload");
}

async function loadGateways(opts = {}) {
  const force = !!opts.force;
  const showModal = !!opts.showModal;
  GW.loading = true;
  paintGwCountdown();
  if (force) renderGwTable();

  let ok = false;
  try {
    if (force && GW.connected) {
      if (showModal) {
        showProgress("Loading Media Gateways", "OSSI list media-gateway…");
        setProgress(20, "list media-gateway…");
        setGwStatus("Updating gateways…");
        try {
          await forceOssiGateways();
          ok = true;
        } catch (e) {
          console.warn("gateway list:", e?.message || e);
          setGwStatus(String(e.message || e));
        }
        setProgress(100, ok ? "Complete" : "Failed");
        finishProgress(
          ok,
          ok ? "Refresh complete" : document.getElementById("gw-auto-status")?.textContent || "Gateway update incomplete"
        );
      } else {
        setGwStatus("Auto update…");
        try {
          await forceOssiGateways();
          ok = true;
        } catch (e) {
          setGwStatus("Auto update incomplete");
          console.warn("gateway auto:", e?.message || e);
        }
      }
    }

    if (!ok || !force) {
      let data = null;
      try {
        data = await fetchJsonGw(apiUrlGw("gateways"));
      } catch {
        /* 404 old DLL */
      }
      if (!data || !Array.isArray(data.items)) {
        try {
          const td = await fetchJsonGw(apiUrlGw("trunk-data"));
          const inner = td.data || td;
          if (inner && inner.gateways) data = inner.gateways;
        } catch {
          /* ignore */
        }
      }
      if (!data || !Array.isArray(data.items)) {
        try {
          data = await fetchJsonGw(siteUrlGw("gateways_cache.json") + "?t=" + Date.now());
        } catch {
          data = null;
        }
      }
      if (data) {
        applyGwPayload(data);
        ok = true;
      }
    }
  } finally {
    GW.loading = false;
    paintGwCountdown();
    paintGwUpdated();
  }
  return GW.data;
}

function startGwCountdownPaint() {
  if (GW.countdownTimer) return;
  GW.countdownTimer = setInterval(paintGwCountdown, 250);
}

export function setGatewaySessionConnected(connected) {
  GW.connected = !!connected;
  const btn = document.getElementById("btn-gw-refresh");
  if (btn) btn.disabled = !GW.connected;
  if (!GW.connected) {
    setGwStatus("");
    paintGwCountdown();
  } else {
    startGwCountdownPaint();
    loadGateways({ force: false, showModal: false }).catch(() => {});
    paintGwCountdown();
  }
}

export function setGatewayTabActive(active) {
  GW.tabActive = !!active;
  paintGwCountdown();
}

export function setOssiBusy(busy) {
  GW.ossiBusy = !!busy;
  if (!busy && GW.pendingSilent && GW.connected && !GW.loading) {
    GW.pendingSilent = false;
    refreshGatewaysSilent().catch(() => {});
  }
}

export function onGatewayTabShow() {
  GW.tabActive = true;
  startGwCountdownPaint();
  // Cache only — Auto 60s / login pack refreshes list media-gateway
  loadGateways({ force: false, showModal: false }).catch(() => {});
  renderGwTable();
  paintGwCountdown();
}

/** Called after Trunk + Alarm cycle — silent list media-gateway. */
export async function refreshGatewaysSilent() {
  if (!GW.connected) return;
  if (GW.loading || GW.ossiBusy) {
    GW.pendingSilent = true;
    return;
  }
  GW.pendingSilent = false;
  try {
    await loadGateways({ force: true, showModal: false });
  } catch {
    /* next cycle */
  }
  if (GW.pendingSilent && !GW.loading) {
    GW.pendingSilent = false;
    try {
      await loadGateways({ force: true, showModal: false });
    } catch {
      /* ignore */
    }
  }
}

/** Trunk Auto countdown drives Gateway "Next" so all share one 60s. */
export function syncGatewayCountdown(nextAtMs) {
  if (nextAtMs) GW.nextAt = nextAtMs;
  paintGwCountdown();
}

function gwRowByMg(mg) {
  return (GW.data.items || []).find((x) => Number(x.mg) === Number(mg)) || null;
}

function boardKind(typ) {
  const t = String(typ || "").toUpperCase();
  if (t.includes("ICC")) return "icc";
  if (t.includes("DCP")) return "dcp";
  if (t.includes("ANA")) return "ana";
  if (t.includes("DS1")) return "ds1";
  return "";
}

function showGwList() {
  const list = document.getElementById("gw-list-view");
  const det = document.getElementById("gw-detail-view");
  if (list) list.hidden = false;
  if (det) det.hidden = true;
}

function showGwDetailPane() {
  const list = document.getElementById("gw-list-view");
  const det = document.getElementById("gw-detail-view");
  if (list) list.hidden = true;
  if (det) det.hidden = false;
}

function paintGwDetailHeader(mg) {
  const row = gwRowByMg(mg) || {};
  const title = document.getElementById("gw-detail-title");
  const meta = document.getElementById("gw-detail-meta");
  if (title) title.textContent = `MG ${mg}  ${row.hostname || ""}`.trim();
  if (meta) {
    const node = String(row.node || "").toUpperCase() === "DOWN" ? "DOWN" : (row.node ? "UP" : "—");
    meta.textContent = [row.ip, row.type, node].filter(Boolean).join(" · ");
  }
}

function paintGwDetailBody(payload, statusMsg) {
  const boards = (payload && payload.boards) || [];
  const assigned = (payload && payload.assigned) || [];
  const sum = (payload && payload.summary) || {};
  const kpi = document.getElementById("gw-detail-kpi");
  if (kpi) {
    kpi.innerHTML = [
      { k: "Boards", v: sum.boards ?? boards.length },
      { k: "Assigned", v: sum.assigned ?? assigned.length },
      { k: "Unassigned", v: sum.unassigned ?? "—" },
      { k: "With ext", v: sum.withExt ?? assigned.filter((a) => a.extension).length },
    ]
      .map(
        (it) => `<div class="cdr-kpi"><div class="cdr-kpi-v">${escapeHtml(String(it.v))}</div>
        <div class="cdr-kpi-k">${escapeHtml(it.k)}</div></div>`
      )
      .join("");
  }
  const bt = document.getElementById("gw-board-tbody");
  if (bt) {
    if (!boards.length) {
      bt.innerHTML = `<tr class="empty"><td colspan="7">${escapeHtml(statusMsg || "Loading configuration…")}</td></tr>`;
    } else {
      bt.innerHTML = boards
        .map((b) => {
          const ports = b.ports || [];
          const asg = ports.filter((p) => p.state === "assigned").length;
          const una = ports.filter((p) => p.state === "unassigned").length;
          const chips = ports
            .map((p) => {
              const st = p.state || "unassigned";
              const ext = p.extension ? `<span class="gw-chip-ext">${escapeHtml(p.extension)}</span>` : "";
              return `<span class="gw-chip ${escapeHtml(st)}" title="${escapeHtml(
                [p.port || p.n, st, p.extension].filter(Boolean).join(" ")
              )}">${escapeHtml(p.n || "?")}${ext}</span>`;
            })
            .join("");
          const kind = boardKind(b.type);
          return `<tr class="gw-board-${kind}">
            <td class="mono">${escapeHtml(b.board || "—")}</td>
            <td>${escapeHtml(b.type || "—")}</td>
            <td class="mono">${escapeHtml(b.code || "—")}</td>
            <td class="mono">${escapeHtml(b.vintage || "—")}</td>
            <td class="mono">${asg}</td>
            <td class="mono">${una}</td>
            <td><div class="gw-chip-row">${chips || "—"}</div></td>
          </tr>`;
        })
        .join("");
    }
  }
  const pt = document.getElementById("gw-port-tbody");
  if (pt) {
    if (!assigned.length) {
      pt.innerHTML = `<tr class="empty"><td colspan="5">${
        boards.length ? "No assigned ports." : escapeHtml(statusMsg || "—")
      }</td></tr>`;
    } else {
      pt.innerHTML = assigned
        .map(
          (a) => `<tr>
            <td class="mono">${escapeHtml(a.port || "—")}</td>
            <td class="mono">${escapeHtml(a.extension || "—")}</td>
            <td>${escapeHtml(a.name || "—")}</td>
            <td>${escapeHtml(a.extType || "—")}</td>
            <td class="mono">${escapeHtml(a.code || a.type || "—")}</td>
          </tr>`
        )
        .join("");
    }
  }
}

export function closeGatewayDetail() {
  GW.detailMg = null;
  showGwList();
}

export function openGatewayDetail(mg, opts = {}) {
  const n = Number(mg);
  if (!n) return;
  GW.detailMg = n;
  showGwDetailPane();
  paintGwDetailHeader(n);
  const cached = GW.configByMg[n];
  paintGwDetailBody(cached || { boards: [], assigned: [] }, cached ? "" : "Click-in OSSI list configuration…");
  if (!GW.connected) {
    paintGwDetailBody(cached || { boards: [], assigned: [] }, "Login required for list configuration media-gateway.");
    return;
  }
  const enqueue = window.__cmEnqueueGwConfig;
  if (typeof enqueue === "function") {
    enqueue(n, { showModal: opts.showModal !== false });
  } else {
    runGatewayConfigRefresh(n, { showModal: opts.showModal !== false }).catch((e) => {
      setGwStatus(String(e.message || e));
    });
  }
}

export async function runGatewayConfigRefresh(mg, opts = {}) {
  const n = Number(mg);
  const showModal = !!opts.showModal;
  if (!n) return null;
  if (showModal) {
    showProgress(`MG ${n} configuration`, "OSSI list configuration media-gateway…");
    setProgress(25, `list configuration media-gateway ${n}…`);
  }
  setGwStatus(`list configuration media-gateway ${n}…`);
  let payload = null;
  try {
    const res = await fetchJsonGw(apiUrlGw("refresh/one"), {
      method: "POST",
      body: JSON.stringify({ tg: TG_GW_CONFIG_BASE + n }),
    });
    payload = res && (res.gatewayConfig || (res.gatewayConfigRefresh ? res : null));
    if (!payload || !Array.isArray(payload.boards)) {
      throw new Error((res && (res.error || res.Error)) || "no configuration payload");
    }
  } catch (e) {
    try {
      payload = await fetchJsonGw(apiUrlGw(`gateways/${n}/config?force=1`));
    } catch (e2) {
      if (showModal) finishProgress(false, String(e2.message || e.message || e));
      setGwStatus(String(e2.message || e.message || e));
      if (GW.detailMg === n) {
        paintGwDetailBody(GW.configByMg[n] || { boards: [], assigned: [] }, String(e2.message || e.message || e));
      }
      throw e2;
    }
  }
  GW.configByMg[n] = payload;
  const t = payload.timing || {};
  const nBoard = (payload.boards || []).length;
  setGwStatus(
    payload.error
      ? String(payload.error)
      : `list configuration media-gateway ${n} ${t.listSec != null ? t.listSec + "s" : ""} · ${nBoard} boards`
  );
  if (GW.detailMg === n) {
    paintGwDetailHeader(n);
    paintGwDetailBody(payload, payload.error || "");
  }
  if (showModal) {
    finishProgress(!payload.error || nBoard > 0, nBoard ? `${nBoard} boards` : payload.error || "No boards");
  }
  return payload;
}

export function initGatewayUi() {
  startGwCountdownPaint();

  const search = document.getElementById("gw-search");
  if (search) {
    search.addEventListener("input", () => {
      GW.query = search.value || "";
      paintGwSummary();
      renderGwTable();
    });
  }

  const tbody = document.getElementById("gw-tbody");
  if (tbody) {
    tbody.addEventListener("click", (ev) => {
      const btn = ev.target && ev.target.closest && ev.target.closest(".gw-host-btn");
      if (!btn) return;
      ev.preventDefault();
      const mg = Number(btn.getAttribute("data-mg"));
      if (mg) openGatewayDetail(mg, { showModal: true });
    });
  }
  document.getElementById("btn-gw-detail-back")?.addEventListener("click", () => closeGatewayDetail());
  document.getElementById("btn-gw-detail-refresh")?.addEventListener("click", () => {
    if (!GW.detailMg) return;
    openGatewayDetail(GW.detailMg, { showModal: true });
  });

  document.getElementById("btn-gw-refresh")?.addEventListener("click", async () => {
    const btn = document.getElementById("btn-gw-refresh");
    if (btn) {
      btn.disabled = true;
      btn.textContent = "Refreshing…";
    }
    try {
      if (GW.ossiBusy) {
        setGwStatus("OSSI busy (Trunk updating) — will refresh when free");
        GW.pendingSilent = true;
        return;
      }
      await loadGateways({ force: true, showModal: true });
    } catch (e) {
      setGwStatus(String(e.message || e));
      finishProgress(false, String(e.message || e));
    } finally {
      if (btn) {
        btn.disabled = !GW.connected;
        btn.textContent = "Refresh";
      }
    }
  });

  paintGwSummary();
  renderGwTable();
  paintGwUpdated();
}
