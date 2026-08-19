"""Parse Avaya CM `display alarms` OSSI / SAT text (read-only)."""

from __future__ import annotations

import re
from datetime import datetime, timedelta
from typing import Any


_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)

_SEVERITY = re.compile(r"\b(MAJOR|MINOR|WARNING|WARN|WRN|MAJ|MIN)\b", re.I)
_DATE_MD_HM = re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{1,2}):(\d{2})\b")
_DATE_TIME = re.compile(
    r"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?[ T]+(\d{1,2}):(\d{2})(?::(\d{2}))?\b"
)
_DATE_MD_SPACE_HM = re.compile(r"\b(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})\b")
_DATE_ONLY = re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b")
_PORT_LIKE = re.compile(r"^[\dA-Za-z][\w\-/\.]{1,24}$")


def _norm_sev(s: str) -> str:
    u = (s or "").strip().upper()
    if u in ("MAJOR", "MAJ"):
        return "MAJOR"
    if u in ("MINOR", "MIN"):
        return "MINOR"
    if u in ("WARNING", "WARN", "WRN"):
        return "WARNING"
    return u or "WARNING"


def format_alarm_date(dt: datetime | None, raw: str = "") -> str:
    if dt is None:
        return (raw or "").strip() or "—"
    mon = _MONTHS[dt.month - 1]
    return f"{dt.day} {mon} {dt.year} {dt.hour:02d}:{dt.minute:02d}"


def _parse_dt(mm: int, dd: int, yy: int | None, hh: int, mi: int, ss: int = 0) -> datetime | None:
    try:
        if yy is None:
            yy = datetime.now().year
        elif yy < 100:
            yy = 2000 + yy
        return datetime(yy, mm, dd, hh, mi, ss)
    except ValueError:
        return None


def _dt_from_parts(mm: int, dd: int, hh: int, mi: int) -> datetime | None:
    """CM alarm date has no year — use current year, roll back if in the future."""
    if not (1 <= mm <= 12 and 1 <= dd <= 31 and 0 <= hh <= 23 and 0 <= mi <= 59):
        return None
    now = datetime.now()
    dt = _parse_dt(mm, dd, now.year, hh, mi)
    if dt is None:
        dt = _parse_dt(dd, mm, now.year, hh, mi)
    if dt is None:
        return None
    if dt > now + timedelta(days=1):
        try:
            dt = dt.replace(year=now.year - 1)
        except ValueError:
            pass
    return dt


def _extract_dt(text: str) -> tuple[datetime | None, str]:
    if not text:
        return None, ""
    m = _DATE_MD_HM.search(text)
    if m:
        mm, dd, hh, mi = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        if 0 <= hh <= 23:
            dt = _dt_from_parts(mm, dd, hh, mi)
            if dt:
                return dt, m.group(0)
    m = _DATE_MD_SPACE_HM.search(text)
    if m:
        mm, dd, hh, mi = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        dt = _dt_from_parts(mm, dd, hh, mi)
        if dt:
            return dt, m.group(0)
    m = _DATE_TIME.search(text)
    if m:
        mm, dd = int(m.group(1)), int(m.group(2))
        yy = int(m.group(3)) if m.group(3) else None
        hh, mi = int(m.group(4)), int(m.group(5))
        ss = int(m.group(6)) if m.group(6) else 0
        dt = _parse_dt(mm, dd, yy, hh, mi, ss)
        if dt is None:
            dt = _parse_dt(dd, mm, yy, hh, mi, ss)
        if dt:
            return dt, m.group(0)
    m2 = _DATE_ONLY.search(text)
    if m2:
        mm, dd, yy = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
        dt = _parse_dt(mm, dd, yy, 0, 0)
        if dt is None:
            dt = _parse_dt(dd, mm, yy, 0, 0)
        if dt:
            return dt, m2.group(0)
    return None, ""


def _strip_d(s: str) -> str:
    if s.startswith("d") and len(s) > 1 and not s.lower().startswith("display"):
        body = s[1:]
        if body.startswith("\t"):
            body = body[1:]
        return body
    return s


