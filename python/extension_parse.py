"""Parse Avaya CM OSSI `list extension` + `list station` inventory.

`list extension` (2 d-lines per record + n):

  d700\\tVDN-extension\\t1\\t1
  dHotline-700\\t1
  n

`list station` (3 d-lines per record + n; tabs required):

  d20002\\t043V612\\t\\t\\t
  d1\\t\\tCallrID\\t\\tno
  d\\t\\t\\t4\\t1
  n
  d20014\\t043V314\\tChan Wing Kit\\t\\t
  ...

line1: extension, port, name, room?, …
"""

from __future__ import annotations

import re
from typing import Any

_EXT_RE = re.compile(r"^\d{2,13}[A-Za-z]?$")
# IP S00001 / media-gateway 043V612 / unassigned X / analog ANA00001
_PORT_RE = re.compile(
    r"^(?:"
    r"X|"
    r"S\d{3,8}|"
    r"\d{1,3}V\d{1,8}|"
    r"ANA\d+|"
    r"T\d+|"
    r"IP"
    r")$",
    re.I,
)


def _norm_lines(text: str) -> list[str]:
    raw = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    raw = re.sub(r"more\?\s*\[y\]y?", "\n", raw, flags=re.I)
    return [ln.strip() for ln in raw.split("\n") if ln.strip()]


def _d_fields(line: str) -> list[str]:
    if not line.startswith("d"):
        return []
    return [(x or "").strip() for x in line[1:].split("\t")]


def parse_list_extension(text: str) -> list[dict[str, Any]]:
    """Return one row per extension from OSSI `list extension`."""
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    lines = _norm_lines(text)
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln == "n" or ln == "t" or ln.startswith("c") or ln.startswith("f"):
            i += 1
            continue
        f = _d_fields(ln)
        if not f:
            i += 1
            continue
        ext = f[0]
        if not _EXT_RE.match(ext):
            i += 1
            continue

        typ = (f[1] if len(f) > 1 else "") or "—"
        name = ""
        # Second d-line is name (optional empties)
        j = i + 1
        if j < len(lines):
            f2 = _d_fields(lines[j])
            if f2:
                # name is first field of second d-line (may be blank)
                name = f2[0] if f2[0] else ""
                # If second line looks like another extension header, do not consume
                if _EXT_RE.match(f2[0]) and len(f2) >= 2 and f2[1] and not f2[1].isdigit():
                    # e.g. next record started without name line
                    name = ""
                    j = i
                else:
                    pass  # consumed name line
            elif lines[j] == "n":
                j = i  # no name line
        if j > i:
            i = j + 1
        else:
            i += 1

        if ext in seen:
            continue
        seen.add(ext)
        rows.append(
            {
                "extension": ext,
                "type": typ,
                "port": "—",
                "name": name if name else "—",
                "room": "",
                "cor": "",
                "cos": "",
                "raw": "\t".join(f + ([name] if name else [])),
            }
        )

    def _ext_key(e: str) -> tuple:
        m = re.match(r"^(\d+)([A-Za-z]?)$", e)
        if m:
            return (int(m.group(1)), m.group(2) or "")
        return (0, e)

    rows.sort(key=lambda r: _ext_key(str(r.get("extension") or "")))
    return rows


def _is_port(value: str) -> bool:
    s = (value or "").strip()
    return bool(s) and bool(_PORT_RE.match(s))


def parse_list_station(text: str) -> dict[str, dict[str, str]]:
    """Map extension → {port, name, room} from OSSI `list station`."""
    by_ext: dict[str, dict[str, str]] = {}
    lines = _norm_lines(text)
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln == "n" or ln == "t" or ln.startswith("c") or ln.startswith("f"):
            i += 1
            continue
        f = _d_fields(ln)
        if not f:
            i += 1
            continue
        ext = (f[0] or "").strip()
        port = (f[1] if len(f) > 1 else "").strip()
        if not _EXT_RE.match(ext) or not _is_port(port):
            i += 1
            continue
        name = (f[2] if len(f) > 2 else "").strip()
        room = (f[3] if len(f) > 3 else "").strip()
        if ext not in by_ext:
            by_ext[ext] = {
                "extension": ext,
                "port": port,
                "name": name,
                "room": room,
            }
        # Skip the rest of this record (2 more d-lines + n) unless next header
        i += 1
        skipped = 0
        while i < len(lines) and skipped < 4:
            nxt = lines[i]
            f2 = _d_fields(nxt)
            if f2:
                ext2 = (f2[0] or "").strip()
                port2 = (f2[1] if len(f2) > 1 else "").strip()
                if _EXT_RE.match(ext2) and _is_port(port2):
                    break
            if nxt == "n":
                i += 1
                break
            if nxt == "t" or nxt.startswith("c"):
                break
            i += 1
            skipped += 1
    return by_ext


def merge_extension_ports(
    extensions: list[dict[str, Any]],
    station_by_ext: dict[str, dict[str, str]] | None,
    prev_items: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Overlay Port/Room from list station; keep last-good ports if station list is thin."""
    prev_ports: dict[str, str] = {}
    prev_rooms: dict[str, str] = {}
    for r in prev_items or []:
        e = str(r.get("extension") or "").strip()
        p = str(r.get("port") or "").strip()
        if e and p and p != "—":
            prev_ports[e] = p
        rm = str(r.get("room") or "").strip()
        if e and rm and rm != "—":
            prev_rooms[e] = rm

    use_station = dict(station_by_ext or {})
    if prev_ports and len(use_station) < max(50, int(len(prev_ports) * 0.5)):
        use_station = {}

    out: list[dict[str, Any]] = []
    for r in extensions:
        row = dict(r)
        ext = str(row.get("extension") or "").strip()
        st = use_station.get(ext) or {}
        port = str(st.get("port") or "").strip()
        room = str(st.get("room") or "").strip()
        if not port:
            port = prev_ports.get(ext, "")
        if not room:
            room = prev_rooms.get(ext, "")
        row["port"] = port if port else "—"
        if room:
            row["room"] = room
        out.append(row)
    return out


def extension_summary(items: list[dict[str, Any]] | None) -> dict[str, Any]:
    items = items or []
    by_type: dict[str, int] = {}
    port_n = 0
    for r in items:
        t = str(r.get("type") or "—").strip() or "—"
        by_type[t] = by_type.get(t, 0) + 1
        p = str(r.get("port") or "").strip()
        if p and p != "—":
            port_n += 1
    types = sorted(by_type.keys(), key=lambda x: (-by_type[x], x.lower()))
    return {
        "total": len(items),
        "typeCount": len(by_type),
        "byType": by_type,
        "types": types,
        "portCount": port_n,
    }
