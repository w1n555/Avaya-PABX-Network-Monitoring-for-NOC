/**
 * Avaya NOC UI — single-card Trunk Group Status
 * OSSI via /CM/api · trunk_data.json + monitored_trunks.json
 */

const API = "api";

const $ = (id) => document.getElementById(id);

const state = {
  connected: false,
  timer: null,
  heartbeatTimer: null,
  /** @type {{tg:number,order:number,note:string}[]} */
  monitored: [],
  /** @type {object[]} live trunk rows joined with notes */
  trunkItems: [],
  disconnecting: false,
  detailTg: null,
  dragTg: null,
};

function apiUrl(path) {
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

function setSessionLabel(text, ok) {
  const el = $("meta-session");
  el.textContent = text;
  el.style.color = ok ? "var(--ok)" : "";
}

/** Login state machine: before login hide tabs/content; after show; dim when mid-session drop. */
function applyUiMode() {
  const tabs = $("main-tabs");
  const panel = $("panel-trunk");
  const card = $("trunk-card");
  const btnRef = $("btn-refresh-now");
  const btnDisc = $("btn-disconnect");

  if (state.connected) {
    tabs.hidden = false;
    panel.classList.remove("hidden");
    card.classList.remove("dimmed");
    btnRef.disabled = false;
    btnDisc.disabled = false;
    $("connect-hint").textContent =
      "已登入。開住呢頁先會 auto refresh（60s）。熄頁會斷 OSSI；無心跳約 90 秒亦會 logoff。Idle 上限 30 分鐘。";
  } else {
    // keep tabs visible if we had data before (dimmed), else hide until first login in this page load
    if (state.trunkItems.length || state.monitored.length) {
      tabs.hidden = false;
      panel.classList.remove("hidden");
      card.classList.add("dimmed");
    } else {
      tabs.hidden = true;
      panel.classList.add("hidden");
    }
    btnRef.disabled = true;
    btnDisc.disabled = true;
  }
}

function tickClock() {
  $("live-clock").textContent = new Date().toLocaleTimeString();
}

function fmtTime(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function utilColorClass(item) {
  return item.statusColor || "green";
}

function mergeRows() {
  /** Prefer monitored order; join live trunk_data by tg. */
  const byTg = new Map((state.trunkItems || []).map((it) => [Number(it.tg), it]));
  const mon = state.monitored.length
    ? state.monitored
    : (state.trunkItems || []).map((it, i) => ({
        tg: Number(it.tg),
        order: i,
        note: it.note || "",
      }));

  return mon.map((m) => {
    const live = byTg.get(m.tg) || {};
    return {
      tg: m.tg,
      order: m.order,
      note: m.note ?? live.note ?? "",
      name: live.name || "",
      type: live.type || "",
      tac: live.tac || "",
      total: live.total,
      idle: live.idle,
      busy: live.busy,
      oos: live.oos,
      utilizationPct: live.utilizationPct,
      statusColor: live.statusColor,
      lastUpdate: live.lastUpdate,
      error: live.error,
      hasLive: !!live.tg || live.total != null,
    };
  });
}

function renderTrunkTable() {
  const tbody = $("trunk-tbody");
  const rows = mergeRows();

  if (!rows.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="12">${
      state.connected ? "未有監控 TG — 上面加入 TG 號碼。" : "Login 後會顯示監控中嘅 Trunk Group。"
    }</td></tr>`;
    return;
  }

  tbody.innerHTML = "";
  for (const it of rows) {
    const color = utilColorClass(it);
    const util = Number(it.utilizationPct || 0);
    const tr = document.createElement("tr");
    tr.className = "tg-row";
    tr.dataset.tg = String(it.tg);
    tr.draggable = true;
    if (it.error) tr.title = it.error;

    tr.innerHTML = `
      <td class="col-drag"><span class="drag-handle" title="拖曳排序">⋮⋮</span></td>
      <td class="tg-cell"><button type="button" class="link-tg" data-open="${it.tg}">TG ${it.tg}</button></td>
      <td class="col-note"><input type="text" class="note-input" data-note-tg="${it.tg}" maxlength="200" value="${escapeHtml(
        it.note || ""
      )}" placeholder="Note…" /></td>
      <td class="name-cell">${escapeHtml(it.name || "—")}${
        it.type ? `<span class="name">${escapeHtml(it.type)}${it.tac ? " · TAC " + escapeHtml(it.tac) : ""}</span>` : ""
      }</td>
      <td>${it.total ?? "—"}</td>
      <td>${it.idle ?? "—"}</td>
      <td>${it.busy ?? "—"}</td>
      <td>${it.oos ?? "—"}</td>
      <td>
        <strong>${it.hasLive ? util.toFixed(1) + "%" : "—"}</strong>
        ${
          it.hasLive
            ? `<div class="util-bar"><i style="width:${Math.min(100, util)}%;background:var(--${
                color === "yellow" ? "warn" : color === "red" ? "bad" : "ok"
              })"></i></div>`
            : ""
        }
      </td>
      <td>${
        it.hasLive
          ? `<span class="badge ${color}"><span class="dot"></span>${color}</span>`
          : `<span class="badge muted">—</span>`
      }</td>
      <td>${fmtTime(it.lastUpdate)}</td>
      <td><button type="button" class="btn btn-danger btn-rm" data-rm="${it.tg}">Remove</button></td>
    `;
    tbody.appendChild(tr);
  }

  bindRowInteractions(tbody);
}

function bindRowInteractions(tbody) {
  tbody.querySelectorAll(".link-tg").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      openDetail(Number(btn.dataset.open));
    });
  });
  tbody.querySelectorAll(".btn-rm").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      removeTg(Number(btn.dataset.rm));
    });
  });
  tbody.querySelectorAll(".note-input").forEach((inp) => {
    let t = null;
    const save = () => saveNote(Number(inp.dataset.noteTg), inp.value);
    inp.addEventListener("change", save);
    inp.addEventListener("blur", save);
    inp.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        inp.blur();
      }
    });
    inp.addEventListener("input", () => {
      clearTimeout(t);
      t = setTimeout(save, 800);
    });
    inp.addEventListener("mousedown", (e) => e.stopPropagation());
    inp.addEventListener("click", (e) => e.stopPropagation());
  });

  tbody.querySelectorAll("tr.tg-row").forEach((tr) => {
    tr.addEventListener("dragstart", (e) => {
      state.dragTg = Number(tr.dataset.tg);
      tr.classList.add("dragging");
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", tr.dataset.tg);
    });
    tr.addEventListener("dragend", () => {
      tr.classList.remove("dragging");
      state.dragTg = null;
      tbody.querySelectorAll(".drag-over").forEach((el) => el.classList.remove("drag-over"));
    });
    tr.addEventListener("dragover", (e) => {
      e.preventDefault();
      e.dataTransfer.dropEffect = "move";
      tr.classList.add("drag-over");
    });
    tr.addEventListener("dragleave", () => tr.classList.remove("drag-over"));
    tr.addEventListener("drop", async (e) => {
      e.preventDefault();
      tr.classList.remove("drag-over");
      const from = state.dragTg ?? Number(e.dataTransfer.getData("text/plain"));
      const to = Number(tr.dataset.tg);
      if (!from || !to || from === to) return;
      await reorder(from, to);
    });
  });
}

async function reorder(fromTg, toTg) {
  const list = state.monitored.map((x) => ({ ...x }));
  const fromIdx = list.findIndex((x) => x.tg === fromTg);
  const toIdx = list.findIndex((x) => x.tg === toTg);
  if (fromIdx < 0 || toIdx < 0) return;
  const [item] = list.splice(fromIdx, 1);
  list.splice(toIdx, 0, item);
  list.forEach((it, i) => {
    it.order = i;
  });
  state.monitored = list;
  renderTrunkTable();
  try {
    const res = await api("monitored", {
      method: "PUT",
      body: JSON.stringify({
        items: list.map((it) => ({ tg: it.tg, order: it.order, note: it.note || "" })),
        refreshStatus: false,
      }),
    });
    applyMonitoredResponse(res);
  } catch (e) {
    setError(String(e.message || e));
    await loadMonitored();
  }
}

async function saveNote(tg, note) {
  const mon = state.monitored.find((x) => x.tg === tg);
  if (mon && mon.note === note) return;
  if (mon) mon.note = note;
  try {
    const res = await api("monitored/note", {
      method: "POST",
      body: JSON.stringify({ tg, note }),
    });
    applyMonitoredResponse(res);
  } catch (e) {
    setError(String(e.message || e));
  }
}

function applyMonitoredResponse(res) {
  if (res.items && Array.isArray(res.items)) {
    state.monitored = res.items.map((it, i) => ({
      tg: Number(it.tg),
      order: Number(it.order ?? i),
      note: it.note || "",
    }));
  } else if (res.trunks) {
    state.monitored = res.trunks.map((tg, i) => ({
      tg: Number(tg),
      order: i,
      note: (state.monitored.find((m) => m.tg === Number(tg)) || {}).note || "",
    }));
  }
}

function renderTrunkMeta(data) {
  $("meta-updated").textContent = fmtTime(data && data.lastUpdate);
  if (data && data.host) $("meta-host").textContent = data.host;
  if (data && data.connected) {
    setSessionLabel("Monitoring (OSSI)", true);
  } else if (!state.connected) {
    setSessionLabel("已斷線", false);
  }
}

async function loadTrunkData() {
  const res = await api("trunk-data");
  const data = res.data || res;
  state.trunkItems = (data && data.items) || [];
  // keep notes from monitored when live items omit them
  renderTrunkMeta(data);
  renderTrunkTable();
  if (data.error) setError(data.error);
  else setError("");
  return data;
}

async function loadMonitored() {
  const res = await api("monitored");
  applyMonitoredResponse(res);
  renderTrunkTable();
}

async function openDetail(tg) {
  if (!state.connected) {
    setError("請先 Login 先睇 channel 詳情。");
    return;
  }
  state.detailTg = tg;
  $("trunk-list-view").hidden = true;
  $("trunk-detail-view").hidden = false;
  $("detail-title").textContent = `TG ${tg}`;
  $("detail-meta").textContent = "Loading…";
  $("detail-tbody").innerHTML = `<tr class="empty"><td colspan="5">Loading…</td></tr>`;
  await loadDetail(tg);
}

async function loadDetail(tg) {
  try {
    const res = await api(`trunks/${tg}/detail`);
    const mon = state.monitored.find((m) => m.tg === tg);
    const note = (res.note || (mon && mon.note) || "").trim();
    $("detail-title").textContent = `TG ${tg}${res.name ? " · " + res.name : ""}`;
    $("detail-meta").textContent = [
      res.type ? res.type : "",
      res.tac ? "TAC " + res.tac : "",
      note ? "Note: " + note : "",
      res.counts
        ? `Total ${res.counts.total ?? "—"} · Idle ${res.counts.idle ?? "—"} · Busy ${res.counts.busy ?? "—"}`
        : "",
    ]
      .filter(Boolean)
      .join(" · ");

    const channels = res.channels || [];
    const tbody = $("detail-tbody");
    if (!channels.length) {
      tbody.innerHTML = `<tr class="empty"><td colspan="5">${
        res.error || "無 channel 資料（或 parse 唔到）。"
      }</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    for (const ch of channels) {
      const tr = document.createElement("tr");
      const busy = String(ch.busy || "").toLowerCase() === "yes";
      tr.innerHTML = `
        <td class="mono">${escapeHtml(ch.member || "")}</td>
        <td class="mono">${escapeHtml(ch.port || "—")}</td>
        <td>${escapeHtml(ch.state || "—")}</td>
        <td>${busy ? '<span class="badge yellow"><span class="dot"></span>yes</span>' : "no"}</td>
        <td class="mono">${escapeHtml(ch.connected || "—")}</td>
      `;
      tbody.appendChild(tr);
    }
  } catch (e) {
    $("detail-tbody").innerHTML = `<tr class="empty"><td colspan="5">${escapeHtml(
      String(e.message || e)
    )}</td></tr>`;
  }
}

