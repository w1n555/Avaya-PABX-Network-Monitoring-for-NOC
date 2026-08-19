# avaya-ossi (AVAYA-OSSI-2026)

**Standalone, read-only** client for **Avaya Aura Communication Manager** OSSI over SSH.

- Not a dashboard. Not IIS. Not CDR.
- Any app (NOC UI, scripts, sidecar API) can install and call it.
- Point it at **your** CM with env vars — no hard-coded customer IP.

Verified style: **CM 10.2**, terminal type **`ossit`**, SAT port **5022**.

---

## Features

| Feature | Detail |
|---------|--------|
| Read-only gate | **Only** commands starting with `list` / `display` / `status` |
| Long-lived session | Login once; reuse SSH+OSSI for later commands |
| Idle logoff | Default **30 minutes**; every command resets the timer |
| Error recovery | On failure → reconnect + **one** retry |
| Huge lists | `max_more_pages` then answer **`n`** (safe sample) |
| Forms | `run(..., form_fields=["0001y"])` → `f0001\\tvalue` then `t` |
| Installable package | `pip install -e .` → `import avaya_ossi` |

---

## Read-only policy (important)

This library **deliberately** allows only SAT/OSSI commands that start with:

| Allowed prefix | Examples |
|----------------|----------|
| `list` | `list station`, `list trunk-group` |
| `display` | `display time`, `display system-parameters maintenance` |
| `status` | `status trunk 1`, `status station 20002`, `status logins` |

Anything else is **rejected in the client before SSH send** (e.g. `change`, `save`, `busyout`, `reload`, `monitor …`).

- This is a **software safety gate** on top of CM login profile rights.
- Prefer a **read-only** CM account as well (e.g. `monitor`).
- Details: [docs/SAFETY.md](docs/SAFETY.md).

### For future maintainers — if you need to change this

**Default for this repo is read-only monitoring. Do not relax the gate casually on production Main CM.**

If you **intentionally** need more commands (your risk, your change):

| What | Where |
|------|--------|
| **Allowed prefixes** (`list` / `display` / `status`) | `src/avaya_ossi/safety.py` → `assert_readonly_command()` |
| **Forbidden keywords** (`change`, `save`, `busyout`, …) | `src/avaya_ossi/safety.py` → `FORBIDDEN_TOKENS` |
| Enforced on every `run()` | `src/avaya_ossi/session.py` (calls `assert_readonly_command`) |
| CLI oneshot / multi-command | same gate via `session` / CLI |

Also update **this README** and **docs/SAFETY.md** so the next person knows the policy changed.

There is **no** config flag to open write commands — change the code above on purpose, or fork. That is intentional.

---

## Install

```powershell
cd /path/to/AVAYA-OSSI-2026
python -m venv .venv
# Windows:
.\.venv\Scripts\Activate.ps1
# Linux/macOS:
# source .venv/bin/activate

pip install -e .
copy .env.example .env   # or: cp .env.example .env
# edit .env — set CM_HOST and CM_PASSWORD (never commit .env)
```

**Python:** 3.11+

---

## Configure

| Variable | Required | Default | Meaning |
|----------|----------|---------|---------|
| `CM_HOST` | **yes** | — | CM IP or hostname |
| `CM_PASSWORD` | **yes** | — | SAT password |
| `CM_PORT` | | `5022` | SSH / SAT port |
| `CM_USERNAME` | | `monitor` | Prefer a RO login |
| `CM_PIN` | | | Access code if prompted |
| `CM_OSSI_TERM` | | `ossit` | try `ossi` if needed |
| `CM_IDLE_LOGOFF_MINUTES` | | `30` | Idle → logoff |
| `CM_MAX_MORE_PAGES` | | `80` | Cap `more?[y]` |
| `CM_READ_TIMEOUT` | | `120` | Per-command read (seconds) |
| `CM_CONNECT_TIMEOUT` | | `20` | SSH connect (seconds) |

---

## Library usage (other repos / apps)

```python
from avaya_ossi import OssiSession, load_session_config, ConfigError

try:
    cfg = load_session_config()  # reads .env / environment
except ConfigError as e:
    raise SystemExit(e)

with OssiSession(cfg) as sess:
    r1 = sess.run("status trunk 1")          # logs in
    r2 = sess.run("list trunk-group")        # reuses session
    r3 = sess.run("list station", max_more_pages=5)  # sample only
    r4 = sess.run("display alarms", form_fields=["0001y"])  # Active=y (tab FID)

    print(r1.ok, r1.elapsed_seconds, r1.did_login)
    print(r2.used_existing_session)          # True
    # r*.text  → stripped OSSI text
    # r*.raw   → full exchange
```

### How a Dashboard repo should call this

```text
Dashboard / CmApi  ──import──►  avaya-ossi  ──SSH:5022──►  your CM
```

1. On the machine that can reach CM:  
   `pip install -e /path/to/AVAYA-OSSI-2026`
2. Import `OssiSession` (Python service) **or** expose a thin local HTTP wrapper and call it from C#/other.
3. Do **not** copy SSH/OSSI code into the dashboard — depend on this package.

C# IIS apps cannot `import` Python directly; use a small Python sidecar HTTP API, or re-implement the same policy in C# using [docs/PROTOCOL.md](docs/PROTOCOL.md).

---

## CLI

```powershell
# Long-lived session (multiple -c commands share one login)
avaya-ossi -c "status trunk 1" -c "list trunk-group" -q

# One-shot debug
avaya-ossi-oneshot -c "display time" -q

# Same as avaya-ossi
python -m avaya_ossi -c "status trunk 1" -q

# Sample first pages of a large station list
avaya-ossi -c "list station" --max-more-pages 3 -q
```

---

## Safety

See [docs/SAFETY.md](docs/SAFETY.md).

- Use a **read-only** CM login when possible.
- Do not flood production Mains.
- This client does not send `change` / `save` / `busyout` / `reload` / etc.

---

## Repository layout

```text
AVAYA-OSSI-2026/
  README.md
  pyproject.toml          # package metadata + entry points
  requirements.txt        # same deps (optional; prefer pip install -e .)
  .env.example
  docs/
    SAFETY.md
    PROTOCOL.md
    TEST-RESULTS.md
  src/avaya_ossi/         # installable library
    __init__.py           # public API
    version.py
    config.py
    safety.py
    io.py
    session.py            # OssiSession
    cli.py
    oneshot.py
  scripts/                # thin wrappers (package must be installed)
  samples/                # optional local captures (gitignored raw_*)
```

Internal modules are split for clarity; **callers only need** `import avaya_ossi`.

---

## Public API (stable surface)

| Name | Role |
|------|------|
| `load_session_config()` | Env / `.env` → `SessionConfig` |
| `SessionConfig` | Immutable settings |
| `OssiSession` | Context manager; `run()` / `status()` / `close()` |
| `CommandResult` | `ok`, `text`, `raw`, `did_login`, `used_existing_session`, … |
| `assert_readonly_command()` | Safety check |
| `ConfigError` | Missing host/password/etc. |
| `__version__` | Package version |

---

## Status

| Area | State |
|------|--------|
| OSSI connect + RO commands | Done |
| Long-lived session + idle logoff | Done |
| Package install | Done |
| Standalone (any CM via env) | Done |
| Field parsers / dashboard UI | Out of scope (app layer) |
| Unit test / CI | Out of scope for this release |

---

## References

- [deesnow/ossi_tool](https://github.com/deesnow/ossi_tool)  
- [ikhomutov/python-ossi](https://github.com/ikhomutov/python-ossi)  

Protocol detail: [docs/PROTOCOL.md](docs/PROTOCOL.md).
