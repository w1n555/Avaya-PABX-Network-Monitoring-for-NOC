"""Parse Avaya CM `list media-gateway` OSSI and join Active alarm counts by MG."""

from __future__ import annotations

import re
from typing import Any

# First IP / hostname line: Num, Name, Serial, IP, Type (g450 / g430 / …)
_TYPE_RE = re.compile(r"^g\d{3}$", re.I)
# Alarm Port on a gateway: 001V2, 014V517, 019V510
_PORT_MG = re.compile(r"^0*(\d+)V", re.I)


def _norm_lines(text: str) -> list[str]:
    raw = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    # more?[y] can sit on its own line or glued to a d-line
    raw = re.sub(r"more\?\[y\]y?", "\n", raw, flags=re.I)
    return [ln.strip() for ln in raw.split("\n") if ln.strip()]


def _d_fields(line: str) -> list[str]:
    if not line.startswith("d"):
        return []
    return line[1:].split("\t")


def parse_list_media_gateway(text: str) -> list[dict[str, Any]]:
    """Return one row per administered media gateway, MG# order."""
    rows: list[dict[str, Any]] = []
    seen: set[int] = set()
    lines = _norm_lines(text)
    i = 0
    while i < len(lines):
        f = _d_fields(lines[i])
        if len(f) >= 5 and f[0].isdigit() and _TYPE_RE.match((f[4] or "").strip()):
            try:
                mg = int(f[0])
            except ValueError:
                i += 1
                continue
            hostname = (f[1] or "").strip()
            serial = (f[2] or "").strip()
            ip = (f[3] or "").strip()
            typ = (f[4] or "").strip().lower()
            reg = ""
            net_rgn = ""
            fw = ""
            j = i + 1
            while j < len(lines):
                nf = _d_fields(lines[j])
                if not nf:
                    j += 1
                    continue
                # Second d-line: NetRgn, Reg y/n, FW, HW…
                if len(nf) >= 2 and (nf[1] or "").strip().lower() in ("y", "n"):
                    net_rgn = (nf[0] or "").strip()
                    reg = (nf[1] or "").strip().lower()
                    fw = (nf[2] or "").strip() if len(nf) > 2 else ""
                    break
                # Next gateway header — Reg missing
                if len(nf) >= 5 and nf[0].isdigit() and _TYPE_RE.match((nf[4] or "").strip()):
                    break
                j += 1
            if mg not in seen:
                seen.add(mg)
                up = reg == "y"
                rows.append(
                    {
                        "mg": mg,
                        "hostname": hostname,
                        "serial": serial,
                        "ip": ip,
                        "type": typ,
                        "reg": reg or "n",
                        "node": "UP" if up else "DOWN",
                        "netRgn": net_rgn,
                        "fw": fw,
                    }
                )
            i = j if j > i else i + 1
            continue
        i += 1
    rows.sort(key=lambda r: int(r["mg"]))
    return rows


def mg_from_port(port: str | None) -> int | None:
    m = _PORT_MG.match(str(port or "").strip())
    if not m:
        return None
    try:
        return int(m.group(1))
    except ValueError:
        return None


def alarm_counts_by_mg(alarms: list[dict[str, Any]] | None) -> dict[int, dict[str, int]]:
    """Count ALL Active alarms whose Port is on that MG (001V2, 014V517, …)."""
    out: dict[int, dict[str, int]] = {}
    for a in alarms or []:
        mg = mg_from_port(a.get("port"))
        if mg is None:
            continue
        bucket = out.setdefault(mg, {"mj": 0, "mn": 0, "wn": 0})
        sev = str(a.get("severity") or "").upper()
        if sev in ("MAJOR", "MAJ"):
            bucket["mj"] += 1
        elif sev in ("MINOR", "MIN"):
            bucket["mn"] += 1
        else:
            bucket["wn"] += 1
    return out