function closeDetail() {
  state.detailTg = null;
  $("trunk-detail-view").hidden = true;
  $("trunk-list-view").hidden = false;
}

async function connect() {
  setError("");
  setStatus("Login… 自動啟動 OSSI bridge → 連 CM → 開始 monitor…");
  setSessionLabel("Connecting…", false);
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
    const res = await api("session/connect", { method: "POST", body: JSON.stringify(body) });
    state.connected = true;
    state.disconnecting = false;
    $("meta-host").textContent = res.host || body.host;
    setSessionLabel("Monitoring (OSSI)", true);
    setStatus("已登入。開住呢頁先會 refresh（60s）。熄頁 / 關 tab 會斷 OSSI。");
    applyUiMode();
    await loadMonitored();
    if (res.trunkData) {
      const td = res.trunkData;
      state.trunkItems = (td.items || td.Items || []) ;
      renderTrunkMeta(td);
      renderTrunkTable();
    } else {
      await loadTrunkData();
    }
    $("chk-auto").checked = true;
    scheduleAuto();
    startHeartbeat();
  } catch (e) {
    state.connected = false;
    setError(String(e.message || e));
    setSessionLabel("已斷線", false);
    setStatus("");
    applyUiMode();
  } finally {
    $("btn-connect").disabled = false;
  }
}

