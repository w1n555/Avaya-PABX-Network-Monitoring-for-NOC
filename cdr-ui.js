/**
 * CDR tab UI — mock data only (real CM CDR logger later).
 * Search · Daily hourly · Monthly hourly · Trunk size estimate
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

function parseLocalDate(s) {
  if (!s) return null;
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d, 0, 0, 0, 0);
}

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function fmtDur(sec) {
  const s = Math.max(0, Math.round(sec));
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

/** Deterministic pseudo-random 0..1 from seed */
function prand(seed) {
  const x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
}

/**
 * Build mock CDR rows for last ~35 days.
 * Busy hours: 10–12, 14–17 weekdays; lighter nights/weekends.
 */
function generateMockCdr(now = new Date()) {
  const tgs = [1, 2, 3, 11, 12, 13];
  const rows = [];
  let id = 1;
  const day0 = startOfDay(now);

  for (let dayOffset = 34; dayOffset >= 0; dayOffset--) {
    const day = new Date(day0);
    day.setDate(day.getDate() - dayOffset);
    const dow = day.getDay(); // 0 Sun
    const weekend = dow === 0 || dow === 6;

    for (let hour = 0; hour < 24; hour++) {
      let base = 2;
      if (hour >= 9 && hour <= 11) base = weekend ? 8 : 28;
      else if (hour >= 14 && hour <= 17) base = weekend ? 10 : 32;
      else if (hour >= 12 && hour <= 13) base = weekend ? 6 : 18;
      else if (hour >= 18 && hour <= 20) base = weekend ? 12 : 14;
      else if (hour >= 7 && hour <= 8) base = weekend ? 4 : 12;
      else if (hour >= 21 || hour <= 6) base = weekend ? 1 : 3;

      const jitter = Math.floor(prand(dayOffset * 100 + hour) * 8) - 2;
      const n = Math.max(0, base + jitter);

      for (let i = 0; i < n; i++) {
        const seed = dayOffset * 10000 + hour * 100 + i;
        const minute = Math.floor(prand(seed + 1) * 60);
        const second = Math.floor(prand(seed + 2) * 60);
        const end = new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute, second);
        const dur = 15 + Math.floor(prand(seed + 3) * 420); // 15s–7min
        const dir = prand(seed + 4) > 0.42 ? "out" : "in";
        const tg = tgs[Math.floor(prand(seed + 5) * tgs.length)];
        const ext = 2000 + Math.floor(prand(seed + 6) * 800);
        const external =
          dir === "out"
            ? `8529${String(10000000 + Math.floor(prand(seed + 7) * 89999999)).slice(0, 8)}`
            : `8526${String(10000000 + Math.floor(prand(seed + 8) * 89999999)).slice(0, 8)}`;

        rows.push({
          id: id++,
          endTime: end.toISOString(),
          endLocal: end,
          dir,
          calling: dir === "out" ? String(ext) : external,
          called: dir === "out" ? external : String(ext),
          tg,
          durationSec: dur,
          cond: prand(seed + 9) > 0.92 ? "7" : "9", // mock condition codes
          mock: true,
        });
      }
    }
  }
  return rows;
}

const CDR = {
  all: [],
  lastSearch: [],
};

function ensureMock() {
  if (!CDR.all.length) CDR.all = generateMockCdr();
}

function filterCdr(opts) {
  ensureMock();
  const from = opts.from ? startOfDay(parseLocalDate(opts.from)) : null;
  let to = opts.to ? startOfDay(parseLocalDate(opts.to)) : null;
  if (to) to = new Date(to.getTime() + 86400000 - 1);

  const calling = (opts.calling || "").trim();
  const called = (opts.called || "").trim();
  const trunk = (opts.trunk || "").trim().replace(/^tg/i, "");
  const dir = opts.dir || "";
  const minDur = Number(opts.minDur) || 0;

  return CDR.all.filter((r) => {
    if (from && r.endLocal < from) return false;
    if (to && r.endLocal > to) return false;
    if (calling && !String(r.calling).includes(calling)) return false;
    if (called && !String(r.called).includes(called)) return false;
    if (trunk && String(r.tg) !== String(trunk)) return false;
    if (dir && r.dir !== dir) return false;
    if (r.durationSec < minDur) return false;
    return true;
  });
}

function hourlyCounts(rows) {
  const h = Array(24).fill(0);
  for (const r of rows) h[r.endLocal.getHours()]++;
  return h;
}

