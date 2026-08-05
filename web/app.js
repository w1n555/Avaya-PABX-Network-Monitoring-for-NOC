/**
 * Trunk NOC dashboard — live via /api (same-origin under /CM/)
 * CSV export is pure client-side. No dummy data.
 */

const API = new URL("api/", window.location.href).pathname.replace(/\/?$/, "/");

const state = {
  connected: false,
  host: "",
  trunks: [],
  filter: "",
  sortKey: "tg",
  sortDir: 1,
  detailTg: null,
  channels: [],
  configText: "",
  lastSuccess: null,
  lastAttempt: null,
  lastError: null,
  autoTimer: null,
  busy: false,
  apiLog: [], // browser-side last API calls
  satTraces: [],
};

const $ = (s) => document.querySelector(s);

function setBusy(on, label) {
  state.busy = !!on;
  document.body.classList.toggle("is-busy", state.busy);
  const el = $("#busy-line");
  if (!el) return;
  if (on) {
    el.hidden = false;
    el.textContent = label || "⏳ Waiting for CM SAT… (live SSH — can take 5–30s)";
  } else {
    el.hidden = true;
  }
  // keep connect/disconnect semantics
  $("#btn-connect").disabled = state.connected || state.busy;
  $("#btn-disconnect").disabled = !state.connected || state.busy;
  $("#btn-refresh").disabled = !state.connected || state.busy;
  $("#btn-refresh-detail").disabled = !state.connected || state.busy;
}

function pushApiLog(entry) {
  state.apiLog.unshift(entry);
  if (state.apiLog.length > 30) state.apiLog.length = 30;
  renderIoPanel();
}

function renderIoPanel() {
  if ($("#chk-io") && !$("#chk-io").checked) {
    $("#io-panel").style.display = "none";
    return;
  }
  if ($("#io-panel")) $("#io-panel").style.display = "";
  const apiEl = $("#api-io-log");
  const satEl = $("#sat-io-log");
  if (!apiEl || !satEl) return;

  if (!state.apiLog.length) apiEl.textContent = "— no API calls yet —";
  else {
    apiEl.textContent = state.apiLog
      .slice(0, 12)
      .map((e) => {
        const bodyHint = e.reqBody ? ` body=${e.reqBody}` : "";
        return `[${e.at}] ${e.method} ${e.path} → ${e.status} ${e.ms}ms${bodyHint}\n${e.summary || ""}`;
      })
      .join("\n----------------\n");
  }

  if (!state.satTraces.length) satEl.textContent = "— no SAT traces yet (connect first) —";
  else {
    satEl.textContent = state.satTraces
      .slice()
      .reverse()
      .slice(0, 8)
      .map((t) => {
        const cmd = t.command || t.Command || "";
        const ms = t.durationMs ?? t.DurationMs ?? "?";
        const ok = t.ok ?? t.Ok;
        const pages = t.pagesFetched ?? t.PagesFetched ?? 0;
        const err = t.error || t.Error || "";
        const prev = t.outputPreview || t.OutputPreview || "";
        return `[${t.at || t.At || ""}] SAT ${ok === false ? "FAIL" : "OK"} ${ms}ms pages=${pages}\n> ${cmd}${err ? "\nERR: " + err : ""}\n${prev.slice(0, 1200)}`;
      })
      .join("\n================\n");
  }
}

function ingestSatTraces(body) {
  const tr = body?.satTraces || body?.SatTraces;
  if (Array.isArray(tr) && tr.length) {
    state.satTraces = tr;
    renderIoPanel();
  }
}

