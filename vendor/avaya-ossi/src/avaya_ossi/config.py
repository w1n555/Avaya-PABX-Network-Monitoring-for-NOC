"""Session / connection config from env or explicit args.

No customer-specific host defaults — every deployment supplies its own CM.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover

    def load_dotenv(*_a: object, **_k: object) -> bool:
        return False


class ConfigError(ValueError):
    """Missing or invalid configuration."""


@dataclass(frozen=True, slots=True)
class SessionConfig:
    """Immutable connection + session policy settings."""

    host: str
    port: int
    username: str
    password: str
    pin: str = ""
    ossi_term: str = "ossit"
    connect_timeout: float = 20.0
    banner_timeout: float = 25.0
    read_timeout: float = 120.0
    idle_logoff_seconds: float = 30 * 60
    idle_check_interval: float = 15.0
    max_more_pages: int = 80


def _find_dotenv() -> Path | None:
    """Prefer package repo .env, then process cwd (walk up a few levels)."""
    here = Path(__file__).resolve()
    candidates: list[Path] = [
        here.parents[2] / ".env",  # repo root with src/ layout
        Path.cwd() / ".env",
    ]
    for parent in list(here.parents)[:5]:
        candidates.append(parent / ".env")
    seen: set[Path] = set()
    for p in candidates:
        rp = p.resolve() if p.exists() else p
        if rp in seen:
            continue
        seen.add(rp)
        if p.is_file():
            return p
    return None


def _env(name: str, default: str = "") -> str:
    """Read env var; tolerate UTF-8 BOM on the key name from some editors."""
    if name in os.environ:
        return os.environ[name]
    bom_key = "\ufeff" + name
    if bom_key in os.environ:
        return os.environ[bom_key]
    return default


def load_session_config(
    *,
    host: str | None = None,
    port: int | str | None = None,
    username: str | None = None,
    password: str | None = None,
    pin: str | None = None,
    ossi_term: str | None = None,
    idle_logoff_minutes: float | None = None,
    max_more_pages: int | None = None,
    read_timeout: float | None = None,
    connect_timeout: float | None = None,
    require: bool = True,
) -> SessionConfig:
    """
    Build :class:`SessionConfig` from explicit kwargs and/or environment.

    Required (unless passed as kwargs): ``CM_HOST``, ``CM_PASSWORD``.
    Optional: ``CM_PORT`` (5022), ``CM_USERNAME`` (monitor), ``CM_PIN``,
    ``CM_OSSI_TERM`` (ossit), ``CM_IDLE_LOGOFF_MINUTES`` (30),
    ``CM_MAX_MORE_PAGES`` (80), ``CM_READ_TIMEOUT`` (120).
    """
    env_path = _find_dotenv()
    if env_path is not None:
        # encoding utf-8-sig strips BOM so keys are CM_HOST not \\ufeffCM_HOST
        load_dotenv(env_path, encoding="utf-8-sig")
    load_dotenv(encoding="utf-8-sig")

    h = (host if host is not None else _env("CM_HOST", "")).strip()
    p_raw = port if port is not None else _env("CM_PORT", "5022")
    u = (username if username is not None else _env("CM_USERNAME", "monitor")).strip()
    pw = password if password is not None else _env("CM_PASSWORD", "")
    pn = pin if pin is not None else _env("CM_PIN", "")
    term = (ossi_term or _env("CM_OSSI_TERM", "ossit")).strip().lower()
    if term not in {"ossit", "ossi"}:
        term = "ossit"

    idle_env = _env("CM_IDLE_LOGOFF_MINUTES", "30")
    idle_min = (
        float(idle_logoff_minutes)
        if idle_logoff_minutes is not None
        else float(idle_env or "30")
    )
    if idle_min < 1:
        raise ConfigError("idle_logoff_minutes must be >= 1")

    more = max_more_pages
    if more is None:
        more = int(_env("CM_MAX_MORE_PAGES", "80"))
    if more < 0:
        raise ConfigError("max_more_pages must be >= 0")

    rto = read_timeout
    if rto is None:
        rto = float(_env("CM_READ_TIMEOUT", "120"))

    cto = connect_timeout
    if cto is None:
        cto = float(_env("CM_CONNECT_TIMEOUT", "20"))

    missing: list[str] = []
    if not h:
        missing.append("CM_HOST (or host=)")
    if not u:
        missing.append("CM_USERNAME (or username=)")
    if not pw:
        missing.append("CM_PASSWORD (or password=)")
    if missing and require:
        raise ConfigError(
            "Missing required settings: "
            + ", ".join(missing)
            + ". Copy .env.example → .env or pass kwargs. Never commit secrets."
        )

    try:
        p = int(p_raw)  # type: ignore[arg-type]
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"Invalid CM_PORT: {p_raw!r}") from exc

    return SessionConfig(
        host=h,
        port=p,
        username=u,
        password=pw or "",
        pin=(pn or "").strip(),
        ossi_term=term,
        connect_timeout=cto,
        idle_logoff_seconds=idle_min * 60.0,
        max_more_pages=more,
        read_timeout=rto,
    )
