# Avaya PABX Network Monitoring for NOC

Private project: **live** Avaya Communication Manager trunk monitoring for NOC.

| Item | Value |
|------|--------|
| **Source + IIS folder** | `C:\inetpub\wwwroot\CM` |
| **URL (this machine)** | `http://127.0.0.1:8888/CM/` |
| **API (auto by UI)** | `http://127.0.0.1:8888/CM/api/` |
| **Default Main CM** | `172.29.88.12:5022` · Terminal **VT220** |
| **Export** | Browser CSV only |
| **Safety** | Read-only SAT · **no** change/save · **no** CDR logging |

- **UI:** static files (no npm / no build)  
- **API:** ASP.NET Core 8 under `api/` — used **only** by the web UI  

GitHub: https://github.com/w1n555/Avaya-PABX-Network-Monitoring-for-NOC  

---

## Do I need IIS GUI every time?

| Situation | What to do |
|-----------|------------|
| **First time** / new server | Run **`one-click-deploy.ps1`** as Admin (or Option B GUI once) |
| **Later updates** (code change) | Run **`one-click-deploy.ps1`** again as Admin |
| Hosting Bundle **already installed** | Script **auto-skips** download — no flag needed |

Only one deploy script: **`scripts\one-click-deploy.ps1`**.

---

# Option A — One-click deploy (only script you need)

**Run PowerShell as Administrator**, then:

```powershell
cd C:\inetpub\wwwroot\CM\scripts
Set-ExecutionPolicy -Scope Process Bypass -Force
.\one-click-deploy.ps1
```

### Hosting Bundle — auto skip?

**Yes.** The script checks for ASP.NET Core Module (ANCM):

| Detected | Behaviour |
|----------|-----------|
| Bundle / ANCM **already installed** | Prints `ANCM already installed - skip download` and **does not download** |
| **Not** installed | Downloads (with progress) and installs quietly |

You do **not** need `-SkipBundleDownload` in normal use.  
That switch is only for rare cases (e.g. offline machine, install bundle yourself later).

The script shows a **0–100% progress bar** and will:

1. Check Administrator  
2. Detect / enable **IIS** (if missing)  
3. Install **ASP.NET Core 8 Hosting Bundle** only if missing (**auto-skip** if present)  
4. Prepare `C:\inetpub\wwwroot\CM`  
5. Copy project / static UI files  
6. `dotnet publish` API → `CM\api`  
7. Create App Pool **CmApiNoManaged** (**.NET CLR = No Managed Code**)  
8. Create/update IIS Application **`/CM`** and **`/CM/api`**  
9. Smoke-test UI + `http://127.0.0.1:8888/CM/api/health`  
10. Finish at **100%**

Optional (rarely needed):

```powershell
.\one-click-deploy.ps1 -SitePort 8888
.\one-click-deploy.ps1 -SkipBundleDownload      # force skip even if ANCM not detected
.\one-click-deploy.ps1 -SkipIisFeatureInstall   # skip enabling IIS features
```

See also: `scripts\ONE-CLICK-DEPLOY.txt`

If the one-click script cannot run (no admin / corporate policy), use **Option B (GUI)** below.

---

# Option B — First-time IIS setup (GUI) — step by step

Do this **once** on each Windows server that will host the app (only if you do **not** use one-click).

---

### Step 0 — Put files on disk

Folder must look like:

```
C:\inetpub\wwwroot\CM\
  index.html
  app.js
  style.css
  web.config
  api\              ← published API (CmApi.dll, web.config, …)
  web\
  src\
  scripts\
```

