#!/usr/bin/env python3
"""
Avaya CM CDR logger — TCP server (CM pushes records to us).

Listens (default 0.0.0.0:9000). Writes one call per line into:
  <log_dir>/YYYYMMDD.TXT

Tuned for this CM (read from SAT):
  - Primary format: customized
  - Date format: month/day
  - Custom field map → fixed record length 173 (incl. return + line-feed)
  - Node NMC-CDR → 172.29.92.154 (this host)

Usage:
  python cdr_logger.py
  python cdr_logger.py --host 0.0.0.0 --port 9000 --log-dir C:\\inetpub\\wwwroot\\CM\\cdr-link\\cdr
"""

from __future__ import annotations

import argparse
import logging
import re
import socket
import socketserver
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Customized CDR layout from CM display system-parameters cdr (field lengths)
# Record length must total 173 including trailing return + line-feed.
# ---------------------------------------------------------------------------

# (field_name, width) — spaces included as fields for fixed-width slicing
CUSTOM_FIELDS: list[tuple[str, int]] = [
    ("date", 6),
    ("_sp1", 1),
    ("time", 4),
    ("_sp2", 1),
    ("sec_dur", 5),
    ("_sp3", 1),
    ("cond_code", 1),
    ("_sp4", 1),
    ("code_used", 4),
    ("_sp5", 1),
    ("code_dial", 4),
    ("_sp6", 1),
    ("dialed_num", 23),
    ("_sp7", 1),
    ("clg_num_in_tac", 15),
    ("_sp8", 1),
    ("in_trk_code", 4),
    ("_sp9", 1),
    ("in_crt_id", 4),
    ("_sp10", 1),
    ("calling_num", 15),
    ("_sp11", 1),
    ("out_crt_id", 4),
    ("_sp12", 1),
    ("ppm", 5),
    ("_sp13", 1),
    ("isdn_cc", 11),
    ("_sp14", 1),
    ("attd_console", 2),
    ("_sp15", 1),
    ("vdn", 16),
    ("_sp16", 1),
    ("acct_code", 15),
    ("_sp17", 1),
    ("auth_code", 13),
    ("_sp18", 1),
    ("node_num", 2),
    ("return", 1),
    ("line_feed", 1),
]

RECORD_LEN = sum(w for _, w in CUSTOM_FIELDS)
assert RECORD_LEN == 173, f"layout sum={RECORD_LEN}, expected 173"

# Headers written once at top of each new daily file (comment line)
LINE_HEADER = (
    "# recv_local|raw|date|time|sec_dur|cond|code_used|code_dial|dialed_num|"
    "clg_num_in_tac|in_trk|in_crt|calling_num|out_crt|ppm|isdn_cc|attd|vdn|"
    "acct|auth|node"
)


class LoggerConfig:
    def __init__(
        self,
        host: str = "0.0.0.0",
        port: int = 9000,
        log_dir: Path | None = None,
        raw_fallback: bool = True,
    ):
        self.host = host
        self.port = port
        self.log_dir = log_dir or (Path(__file__).resolve().parent / "cdr")
        self.raw_fallback = raw_fallback  # if not fixed-width, still write raw lines


def setup_logging(log_dir: Path) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    logs = Path(__file__).resolve().parent / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(logs / "cdr_logger.log", encoding="utf-8"),
        ],
    )


def daily_path(log_dir: Path, when: datetime | None = None) -> Path:
    when = when or datetime.now()
    return log_dir / f"{when.strftime('%Y%m%d')}.txt"


def parse_custom_record(blob: bytes | str) -> dict[str, str] | None:
    """Slice one 173-byte customized record into fields."""
    if isinstance(blob, bytes):
        # Avaya often sends ASCII; replace bad bytes
        s = blob.decode("ascii", errors="replace")
    else:
        s = blob
    # strip trailing CR/LF for length check if already stripped
    raw = s
    if len(raw) < RECORD_LEN - 2:
        return None
    # pad/truncate to RECORD_LEN without LF for field parse
    body = raw.replace("\r", "").replace("\n", "")
    if len(body) < RECORD_LEN - 2:
        # allow missing trailing return/lf
        body = body.ljust(RECORD_LEN - 2)[: RECORD_LEN - 2]
        body = body + "\r\n"
    elif len(body) >= RECORD_LEN:
        body = body[:RECORD_LEN]
    else:
        body = body.ljust(RECORD_LEN)

    out: dict[str, str] = {"_raw": body[: RECORD_LEN - 2].rstrip("\r\n")}
    pos = 0
    for name, width in CUSTOM_FIELDS:
        chunk = body[pos : pos + width]
        pos += width
        if name.startswith("_") or name in ("return", "line_feed"):
            continue
        out[name] = chunk.strip()
    return out


def format_output_line(fields: dict[str, str], recv_at: datetime) -> str:
    """One call = one line (pipe-separated, easy for later Search)."""
    keys = [
        "date",
        "time",
        "sec_dur",
        "cond_code",
        "code_used",
        "code_dial",
        "dialed_num",
        "clg_num_in_tac",
        "in_trk_code",
        "in_crt_id",
        "calling_num",
        "out_crt_id",
        "ppm",
        "isdn_cc",
        "attd_console",
        "vdn",
        "acct_code",
        "auth_code",
        "node_num",
    ]
    parts = [recv_at.strftime("%Y-%m-%d %H:%M:%S"), fields.get("_raw", "")]
    parts.extend(fields.get(k, "") for k in keys)
    # sanitize pipes/newlines inside fields
    clean = [re.sub(r"[\r\n|]+", " ", p) for p in parts]
    return "|".join(clean)


