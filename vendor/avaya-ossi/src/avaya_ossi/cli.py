"""CLI entry: ``avaya-ossi`` / ``python -m avaya_ossi``."""

from __future__ import annotations

import argparse
import sys
import time

from avaya_ossi.config import ConfigError, load_session_config
from avaya_ossi.io import count_data_rows
from avaya_ossi.safety import assert_readonly_command
from avaya_ossi.session import OssiSession
from avaya_ossi.version import __version__


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="avaya-ossi",
        description=(
            "Read-only Avaya CM OSSI — long-lived session "
            "(reuse login; idle logoff; re-login only on error)."
        ),
    )
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    p.add_argument("--host", default=None, help="CM host (or CM_HOST)")
    p.add_argument("--port", default=None, help="SSH/SAT port (default 5022)")
    p.add_argument("--username", default=None, help="Login (default monitor)")
    p.add_argument("--password", default=None, help="Prefer CM_PASSWORD env")
    p.add_argument("--pin", default=None, help="Optional PIN / access code")
    p.add_argument("--ossi-term", default=None, choices=["ossit", "ossi"])
    p.add_argument(
        "--idle-minutes",
        type=float,
        default=None,
        help="Idle minutes before logoff (default 30)",
    )
    p.add_argument(
        "--max-more-pages",
        type=int,
        default=None,
        help="Cap more?[y] pages (default 80). Use small value to sample huge lists.",
    )
    p.add_argument(
        "--command",
        "-c",
        action="append",
        dest="commands",
        default=None,
        help="RO command (repeatable). Default: status trunk 1",
    )
    p.add_argument(
        "--pause",
        type=float,
        default=1.0,
        help="Seconds between commands (default 1)",
    )
    p.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="Timing/flags only; less raw dump",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        cfg = load_session_config(
            host=args.host,
            port=args.port,
            username=args.username,
            password=args.password,
            pin=args.pin,
            ossi_term=args.ossi_term,
            idle_logoff_minutes=args.idle_minutes,
            max_more_pages=args.max_more_pages,
        )
    except ConfigError as exc:
        print(f"Config error: {exc}", file=sys.stderr)
        return 2

    commands = args.commands or ["status trunk 1"]
    try:
        for c in commands:
            assert_readonly_command(c)
    except ValueError as exc:
        print(f"Safety: {exc}", file=sys.stderr)
        return 2

    print(f"avaya-ossi {__version__} (read-only, long-lived session)")
    print(f"  host           : {cfg.host}:{cfg.port}")
    print(f"  username       : {cfg.username}")
    print(f"  idle logoff    : {cfg.idle_logoff_seconds / 60:.1f} min")
    print(f"  max more pages : {cfg.max_more_pages}")
    print(f"  commands       : {commands}")
    print()

    exit_ok = True
    with OssiSession(cfg) as sess:
        for i, cmd in enumerate(commands):
            if i and args.pause > 0:
                time.sleep(args.pause)
            print(f"--- [{i + 1}/{len(commands)}] {cmd} ---")
            st_before = sess.status()
            print(
                f"  before: connected={st_before['connected']} "
                f"until_logoff={st_before['seconds_until_idle_logoff']}"
            )
            result = sess.run(cmd)
            drows = count_data_rows(result.raw) if result.raw else 0
            print(
                f"  ok={result.ok}  elapsed={result.elapsed_seconds:.2f}s  "
                f"existing_session={result.used_existing_session}  "
                f"did_login={result.did_login}  retried={result.retried_after_error}  "
                f"more_pages={result.more_pages}  d_rows≈{drows}  "
                f"truncated={result.truncated_pages}"
            )
            if result.error:
                print(f"  error: {result.error}")
                exit_ok = False
            if not result.ok:
                exit_ok = False
            if not args.quiet:
                text = result.text
                print(text[:2500] if len(text) > 2500 else text)
            st_after = sess.status()
            print(
                f"  after: connected={st_after['connected']} "
                f"logins={st_after['login_count']} cmds={st_after['command_count']}"
            )
            print()

        print("session:", sess.status())

    print("Done.")
    return 0 if exit_ok else 1


if __name__ == "__main__":
    sys.exit(main())