def _alarm_records(text: str) -> list[list[str]]:
    """
    Group OSSI d-lines into multi-line alarm records.

    Live CM format (one record):
      d014V517<TAB>DIG-LINE<TAB>n<TAB>22329<TAB>WARNING
      dRDY<TAB><TAB><TAB>10<TAB>17
      d15<TAB>07<TAB>00<TAB>00<TAB>00
      d00
      n
    """
    recs: list[list[str]] = []
    cur: list[str] = []
    for raw_ln in (text or "").replace("\r", "").split("\n"):
        s = raw_ln.strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith("c") or s in ("t", "y") or low.startswith("e"):
            continue
        if "more?" in low:
            continue
        if s.startswith("f") and not _SEVERITY.search(s):
            continue
        if s == "n":
            if cur:
                recs.append(cur)
                cur = []
            continue
        body = _strip_d(s)
        if not body:
            continue
        if _SEVERITY.search(body):
            if cur:
                recs.append(cur)
            cur = [body]
        elif cur:
            cur.append(body)
        # ignore header-only lines
    if cur:
        recs.append(cur)
    return recs


def _ints(parts: list[str]) -> list[int]:
    out: list[int] = []
    for p in parts:
        t = (p or "").strip()
        if t.isdigit():
            out.append(int(t))
    return out


def _parse_record(lines: list[str], status: str) -> dict[str, Any] | None:
    if not lines:
        return None
    head = lines[0]
    parts = head.split("\t") if "\t" in head else re.split(r"\s{2,}", head)
    parts = [p.strip() for p in parts]

    sev_m = _SEVERITY.search(head)
    if not sev_m:
        return None
    severity = _norm_sev(sev_m.group(1))

    port = ""
    mtce = ""
    ack = ""
    alt = ""
    if parts:
        p0 = parts[0]
        if _PORT_LIKE.match(p0) and not _SEVERITY.match(p0):
            port = p0
    for p in parts[1:]:
        if _SEVERITY.match(p):
            break
        if p.upper() in ("Y", "N", "C"):
            ack = p.upper()
            continue
        if not mtce:
            mtce = p
        elif not alt:
            alt = p
    if not mtce:
        mtce = "UNKNOWN"

    svc = ""
    mm = dd = hh = mi = 0
    # Line 2: Svc + month + day   e.g. RDY \t \t \t 10 \t 17
    if len(lines) >= 2:
        p2 = [x.strip() for x in lines[1].split("\t")]
        for tok in p2:
            if tok.upper() in ("RDY", "OUT", "IN"):
                svc = tok.upper()
                break
        nums = _ints(p2)
        if len(nums) >= 2:
            mm, dd = nums[0], nums[1]
        elif len(nums) == 1:
            mm = nums[0]
    # Line 3: hour + minute [+ resolved bits]
    if len(lines) >= 3:
        nums = _ints([x.strip() for x in lines[2].split("\t")])
        if len(nums) >= 2:
            hh, mi = nums[0], nums[1]
        elif len(nums) == 1:
            hh = nums[0]

    dt = _dt_from_parts(mm, dd, hh, mi) if (mm or dd or hh or mi) else None
    if dt is None:
        dt, _ = _extract_dt("\n".join(lines))
    # CM/OSSI has no year. Display SAT-readable English month, no invented year.
    # Epoch still uses current/previous year only so we can sort newest → oldest.
    raw_dt = f"{mm:02d}/{dd:02d}/{hh:02d}:{mi:02d}" if (mm or dd) else ""
    if mm and dd:
        mon = _MONTHS[mm - 1] if 1 <= mm <= 12 else f"{mm:02d}"
        date_disp = f"{dd} {mon} {hh:02d}:{mi:02d}"
    else:
        date_disp = raw_dt or "—"
    epoch = int(dt.timestamp()) if dt else 0

    key = f"{port}|{mtce}|{severity}|{raw_dt}|{status}"
    return {
        "id": key,
        "port": port,
        "mtceName": mtce,
        "mtceType": mtce,
        "altName": alt,
        "severity": severity,
        "alarmed": date_disp,
        "alarmedRaw": raw_dt,
        "alarmedEpoch": epoch,
        "status": status,
        "svcState": svc,
        "ack": ack,
        "raw": " | ".join(lines)[:300],
    }


def parse_alarms(text: str, *, status: str = "active") -> list[dict[str, Any]]:
    """Parse every OSSI record — keep SAT/export duplicates, dump order."""
    out: list[dict[str, Any]] = []
    for rec in _alarm_records(text or ""):
        row = _parse_record(rec, status)
        if not row:
            continue
        row["id"] = f"{row['id']}|{len(out)}"
        out.append(row)
    out.sort(key=lambda r: (r.get("alarmedEpoch") or 0, r.get("port") or ""), reverse=True)
    return out
