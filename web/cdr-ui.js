/**
 * CDR tab — real daily files via /CM/api/cdr/*
 * Search / Daily / Weekly / Monthly with progress popup (file-by-file %).
 */

function pad2(n) {
  return String(n).padStart(2, "0");
}

function toDateInputValue(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function toMonthInputValue(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}`;
}

function ymdFromInput(s) {
  return (s || "").replace(/-/g, "");
}

function parseLocalDate(s) {
  if (!s) return null;
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
}

function addDays(d, n) {
  const x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  x.setDate(x.getDate() + n);
  return x;
}

function fmtDur(sec) {
  const s = Math.max(0, Math.round(Number(sec) || 0));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${pad2(r)}`;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function apiUrl(path) {
  let dir = window.location.pathname || "/";
  if (/\.html?$/i.test(dir)) dir = dir.replace(/\/[^/]*$/, "/");
  else if (!dir.endsWith("/")) dir += "/";
  return dir + "api/" + String(path).replace(/^\//, "");
}

async function apiGet(path) {
  const res = await fetch(apiUrl(path), { credentials: "same-origin" });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }
  if (!res.ok) throw new Error((body && (body.error || body.Error)) || res.statusText);
  return body;
}

const CDR = {
  lastSearch: [],
  busy: false,
};

/* ---------- progress modal ---------- */
function showProgress(title, sub) {
  const m = document.getElementById("progress-modal");
  if (!m) return;
  m.hidden = false;
  document.getElementById("progress-modal-title").textContent = title || "Working…";
  document.getElementById("progress-modal-sub").textContent = sub || "Please wait…";
  document.getElementById("progress-modal-detail").textContent = "";
  document.getElementById("progress-bar-fill").style.width = "0%";
  document.getElementById("progress-pct").textContent = "0%";
  document.getElementById("progress-modal-spinner").className = "modal-spinner";
  document.getElementById("btn-progress-close").hidden = true;
}

function setProgress(pct, detail) {
  const p = Math.max(0, Math.min(100, Math.round(pct)));
  const fill = document.getElementById("progress-bar-fill");
  const label = document.getElementById("progress-pct");
  if (fill) fill.style.width = p + "%";
  if (label) label.textContent = p + "%";
  if (detail != null) {
    const el = document.getElementById("progress-modal-detail");
    if (el) el.textContent = detail;
  }
}

function hideProgress(delayMs = 0) {
  const m = document.getElementById("progress-modal");
  if (!m) return;
  const go = () => {
    m.hidden = true;
  };
  if (delayMs > 0) setTimeout(go, delayMs);
  else go();
}

function finishProgress(ok, message) {
  document.getElementById("progress-modal-spinner").className = ok
    ? "modal-spinner done"
    : "modal-spinner fail";
  document.getElementById("progress-modal-sub").textContent = message || (ok ? "Done" : "Failed");
  if (!ok) document.getElementById("btn-progress-close").hidden = false;
  else hideProgress(500);
}

function renderHourChart(el, counts) {
  if (!el) return;
  const max = Math.max(1, ...counts);
  el.innerHTML = counts
    .map((c, hour) => {
      const pct = Math.round((c / max) * 100);
      const peak = c === max && c > 0;
      return `<div class="hour-bar-wrap" title="${hour}:00 — ${c} calls">
        <div class="hour-bar ${peak ? "peak" : ""}" style="height:${Math.max(2, pct)}%"></div>
        <span class="hour-n">${c || ""}</span>
      </div>`;
    })
    .join("");
}

function renderKpis(el, items) {
  if (!el) return;
  el.innerHTML = items
    .map(
      (it) => `<div class="cdr-kpi">
      <div class="cdr-kpi-v">${escapeHtml(String(it.value))}</div>
      <div class="cdr-kpi-k">${escapeHtml(it.label)}</div>
    </div>`
    )
    .join("");
}

function emptyHourly() {
  return Array(24).fill(0);
}

function addHourly(a, b) {
  for (let i = 0; i < 24; i++) a[i] += b[i] || 0;
  return a;
}

function peakOf(counts) {
  let max = -1;
  let hour = 0;
  for (let i = 0; i < 24; i++) {
    if (counts[i] > max) {
      max = counts[i];
      hour = i;
    }
  }
  return { hour, count: Math.max(0, max) };
}

function getFilterFromForm() {
  return {
    calling: document.getElementById("cdr-calling")?.value || "",
    called: document.getElementById("cdr-called")?.value || "",
    trunk: document.getElementById("cdr-trunk")?.value || "",
    dir: document.getElementById("cdr-dir")?.value || "",
    minDur: "0",
  };
}

/** Avaya CM condition code → short English (common set; non-59-char formats). */
function condLabel(code) {
  const c = String(code || "").trim().toUpperCase();
  const map = {
    "0": "Intra-switch",
    "1": "Attendant",
    "3": "Conference",
    "4": "Long call",
    "6": "ISDN/data",
    "7": "Outgoing",
    "8": "In→Attn",
    "9": "Incoming",
    A: "Outgoing",
    B: "Adjunct out",
    C: "Conference",
    E: "Feature",
    F: "Forwarded",
    G: "AAR/ARS",
    H: "Headset",
    I: "Incomplete",
    J: "DID/attendant",
    K: "Lookahead",
    L: "Conference",
    M: "MWI",
    N: "Network",
    P: "Personal CO",
    R: "Ringdown",
    S: "Serial",
    T: "Redirected",
    U: "Unattended",
  };
  if (!c) return "—";
  const name = map[c];
  return name ? `${c} · ${name}` : c;
}

/**
 * NOC-friendly party / TAC view.
 * TAC1 = code-used (often out TAC / access code)
 * TAC2 = in-trk (incoming trunk TAC) — empty on pure outbound when CM leaves it blank
 */
function partyView(r) {
  const dir = (r.dir || "").toLowerCase();
  const calling = (r.callingNum || r.clgNum || "").trim();
  const dialed = (r.dialedNum || "").trim();
  const clg = (r.clgNum || "").trim();
  const tac1 = (r.codeUsed || r.codeDial || "").trim();
  const tac2 = (r.inTrk || "").trim();

  if (dir === "in" || r.cond === "9") {
    return {
      from: calling || clg || "—",
      to: dialed || "—",
      tac1: tac1 || "—",
      tac2: tac2 || "—",
    };
  }
  if (dir === "out" || r.cond === "7" || r.cond === "A") {
    return {
      from: clg || calling || "—",
      to: dialed || "—",
      tac1: tac1 || "—",
      tac2: tac2 || "—",
    };
  }
  return {
    from: calling || clg || "—",
    to: dialed || "—",
    tac1: tac1 || "—",
    tac2: tac2 || "—",
  };
}

function qs(params) {
  const u = new URLSearchParams();
  Object.entries(params).forEach(([k, v]) => {
    if (v !== "" && v != null) u.set(k, v);
  });
  return u.toString();
}

/** Enumerate yyyyMMdd keys for a calendar range (inclusive). */
function eachDayKey(fromYmd, toYmd) {
  const out = [];
  let d = parseLocalDate(
    `${fromYmd.slice(0, 4)}-${fromYmd.slice(4, 6)}-${fromYmd.slice(6, 8)}`
  );
  const end = parseLocalDate(`${toYmd.slice(0, 4)}-${toYmd.slice(4, 6)}-${toYmd.slice(6, 8)}`);
  if (!d || !end) return out;
  while (d <= end) {
    out.push(
      `${d.getFullYear()}${pad2(d.getMonth() + 1)}${pad2(d.getDate())}`
    );
    d = addDays(d, 1);
  }
  return out;
}

async function scanDay(ymd, filter, maxMatches = 500) {
  const dateIso = `${ymd.slice(0, 4)}-${ymd.slice(4, 6)}-${ymd.slice(6, 8)}`;
  const q = qs({
    date: dateIso,
    calling: filter.calling,
    called: filter.called,
    trunk: filter.trunk,
    dir: filter.dir,
    minDur: filter.minDur,
    maxMatches,
  });
  return apiGet("cdr/scan-day?" + q);
}

/**
 * Scan many days with progress callback.
 * @param {string[]} dayKeys yyyyMMdd
 * @param {(pct:number, detail:string, dayResult:object)=>void} onProgress
 */
async function scanDays(dayKeys, filter, onProgress, maxMatchesPerDay = 500) {
  const results = [];
  const n = Math.max(1, dayKeys.length);
  for (let i = 0; i < dayKeys.length; i++) {
    const ymd = dayKeys[i];
    const r = await scanDay(ymd, filter, maxMatchesPerDay);
    results.push(r);
    const pct = ((i + 1) / n) * 100;
    const detail = `Scanning ${ymd}.txt  (${i + 1}/${dayKeys.length})` +
      (r.fileExists ? ` · ${r.totalInFile || 0} rows` : " · file missing");
    onProgress(pct, detail, r);
  }
  return results;
}

async function runSearch() {
  if (CDR.busy) return;
  CDR.busy = true;
  const from = document.getElementById("cdr-from")?.value;
  const to = document.getElementById("cdr-to")?.value;
  if (!from || !to) {
    alert("Please set From and To dates.");
    CDR.busy = false;
    return;
  }
  const filter = getFilterFromForm();
  const fromKey = ymdFromInput(from);
  const toKey = ymdFromInput(to);

  showProgress("CDR Search", "Listing daily files…");
  try {
    // Prefer only days that exist (faster progress)
    const files = await apiGet(`cdr/files?from=${from}&to=${to}`);
    let days = files.days || [];
    if (!days.length) {
      // still walk calendar so user sees 100% over empty range
      days = eachDayKey(fromKey, toKey);
    }
    if (!days.length) {
      finishProgress(false, "No days in range");
      CDR.busy = false;
      return;
    }

    setProgress(0, `0 / ${days.length} files`);
    const allMatches = [];
    let totalMatch = 0;
    let totalRows = 0;
    let filesHit = 0;

    await scanDays(days, filter, (pct, detail, day) => {
      setProgress(pct, detail);
      if (day.fileExists) filesHit++;
      totalRows += day.totalInFile || 0;
      totalMatch += day.matchCountTotal ?? day.matchCount ?? 0;
      for (const m of day.matches || []) allMatches.push(m);
    }, 300);

    // sort by recv time desc
    allMatches.sort((a, b) => String(b.recvLocal).localeCompare(String(a.recvLocal)));
    CDR.lastSearch = allMatches;

    const meta = document.getElementById("cdr-search-meta");
    const show = allMatches.slice(0, 500);
    if (meta) {
      meta.textContent =
        `Matched ${totalMatch} call(s) in ${filesHit} file(s) · scanned ${totalRows} rows · showing ${show.length}` +
        (totalMatch > show.length ? " (capped)" : "");
    }
    renderSearchTable(show);
    setProgress(100, "Complete");
    finishProgress(true, `Found ${totalMatch} record(s)`);
  } catch (e) {
    finishProgress(false, String(e.message || e));
    document.getElementById("btn-progress-close").hidden = false;
  } finally {
    CDR.busy = false;
  }
}

function renderSearchTable(rows) {
  const tbody = document.getElementById("cdr-result-tbody");
  if (!tbody) return;
  if (!rows.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="9">No matching records.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map((r) => {
      const p = partyView(r);
      const dir = (r.dir || "").toLowerCase();
      return `<tr>
        <td class="mono">${escapeHtml(r.recvLocal || "")}</td>
        <td>${dir ? `<span class="dir-pill ${dir}">${dir}</span>` : "—"}</td>
        <td class="mono">${escapeHtml(p.from)}</td>
        <td class="mono">${escapeHtml(p.to)}</td>
        <td class="mono" title="TAC1 = code-used (out TAC / access)">${escapeHtml(p.tac1)}</td>
        <td class="mono" title="TAC2 = incoming trunk TAC">${escapeHtml(p.tac2)}</td>
        <td class="mono">${fmtDur(r.durationSec)}</td>
        <td class="mono" title="Avaya condition code">${escapeHtml(condLabel(r.cond))}</td>
      </tr>`;
    })
    .join("");
}

async function calcDaily() {
  if (CDR.busy) return;
  CDR.busy = true;
  const day = document.getElementById("cdr-day")?.value;
  if (!day) {
    alert("Pick a day");
    CDR.busy = false;
    return;
  }
  showProgress("Daily hourly", "Scanning day file…");
  try {
    const ymd = ymdFromInput(day);
    setProgress(10, `${ymd}.txt`);
    const r = await scanDay(ymd, {}, 1);
    setProgress(100, r.fileExists ? `OK · ${r.totalInFile} rows` : "File not found");
    const hourly = r.hourly || emptyHourly();
    const peak = peakOf(hourly);
    const total = hourly.reduce((a, b) => a + b, 0);
    renderHourChart(document.getElementById("cdr-daily-chart"), hourly);
    renderKpis(document.getElementById("cdr-daily-kpi"), [
      { label: "Calls (day)", value: total },
      { label: "Peak hour", value: `${peak.hour}:00 (${peak.count})` },
      { label: "File", value: r.fileExists ? r.fileName || ymd + ".txt" : "missing" },
      { label: "Parsed OK", value: r.parseOk ?? "—" },
    ]);
    finishProgress(true, r.fileExists ? "Daily chart ready" : "No file for that day");
  } catch (e) {
    finishProgress(false, String(e.message || e));
    document.getElementById("btn-progress-close").hidden = false;
  } finally {
    CDR.busy = false;
  }
}

async function calcWeekly() {
  if (CDR.busy) return;
  CDR.busy = true;
  const startStr = document.getElementById("cdr-week-start")?.value;
  if (!startStr) {
    alert("Pick week start date");
    CDR.busy = false;
    return;
  }
  const start = parseLocalDate(startStr);
  const days = [];
  for (let i = 0; i < 7; i++) {
    const d = addDays(start, i);
    days.push(`${d.getFullYear()}${pad2(d.getMonth() + 1)}${pad2(d.getDate())}`);
  }
  showProgress("Weekly hourly", "Scanning 7 daily files…");
  try {
    const hourly = emptyHourly();
    let total = 0;
    let filesHit = 0;
    await scanDays(days, {}, (pct, detail, day) => {
      setProgress(pct, detail);
      if (day.fileExists) {
        filesHit++;
        addHourly(hourly, day.hourly || emptyHourly());
        total += (day.hourly || []).reduce((a, b) => a + b, 0);
      }
    }, 1);
    const peak = peakOf(hourly);
    renderHourChart(document.getElementById("cdr-weekly-chart"), hourly);
    renderKpis(document.getElementById("cdr-weekly-kpi"), [
      { label: "Calls (7 days)", value: total },
      { label: "Peak hour", value: `${peak.hour}:00 (${peak.count})` },
      { label: "Files found", value: `${filesHit} / 7` },
      { label: "Avg / day", value: filesHit ? Math.round(total / filesHit) : 0 },
    ]);
    setProgress(100, "Complete");
    finishProgress(true, "Weekly chart ready");
  } catch (e) {
    finishProgress(false, String(e.message || e));
    document.getElementById("btn-progress-close").hidden = false;
  } finally {
    CDR.busy = false;
  }
}

async function calcMonthly() {
  if (CDR.busy) return;
  CDR.busy = true;
  const monthStr = document.getElementById("cdr-month")?.value;
  if (!monthStr) {
    alert("Pick a month");
    CDR.busy = false;
    return;
  }
  const [y, m] = monthStr.split("-").map(Number);
  const from = `${y}-${pad2(m)}-01`;
  const last = new Date(y, m, 0).getDate();
  const to = `${y}-${pad2(m)}-${pad2(last)}`;

  showProgress("Monthly hourly", "Listing month files…");
  try {
    const files = await apiGet(`cdr/files?from=${from}&to=${to}`);
    let days = files.days || [];
    if (!days.length) {
      // generate all calendar days so progress still moves
      days = eachDayKey(ymdFromInput(from), ymdFromInput(to));
    }
    const hourly = emptyHourly();
    let total = 0;
    let filesHit = 0;
    await scanDays(days, {}, (pct, detail, day) => {
      setProgress(pct, detail);
      if (day.fileExists) {
        filesHit++;
        addHourly(hourly, day.hourly || emptyHourly());
        total += (day.hourly || []).reduce((a, b) => a + b, 0);
      }
    }, 1);
    const peak = peakOf(hourly);
    renderHourChart(document.getElementById("cdr-monthly-chart"), hourly);
    renderKpis(document.getElementById("cdr-monthly-kpi"), [
      { label: "Calls (month)", value: total },
      { label: "Peak hour", value: `${peak.hour}:00 (${peak.count})` },
      { label: "Files found", value: filesHit },
      { label: "Days in month", value: last },
    ]);
    setProgress(100, "Complete");
    finishProgress(true, "Monthly chart ready");
  } catch (e) {
    finishProgress(false, String(e.message || e));
    document.getElementById("btn-progress-close").hidden = false;
  } finally {
    CDR.busy = false;
  }
}

function exportCsv() {
  const rows = CDR.lastSearch || [];
  if (!rows.length) {
    alert("Run Search first.");
    return;
  }
  // Excel-friendly: UTF-8 BOM + comma CSV; open in Excel → Data/Sort works
  const header = [
    "Recv time",
    "Dir",
    "Calling From",
    "Called To",
    "TAC1",
    "TAC2",
    "Duration sec",
    "Cond",
    "Cond meaning",
  ];
  const lines = [header.join(",")];
  for (const r of rows) {
    const p = partyView(r);
    const cond = String(r.cond || "").trim();
    const meaning = condLabel(cond).includes("·")
      ? condLabel(cond).split("·")[1].trim()
      : "";
    lines.push(
      [r.recvLocal, r.dir, p.from, p.to, p.tac1, p.tac2, r.durationSec, cond, meaning]
        .map((x) => `"${String(x ?? "").replace(/"/g, '""')}"`)
        .join(",")
    );
  }
  const bom = "\uFEFF";
  const blob = new Blob([bom + lines.join("\r\n")], {
    type: "text/csv;charset=utf-8",
  });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `cdr-export-${toDateInputValue(new Date())}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

async function refreshCdrStatus() {
  const el = document.getElementById("cdr-status-line");
  const rel = document.getElementById("cdr-rel-path");
  try {
    const st = await apiGet("cdr/status");
    // Path is site-relative: <siteRoot>/cdr-link/cdr — not a fixed PC drive letter in logic
    if (rel) rel.textContent = "cdr-link/cdr/YYYYMMDD.txt";
    if (el) {
      el.textContent = st.dayCount
        ? `${st.dayCount} day file(s) · latest ${st.latest}.txt`
        : "No .txt files yet — is CDR logger running?";
    }
    document.getElementById("cdr-live-banner")?.classList.remove("warn");
  } catch (e) {
    if (el) el.textContent = "API error: " + (e.message || e);
    document.getElementById("cdr-live-banner")?.classList.add("warn");
  }
}

export function initCdrUi() {
  const now = new Date();
  const from = addDays(now, -7);
  const weekStart = addDays(now, -((now.getDay() + 6) % 7)); // Monday-start

  const elFrom = document.getElementById("cdr-from");
  const elTo = document.getElementById("cdr-to");
  const elDay = document.getElementById("cdr-day");
  const elWeek = document.getElementById("cdr-week-start");
  const elMonth = document.getElementById("cdr-month");
  if (elFrom) elFrom.value = toDateInputValue(from);
  if (elTo) elTo.value = toDateInputValue(now);
  if (elDay) elDay.value = toDateInputValue(now);
  if (elWeek) elWeek.value = toDateInputValue(weekStart);
  if (elMonth) elMonth.value = toMonthInputValue(now);

  document.getElementById("btn-cdr-search")?.addEventListener("click", runSearch);
  document.getElementById("btn-cdr-export")?.addEventListener("click", exportCsv);
  document.getElementById("btn-cdr-calc-daily")?.addEventListener("click", calcDaily);
  document.getElementById("btn-cdr-calc-weekly")?.addEventListener("click", calcWeekly);
  document.getElementById("btn-cdr-calc-monthly")?.addEventListener("click", calcMonthly);
  document.getElementById("btn-progress-close")?.addEventListener("click", () => hideProgress());

  // empty charts until Calculate
  renderHourChart(document.getElementById("cdr-daily-chart"), emptyHourly());
  renderHourChart(document.getElementById("cdr-weekly-chart"), emptyHourly());
  renderHourChart(document.getElementById("cdr-monthly-chart"), emptyHourly());
  renderKpis(document.getElementById("cdr-daily-kpi"), [
    { label: "Calls (day)", value: "—" },
    { label: "Peak hour", value: "—" },
  ]);
  renderKpis(document.getElementById("cdr-weekly-kpi"), [
    { label: "Calls (7 days)", value: "—" },
    { label: "Peak hour", value: "—" },
  ]);
  renderKpis(document.getElementById("cdr-monthly-kpi"), [
    { label: "Calls (month)", value: "—" },
    { label: "Peak hour", value: "—" },
  ]);

  refreshCdrStatus();
}

export function onCdrTabShow() {
  refreshCdrStatus();
}
