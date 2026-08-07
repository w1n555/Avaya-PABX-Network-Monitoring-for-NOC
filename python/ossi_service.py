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

_lock = threading.RLock()
_session: OssiSession | None = None
_cfg: SessionConfig | None = None
_connected = False
_host = ""
_username = ""
_last_error: str | None = None
_tg_catalog: dict[int, dict[str, Any]] = {}
_stop = threading.Event()


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


def load_monitored() -> list[int]:
    raw = _read_json(
        PATHS.monitored,
        {"trunks": [], "updatedAt": None},
    )
    trunks = raw.get("trunks") if isinstance(raw, dict) else raw
    out: list[int] = []
    for x in trunks or []:
        try:
            n = int(x)
            if n >= 1 and n not in out:
                out.append(n)
        except (TypeError, ValueError):
            continue
    return sorted(out)


def save_monitored(trunks: list[int]) -> dict[str, Any]:
    clean = sorted({int(t) for t in trunks if int(t) >= 1})
    obj = {"trunks": clean, "updatedAt": _now_iso()}
    _write_json(PATHS.monitored, obj)
    return obj


def write_trunk_data(items: list[dict[str, Any]], *, error: str | None = None) -> dict[str, Any]:
    obj = {
        "lastUpdate": _now_iso(),
        "host": _host,
        "username": _username,
        "connected": _connected,
        "error": error,
        "source": "avaya-ossi",
        "items": items,
    }
    _write_json(PATHS.trunk_data, obj)
    return obj


def ensure_seed_files() -> None:
    PATHS.data_dir.mkdir(parents=True, exist_ok=True)
    if not PATHS.monitored.is_file():
        save_monitored([1])  # default sample TG 1 — admin can change
    if not PATHS.trunk_data.is_file():
        write_trunk_data([], error=None)


# ---------------------------------------------------------------------------
# OSSI session
# ---------------------------------------------------------------------------


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

    host = str(body.get("host") or "").strip()
    port = int(body.get("port") or 5022)
    username = str(body.get("username") or "").strip()
    password = str(body.get("password") or "")
    pin = str(body.get("pin") or "")

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

    # first collect
    data = refresh_unlocked()
    return {
        "ok": True,
        "host": host,
        "username": username,
        "connected": True,
        "catalogSize": len(_tg_catalog),
        "trunkData": data,
    }


def refresh_unlocked() -> dict[str, Any]:
    global _last_error, _tg_catalog

    if not _connected or _session is None:
        data = write_trunk_data([], error="Not connected")
        return data

    monitored = load_monitored()
    items: list[dict[str, Any]] = []
    errors: list[str] = []

    # refresh catalog lightly if empty
    if not _tg_catalog:
        cat = _session.run("list trunk-group", max_more_pages=15)
        if cat.ok:
            _tg_catalog = parse_trunk_groups(cat.text)

    for tg in monitored:
        try:
            st = _session.run(f"status trunk {tg}", max_more_pages=12)
            if not st.ok:
                errors.append(f"TG{tg}: {st.error or 'status failed'}")
                meta = _tg_catalog.get(tg, {})
                items.append(
                    {
                        "tg": tg,
                        "name": meta.get("name") or f"TG {tg}",
                        "type": meta.get("type") or "",
                        "tac": meta.get("tac") or "",
                        "total": meta.get("total") or 0,
                        "idle": 0,
                        "busy": 0,
                        "oos": 0,
                        "utilizationPct": 0.0,
                        "statusColor": "red",
                        "lastUpdate": _now_iso(),
                        "error": st.error or "status failed",
                    }
                )
                continue

            counts = parse_channel_counts(st.text)
            meta = _tg_catalog.get(tg, {})
            total = counts["total"] or int(meta.get("total") or 0)
            idle = counts["idle"]
            busy = counts["busy"]
            oos = counts["oos"]
            # If parser found channels, trust sum; else fall back catalog total
            if counts["total"] == 0 and total > 0:
                idle = total
                busy = 0
                oos = 0
            util = utilization_pct(busy, total if total > 0 else (idle + busy + oos))
            tot = total if total > 0 else (idle + busy + oos)
            color = status_color(idle, util)
            items.append(
                {
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
            )
            # gentle pace — avoid hammering Main CM
            time.sleep(0.35)
        except Exception as exc:
            errors.append(f"TG{tg}: {exc}")
            meta = _tg_catalog.get(tg, {})
            items.append(
                {
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
            )

    err = "; ".join(errors) if errors else None
    _last_error = err
    return write_trunk_data(items, error=err)


def session_public() -> dict[str, Any]:
    return {
        "connected": _connected,
        "host": _host or None,
        "username": _username or None,
        "lastError": _last_error,
        "monitored": load_monitored(),
        "catalogSize": len(_tg_catalog),
    }


# ---------------------------------------------------------------------------
# Auto refresh thread
# ---------------------------------------------------------------------------


def _auto_loop() -> None:
    while not _stop.wait(AUTO_REFRESH_SEC):
        with _lock:
            if _connected and _session is not None:
                try:
                    refresh_unlocked()
                except Exception as exc:
                    global _last_error
                    _last_error = str(exc)


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
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
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
                self._send(200, {"ok": True, **save_monitored(load_monitored())})
                return
            if path in ("/trunk-data", "/trunk_data"):
                data = _read_json(PATHS.trunk_data, {"items": [], "connected": False})
                self._send(200, {"ok": True, "data": data})
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
                self._send(200, result)
                return
            if path == "/session/disconnect":
                with _lock:
                    disconnect_unlocked()
                    write_trunk_data([], error=None)
                self._send(200, {"ok": True, "connected": False})
                return
            if path == "/refresh":
                with _lock:
                    data = refresh_unlocked()
                self._send(200, {"ok": True, "data": data})
                return
            if path == "/monitored/add":
                tg = int(body.get("tg") or 0)
                if tg < 1:
                    self._send(400, {"ok": False, "error": "tg required"})
                    return
                with _lock:
                    cur = load_monitored()
                    if tg not in cur:
                        cur.append(tg)
                    obj = save_monitored(cur)
                    if _connected:
                        refresh_unlocked()
                self._send(200, {"ok": True, **obj})
                return
            if path == "/monitored/remove":
                tg = int(body.get("tg") or 0)
                with _lock:
                    cur = [t for t in load_monitored() if t != tg]
                    obj = save_monitored(cur)
                    if _connected:
                        refresh_unlocked()
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
                trunks = body.get("trunks") or []
                with _lock:
                    obj = save_monitored([int(x) for x in trunks])
                    if _connected:
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
