"""CLI entry: ``avaya-ossi-oneshot`` — login → one command → logoff."""

from __future__ import annotations

import argparse
import os
import sys
import time

from avaya_ossi.config import ConfigError, load_session_config
from avaya_ossi.io import count_data_rows
from avaya_ossi.safety import assert_readonly_command
from avaya_ossi.session import OssiSession
from avaya_ossi.version import __version__


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="avaya-ossi-oneshot",
        description="Read-only OSSI one-shot (login → one command → logoff).",
    )
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    p.add_argument("--host", default=None)
    p.add_argument("--port", default=None)
    p.add_argument("--username", default=None)
    p.add_argument("--password", default=None)
    p.add_argument("--pin", default=None)
    p.add_argument("--ossi-term", default=None, choices=["ossit", "ossi"])
    p.add_argument(
        "--command",
        "-c",
        default=None,
        help="Single RO command (or CM_TEST_COMMAND / list trunk-group)",
    )
    p.add_argument("--max-more-pages", type=int, default=None)
    p.add_argument("--quiet", "-q", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        cmd = assert_readonly_command(
            args.command or os.getenv("CM_TEST_COMMAND", "list trunk-group")
        )
        cfg = load_session_config(
            host=args.host,
            port=args.port,
            username=args.username,
            password=args.password,
            pin=args.pin,
            ossi_term=args.ossi_term,
            max_more_pages=args.max_more_pages,
        )
    except (ConfigError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    print(f"avaya-ossi-oneshot {__version__} (read-only)")
    print(f"  host    : {cfg.host}:{cfg.port}")
    print(f"  user    : {cfg.username}")
    print(f"  command : {cmd}")
    print()

    t0 = time.perf_counter()
    with OssiSession(cfg) as sess:
        r = sess.run(cmd)
    wall = time.perf_counter() - t0

    print(
        f"ok={r.ok} cmd_s={r.elapsed_seconds:.2f} wall_s={wall:.2f} "
        f"more={r.more_pages} d_rows≈{count_data_rows(r.raw)} "
        f"truncated={r.truncated_pages} did_login={r.did_login}"
    )
    if r.error:
        print(f"error: {r.error}")
    if not args.quiet:
        text = r.text
        print(text[:4000] if len(text) > 4000 else text)
    return 0 if r.ok else 1


if __name__ == "__main__":
    sys.exit(main())
