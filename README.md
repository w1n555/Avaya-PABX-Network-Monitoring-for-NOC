# Avaya PABX Network Monitoring for NOC

IIS web UI for **read-only** Avaya CM monitoring.

**Path:** `C:\inetpub\wwwroot\CM`  
**Data path:** OSSI package [AVAYA-OSSI-2026](https://github.com/w1n555/AVAYA-OSSI-2026) (`avaya-ossi`) — **not** SAT VT220 screen scraping.

---

## Architecture

```text
Browser (HTML/CSS/JS)
    │  /CM/api/*
    ▼
CmApi (.NET 8, IIS)          thin proxy + start bridge if needed
    │  http://127.0.0.1:18765
    ▼
python/ossi_service.py       long-lived OssiSession (avaya-ossi)
    │  SSH :5022 ossit
    ▼
Avaya CM (read-only list/display/status)
    │
    ▼
data/trunk_data.json         status snapshot
data/monitored_trunks.json   which TG numbers to poll
```

- Connect still uses the **same RO account** (e.g. `monitor`) — password stays in memory on the bridge (not written to disk by the app).
- Auto refresh every **60s** on the bridge while connected; UI also reloads JSON every 60s when Auto is on.
- Only **monitored** trunk groups are polled (limits CM load).

---

## File structure

```text
C:\inetpub\wwwroot\CM\
  index.html          # UI (Trunk tab + placeholders)
  style.css
  app.js
  web.config
  data\
    monitored_trunks.json
    trunk_data.json
  python\
    ossi_service.py   # OSSI bridge
    trunk_parse.py
  api\                # published CmApi
  src\CmApi\          # source
  scripts\            # one-click deploy
  README.md
```

---

## UI (Trunk tab)

| Feature | Behaviour |
|---------|-----------|
| Columns | TG + name, Total, Idle, Busy, OOS, Utilization %, status colour, Last update |
| Colours | Green &lt;70% · Yellow 70–90% · Red &gt;90% or Idle=0 |
| Auto | 60 seconds |
| Admin | Add/remove TG → `monitored_trunks.json` |
| Tabs | Trunk active; Station / VDN / Alarm reserved (disabled) |

---

## Deploy (IIS)

1. Install **.NET 8 Hosting Bundle**, IIS site pointing at `C:\inetpub\wwwroot\CM` (e.g. port 8888).
2. Application **`/CM/api`** → physical path `C:\inetpub\wwwroot\CM\api`, app pool **No Managed Code**.
3. Install OSSI package:

```powershell
pip install -e C:\Users\W1NGGG\source\AVAYA-OSSI-2026
```

4. Publish API:

```powershell
cd C:\inetpub\wwwroot\CM\src\CmApi
dotnet publish -c Release -o C:\inetpub\wwwroot\CM\api
```

5. Start OSSI bridge (or let API auto-start it):

```powershell
python C:\inetpub\wwwroot\CM\python\ossi_service.py --data-dir C:\inetpub\wwwroot\CM\data
```

6. Open `http://127.0.0.1:8888/CM/` → Connect.

Or run `scripts\one-click-deploy.ps1` as Administrator (updated for OSSI).

---

## API (under `/CM/api`)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | API + bridge health |
| POST | `/session/connect` | OSSI login |
| POST | `/session/disconnect` | Logoff |
| GET | `/session/status` | Connected? |
| POST | `/refresh` | Re-poll monitored TGs |
| GET | `/trunk-data` | Snapshot (`trunk_data.json`) |
| GET/PUT | `/monitored` | List / replace TG list |
| POST | `/monitored/add` | `{ "tg": 1 }` |
| POST | `/monitored/remove` | `{ "tg": 1 }` |

---

## Adding a new tab (e.g. Station)

1. Enable the tab button in `index.html` (remove `disabled`).
2. Add a `<main id="panel-station">` panel.
3. Extend `python/ossi_service.py` with station collect + `data/station_data.json`.
4. Add CmApi routes if needed; keep OSSI **list/display/status** only.
5. Wire `app.js` tab switch (already generic for `data-tab` / `data-panel`).

---

## Safety

- Commands go through **avaya-ossi** RO gate (`list` / `display` / `status` only).
- Prefer RO CM login profile.
- Do not monitor dozens of TGs with 1s interval — default 60s + monitored list only.

---

## GitHub

Remote: `https://github.com/w1n555/Avaya-PABX-Network-Monitoring-for-NOC`
