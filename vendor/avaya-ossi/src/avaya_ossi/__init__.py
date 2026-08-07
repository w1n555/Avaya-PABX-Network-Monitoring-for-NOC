"""
avaya-ossi — read-only Avaya Communication Manager OSSI client.

Standalone library: any app can ``pip install`` and connect to **its own** CM.
Does not include a dashboard UI.

Install (editable)::

    pip install -e /path/to/AVAYA-OSSI-2026

Usage::

    from avaya_ossi import OssiSession, load_session_config

    cfg = load_session_config()  # CM_HOST + CM_PASSWORD from env / .env
    with OssiSession(cfg) as sess:
        r = sess.run("status trunk 1")
        print(r.ok, r.text)
"""

from __future__ import annotations

from avaya_ossi.config import ConfigError, SessionConfig, load_session_config
from avaya_ossi.safety import assert_readonly_command
from avaya_ossi.session import CommandResult, OssiSession
from avaya_ossi.version import __version__

__all__ = [
    "CommandResult",
    "ConfigError",
    "OssiSession",
    "SessionConfig",
    "assert_readonly_command",
    "load_session_config",
    "__version__",
]
