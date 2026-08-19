# OSSI protocol notes

## Upstream studied

1. **deesnow/ossi_tool** — SSH → terminal type **`ossit`** → OSSI session  
2. **ikhomutov/python-ossi** — line prefixes `c` / `f` / `d` / `e` / `t`

## Wire format

| Prefix | Meaning |
|--------|---------|
| `c` | command |
| `f` | field id(s) |
| `d` | data value(s) |
| `e` | error |
| `t` | end of transaction |

Typical send:

```text
cstatus trunk 1
t
```

Form commands (e.g. `display alarms`) need field lines **after** `c` and **before** `t`:

```text
cdisplay alarms
f0001	y
t
```

On CM 10.2 this lab, a glued FID such as `0001y` / `0001n` is rejected
(``not a valid FID format``). Use ``f{fid}\\t{value}`` (`run(..., form_fields=...)`).

Multi-page SAT forms may prompt `more?[y]`. This client answers **`y`** until
`max_more_pages`, then **`n`** (truncated sample).

**CM 10.2:** `more?[y]` is often **not** at end-of-line. The next `d`/`t` can
arrive in the **same SSH chunk** (`more?[y]\\nd00\\nt`). Do **not** treat a
mid-stream `t` as end-of-command — that drops remaining pages (seen on
`display alarms` / `list media-gateway`). Answer every new `more?[y]` by
**string position**, then wait for a short quiet idle after the last page.

## Session sketch

```text
SSH :5022
login (password / keyboard-interactive)
Terminal Type prompt → ossit  (or ossi)
then:  c<command>  [f-lines]  /  t
read: answer more?[y] by position; do not stop on a mid-page t
idle logoff → clogoff + drop SSH
```

## Long-lived session policy (`OssiSession`)

```text
run(command):
  if session open AND idle < IDLE_MINUTES:
      send c / t only                 # no login
  else:
      SSH login + ossit
      send c / t
  on transport / OSSI error:
      logoff/drop → login+ossit → retry once
  every action:
      reset idle timer
  background:
      if idle >= IDLE_MINUTES → clogoff + drop
```

Env: `CM_IDLE_LOGOFF_MINUTES` (default 30).

## CM 10.2 observations (reference lab)

1. SSH lands on **Terminal Type** (sending `sat` as terminal type → invalid).  
2. **`ossit`** enters OSSI (`t`).  
3. `list station` can be large — use page caps when sampling.  

Other CM releases may differ slightly; set `CM_OSSI_TERM=ossi` if needed.

## Install / import

```powershell
pip install -e /path/to/AVAYA-OSSI-2026
```

```python
from avaya_ossi import OssiSession, load_session_config, ConfigError
```

Dashboard or other apps import this package; they do not re-implement SSH/OSSI.
