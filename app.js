/**
 * Avaya NOC UI — Trunk tab
 * Data: OSSI bridge via /CM/api (avaya-ossi), files trunk_data.json / monitored_trunks.json
 */

const API = "api";

const $ = (id) => document.getElementById(id);

const state = {
  connected: false,
  timer: null,
  monitored: [],
};

function apiUrl(path) {
  // Works under /CM/ or site root (e.g. /CM/index.html → /CM/api/...)
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + API + "/" + String(path).replace(/^\//, "");
}

async function api(path, opts = {}) {
  const res = await fetch(apiUrl(path), {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  let body = null;
  const text = await res.text();
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }
  if (!res.ok) {
    const err = (body && (body.error || body.Error)) || res.statusText || "Request failed";
    throw new Error(err);
  }
  return body;
}

function setError(msg) {
  const el = $("error-line");
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  el.hidden = false;
  el.textContent = msg;
}

function setStatus(msg) {
  const el = $("status-line");
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  el.hidden = false;
  el.textContent = msg;
}

function tickClock() {
  const d = new Date();
  $("live-clock").textContent = d.toLocaleTimeString();
}

function fmtTime(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function renderMonitored() {
  const ul = $("monitored-list");
  ul.innerHTML = "";
  if (!state.monitored.length) {
    ul.innerHTML = "<li style='opacity:.6'>No trunks monitored — add a TG number.</li>";
    return;
  }
  for (const tg of state.monitored) {
    const li = document.createElement("li");
    li.innerHTML = `<span>TG ${tg}</span>`;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn btn-danger";
    btn.textContent = "Remove";
    btn.addEventListener("click", () => removeTg(tg));
    li.appendChild(btn);
    ul.appendChild(li);
  }
}

function utilColorClass(item) {
  return item.statusColor || "green";
}

function renderTrunkTable(data) {
  const tbody = $("trunk-tbody");
  const items = (data && data.items) || [];
  $("meta-updated").textContent = fmtTime(data && data.lastUpdate);
  if (data && data.host) $("meta-host").textContent = data.host;
  if (data && data.connected) {
    $("meta-session").textContent = "Connected (OSSI)";
    $("meta-session").style.color = "var(--ok)";
  } else {
    $("meta-session").textContent = "Disconnected";
    $("meta-session").style.color = "";
  }

  if (!items.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="8">${
      state.connected ? "No data yet — add trunks or refresh." : "Connect to CM to load data."
    }</td></tr>`;
    return;
  }

  tbody.innerHTML = "";
  for (const it of items) {
    const color = utilColorClass(it);
    const util = Number(it.utilizationPct || 0);
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td class="tg-cell">
        TG ${it.tg}
        <span class="name">${escapeHtml(it.name || "")}${it.type ? " · " + escapeHtml(it.type) : ""}</span>
      </td>
      <td>${it.total ?? "—"}</td>
      <td>${it.idle ?? "—"}</td>
      <td>${it.busy ?? "—"}</td>
      <td>${it.oos ?? "—"}</td>
      <td>
        <strong>${util.toFixed(1)}%</strong>
        <div class="util-bar"><i style="width:${Math.min(100, util)}%;background:var(--${
          color === "yellow" ? "warn" : color === "red" ? "bad" : "ok"
        })"></i></div>
      </td>
      <td><span class="badge ${color}"><span class="dot"></span>${color}</span></td>
      <td>${fmtTime(it.lastUpdate)}</td>
    `;
    if (it.error) tr.title = it.error;
    tbody.appendChild(tr);
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadTrunkData() {
  const res = await api("trunk-data");
  const data = res.data || res;
  renderTrunkTable(data);
  if (data.error) setError(data.error);
  else setError("");
  return data;
}

async function loadMonitored() {
  const res = await api("monitored");
  state.monitored = res.trunks || [];
  renderMonitored();
}

async function connect() {
  setError("");
  setStatus("Login… 自動啟動 OSSI bridge（如未開）→ 連 CM → 開始 monitor…");
  $("btn-connect").disabled = true;
  try {
    const body = {
      host: $("inp-host").value.trim(),
      port: Number($("inp-port").value) || 5022,
      username: $("inp-user").value.trim(),
      password: $("inp-pass").value,
    };
    if (!body.host || !body.username || !body.password) {
      throw new Error("請填 Host、User、Password");
    }
    // Login triggers API auto-start of Python bridge — no manual script
    const res = await api("session/connect", { method: "POST", body: JSON.stringify(body) });
    state.connected = true;
    $("btn-disconnect").disabled = false;
    $("btn-refresh-now").disabled = false;
    $("meta-host").textContent = res.host || body.host;
    $("meta-session").textContent = "Monitoring (OSSI)";
    $("meta-session").style.color = "var(--ok)";
    setStatus("已登入。正在監控 monitored trunks（Auto 60s + bridge 背景刷新）。");
    await loadMonitored();
    if (res.trunkData) renderTrunkTable(res.trunkData);
    else await loadTrunkData();
    // Always enable auto monitor after successful login
    $("chk-auto").checked = true;
    scheduleAuto();
  } catch (e) {
    state.connected = false;
    setError(String(e.message || e));
    setStatus("");
  } finally {
    $("btn-connect").disabled = false;
  }
}

async function disconnect() {
  try {
    await api("session/disconnect", { method: "POST", body: "{}" });
  } catch {
    /* ignore */
  }
  state.connected = false;
  $("btn-disconnect").disabled = true;
  $("btn-refresh-now").disabled = true;
  $("meta-session").textContent = "Disconnected";
  $("meta-session").style.color = "";
  setStatus("Disconnected.");
  clearAuto();
}

async function refreshNow() {
  setStatus("Refreshing via OSSI…");
  try {
    await api("refresh", { method: "POST", body: "{}" });
    await loadTrunkData();
    setStatus("Refresh complete.");
  } catch (e) {
    setError(String(e.message || e));
  }
}

async function addTg() {
  const tg = Number($("inp-tg").value);
  if (!tg || tg < 1) {
    setError("Enter a valid trunk group number.");
    return;
  }
  setError("");
  try {
    const res = await api("monitored/add", { method: "POST", body: JSON.stringify({ tg }) });
    state.monitored = res.trunks || [];
    renderMonitored();
    $("inp-tg").value = "";
    if (state.connected) await loadTrunkData();
  } catch (e) {
    setError(String(e.message || e));
  }
}

async function removeTg(tg) {
  try {
    const res = await api("monitored/remove", { method: "POST", body: JSON.stringify({ tg }) });
    state.monitored = res.trunks || [];
    renderMonitored();
    if (state.connected) await loadTrunkData();
  } catch (e) {
    setError(String(e.message || e));
  }
}

function clearAuto() {
  if (state.timer) {
    clearInterval(state.timer);
    state.timer = null;
  }
}

function scheduleAuto() {
  clearAuto();
  if (!$("chk-auto").checked) return;
  state.timer = setInterval(async () => {
    try {
      await loadTrunkData();
    } catch {
      /* keep UI quiet on poll miss */
    }
  }, 60_000);
}

function bindTabs() {
  document.querySelectorAll(".tab:not(.disabled)").forEach((btn) => {
    btn.addEventListener("click", () => {
      const name = btn.dataset.tab;
      document.querySelectorAll(".tab").forEach((t) => {
        t.classList.toggle("active", t === btn);
        t.setAttribute("aria-selected", t === btn ? "true" : "false");
      });
      document.querySelectorAll("[data-panel]").forEach((p) => {
        p.classList.toggle("hidden", p.dataset.panel !== name);
      });
    });
  });
}

async function init() {
  bindTabs();
  tickClock();
  setInterval(tickClock, 1000);

  $("btn-connect").addEventListener("click", connect);
  $("btn-disconnect").addEventListener("click", disconnect);
  $("btn-refresh-now").addEventListener("click", refreshNow);
  $("btn-add-tg").addEventListener("click", addTg);
  $("inp-tg").addEventListener("keydown", (e) => {
    if (e.key === "Enter") addTg();
  });
  $("chk-auto").addEventListener("change", () => {
    if (state.connected) scheduleAuto();
    else clearAuto();
  });

  try {
    await loadMonitored();
    await loadTrunkData();
    const st = await api("session/status");
    if (st.connected) {
      state.connected = true;
      $("btn-disconnect").disabled = false;
      $("btn-refresh-now").disabled = false;
      $("meta-host").textContent = st.host || "—";
      $("meta-session").textContent = "Connected (OSSI)";
      $("meta-session").style.color = "var(--ok)";
      scheduleAuto();
    }
  } catch {
    /* offline bridge — still show empty UI */
  }

  try {
    // Warm-up: ask API to auto-start OSSI bridge in background (no user action)
    const h = await api("health?ensure=1");
    if (h && h.bridgeHealthy) {
      setStatus("就緒：填 IP / Password → 撳 Login 即開始 monitor（OSSI 已自動準備）。");
    } else if (h && h.bridgeError) {
      setStatus("API 已上。Login 時會再試自動開 bridge。 " + (h.bridgeError || ""));
    } else {
      setStatus("就緒：填 IP / Password → 撳 Login（系統會自動開 OSSI 並開始 monitor）。");
    }
  } catch {
    setStatus("API 未就緒 — 檢查 IIS /CM/api。就緒後只需 Login。");
  }
}

init();
