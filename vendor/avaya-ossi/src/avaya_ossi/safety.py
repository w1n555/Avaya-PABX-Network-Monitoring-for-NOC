"""
Read-only command gate — no write / maintenance ops.

Only commands starting with list / display / status are allowed.
To change that policy (not recommended on production Main), edit this file:
  - FORBIDDEN_TOKENS
  - assert_readonly_command() allowed prefixes
Then update README.md and docs/SAFETY.md.
"""

from __future__ import annotations

from typing import Final

FORBIDDEN_TOKENS: Final[tuple[str, ...]] = (
    "change",
    "add ",
    "remove",
    "duplicate",
    "edit",
    "save",
    "busyout",
    "release",
    "reset",
    "reload",
    "reboot",
    "monitor ",  # interactive monitor screens (not account name "monitor")
    "upload",
    "download",
)


def assert_readonly_command(command: str) -> str:
    """Normalize and reject non-read-only commands."""
    cmd = " ".join(command.strip().split())
    if not cmd:
        raise ValueError("Empty command")
    lower = cmd.lower()
    for token in FORBIDDEN_TOKENS:
        if token in lower:
            raise ValueError(f"Forbidden token {token!r} in command: {cmd!r}")
    if not lower.startswith(("list", "display", "status")):
        raise ValueError(f"Only list/display/status allowed, got: {cmd!r}")
    return cmd