function renderHourChart(el, counts) {
  if (!el) return;
  const max = Math.max(1, ...counts);
  el.innerHTML = counts
    .map((c, hour) => {
      const pct = Math.round((c / max) * 100);
      const peak = c === max && c > 0;
      return `<div class="hour-bar-wrap" title="${hour}:00 — ${c} calls">
        <div class="hour-bar ${peak ? "peak" : ""}" style="height:${pct}%"></div>
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

function runSearch() {
  const opts = {
    from: document.getElementById("cdr-from")?.value,
    to: document.getElementById("cdr-to")?.value,
    calling: document.getElementById("cdr-calling")?.value,
    called: document.getElementById("cdr-called")?.value,
    trunk: document.getElementById("cdr-trunk")?.value,
    dir: document.getElementById("cdr-dir")?.value,
    minDur: document.getElementById("cdr-min-dur")?.value,
  };
  let rows = filterCdr(opts);
  rows = rows.slice().sort((a, b) => b.endLocal - a.endLocal);
  CDR.lastSearch = rows;

  const meta = document.getElementById("cdr-search-meta");
  const tbody = document.getElementById("cdr-result-tbody");
  const maxShow = 200;
  if (meta) {
    meta.textContent = `Found ${rows.length} mock record(s)${
      rows.length > maxShow ? ` · showing first ${maxShow}` : ""
    } · UI preview only`;
  }
  if (!tbody) return;
  if (!rows.length) {
    tbody.innerHTML = `<tr class="empty"><td colspan="7">No mock records match.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .slice(0, maxShow)
    .map((r) => {
      const t = r.endLocal;
      const ts = `${toDateInputValue(t)} ${pad2(t.getHours())}:${pad2(t.getMinutes())}:${pad2(t.getSeconds())}`;
      return `<tr>
        <td class="mono">${ts}</td>
        <td><span class="dir-pill ${r.dir}">${r.dir}</span></td>
        <td class="mono">${escapeHtml(r.calling)}</td>
        <td class="mono">${escapeHtml(r.called)}</td>
        <td>TG ${r.tg}</td>
        <td class="mono">${fmtDur(r.durationSec)}</td>
        <td class="mono">${escapeHtml(r.cond)}</td>
      </tr>`;
    })
    .join("");
}

function refreshDailyChart() {
  ensureMock();
  const dayStr = document.getElementById("cdr-day")?.value;
  const day = dayStr ? startOfDay(parseLocalDate(dayStr)) : startOfDay(new Date());
  const next = new Date(day.getTime() + 86400000);
  const rows = CDR.all.filter((r) => r.endLocal >= day && r.endLocal < next);
  const counts = hourlyCounts(rows);
  const peakHour = counts.indexOf(Math.max(...counts));
  const total = rows.length;
  const avgDur =
    total > 0 ? Math.round(rows.reduce((s, r) => s + r.durationSec, 0) / total) : 0;

  renderHourChart(document.getElementById("cdr-daily-chart"), counts);
  renderKpis(document.getElementById("cdr-daily-kpi"), [
    { label: "Calls (day)", value: total },
    { label: "Peak hour", value: `${peakHour}:00 (${counts[peakHour]})` },
    { label: "Avg duration", value: fmtDur(avgDur) },
    { label: "Talk minutes", value: Math.round(rows.reduce((s, r) => s + r.durationSec, 0) / 60) },
  ]);
}

function refreshMonthlyChart() {
  ensureMock();
  const monthStr = document.getElementById("cdr-month")?.value;
  let y;
  let m;
  if (monthStr) {
    [y, m] = monthStr.split("-").map(Number);
  } else {
    const n = new Date();
    y = n.getFullYear();
    m = n.getMonth() + 1;
  }
  const start = new Date(y, m - 1, 1);
  const end = new Date(y, m, 1);
  const rows = CDR.all.filter((r) => r.endLocal >= start && r.endLocal < end);
  const counts = hourlyCounts(rows);
  const peakHour = counts.indexOf(Math.max(...counts));
  const daysInMonth = new Date(y, m, 0).getDate();
  const daysWithData = new Set(rows.map((r) => r.endLocal.getDate())).size || 1;

  renderHourChart(document.getElementById("cdr-monthly-chart"), counts);
  renderKpis(document.getElementById("cdr-monthly-kpi"), [
    { label: "Calls (month)", value: rows.length },
    { label: "Peak hour (total)", value: `${peakHour}:00 (${counts[peakHour]})` },
    { label: "Avg calls / day", value: Math.round(rows.length / daysWithData) },
    { label: "Days covered", value: `${daysWithData} / ${daysInMonth}` },
  ]);
}

/** Erlang-ish rough check for trunk sizing */
function recalculateTrunkSize() {
  ensureMock();
  const dayStr = document.getElementById("cdr-day")?.value;
  const day = dayStr ? startOfDay(parseLocalDate(dayStr)) : startOfDay(new Date());
  const next = new Date(day.getTime() + 86400000);
  const rows = CDR.all.filter((r) => r.endLocal >= day && r.endLocal < next);
  const counts = hourlyCounts(rows);
  const peakCalls = Math.max(0, ...counts);
  const peakHour = counts.indexOf(peakCalls);
  const peakRows = rows.filter((r) => r.endLocal.getHours() === peakHour);
  const avgDur =
    peakRows.length > 0
      ? peakRows.reduce((s, r) => s + r.durationSec, 0) / peakRows.length
      : rows.length
        ? rows.reduce((s, r) => s + r.durationSec, 0) / rows.length
        : 120;

  const erlang = (peakCalls * avgDur) / 3600;
  const channels = Math.max(1, Number(document.getElementById("cdr-trunk-size")?.value) || 23);
  const targetUtil = Math.min(95, Math.max(30, Number(document.getElementById("cdr-target-util")?.value) || 70)) / 100;
  const util = erlang / channels;
  const headroom = channels - erlang;
  const suggested = Math.max(1, Math.ceil(erlang / targetUtil));

  let verdict = "ok";
  let title = "OK — headroom looks reasonable";
  let detail = "Peak-hour offered load is within target util of provisioned channels (mock estimate).";
  if (util >= 0.9) {
    verdict = "high";
    title = "Tight / possibly undersized";
    detail = "Peak offered load is near or above channel count. Consider more trunks or overflow.";
  } else if (util >= targetUtil) {
    verdict = "warn";
    title = "Above target util";
    detail = "Working hard at busy hour. Watch grade of service; sizing may be tight.";
  } else if (util < 0.35 && channels > suggested + 8) {
    verdict = "over";
    title = "Possibly oversized";
    detail = "Peak load is low vs members. Trunks may be more than needed (cost / capacity).";
  }

  const el = document.getElementById("cdr-size-result");
  if (!el) return;
  el.innerHTML = `
    <div class="size-verdict size-${verdict}">
      <div class="size-title">${escapeHtml(title)}</div>
      <div class="size-detail">${escapeHtml(detail)}</div>
    </div>
    <div class="cdr-kpi-row">
      <div class="cdr-kpi"><div class="cdr-kpi-v">${peakHour}:00</div><div class="cdr-kpi-k">Busy hour (mock day)</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${peakCalls}</div><div class="cdr-kpi-k">Calls in busy hour</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${fmtDur(avgDur)}</div><div class="cdr-kpi-k">Avg talk (busy hour)</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${erlang.toFixed(2)}</div><div class="cdr-kpi-k">Offered erlang (approx)</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${channels}</div><div class="cdr-kpi-k">Trunk members</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${(util * 100).toFixed(0)}%</div><div class="cdr-kpi-k">Load / channels</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${headroom.toFixed(1)}</div><div class="cdr-kpi-k">Spare erlang</div></div>
      <div class="cdr-kpi"><div class="cdr-kpi-v">${suggested}</div><div class="cdr-kpi-k">Suggested members @ target</div></div>
    </div>
    <p class="hint size-note">
      Mock only — not full Erlang-B GoS. When live CDR is on, same UI will use real busy-hour counts.
      Concurrent peak can exceed this simple offered-load model.
    </p>
  `;
}

function exportCsv() {
  const rows = CDR.lastSearch.length ? CDR.lastSearch : filterCdr({
    from: document.getElementById("cdr-from")?.value,
    to: document.getElementById("cdr-to")?.value,
  });
  const header = ["end_time", "dir", "calling", "called", "tg", "duration_sec", "cond", "mock"];
  const lines = [header.join(",")];
  for (const r of rows) {
    const t = r.endLocal;
    const ts = `${toDateInputValue(t)} ${pad2(t.getHours())}:${pad2(t.getMinutes())}:${pad2(t.getSeconds())}`;
    lines.push(
      [ts, r.dir, r.calling, r.called, r.tg, r.durationSec, r.cond, "1"]
        .map((x) => `"${String(x).replace(/"/g, '""')}"`)
        .join(",")
    );
  }
  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `cdr-mock-export-${toDateInputValue(new Date())}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

export function initCdrUi() {
  ensureMock();
  const now = new Date();
  const from = new Date(now);
  from.setDate(from.getDate() - 7);

  const elFrom = document.getElementById("cdr-from");
  const elTo = document.getElementById("cdr-to");
  const elDay = document.getElementById("cdr-day");
  const elMonth = document.getElementById("cdr-month");
  if (elFrom) elFrom.value = toDateInputValue(from);
  if (elTo) elTo.value = toDateInputValue(now);
  if (elDay) elDay.value = toDateInputValue(now);
  if (elMonth) elMonth.value = toMonthInputValue(now);

  document.getElementById("btn-cdr-search")?.addEventListener("click", runSearch);
  document.getElementById("btn-cdr-export")?.addEventListener("click", exportCsv);
  document.getElementById("btn-cdr-size")?.addEventListener("click", recalculateTrunkSize);
  elDay?.addEventListener("change", () => {
    refreshDailyChart();
    recalculateTrunkSize();
  });
  elMonth?.addEventListener("change", refreshMonthlyChart);

  ["cdr-from", "cdr-to", "cdr-calling", "cdr-called", "cdr-trunk", "cdr-dir", "cdr-min-dur"].forEach((id) => {
    document.getElementById(id)?.addEventListener("keydown", (e) => {
      if (e.key === "Enter") runSearch();
    });
  });

  runSearch();
  refreshDailyChart();
  refreshMonthlyChart();
  recalculateTrunkSize();
}

export function onCdrTabShow() {
  // refresh charts when user opens tab
  refreshDailyChart();
  refreshMonthlyChart();
}