If `api\` is missing or empty, run **Option A** `one-click-deploy.ps1` as Administrator (requires .NET SDK to publish).

---

### Step 1 — Install ASP.NET Core 8 Hosting Bundle

1. Download **ASP.NET Core 8.0 Hosting Bundle**  
   https://dotnet.microsoft.com/download/dotnet/8.0  
   → under **Run apps - Runtime** → **Hosting Bundle**
2. Install it (Next → Finish).
3. **Restart IIS** (important):

```powershell
# Run PowerShell as Administrator
iisreset
```

Or: open **Services** → restart **World Wide Web Publishing Service**.

Without this bundle, `/CM/api` will not run.

---

### Step 2 — Open IIS Manager

1. Press `Win` key, type **IIS**, open **Internet Information Services (IIS) Manager**.  
2. Left tree: expand your PC name → **Sites**.

You should already have a site that listens on **port 8888** (or whatever you use) and can serve files under `C:\inetpub\wwwroot\…`.

If the site does **not** exist yet:

1. Right-click **Sites** → **Add Website…**  
2. Example:  
   - **Site name:** `NOC` (any name)  
   - **Physical path:** `C:\inetpub\wwwroot`  
   - **Binding:** `http` · Port **`8888`** · IP All Unassigned  
3. Click **OK**.

---

### Step 3 — Confirm `/CM` is visible

1. Expand your site (e.g. Default Web Site or NOC).  
2. You should see a folder **`CM`** under the site.  
3. Click **CM** → right panel **Browse \*:8888 (http)** or open browser:

   **http://127.0.0.1:8888/CM/**

You should see the dashboard page (even if Connect fails until API is set).

If `CM` folder is missing: copy the project into `C:\inetpub\wwwroot\CM` first.

---

### Step 4 — Convert `api` to an Application (most important)

The folder `CM\api` must be an **IIS Application**, not a plain folder.

1. In left tree: **Sites** → *your site* → **CM** → select folder **`api`**.  
2. **Right-click `api`** → **Convert to Application…**  
3. In **Add Application**:  
   - **Alias:** `api` (leave default)  
   - **Application pool:** click **Select…**  
     - Prefer a pool with **.NET CLR version = No Managed Code**  
     - If none: click **Application Pools** (left) → **Add Application Pool…**  
       - Name: e.g. `CmApiNoManaged`  
       - **.NET CLR version:** **No Managed Code**  
       - Managed pipeline: **Integrated**  
       - OK, then Select this pool for the `api` app  
   - **Physical path:** should be  
     `C:\inetpub\wwwroot\CM\api`  
4. Click **OK**.

After this, left tree should show **`api`** with a different icon (application gear), not a yellow folder.

---

### Step 5 — App Pool quick check

1. Left: **Application Pools**.  
2. Select the pool used by **CM/api**.  
3. Confirm:  
   - **.NET CLR version:** **No Managed Code**  
   - **Status:** Started  
4. If you changed anything: right-click pool → **Recycle**.

---

### Step 6 — Permissions (if 500.19 / 500.30 / access denied)

App Pool identity needs **read/execute** on:

`C:\inetpub\wwwroot\CM\api`

Usually **IIS_IUSRS** / pool identity already inherits from `wwwroot`.  
If API fails with access errors:

1. Right-click folder `C:\inetpub\wwwroot\CM\api` → **Properties** → **Security**.  
2. Ensure **IIS_IUSRS** has **Read & execute**.  
3. Apply → OK.

---

### Step 7 — Test API alone

Browser or PowerShell:

```text
http://127.0.0.1:8888/CM/api/health
```

Expected JSON similar to:

```json
{"ok":true,"service":"CmApi","mode":"read-only-sat"}
```

| Result | Meaning |
|--------|---------|
| JSON ok | Application + Hosting Bundle OK |
| 404 | `api` not converted to Application, or wrong path |
| 500.0 / ANCM errors | Hosting Bundle missing or IIS not restarted after install |
| Blank / 403 | Permissions or site binding |

---

### Step 8 — Test full dashboard

1. Open: **http://127.0.0.1:8888/CM/**  
2. Fill:  
   - Host: `172.29.88.12`  
   - Port: `5022`  
   - User: `monitor`  
   - Password: *(your RO password)*  
3. Click **Connect**.  
4. Trunk list should load from **live** CM.  
5. Click a **trunk name** → channel status.  
6. **Export CSV** if needed.

PC must reach CM on **TCP 5022** (your `172.29.0.0/16` Ethernet route).

---

### Step 9 — Optional: reduce IIS logging

App already sets `httpLogging dontLog` on site `web.config` where supported.  
To turn off site logging in GUI:

1. Select your **site** → **Logging**.  
2. Right side **Disable** (if your policy allows).

This is **not** CDR; we never collect call detail records.

---

## After first setup — update / redeploy

```powershell
# Admin PowerShell — same one-click script
cd C:\inetpub\wwwroot\CM\scripts
.\one-click-deploy.ps1
```

If Bundle is already installed, download is **skipped automatically**.  
Then refresh browser: **http://127.0.0.1:8888/CM/**

---

## New server checklist

Run **`one-click-deploy.ps1` as Administrator** on the new server (or Option B GUI once).  
Copy/clone project into `C:\inetpub\wwwroot\CM` first if needed.

---

## Repository layout

```
C:\inetpub\wwwroot\CM\
  index.html, app.js, style.css, web.config   ← served as /CM/
  web\                                        ← edit UI here, then redeploy
  api\                                        ← published ASP.NET Core (IIS Application)
  src\CmApi\                                  ← API source
  scripts\one-click-deploy.ps1                ← only deploy script
  README.md
```

---

## API (automatic only — browser uses these)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/CM/api/session/connect` | SSH + VT220 + probe |
| POST | `/CM/api/session/disconnect` | Clear session |
| GET | `/CM/api/session/status` | Connected / last success |
| GET | `/CM/api/trunks` | `list trunk-group` |
| GET | `/CM/api/trunks/{tg}` | `status trunk` + config |
| GET | `/CM/api/health` | Liveness |

Session cookie `cm_sid` (HttpOnly). Password stays in server memory only.

---

## Safety

- Blocks `change` / `add` / `remove` / `save` / `busyout` / `release` / `reset`  
- No database, no CDR collector  
- Credentials not written to disk by the app  

---

## Trunk UI

1. **Index** — groups, filter, sort, stats, CSV  
2. **Detail** — click name → config + channels, CSV  
3. **Last success / last attempt** — failed refresh keeps last good data  

Caller / Called / Duration / Extension are **best-effort** from `status trunk` (often `—` when idle).

---

## Local API debug (without full IIS)

```powershell
cd C:\inetpub\wwwroot\CM\src\CmApi
dotnet run
```

---

## Troubleshooting quick table

| Symptom | What to check |
|---------|----------------|
| UI opens, Connect fails | `/CM/api/health` · Application created? · Hosting Bundle? |
| 404 on `/CM/api/health` | Convert **api** to Application |
| ANCM / 500.30 / 500.31 | Install Hosting Bundle + `iisreset` |
| Connect timeout to CM | Route/firewall to `172.29.88.12:5022` |
| Login fail | Username/password · RO account · port 5022 |
| Empty trunk list | Connected to Main CM (not LSP)? · Watch error line on UI |
