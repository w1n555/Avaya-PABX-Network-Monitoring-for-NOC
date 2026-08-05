# Avaya PABX Network Monitoring for NOC

Private project: **live** Avaya Communication Manager trunk monitoring for NOC.

- **UI:** static files (no npm / no build) — TELECOM360-style drop-in  
- **API:** ASP.NET Core 8 under `api/` — used **only** by the web UI to poll CM SAT (SSH)  
- **Export:** browser-side **CSV** (UTF-8 BOM)  
- **CM access:** read-only (`list` / `display` / `status`) — **no** change/save, **no** CDR logging  

Default Main CM: `172.29.88.12:5022` · Terminal: **VT220**

---

## Repository layout

```
web/                 → static dashboard (index.html, app.js, style.css)
src/CmApi/           → live SAT API (SSH.NET)
scripts/publish-iis.ps1
deploy/CM/           → output of publish (xcopy this to IIS)
```

---

## Local path = IIS path (this machine)

| Item | Value |
|------|--------|
| **Source + site root** | `C:\inetpub\wwwroot\CM` |
| **URL** | `http://127.0.0.1:8888/CM/` |
| **API** | `http://127.0.0.1:8888/CM/api/` (auto-used by UI) |

```
C:\inetpub\wwwroot\CM\
  index.html, app.js, style.css, web.config   ← static UI (site root)
  web\                                        ← edit static here, then publish
  api\                                        ← published ASP.NET Core app
  src\CmApi\                                  ← API source
  scripts\publish-iis.ps1
```

### Prerequisites

1. **IIS** (site on port **8888**)  
2. **ASP.NET Core 8 Hosting Bundle**  
3. Network to CM **TCP 5022**  
4. IIS: **`/CM/api` Convert to Application** · App Pool **No Managed Code**

### Publish (in-place)

```powershell
cd C:\inetpub\wwwroot\CM\scripts
.\publish-iis.ps1
```

Then open: **http://127.0.0.1:8888/CM/**

Frontend calls **`./api/...`** (same folder tree). Site `web.config` sets `httpLogging dontLog` (no call logging).

---

## API (automatic use only)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/session/connect` | SSH login + VT220 + `display time` probe |
| POST | `/api/session/disconnect` | Drop session (memory) |
| GET | `/api/session/status` | Connected? last success/attempt |
| GET | `/api/trunks` | `list trunk-group` |
| GET | `/api/trunks/{tg}` | `display trunk-group` + `status trunk` |
| GET | `/api/health` | Liveness |

Session id in **HttpOnly cookie** `cm_sid` (password only in RAM).

---

## Safety

- Command blocklist rejects `change` / `add` / `remove` / `save` / `busyout` / `release` / `reset`  
- No database, no CDR collector  
- Credentials not written to disk by the app  

---

## Local API debug (without IIS)

```powershell
cd src\CmApi
dotnet run
# API on http://localhost:5xxx — point app.js API base if needed
```

---

## Trunk UI

1. **Index** — trunk groups, filter, sort, stats, CSV export  
2. **Detail** — click name → config text + channels; CSV export  
3. **Last success / last attempt** — failed refresh keeps last good data  

Channel fields Caller / Called / Duration / Extension are **best-effort** from `status trunk` (often empty when idle).