function stopHeartbeat() {
  if (state.heartbeatTimer) {
    clearInterval(state.heartbeatTimer);
    state.heartbeatTimer = null;
  }
}

function startHeartbeat() {
  stopHeartbeat();
  state.heartbeatTimer = setInterval(() => {
    if (!state.connected) return;
    api("session/heartbeat", { method: "POST", body: "{}" }).catch(() => {});
  }, 30_000);
  api("session/heartbeat", { method: "POST", body: "{}" }).catch(() => {});
}

function disconnectOnPageClose() {
  if (!state.connected || state.disconnecting) return;
  state.disconnecting = true;
  state.connected = false;
  stopHeartbeat();
  clearAuto();
  try {
    const url = apiUrl("session/disconnect");
    const blob = new Blob(["{}"], { type: "application/json" });
    if (navigator.sendBeacon) {
      navigator.sendBeacon(url, blob);
    } else {
      fetch(url, {
        method: "POST",
        body: "{}",
        headers: { "Content-Type": "application/json" },
        keepalive: true,
      });
    }
  } catch {
    /* ignore */
  }
}

async function disconnect() {
  state.disconnecting = true;
  stopHeartbeat();
  try {
    await api("session/disconnect", { method: "POST", body: "{}" });
  } catch {
    /* ignore */
  }
  state.connected = false;
  state.disconnecting = false;
  setSessionLabel("已斷線", false);
  setStatus("已 Logout — OSSI session 已斷。");
  clearAuto();
  closeDetail();
  applyUiMode();
}