def join_gateways(
    gateways: list[dict[str, Any]],
    alarms: list[dict[str, Any]] | None,
) -> list[dict[str, Any]]:
    counts = alarm_counts_by_mg(alarms)
    joined: list[dict[str, Any]] = []
    for g in gateways:
        c = counts.get(int(g["mg"]), {"mj": 0, "mn": 0, "wn": 0})
        row = dict(g)
        row["mj"] = int(c["mj"])
        row["mn"] = int(c["mn"])
        row["wn"] = int(c["wn"])
        joined.append(row)
    return joined


def gateway_summary(items: list[dict[str, Any]]) -> dict[str, int]:
    up = down = mj = mn = wn = 0
    for it in items:
        if str(it.get("node") or "").upper() == "UP":
            up += 1
        else:
            down += 1
        mj += int(it.get("mj") or 0)
        mn += int(it.get("mn") or 0)
        wn += int(it.get("wn") or 0)
    return {
        "total": len(items),
        "up": up,
        "down": down,
        "mj": mj,
        "mn": mn,
        "wn": wn,
    }


# list configuration media-gateway — board 051V5, ports 01 / u / t / p
_BOARD_NUM = re.compile(r"^0*(\d+)V(\d+)$", re.I)
_SAT_BOARD = re.compile(
    r"^(?P<board>0*\d{1,3}V\d{1,2})\s+"
    r"(?P<typ>[A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z][A-Za-z0-9]*)?)\s+"
    r"(?P<code>[A-Za-z0-9]+)\s+"
    r"(?P<hw>HW\S+)(?:\s+(?P<fw>FW\S+))?"
    r"(?:\s+(?P<ports>.*))?$",
    re.I,
)
_PORT_TOK = re.compile(r"^(?:u|t|p|[0-9]{1,2})$", re.I)
_SKIP_CFG = re.compile(
    r"system configuration|board\s+number|assigned ports|command:|"
    r"command successfully|more\?|u=unassigned",
    re.I,
)


def avaya_port(mg: int, slot: str | int, circuit: str | int) -> str:
    """051 + V + 5 + 01 → 051V501 (list station Port)."""
    try:
        circ = int(str(circuit).strip())
    except ValueError:
        circ = 0
    return f"{int(mg):03d}V{int(slot)}{circ:02d}"


def norm_avaya_port(port: str | None) -> str:
    s = str(port or "").strip().upper()
    m = re.match(r"^0*(\d+)V(\d+)$", s, re.I)
    if not m:
        return s
    gw = int(m.group(1))
    rest = m.group(2)
    if len(rest) <= 2:
        return f"{gw:03d}V{int(rest)}"
    slot, circ = rest[:-2], rest[-2:]
    return f"{gw:03d}V{int(slot)}{int(circ):02d}"


def _port_state(tok: str) -> tuple[str, str]:
    t = (tok or "").strip().lower()
    if t == "u":
        return "", "unassigned"
    if t == "t":
        return "", "tti"
    if t == "p":
        return "", "psa"
    if t.isdigit():
        return f"{int(t):02d}", "assigned"
    return "", "unassigned"


def _new_board(board: str, typ: str, code: str, vintage: str) -> dict[str, Any]:
    m = _BOARD_NUM.match((board or "").strip())
    mg = int(m.group(1)) if m else 0
    slot = m.group(2) if m else ""
    return {
        "board": f"{mg:03d}V{slot}" if m else (board or "").strip().upper(),
        "mg": mg,
        "slot": slot,
        "type": (typ or "").strip(),
        "code": (code or "").strip(),
        "vintage": (vintage or "").strip(),
        "ports": [],
    }


def _append_port_tokens(board: dict[str, Any], tokens: list[str]) -> None:
    for raw in tokens:
        tok = (raw or "").strip()
        if not tok or not _PORT_TOK.match(tok):
            continue
        circ, state = _port_state(tok)
        n = circ or tok.lower()
        board["ports"].append(
            {
                "n": n,
                "state": state,
                "port": avaya_port(board["mg"], board["slot"], circ) if state == "assigned" and circ else "",
            }
        )


