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
