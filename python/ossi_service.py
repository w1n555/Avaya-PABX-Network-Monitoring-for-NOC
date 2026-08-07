#!/usr/bin/env python3
"""
Local OSSI bridge for Avaya NOC dashboard (read-only).

Uses installable package: avaya-ossi (AVAYA-OSSI-2026).
Listens on 127.0.0.1 only. Does not expose CM to the LAN.

Endpoints (JSON):
  GET  /health
  GET  /session
  POST /session/connect   {host,port,username,password,pin?}
  POST /session/disconnect
  POST /refresh           optional {force:true}
  GET  /monitored
  PUT  /monitored         {trunks:[1,2,3]}
  POST /monitored/add     {tg:1}
  POST /monitored/remove  {tg:1}

Writes:
  <data-dir>/trunk_data.json
  <data-dir>/monitored_trunks.json
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# Portable site root = parent of this python/ folder (any install path)
_SITE_ROOT = Path(__file__).resolve().parent.parent


def _bootstrap_path() -> None:
    """Prefer site venv imports; fall back to bundled vendor package only."""
    vendored = _SITE_ROOT / "vendor" / "avaya-ossi" / "src"
    if vendored.is_dir() and str(vendored) not in sys.path:
        sys.path.insert(0, str(vendored))


_bootstrap_path()

from avaya_ossi import OssiSession, SessionConfig  # noqa: E402
from trunk_parse import (  # noqa: E402
    parse_channel_counts,
    parse_channels,
    parse_trunk_groups,
    status_color,
    utilization_pct,
)

# ---------------------------------------------------------------------------
# Paths / state (defaults under install root; --data-dir can override)
# ---------------------------------------------------------------------------


class _Paths:
    data_dir: Path = _SITE_ROOT / "data"

    @property
    def monitored(self) -> Path:
        return self.data_dir / "monitored_trunks.json"

    @property
    def trunk_data(self) -> Path:
        return self.data_dir / "trunk_data.json"


PATHS = _Paths()
AUTO_REFRESH_SEC = 60
# If no UI heartbeat / page activity for this long → logoff OSSI (browser closed)
UI_GONE_SEC = 90
# Watchdog tick (check UI gone more often than full trunk refresh)
UI_WATCH_SEC = 15

_lock = threading.RLock()
# Serialize OSSI SSH commands only — do NOT hold _lock during long status trunk runs
# so heartbeat / trunk-data reads stay responsive.
_ossi_lock = threading.Lock()
_session: OssiSession | None = None
_cfg: SessionConfig | None = None
_connected = False
_host = ""
_username = ""
_last_error: str | None = None
_tg_catalog: dict[int, dict[str, Any]] = {}
_stop = threading.Event()
_last_ui_seen = 0.0  # time.monotonic(); 0 = no UI since process start
_last_refresh_at = 0.0
_refreshing = False


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _read_json(path: Path, default: Any) -> Any:
    if not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_monitored_items() -> list[dict[str, Any]]:
    """
    Preferred shape:
      { "items": [ {"tg":1,"order":0,"note":"..."}, ... ], "updatedAt": "..." }
    Legacy:
      { "trunks": [1,2,3] }
    """
    raw = _read_json(PATHS.monitored, {"items": [], "updatedAt": None})
    items: list[dict[str, Any]] = []
    seen: set[int] = set()

    if isinstance(raw, dict) and isinstance(raw.get("items"), list) and raw["items"]:
        for i, it in enumerate(raw["items"]):
            if not isinstance(it, dict):
                continue
            try:
                tg = int(it.get("tg") or 0)
            except (TypeError, ValueError):
                continue
            if tg < 1 or tg in seen:
                continue
            seen.add(tg)
            try:
                order = int(it.get("order", i))
            except (TypeError, ValueError):
                order = i
            note = str(it.get("note") or "")
            items.append({"tg": tg, "order": order, "note": note})
    else:
        trunks = raw.get("trunks") if isinstance(raw, dict) else raw
        for i, x in enumerate(trunks or []):
            try:
                tg = int(x)
            except (TypeError, ValueError):
                continue
            if tg < 1 or tg in seen:
                continue
            seen.add(tg)
            items.append({"tg": tg, "order": i, "note": ""})

    items.sort(key=lambda x: (x["order"], x["tg"]))
    for i, it in enumerate(items):
        it["order"] = i
    return items


def load_monitored() -> list[int]:
    """TG numbers in display order (for OSSI poll)."""
    return [it["tg"] for it in load_monitored_items()]


def save_monitored_items(items: list[dict[str, Any]]) -> dict[str, Any]:
    clean: list[dict[str, Any]] = []
    seen: set[int] = set()
    # sort by order then reindex
    tmp = []
    for it in items:
        try:
            tg = int(it.get("tg") or 0)
        except (TypeError, ValueError):
            continue
        if tg < 1 or tg in seen:
            continue
        seen.add(tg)
        try:
            order = int(it.get("order", len(tmp)))
        except (TypeError, ValueError):
            order = len(tmp)
        note = str(it.get("note") or "")[:200]
        tmp.append({"tg": tg, "order": order, "note": note})
    tmp.sort(key=lambda x: (x["order"], x["tg"]))
    for i, it in enumerate(tmp):
        clean.append({"tg": it["tg"], "order": i, "note": it["note"]})
    obj = {
        "items": clean,
        "trunks": [c["tg"] for c in clean],  # legacy compat
        "updatedAt": _now_iso(),
    }
    _write_json(PATHS.monitored, obj)
    return obj


def save_monitored(trunks: list[int]) -> dict[str, Any]:
    """Legacy helper: replace list, keep notes where possible."""
    prev = {it["tg"]: it for it in load_monitored_items()}
    items = []
    for i, t in enumerate(trunks):
        try:
            tg = int(t)
        except (TypeError, ValueError):
            continue
        if tg < 1:
            continue
        items.append(
            {
                "tg": tg,
                "order": i,
                "note": prev.get(tg, {}).get("note", ""),
            }
        )
    return save_monitored_items(items)


def write_trunk_data(
    items: list[dict[str, Any]],
    *,
    error: str | None = None,
    refreshing: bool | None = None,
) -> dict[str, Any]:
    # Attach notes/order from monitored config (local cache metadata)
    meta = {it["tg"]: it for it in load_monitored_items()}
    for it in items:
        m = meta.get(it.get("tg"))
        if m:
            it["note"] = m.get("note", "")
            it["order"] = m.get("order", 0)
    items = sorted(items, key=lambda x: (x.get("order", 0), x.get("tg", 0)))
    obj = {
        "lastUpdate": _now_iso(),
        "host": _host,
        "username": _username,
        "connected": _connected,
        "error": error,
        "source": "avaya-ossi",
        "refreshing": bool(_refreshing if refreshing is None else refreshing),
        "items": items,
    }
    _write_json(PATHS.trunk_data, obj)
    return obj


def _load_trunk_items_map() -> dict[int, dict[str, Any]]:
    raw = _read_json(PATHS.trunk_data, {"items": []})
    items = raw.get("items") if isinstance(raw, dict) else []
    out: dict[int, dict[str, Any]] = {}
    for it in items or []:
        if not isinstance(it, dict):
            continue
        try:
            tg = int(it.get("tg") or 0)
        except (TypeError, ValueError):
            continue
        if tg >= 1:
            out[tg] = dict(it)
    return out


def ensure_seed_files() -> None:
    PATHS.data_dir.mkdir(parents=True, exist_ok=True)
    if not PATHS.monitored.is_file():
        save_monitored_items([{"tg": 1, "order": 0, "note": ""}])
    else:
        # normalize legacy file on boot
        save_monitored_items(load_monitored_items())
    if not PATHS.trunk_data.is_file():
        write_trunk_data([], error=None)


# ---------------------------------------------------------------------------
# OSSI session
# ---------------------------------------------------------------------------


def touch_ui() -> None:
    """Browser is open / polled — keep OSSI session alive for refresh."""
    global _last_ui_seen
    _last_ui_seen = time.monotonic()


def ui_is_present() -> bool:
    if _last_ui_seen <= 0:
        return False
    return (time.monotonic() - _last_ui_seen) <= UI_GONE_SEC


def disconnect_unlocked() -> None:
    global _session, _cfg, _connected, _last_error
    if _session is not None:
        try:
            _session.close()
        except Exception:
            pass
    _session = None
    _cfg = None
    _connected = False


def connect_unlocked(body: dict[str, Any]) -> dict[str, Any]:
    global _session, _cfg, _connected, _host, _username, _last_error, _tg_catalog

    # Accept camelCase or PascalCase (C# / browsers)
    def _g(*keys: str) -> str:
        for k in keys:
            if k in body and body[k] is not None:
                return str(body[k])
        return ""

    host = _g("host", "Host").strip()
    port_s = _g("port", "Port") or "5022"
    port = int(port_s) if str(port_s).isdigit() else 5022
    username = _g("username", "Username").strip()
    password = _g("password", "Password")
    pin = _g("pin", "Pin")

    if not host or not username or not password:
        raise ValueError("host, username, and password required")

    disconnect_unlocked()

    cfg = SessionConfig(
        host=host,
        port=port,
        username=username,
        password=password,
        pin=pin,
        ossi_term="ossit",
        idle_logoff_seconds=30 * 60,
        max_more_pages=40,
        read_timeout=120.0,
    )
    sess = OssiSession(cfg)
    # prove session with light RO command
    r = sess.run("display time", max_more_pages=1)
    if not r.ok:
        sess.close()
        raise RuntimeError(r.error or "display time failed")

    _session = sess
    _cfg = cfg
    _connected = True
    _host = host
    _username = username
    _last_error = None

    # catalog names (capped pages — safe sample; usually enough for TG list)
    cat = sess.run("list trunk-group", max_more_pages=15)
    if cat.ok:
        _tg_catalog = parse_trunk_groups(cat.text)
    else:
        _tg_catalog = {}

    touch_ui()  # Login counts as UI present

    # First trunk poll is done by caller OUTSIDE _lock so heartbeat stays free
    return {
        "ok": True,
        "host": host,
        "username": username,
        "connected": True,
        "catalogSize": len(_tg_catalog),
        "trunkData": None,
        "uiTimeoutSec": UI_GONE_SEC,
        "sessionIdleLogoffMin": 30,
    }


def _status_one_tg(sess: OssiSession, tg: int, catalog: dict[int, dict[str, Any]]) -> dict[str, Any]:
    """Run one OSSI `status trunk N` and return a trunk row dict."""
    meta = catalog.get(tg, {})
    st = sess.run(f"status trunk {tg}", max_more_pages=12)
    if not st.ok:
        return {
            "tg": tg,
            "name": meta.get("name") or f"TG {tg}",
            "type": meta.get("type") or "",
            "tac": meta.get("tac") or "",
            "total": int(meta.get("total") or 0),
            "idle": 0,
            "busy": 0,
            "oos": 0,
            "utilizationPct": 0.0,
            "statusColor": "red",
            "lastUpdate": _now_iso(),
            "error": st.error or "status failed",
        }
    counts = parse_channel_counts(st.text)
    total = counts["total"] or int(meta.get("total") or 0)
    idle = counts["idle"]
    busy = counts["busy"]
    oos = counts["oos"]
    if counts["total"] == 0 and total > 0:
        idle = total
        busy = 0
        oos = 0
    util = utilization_pct(busy, total if total > 0 else (idle + busy + oos))
    tot = total if total > 0 else (idle + busy + oos)
    color = status_color(idle, util)
    return {
        "tg": tg,
        "name": meta.get("name") or f"TG {tg}",
        "type": meta.get("type") or "",
        "tac": meta.get("tac") or "",
        "total": tot,
        "idle": idle,
        "busy": busy,
        "oos": oos,
        "utilizationPct": util,
        "statusColor": color,
        "lastUpdate": _now_iso(),
        "error": None,
    }


def refresh_unlocked() -> dict[str, Any]:
    """
    Poll each monitored TG with `status trunk N`.
    Writes trunk_data.json after EACH TG so the UI can update progressively.
    Does not hold _lock during OSSI I/O (caller should release before long work,
    or use refresh_progressive which manages locks).
    """
    global _last_error, _tg_catalog, _last_refresh_at, _refreshing

    with _lock:
        if not _connected or _session is None:
            # Keep last rows; only flip connected flag
            by = _load_trunk_items_map()
            return write_trunk_data(list(by.values()), error="Not connected", refreshing=False)
        sess = _session
        monitored = load_monitored()
        catalog = dict(_tg_catalog)
        _refreshing = True

    # Seed map with previous values so partial pass still shows old numbers for pending TGs
    by_tg = _load_trunk_items_map()
    # Drop TGs no longer monitored
    mon_set = set(monitored)
    by_tg = {k: v for k, v in by_tg.items() if k in mon_set}
    errors: list[str] = []

    # catalog if empty (one OSSI call)
    if not catalog:
        with _ossi_lock:
            with _lock:
                if not _connected or _session is None:
                    _refreshing = False
                    return write_trunk_data(list(by_tg.values()), error="Not connected", refreshing=False)
                sess = _session
            cat = sess.run("list trunk-group", max_more_pages=15)
        if cat.ok:
            with _lock:
                _tg_catalog = parse_trunk_groups(cat.text)
                catalog = dict(_tg_catalog)

    for tg in monitored:
        with _lock:
            if not _connected or _session is None:
                break
            sess = _session
            catalog = dict(_tg_catalog)
        try:
            with _ossi_lock:
                row = _status_one_tg(sess, tg, catalog)
            if row.get("error"):
                errors.append(f"TG{tg}: {row['error']}")
            by_tg[tg] = row
            # Progressive disk write — UI polls trunk-data and paints immediately
            partial_err = "; ".join(errors) if errors else None
            with _lock:
                write_trunk_data(list(by_tg.values()), error=partial_err, refreshing=True)
            time.sleep(0.25)
        except Exception as exc:
            errors.append(f"TG{tg}: {exc}")
            meta = catalog.get(tg, {})
            by_tg[tg] = {
                "tg": tg,
                "name": meta.get("name") or f"TG {tg}",
                "type": meta.get("type") or "",
                "tac": meta.get("tac") or "",
                "total": int(meta.get("total") or 0),
                "idle": 0,
                "busy": 0,
                "oos": 0,
                "utilizationPct": 0.0,
                "statusColor": "red",
                "lastUpdate": _now_iso(),
                "error": str(exc),
            }
            with _lock:
                write_trunk_data(list(by_tg.values()), error="; ".join(errors), refreshing=True)

    err = "; ".join(errors) if errors else None
    with _lock:
        _last_error = err
        _last_refresh_at = time.monotonic()
        _refreshing = False
        return write_trunk_data(list(by_tg.values()), error=err, refreshing=False)


def refresh_one_tg(tg: int) -> dict[str, Any]:
    """Single TG status + immediate write (for on-demand progressive UI)."""
    global _last_error, _refreshing
    with _lock:
        if not _connected or _session is None:
            raise RuntimeError("Not connected")
        sess = _session
        catalog = dict(_tg_catalog)
    with _ossi_lock:
        row = _status_one_tg(sess, int(tg), catalog)
    by_tg = _load_trunk_items_map()
    by_tg[int(tg)] = row
    with _lock:
        if row.get("error"):
            _last_error = f"TG{tg}: {row['error']}"
        data = write_trunk_data(list(by_tg.values()), error=_last_error, refreshing=False)
    return {"ok": not bool(row.get("error")), "item": row, "data": data}


def session_public() -> dict[str, Any]:
    ui_age = None
    if _last_ui_seen > 0:
        ui_age = round(time.monotonic() - _last_ui_seen, 1)
    return {
        "connected": _connected,
        "host": _host or None,
        "username": _username or None,
        "lastError": _last_error,
        "monitored": load_monitored(),
        "catalogSize": len(_tg_catalog),
        "uiPresent": ui_is_present(),
        "uiAgeSec": ui_age,
        "uiGoneTimeoutSec": UI_GONE_SEC,
        "sessionIdleLogoffMin": 30,
    }


# ---------------------------------------------------------------------------
# Auto refresh thread — only while UI is open; logoff when page gone
# ---------------------------------------------------------------------------


def _auto_loop() -> None:
    """
    - Every UI_WATCH_SEC: if connected but no UI heartbeat → disconnect (page closed)
    - Every AUTO_REFRESH_SEC while UI present: status trunk poll (progressive writes)
    - If no UI: do NOT refresh
    """
    global _last_error
    while not _stop.is_set():
        if _stop.wait(UI_WATCH_SEC):
            break
        do_refresh = False
        with _lock:
            if not _connected or _session is None:
                continue
            if not ui_is_present():
                try:
                    disconnect_unlocked()
                    # Keep last TG rows; only mark offline (UI should not flash empty)
                    by = _load_trunk_items_map()
                    write_trunk_data(list(by.values()), error=None, refreshing=False)
                    _last_error = "UI closed or silent — OSSI logged off"
                except Exception as exc:
                    _last_error = str(exc)
                continue
            due = (_last_refresh_at <= 0) or (
                (time.monotonic() - _last_refresh_at) >= AUTO_REFRESH_SEC
            )
            if due and not _refreshing:
                do_refresh = True
        if do_refresh:
            try:
                # refresh_unlocked manages its own short lock sections + progressive writes
                refresh_unlocked()
            except Exception as exc:
                with _lock:
                    _last_error = str(exc)
                    _refreshing = False


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "OssiBridge/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        # quiet — no request logging of credentials
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, obj: Any) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        """Read JSON body. Supports Content-Length and chunked/no-length clients."""
        raw = b""
        try:
            length = self.headers.get("Content-Length")
            if length is not None and str(length).isdigit() and int(length) > 0:
                raw = self.rfile.read(int(length))
            else:
                # HttpClient may use chunked transfer without Content-Length
                te = (self.headers.get("Transfer-Encoding") or "").lower()
                if "chunked" in te:
                    while True:
                        line = self.rfile.readline()
                        if not line:
                            break
                        size_s = line.strip().split(b";")[0]
                        try:
                            size = int(size_s, 16)
                        except ValueError:
                            break
                        if size == 0:
                            self.rfile.readline()  # trailing CRLF
                            break
                        raw += self.rfile.read(size)
                        self.rfile.readline()  # chunk CRLF
                else:
                    # last resort: short non-blocking-ish read
                    self.connection.settimeout(0.5)
                    try:
                        while True:
                            chunk = self.rfile.read(65536)
                            if not chunk:
                                break
                            raw += chunk
                    except Exception:
                        pass
        except Exception:
            return {}
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        try:
            if path == "/health":
                self._send(200, {"ok": True, "service": "ossi-bridge", "connected": _connected})
                return
            if path == "/session":
                with _lock:
                    self._send(200, {"ok": True, **session_public()})
                return
            if path == "/monitored":
                obj = save_monitored_items(load_monitored_items())
                self._send(200, {"ok": True, **obj})
                return
            if path in ("/trunk-data", "/trunk_data"):
                with _lock:
                    if _connected:
                        touch_ui()
                    live = _connected
                data = _read_json(PATHS.trunk_data, {"items": [], "connected": False})
                if not isinstance(data, dict):
                    data = {"items": [], "connected": False}
                # Always override file cache with live session flag (stale connected:true was misleading UI)
                data["connected"] = live
                if not live:
                    # keep last host/items for display, but never claim Monitoring from disk alone
                    data["connected"] = False
                self._send(200, {"ok": True, "data": data})
                return
            # GET /trunks/123/detail
            if path.startswith("/trunks/") and path.endswith("/detail"):
                parts = path.strip("/").split("/")
                # trunks / {tg} / detail
                if len(parts) == 3 and parts[0] == "trunks" and parts[2] == "detail":
                    try:
                        tg = int(parts[1])
                    except ValueError:
                        self._send(400, {"ok": False, "error": "invalid tg"})
                        return
                    with _lock:
                        touch_ui()
                        if not _connected or _session is None:
                            self._send(401, {"ok": False, "error": "Not connected"})
                            return
                        st = _session.run(f"status trunk {tg}", max_more_pages=12)
                        channels = parse_channels(st.text) if st.ok else []
                        counts = parse_channel_counts(st.text) if st.ok else {}
                        meta = _tg_catalog.get(tg, {})
                        mon = next((m for m in load_monitored_items() if m["tg"] == tg), {})
                    self._send(
                        200,
                        {
                            "ok": bool(st.ok),
                            "tg": tg,
                            "name": mon.get("note") and meta.get("name") or meta.get("name") or f"TG {tg}",
                            "note": mon.get("note", ""),
                            "type": meta.get("type") or "",
                            "tac": meta.get("tac") or "",
                            "counts": counts,
                            "channels": channels,
                            "error": None if st.ok else (st.error or "status failed"),
                            "connectedHint": "Connected column is port/raw from status trunk (not station name).",
                        },
                    )
                    return
            self._send(404, {"ok": False, "error": "not found"})
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc)})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        body = self._read_json()
        try:
            if path == "/session/connect":
                with _lock:
                    result = connect_unlocked(body)
                # Progressive status trunk outside connect lock
                try:
                    data = refresh_unlocked()
                    result["trunkData"] = data
                except Exception as exc:
                    result["trunkData"] = None
                    result["refreshError"] = str(exc)
                self._send(200, result)
                return
            if path == "/session/disconnect":
                with _lock:
                    disconnect_unlocked()
                    by = _load_trunk_items_map()
                    write_trunk_data(list(by.values()), error=None, refreshing=False)
                self._send(200, {"ok": True, "connected": False})
                return
            if path in ("/session/heartbeat", "/heartbeat"):
                # Never block on long OSSI refresh — only stamp UI + quick status
                touch_ui()
                with _lock:
                    st = session_public()
                self._send(200, {"ok": True, **st})
                return
            if path == "/refresh":
                touch_ui()
                # Do not hold _lock for entire multi-TG poll
                data = refresh_unlocked()
                self._send(200, {"ok": True, "data": data})
                return
            if path in ("/refresh/one", "/refresh/tg"):
                touch_ui()
                tg = int(body.get("tg") or body.get("Tg") or 0)
                if tg < 1:
                    self._send(400, {"ok": False, "error": "tg required"})
                    return
                try:
                    result = refresh_one_tg(tg)
                    self._send(200, result)
                except Exception as exc:
                    self._send(401 if "Not connected" in str(exc) else 500, {"ok": False, "error": str(exc)})
                return
            if path == "/monitored/add":
                tg = int(body.get("tg") or body.get("Tg") or 0)
                note = str(body.get("note") or "")
                if tg < 1:
                    self._send(400, {"ok": False, "error": "tg required"})
                    return
                with _lock:
                    items = load_monitored_items()
                    if not any(i["tg"] == tg for i in items):
                        items.append({"tg": tg, "order": len(items), "note": note})
                    obj = save_monitored_items(items)
                    connected = _connected
                if connected:
                    try:
                        refresh_one_tg(tg)
                    except Exception:
                        pass
                self._send(200, {"ok": True, **obj})
                return
            if path == "/monitored/remove":
                tg = int(body.get("tg") or body.get("Tg") or 0)
                with _lock:
                    items = [i for i in load_monitored_items() if i["tg"] != tg]
                    obj = save_monitored_items(items)
                    by = _load_trunk_items_map()
                    if tg in by:
                        del by[tg]
                        write_trunk_data(list(by.values()), error=None)
                self._send(200, {"ok": True, **obj})
                return
            if path == "/monitored/note":
                tg = int(body.get("tg") or body.get("Tg") or 0)
                note = str(body.get("note") or body.get("Note") or "")[:200]
                with _lock:
                    items = load_monitored_items()
                    for it in items:
                        if it["tg"] == tg:
                            it["note"] = note
                            break
                    obj = save_monitored_items(items)
                self._send(200, {"ok": True, **obj})
                return
            self._send(404, {"ok": False, "error": "not found"})
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc), "trace": traceback.format_exc()[-500:]})

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        body = self._read_json()
        try:
            if path == "/monitored":
                with _lock:
                    if isinstance(body.get("items"), list):
                        obj = save_monitored_items(body["items"])
                    else:
                        trunks = body.get("trunks") or []
                        obj = save_monitored([int(x) for x in trunks])
                    if _connected and body.get("refresh", True):
                        # optional: skip heavy refresh when only reordering
                        if body.get("refresh") is not False:
                            pass
                        # only refresh status if explicitly requested
                        if body.get("refreshStatus"):
                            refresh_unlocked()
                self._send(200, {"ok": True, **obj})
                return
            self._send(404, {"ok": False, "error": "not found"})
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc)})

def main() -> int:
    parser = argparse.ArgumentParser(description="OSSI bridge for CM NOC")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--data-dir", default=str(PATHS.data_dir))
    args = parser.parse_args()

    PATHS.data_dir = Path(args.data_dir)
    ensure_seed_files()

    t = threading.Thread(target=_auto_loop, name="ossi-auto-refresh", daemon=True)
    t.start()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        f"ossi-bridge listening http://{args.host}:{args.port} data={PATHS.data_dir}",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _stop.set()
        with _lock:
            disconnect_unlocked()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