def parse_list_configuration_media_gateway(text: str, mg: int | None = None) -> list[dict[str, Any]]:
    """Parse OSSI d-lines or SAT-like SYSTEM CONFIGURATION dump into boards."""
    boards: list[dict[str, Any]] = []
    cur: dict[str, Any] | None = None
    lines = _norm_lines(text)

    def _keep(b: dict[str, Any] | None) -> None:
        if b and b.get("board") and b["board"] not in {x["board"] for x in boards}:
            boards.append(b)

    for ln in lines:
        if _SKIP_CFG.search(ln) and not ln.startswith("d"):
            continue
        f = _d_fields(ln)
        if f:
            head = (f[0] or "").strip()
            bm = _BOARD_NUM.match(head)
            if bm:
                _keep(cur)
                rest = [(x or "").strip() for x in f[1:]]
                typ = ""
                code = ""
                vintage = ""
                port_at = 0
                if len(rest) >= 2 and rest[1].upper() == "MM":
                    typ = f"{rest[0]} {rest[1]}".strip()
                    port_at = 2
                elif rest:
                    typ = rest[0]
                    port_at = 1
                if port_at < len(rest) and rest[port_at] and not _PORT_TOK.match(rest[port_at]) and not rest[port_at].upper().startswith("HW"):
                    code = rest[port_at]
                    port_at += 1
                hw_bits: list[str] = []
                while port_at < len(rest) and rest[port_at].upper().startswith(("HW", "FW")):
                    hw_bits.append(rest[port_at])
                    port_at += 1
                vintage = " ".join(hw_bits)
                cur = _new_board(head, typ, code, vintage)
                if mg and cur["mg"] and int(mg) != cur["mg"]:
                    cur = None
                    continue
                _append_port_tokens(cur, rest[port_at:])
                continue
            if cur is not None:
                toks = [(x or "").strip() for x in f if (x or "").strip()]
                if toks and all(_PORT_TOK.match(t) for t in toks):
                    _append_port_tokens(cur, toks)
                    continue
            continue

        sat = _SAT_BOARD.match(ln)
        if sat:
            _keep(cur)
            vintage = " ".join(x for x in (sat.group("hw"), sat.group("fw")) if x)
            cur = _new_board(sat.group("board"), sat.group("typ"), sat.group("code"), vintage)
            if mg and cur["mg"] and int(mg) != cur["mg"]:
                cur = None
                continue
            extra = sat.group("ports") or ""
            _append_port_tokens(cur, extra.split())
            continue
        if cur is not None:
            toks = ln.split()
            if toks and all(_PORT_TOK.match(t) for t in toks):
                _append_port_tokens(cur, toks)

    _keep(cur)
    if mg:
        boards = [b for b in boards if int(b.get("mg") or 0) == int(mg)]
    return boards


def join_config_extensions(
    boards: list[dict[str, Any]],
    extensions: list[dict[str, Any]] | None,
) -> list[dict[str, Any]]:
    """Attach list station extension/name onto assigned ports. Missing ext → empty."""
    by_port: dict[str, dict[str, Any]] = {}
    for e in extensions or []:
        p = norm_avaya_port(str(e.get("port") or ""))
        if p and p != "—":
            by_port[p] = e
    assigned: list[dict[str, Any]] = []
    for b in boards:
        for p in b.get("ports") or []:
            if p.get("state") != "assigned" or not p.get("port"):
                p["extension"] = ""
                p["name"] = ""
                p["extType"] = ""
                continue
            key = norm_avaya_port(p["port"])
            ext = by_port.get(key) or {}
            p["extension"] = str(ext.get("extension") or "")
            p["name"] = str(ext.get("name") or "")
            p["extType"] = str(ext.get("type") or "")
            assigned.append(
                {
                    "port": p["port"],
                    "slot": b.get("slot"),
                    "circuit": p.get("n"),
                    "board": b.get("board"),
                    "code": b.get("code"),
                    "type": b.get("type"),
                    "extension": p["extension"],
                    "name": p["name"],
                    "extType": p["extType"],
                }
            )
    return assigned