async function refreshNow() {
  setStatus("Refreshing via OSSI…");
  try {
    await api("refresh", { method: "POST", body: "{}" });
    await loadTrunkData();
    if (state.detailTg) await loadDetail(state.detailTg);
    setStatus("Refresh complete.");
  } catch (e) {
    setError(String(e.message || e));
  }
}

async function addTg() {
  const tg = Number($("inp-tg").value);
  const note = ($("inp-tg-note").value || "").trim();
  if (!tg || tg < 1) {
    setError("請輸入有效 TG 號碼。");
    return;
  }
  setError("");
  try {
    const res = await api("monitored/add", {
      method: "POST",
      body: JSON.stringify({ tg, note }),
    });
    applyMonitoredResponse(res);
    $("inp-tg").value = "";
    $("inp-tg-note").value = "";
    if (state.connected) await loadTrunkData();
    else renderTrunkTable();
  } catch (e) {
    setError(String(e.message || e));
  }
}

async function removeTg(tg) {
  try {
    const res = await api("monitored/remove", { method: "POST", body: JSON.stringify({ tg }) });
    applyMonitoredResponse(res);
    if (state.detailTg === tg) closeDetail();
    if (state.connected) await loadTrunkData();
    else renderTrunkTable();
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
    if (!state.connected) return;
    try {
      await loadTrunkData();
      if (state.detailTg) await loadDetail(state.detailTg);
    } catch {
      /* quiet poll miss */
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
  $("btn-detail-back").addEventListener("click", closeDetail);
  $("btn-detail-refresh").addEventListener("click", () => {
    if (state.detailTg) loadDetail(state.detailTg);
  });
  $("inp-tg").addEventListener("keydown", (e) => {
    if (e.key === "Enter") addTg();
  });
  $("inp-tg-note").addEventListener("keydown", (e) => {
    if (e.key === "Enter") addTg();
  });
  $("chk-auto").addEventListener("change", () => {
    if (state.connected) scheduleAuto();
    else clearAuto();
  });

  window.addEventListener("pagehide", disconnectOnPageClose);
  window.addEventListener("beforeunload", disconnectOnPageClose);

  applyUiMode();

  try {
    await loadMonitored();
    await loadTrunkData();
    const st = await api("session/status");
    if (st.connected) {
      state.connected = true;
      $("meta-host").textContent = st.host || "—";
      setSessionLabel("Connected (OSSI)", true);
      applyUiMode();
      scheduleAuto();
      startHeartbeat();
    }
  } catch {
    /* offline bridge */
  }

  try {
    const h = await api("health?ensure=1");
    if (h && h.bridgeHealthy) {
      setStatus("就緒：填 IP / Password → 撳 Login 即開始 monitor。");
    } else if (h && h.bridgeError) {
      setStatus("API 已上。Login 時會再試自動開 bridge。 " + (h.bridgeError || ""));
    } else {
      setStatus("就緒：填 IP / Password → 撳 Login。");
    }
  } catch {
    setStatus("API 未就緒 — 檢查 IIS /CM/api。就緒後只需 Login。");
  }
}

init();