class DailyWriter:
    """Thread-safe append to YYYYMMDD.TXT (one record per line)."""

    def __init__(self, log_dir: Path):
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._current_day: str | None = None
        self._fh = None

    def _ensure_file(self, when: datetime):
        day = when.strftime("%Y%m%d")
        if self._current_day == day and self._fh is not None:
            return
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:
                pass
        path = daily_path(self.log_dir, when)
        new_file = not path.exists() or path.stat().st_size == 0
        # buffering=1 line-buffered; allow other processes (API search) to read while we append
        self._fh = open(path, "a", encoding="utf-8", newline="\n", buffering=1)
        try:
            # On Windows, ensure share mode is not exclusive (Python open defaults allow read share)
            pass
        except Exception:
            pass
        self._current_day = day
        if new_file:
            self._fh.write(LINE_HEADER + "\n")
            self._fh.flush()
        logging.info("Writing CDR to %s", path)

    def write_line(self, line: str, when: datetime | None = None) -> None:
        when = when or datetime.now()
        with self._lock:
            self._ensure_file(when)
            assert self._fh is not None
            self._fh.write(line.rstrip("\r\n") + "\n")
            self._fh.flush()

    def close(self) -> None:
        with self._lock:
            if self._fh is not None:
                try:
                    self._fh.close()
                except Exception:
                    pass
                self._fh = None


class CdrBuffer:
    """Accumulate TCP bytes → emit complete records (fixed 173 or newline)."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes) -> list[bytes]:
        self.buf.extend(data)
        out: list[bytes] = []

        # Prefer newline-delimited if CM sends LF (customized often includes LF at end)
        while True:
            # Fixed-width path when we have full record(s)
            if len(self.buf) >= RECORD_LEN:
                # If buffer has CR/LF early, take line mode for that chunk
                nl = self.buf.find(b"\n")
                if 0 <= nl < RECORD_LEN:
                    rec = bytes(self.buf[: nl + 1])
                    del self.buf[: nl + 1]
                    if rec.strip():
                        out.append(rec)
                    continue
                rec = bytes(self.buf[:RECORD_LEN])
                del self.buf[:RECORD_LEN]
                out.append(rec)
                continue

            nl = self.buf.find(b"\n")
            if nl >= 0:
                rec = bytes(self.buf[: nl + 1])
                del self.buf[: nl + 1]
                if rec.strip():
                    out.append(rec)
                continue
            break
        return out


class CdrHandler(socketserver.BaseRequestHandler):
    writer: DailyWriter
    cfg: LoggerConfig

    def handle(self) -> None:
        peer = self.client_address
        conn: socket.socket = self.request
        logging.info("CM connected from %s:%s", peer[0], peer[1])
        buf = CdrBuffer()
        count = 0
        try:
            # Long-lived TCP session: CM keeps link open; do not close on idle
            conn.settimeout(600.0)
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            while True:
                try:
                    chunk = conn.recv(8192)
                except socket.timeout:
                    logging.debug("idle %s:%s (still up)", peer[0], peer[1])
                    continue
                if not chunk:
                    break
                logging.info("RX %s bytes from %s:%s", len(chunk), peer[0], peer[1])
                for rec in buf.feed(chunk):
                    now = datetime.now()
                    try:
                        fields = parse_custom_record(rec)
                        if fields:
                            line = format_output_line(fields, now)
                        elif self.cfg.raw_fallback:
                            raw = rec.decode("ascii", errors="replace").rstrip("\r\n")
                            if not raw.strip():
                                continue
                            line = f"{now.strftime('%Y-%m-%d %H:%M:%S')}|{raw}"
                        else:
                            continue
                        self.writer.write_line(line, now)
                        count += 1
                        if count == 1 or count % 20 == 0:
                            logging.info("Records written this connection: %s", count)
                    except Exception:
                        logging.exception("record parse/write error; continuing")
        except ConnectionResetError:
            logging.warning("Connection reset by %s", peer)
        except Exception:
            logging.exception("Error handling %s", peer)
        finally:
            logging.info("CM disconnected %s:%s (records=%s)", peer[0], peer[1], count)
            try:
                conn.close()
            except Exception:
                pass


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def run_server(cfg: LoggerConfig) -> None:
    setup_logging(cfg.log_dir)
    writer = DailyWriter(cfg.log_dir)
    logging.info(
        "CDR logger starting listen=%s:%s log_dir=%s record_len=%s",
        cfg.host,
        cfg.port,
        cfg.log_dir,
        RECORD_LEN,
    )
    logging.info("Expect CM push from Main CM (NMC-CDR → this host). Format: customized.")

    class Handler(CdrHandler):
        pass

    Handler.writer = writer
    Handler.cfg = cfg

    with ThreadedTCPServer((cfg.host, cfg.port), Handler) as server:
        logging.info("Listening — waiting for CM CDR link…")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            logging.info("Shutdown requested")
        finally:
            writer.close()


def main(argv: Iterable[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description="Avaya CM CDR TCP logger (daily TXT files)")
    p.add_argument("--host", default="0.0.0.0", help="Bind address (default 0.0.0.0)")
    p.add_argument("--port", type=int, default=9000, help="TCP port CM Remote Port (default 9000)")
    p.add_argument(
        "--log-dir",
        type=Path,
        default=here / "cdr",
        help="Directory for YYYYMMDD.TXT (default ./cdr)",
    )
    args = p.parse_args(list(argv) if argv is not None else None)
    cfg = LoggerConfig(host=args.host, port=args.port, log_dir=args.log_dir.resolve())
    run_server(cfg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
