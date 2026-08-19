"""Low-level SSH channel helpers."""

from __future__ import annotations

import re
import time

import paramiko
from paramiko.channel import Channel


def drain_pending(chan: Channel) -> str:
    """Read already-buffered SSH data only. Do not wait if the channel is empty.

    Used between commands so a clean channel does not burn ``recv_for``'s
    full timeout (that helper must still wait when a banner is expected).
    Slightly longer than a pure non-block so residual more?[y] tails clear.
    """
    if not chan.recv_ready():
        return ""
    return recv_for(chan, timeout=0.6, idle=0.12)


def drain_until_quiet(
    chan: Channel,
    *,
    max_wait: float = 2.5,
    quiet: float = 0.4,
    stop_more: bool = True,
) -> str:
    """Drain residual OSSI until channel is quiet.

    Critical between list/display commands: leftover more?[y] pages will otherwise
    glue into the next ``c…``/``t`` and poison alarms / gateways / extensions.
    """
    chan.settimeout(0.35)
    chunks: list[str] = []
    deadline = time.monotonic() + max_wait
    last = time.monotonic()
    while time.monotonic() < deadline:
        if chan.recv_ready():
            try:
                data = chan.recv(65535).decode("utf-8", errors="replace")
            except Exception:
                break
            if not data:
                break
            chunks.append(data)
            last = time.monotonic()
            if stop_more and re.search(r"more\?\s*\[y\]", data, re.I):
                try:
                    send_line(chan, "n")
                except Exception:
                    pass
                time.sleep(0.05)
        elif chunks and (time.monotonic() - last) >= quiet:
            break
        elif not chunks and (time.monotonic() - last) >= quiet:
            break
        else:
            time.sleep(0.04)
    return "".join(chunks)


def recv_for(chan: Channel, timeout: float, idle: float = 0.8) -> str:
    chan.settimeout(0.35)
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout
    last = time.monotonic()
    while time.monotonic() < deadline:
        if chan.recv_ready():
            try:
                data = chan.recv(65535)
            except Exception:
                break
            if not data:
                break
            chunks.append(data)
            last = time.monotonic()
        elif chunks and (time.monotonic() - last) >= idle:
            break
        else:
            time.sleep(0.05)
    return b"".join(chunks).decode("utf-8", errors="replace")


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b.", "", text)


def send_line(chan: Channel, line: str) -> None:
    chan.sendall((line + "\r").encode("utf-8"))


def looks_like_prompt(text: str, *needles: str) -> bool:
    low = text.lower()
    return any(n.lower() in low for n in needles)


def ossi_has_error(raw: str) -> bool:
    """True if OSSI body has a real e-line (``e1 00000000 …``), not any ``e…`` text."""
    visible = strip_ansi(raw)
    for line in visible.replace("\r", "").split("\n"):
        s = line.strip()
        if re.match(r"^e\d+\s", s):
            return True
    return False


def channel_alive(client: paramiko.SSHClient | None, chan: Channel | None) -> bool:
    if client is None or chan is None:
        return False
    try:
        if chan.closed:
            return False
        tr = client.get_transport()
        if tr is None or not tr.is_active():
            return False
        return True
    except Exception:
        return False


def count_data_rows(raw: str) -> int:
    """Count OSSI d-lines (rough inventory size)."""
    n = 0
    for line in strip_ansi(raw).replace("\r", "").split("\n"):
        s = line.strip()
        if s.startswith("d") and len(s) > 1:
            n += 1
    return n
