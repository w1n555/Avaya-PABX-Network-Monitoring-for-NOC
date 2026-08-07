"""Low-level SSH channel helpers."""

from __future__ import annotations

import re
import time

import paramiko
from paramiko.channel import Channel


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
    """True if OSSI body looks like an application error (e-lines)."""
    visible = strip_ansi(raw)
    for line in visible.replace("\r", "").split("\n"):
        s = line.strip()
        if s.startswith("e") and len(s) > 1:
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