function fmt(dt) {
  if (!dt) return "—";
  const d = typeof dt === "string" ? new Date(dt) : dt;
  if (Number.isNaN(d.getTime())) return String(dt);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function escapeHtml(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function api(path, opts = {}) {
  const method = (opts.method || "GET").toUpperCase();
  const p = path.replace(/^\//, "");
  const t0 = performance.now();
  let reqBody = "";
  if (opts.body && method !== "GET") {
    try {
      const j = JSON.parse(opts.body);
      if (j.password) j.password = "***";
      reqBody = JSON.stringify(j);
    } catch {
      reqBody = "(body)";
    }
  }
  const res = await fetch(API + p, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  const ms = Math.round(performance.now() - t0);
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  const summaryParts = [];
  if (body?.items || body?.Items) summaryParts.push(`items=${(body.items || body.Items).length}`);
  if (body?.channels || body?.Channels) summaryParts.push(`channels=${(body.channels || body.Channels).length}`);
  if (body?.error || body?.Error) summaryParts.push(`error=${body.error || body.Error}`);
  if (body?.ok === false || body?.Ok === false) summaryParts.push("ok=false");
  pushApiLog({
    at: new Date().toLocaleTimeString("en-GB", { hour12: false }),
    method,
    path: p,
    status: res.status,
    ms,
    reqBody: reqBody.slice(0, 200),
    summary: summaryParts.join(" "),
  });
  if (body) ingestSatTraces(body);
  if (!res.ok) {
    const msg = body?.error || body?.Error || res.statusText || `HTTP ${res.status}`;
    const err = new Error(msg);
    err.body = body;
    err.status = res.status;
    throw err;
  }
  return body;
}

function setError(msg) {
  const el = $("#error-line");
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    state.lastError = null;
    return;
  }
  state.lastError = msg;
  el.hidden = false;
  el.textContent = msg;
}

function updateMeta() {
  $("#cm-host").textContent = state.host || "—";
  $("#conn-status").textContent = state.connected ? "Connected" : "Disconnected";
  $("#conn-status").className = "value " + (state.connected ? "ok" : "");
  $("#last-success").textContent = fmt(state.lastSuccess);
  $("#last-attempt").textContent = fmt(state.lastAttempt);
  const badge = $("#live-badge");
  const txt = $("#live-badge-text");
  if (state.connected) {
    badge.classList.remove("paused");
    txt.textContent = "Live";
  } else {
    badge.classList.add("paused");
    txt.textContent = "Idle";
  }
  $("#btn-connect").disabled = state.connected || state.busy;
  $("#btn-disconnect").disabled = !state.connected || state.busy;
  $("#btn-refresh").disabled = !state.connected || state.busy;
  $("#btn-refresh-detail").disabled = !state.connected || state.busy;
}

function filteredTrunks() {
  let rows = [...state.trunks];
  const q = state.filter.trim().toLowerCase();
  if (q) {
    rows = rows.filter(
      (t) =>
        String(t.tg).includes(q) ||
        (t.name || "").toLowerCase().includes(q) ||
        (t.type || "").toLowerCase().includes(q)
    );
  }
  const k = state.sortKey;
  rows.sort((a, b) => {
    const av = a[k] ?? "";
    const bv = b[k] ?? "";
    if (typeof av === "number" && typeof bv === "number") return (av - bv) * state.sortDir;
    return String(av).localeCompare(String(bv)) * state.sortDir;
  });
  return rows;
}

function renderStats(items) {
  const total = items.length;
  const inUse = items.reduce((s, t) => s + (Number(t.inUse) || 0), 0);
  const oos = items.reduce((s, t) => s + (Number(t.oos) || 0), 0);
  const peak = items.reduce((m, t) => Math.max(m, Number(t.usagePct) || 0), 0);
  $("#trunk-stats").innerHTML = `
    <div class="stat-card info"><div class="stat-label">Trunk Groups</div><div class="stat-value">${total}</div></div>
    <div class="stat-card ok"><div class="stat-label">In-Use (known)</div><div class="stat-value">${inUse}</div></div>
    <div class="stat-card ${peak >= 80 ? "danger" : peak >= 50 ? "warn" : "ok"}"><div class="stat-label">Peak Usage%</div><div class="stat-value">${peak.toFixed(1)}%</div></div>
    <div class="stat-card ${oos > 0 ? "danger" : "ok"}"><div class="stat-label">OOS (known)</div><div class="stat-value">${oos}</div></div>
  `;
}

function usageBar(pct) {
  if (pct == null || Number.isNaN(Number(pct))) return "—";
  const p = Math.max(0, Math.min(100, Number(pct)));
  let level = "";
  if (p >= 80) level = "high";
  else if (p >= 50) level = "mid";
  return `<div class="usage-bar-wrap"><div class="usage-bar-track"><div class="usage-bar-fill ${level}" style="width:${p}%"></div></div><span class="usage-pct">${p.toFixed(1)}%</span></div>`;
}

function renderIndex() {
  const rows = filteredTrunks();
  renderStats(state.trunks);
  const tb = $("#trunk-tbody");
  if (!rows.length) {
    tb.innerHTML = `<tr class="empty-row"><td colspan="7">${state.connected ? "No trunks (or filter empty)" : "Connect to CM to load live trunks"}</td></tr>`;
    return;
  }
  tb.innerHTML = rows
    .map((t) => {
      const oos = Number(t.oos) || 0;
      const cls = oos > 0 ? "row-warn" : "";
      return `<tr class="${cls}" data-tg="${t.tg}">
        <td>${escapeHtml(t.tg)}</td>
        <td class="cell-name"><a href="#" class="trunk-link" data-tg="${t.tg}">${escapeHtml(t.name || "—")}</a></td>
        <td><span class="pill pill-info">${escapeHtml(t.type || "—")}</span></td>
        <td>${escapeHtml(t.total ?? "—")}</td>
        <td>${t.inUse == null ? "—" : escapeHtml(t.inUse)}</td>
        <td class="usage-cell">${usageBar(t.usagePct)}</td>
        <td>${t.oos == null ? "—" : escapeHtml(t.oos)}</td>
      </tr>`;
    })
    .join("");
}

function renderDetail() {
  $("#detail-title").textContent = `Trunk ${state.detailTg} — Channel Status`;
  $("#detail-config").textContent = state.configText || "—";
  const ch = state.channels;
  const inUse = ch.filter((c) => /in-use/i.test(c.serviceState || "")).length;
  const oos = ch.filter((c) => /OOS/i.test(c.serviceState || "")).length;
  $("#detail-stats").innerHTML = `
    <div class="stat-card info"><div class="stat-label">Channels</div><div class="stat-value">${ch.length}</div></div>
    <div class="stat-card ok"><div class="stat-label">In-Use</div><div class="stat-value">${inUse}</div></div>
    <div class="stat-card ${oos ? "danger" : "ok"}"><div class="stat-label">OOS</div><div class="stat-value">${oos}</div></div>
    <div class="stat-card info"><div class="stat-label">TG#</div><div class="stat-value">${escapeHtml(state.detailTg)}</div></div>
  `;
  const tb = $("#channel-tbody");
  if (!ch.length) {
    tb.innerHTML = `<tr class="empty-row"><td colspan="9">No channel rows parsed</td></tr>`;
    return;
  }
  tb.innerHTML = ch
    .map((c) => {
      const bad = /OOS/i.test(c.serviceState || "");
      const busy = /in-use/i.test(c.serviceState || "");
      const cls = bad ? "row-danger" : busy ? "row-warn" : "";
      return `<tr class="${cls}">
        <td>${escapeHtml(c.member)}</td>
        <td>${escapeHtml(c.port)}</td>
        <td>${escapeHtml(c.serviceState)}</td>
        <td>${escapeHtml(c.mtceBusy)}</td>
        <td>${escapeHtml(c.connectedPorts || "—")}</td>
        <td>${escapeHtml(c.caller || "—")}</td>
        <td>${escapeHtml(c.called || "—")}</td>
        <td>${escapeHtml(c.duration || "—")}</td>
        <td>${escapeHtml(c.extension || "—")}</td>
      </tr>`;
    })
    .join("");
}

function showIndex() {
  state.detailTg = null;
  $("#view-index").hidden = false;
  $("#view-detail").hidden = true;
  renderIndex();
}

function showDetail() {
  $("#view-index").hidden = true;
  $("#view-detail").hidden = false;
  renderDetail();
}

/* ---------- Live actions ---------- */

async function connect() {
  if (state.busy) return;
  setError("");
  const body = {
    host: $("#inp-host").value.trim(),
    port: Number($("#inp-port").value) || 5022,
    username: $("#inp-user").value.trim(),
    password: $("#inp-pass").value,
    terminalType: "VT220",
  };
  setBusy(true, "⏳ Connecting SSH + VT220 to CM…");
  try {
    const res = await api("session/connect", { method: "POST", body: JSON.stringify(body) });
    state.connected = true;
    state.host = res.host || body.host;
    state.lastSuccess = res.connectedAt || new Date().toISOString();
    state.lastAttempt = state.lastSuccess;
    updateMeta();
    setBusy(true, "⏳ Loading trunk list from CM (list trunk-group)…");
    await refreshTrunks({ nested: true });
    startAuto();
  } catch (e) {
    state.connected = false;
    state.lastAttempt = new Date().toISOString();
    setError("Connect failed: " + e.message);
    updateMeta();
  } finally {
    setBusy(false);
  }
}

async function disconnect() {
  try {
    await api("session/disconnect", { method: "POST", body: "{}" });
  } catch {
    /* ignore */
  }
  stopAuto();
  state.connected = false;
  state.trunks = [];
  state.channels = [];
  setError("");
  updateMeta();
  renderIndex();
  showIndex();
}

async function refreshTrunks(opts = {}) {
  if (!state.connected) return;
  if (state.busy && !opts.nested) return;
  state.lastAttempt = new Date().toISOString();
  updateMeta();
  if (!opts.nested) setBusy(true, "⏳ list trunk-group on CM…");
  try {
    const res = await api("trunks");
    const items = (res.items || res.Items || []).map(normalizeTrunk);
    if (res.ok === false || res.Ok === false) {
      state.trunks = items.length ? items : state.trunks;
      state.lastSuccess = res.lastSuccessAt || res.LastSuccessAt || state.lastSuccess;
      state.lastAttempt = res.lastAttemptAt || res.LastAttemptAt || state.lastAttempt;
      setError("Update failed: " + (res.error || res.Error || "unknown") + " — showing last good data if any");
    } else {
      state.trunks = items;
      state.lastSuccess = res.lastSuccessAt || res.LastSuccessAt || new Date().toISOString();
      state.lastAttempt = res.lastAttemptAt || res.LastAttemptAt || state.lastAttempt;
      setError("");
    }
    updateMeta();
    renderIndex();
  } catch (e) {
    state.lastAttempt = new Date().toISOString();
    setError("Update failed: " + e.message + " — last success unchanged");
    if (e.body) {
      const items = (e.body.items || e.body.Items || []).map(normalizeTrunk);
      if (items.length) state.trunks = items;
      state.lastSuccess = e.body.lastSuccessAt || e.body.LastSuccessAt || state.lastSuccess;
      ingestSatTraces(e.body);
    }
    updateMeta();
    renderIndex();
  } finally {
    if (!opts.nested) setBusy(false);
  }
}

function normalizeTrunk(t) {
  return {
    tg: t.tg ?? t.Tg,
    name: t.name ?? t.Name ?? "",
    type: t.type ?? t.Type ?? "",
    total: t.total ?? t.Total ?? 0,
    inUse: t.inUse ?? t.InUse ?? null,
    oos: t.oos ?? t.Oos ?? null,
    usagePct: t.usagePct ?? t.UsagePct ?? null,
    tac: t.tac ?? t.Tac ?? "",
  };
}

function normalizeChannel(c) {
  return {
    member: c.member ?? c.Member ?? "",
    port: c.port ?? c.Port ?? "",
    serviceState: c.serviceState ?? c.ServiceState ?? "",
    mtceBusy: c.mtceBusy ?? c.MtceBusy ?? "",
    connectedPorts: c.connectedPorts ?? c.ConnectedPorts ?? "",
    caller: c.caller ?? c.Caller ?? "",
    called: c.called ?? c.Called ?? "",
    duration: c.duration ?? c.Duration ?? "",
    extension: c.extension ?? c.Extension ?? "",
  };
}

async function openDetail(tg) {
  if (state.busy) return;
  state.detailTg = tg;
  state.lastAttempt = new Date().toISOString();
  updateMeta();
  showDetail();
  setBusy(true, `⏳ status trunk ${tg} + display trunk-group ${tg} (page 1 only)…`);
  try {
    const res = await api(`trunks/${tg}`);
    if (res.ok === false || res.Ok === false) {
      setError("Detail update failed: " + (res.error || res.Error));
      state.lastSuccess = res.lastSuccessAt || res.LastSuccessAt || state.lastSuccess;
    } else {
      setError("");
      state.lastSuccess = res.lastSuccessAt || res.LastSuccessAt || new Date().toISOString();
    }
    state.lastAttempt = res.lastAttemptAt || res.LastAttemptAt || state.lastAttempt;
    state.channels = (res.channels || res.Channels || []).map(normalizeChannel);
    state.configText = res.rawConfigHint || res.RawConfigHint || JSON.stringify(res.config || res.Config || {}, null, 2);
    updateMeta();
    renderDetail();
  } catch (e) {
    setError("Detail update failed: " + e.message);
    state.lastAttempt = new Date().toISOString();
    if (e.body) ingestSatTraces(e.body);
    updateMeta();
  } finally {
    setBusy(false);
  }
}

async function refreshIo() {
  if (!state.connected) return;
  try {
    const res = await api("session/io");
    const tr = res.traces || res.Traces || [];
    if (Array.isArray(tr)) {
      state.satTraces = tr;
      renderIoPanel();
    }
  } catch (e) {
    /* ignore */
  }
}

/* ---------- CSV export (client-only) ---------- */

function csvEscape(v) {
  const s = v == null ? "" : String(v);
  if (/[",\r\n]/.test(s)) return `"${s.replaceAll('"', '""')}"`;
  return s;
}

function downloadCsv(filename, rows) {
  const bom = "\uFEFF";
  const text = rows.map((r) => r.map(csvEscape).join(",")).join("\r\n");
  const blob = new Blob([bom + text], { type: "text/csv;charset=utf-8;" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

function stamp() {
  return fmt(new Date()).replaceAll(/[: ]/g, (c) => (c === " " ? "_" : "-"));
}

function exportIndex() {
  const rows = [["TG#", "Name", "Type", "Total", "In-Use", "Usage%", "OOS", "CM", "ExportedAt"]];
  for (const t of filteredTrunks()) {
    rows.push([t.tg, t.name, t.type, t.total, t.inUse ?? "", t.usagePct ?? "", t.oos ?? "", state.host, fmt(new Date())]);
  }
  downloadCsv(`CM_Trunks_${stamp()}.csv`, rows);
}

function exportDetail() {
  const rows = [["Member", "Port", "ServiceState", "MtceBusy", "ConnectedPorts", "Caller", "Called", "Duration", "Extension", "TG", "CM"]];
  for (const c of state.channels) {
    rows.push([c.member, c.port, c.serviceState, c.mtceBusy, c.connectedPorts, c.caller, c.called, c.duration, c.extension, state.detailTg, state.host]);
  }
  downloadCsv(`CM_Trunk_${state.detailTg}_Channels_${stamp()}.csv`, rows);
}

/* ---------- Auto refresh ---------- */

function startAuto() {
  stopAuto();
  if (!$("#chk-auto").checked || !state.connected) return;
  state.autoTimer = setInterval(() => {
    if (state.detailTg != null) openDetail(state.detailTg);
    else refreshTrunks();
  }, 30000);
}

function stopAuto() {
  if (state.autoTimer) clearInterval(state.autoTimer);
  state.autoTimer = null;
}

/* ---------- Bind ---------- */

function bind() {
  $("#btn-connect").addEventListener("click", connect);
  $("#btn-disconnect").addEventListener("click", disconnect);
  $("#btn-refresh").addEventListener("click", () => refreshTrunks());
  $("#btn-refresh-detail").addEventListener("click", () => state.detailTg != null && openDetail(state.detailTg));
  $("#btn-back").addEventListener("click", showIndex);
  $("#btn-export-index").addEventListener("click", exportIndex);
  $("#btn-export-detail").addEventListener("click", exportDetail);
  $("#btn-refresh-io")?.addEventListener("click", refreshIo);
  $("#btn-clear-io")?.addEventListener("click", () => {
    state.apiLog = [];
    state.satTraces = [];
    renderIoPanel();
  });
  $("#chk-io")?.addEventListener("change", renderIoPanel);
  $("#trunk-filter").addEventListener("input", (e) => {
    state.filter = e.target.value;
    renderIndex();
  });
  $("#chk-auto").addEventListener("change", () => {
    if ($("#chk-auto").checked) startAuto();
    else stopAuto();
  });
  $("#trunk-tbody").addEventListener("click", (e) => {
    const a = e.target.closest("[data-tg]");
    if (!a || state.busy) return;
    e.preventDefault();
    openDetail(Number(a.dataset.tg));
  });
  document.querySelectorAll("#trunk-table th[data-sort]").forEach((th) => {
    th.style.cursor = "pointer";
    th.addEventListener("click", () => {
      const k = th.dataset.sort;
      if (state.sortKey === k) state.sortDir *= -1;
      else {
        state.sortKey = k;
        state.sortDir = 1;
      }
      renderIndex();
    });
  });
  setInterval(() => {
    $("#live-clock").textContent = new Date().toLocaleTimeString("en-GB", { hour12: false });
  }, 1000);
}

bind();
updateMeta();
renderIndex();
renderIoPanel();
