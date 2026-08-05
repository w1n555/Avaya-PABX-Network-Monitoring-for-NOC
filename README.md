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

## IIS deploy (xcopy)

### Prerequisites on server

1. **IIS** with static content  
2. **ASP.NET Core 8 Hosting Bundle**  
   https://dotnet.microsoft.com/download/dotnet/8.0  
3. Network path from IIS server → CM **TCP 5022**

### Publish (on a build PC)

```powershell
cd scripts
.\publish-iis.ps1
```

Produces `deploy\CM\` with:

```
CM\
  index.html
  app.js
  style.css
  web.config
  api\          ← published CmApi
    web.config
    CmApi.dll
    ...
```

### Install

1. Copy **contents** of `deploy\CM\` → `C:\inetpub\wwwroot\CM\`  
2. IIS Manager → site → **CM\api** → **Convert to Application**  
   - Application pool: **No Managed Code**, integrated  
3. Browse: `http://localhost/CM/`  

Frontend calls **`./api/...`** automatically (same folder tree).

Optional: disable site logging in IIS (business requirement: no CDR / no local logging of calls).

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
