# Avaya PABX Network Monitoring for NOC

IIS web UI for **read-only** Avaya CM 10.x monitoring (OSSI SSH :5022, not SAT scraping).

**Install anywhere** (any Windows folder). OSSI client is **bundled** under `vendor/avaya-ossi`.

---

## Architecture

```text
Browser (HTML/CSS/JS)     tabs: Map · Trunk · Gateway · Extension · CDR · Alarm
    │  /CM/api/*
    ▼
CmApi (.NET 8, IIS)       thin proxy · start OSSI bridge / CDR logger if needed
    │  http://127.0.0.1:18776   (bridge HTTP)
    ▼
python/ossi_service.py    one OssiSession, bind 0.0.0.0:18776
    │  SSH :5022 ossit
    ▼
Avaya CM (read-only list / display / status)

CDR TCP 0.0.0.0:9000  →  cdr-link/cdr/YYYYMMDD.TXT   (call records only)
```

- Login is **manual** (CM Host / RO user / password). Password stays in bridge memory — **never written under wwwroot**.
- **F5** keeps the OSSI session (no disconnect on refresh). Closing the browser tab logs off OSSI after the UI heartbeat stops (~90s).
- While Auto is on, the **open** Map / Trunk / Gateway / Alarm tab packs **Trunk + Active Alarms + list media-gateway** every **90s** (plus open Gateway Details `list configuration`). Extension is hourly, queued so it does not overlap the pack.
- Only **monitored** trunk groups are polled (`status trunk N`).

---

## File structure

```text
<your-extract-folder>/
  index.html style.css app.js *-ui.js web.config
  map/                  # sites.json + offline tiles
  data/  data_live/     # runtime JSON (per machine; not the live alarm/gw caches in git)
  python/               # OSSI bridge
  vendor/avaya-ossi/    # bundled OSSI library
  cdr-link/             # CDR logger + daily TXT
  api/                  # published CmApi
  src/CmApi/            # source
  scripts/install.ps1   # one-click setup (any machine)
  README.md INSTALL.txt
```

---

## UI

| Tab | Behaviour |
|-----|-----------|
| **Map View** | Offline HK map (`map/sites.json`). Pin: MAJOR or DOWN = red; MINOR = yellow; WARNING = green. KPI Major/Minor = **GW boxes + CM-own** (not Alarm row count). Global **Next 90s** / Auto status / Updated. |
| **Trunk** | Monitored TGs. Green &lt;70% · Yellow 70–90% · Red &gt;90% or Idle=0. `0/0/0` → **UPDATE FAILED** (not util red). Auto **90s**. |
| **Gateway** | `list media-gateway`. Denominator = remembered MG set. **Reg=n** = DOWN. Missing this poll = **UPDATE FAILED**. Click-in `list configuration` (ports: used=blue; MJ red / MN yellow / WN orange). |
| **Extension** | `list extension` + `list station`, hourly, queued. |
| **CDR** | Search daily TXT (cap 5000, red if capped). Logger pill UP/DOWN. Login/IIS can **ensure** `:9000` if nothing is listening (skip if already up). |
| **Alarm** | Active only (`display alarms`). Search + mtce filters. Date Alarmed newest first. **Ack = stop webpage flash only** (does not clear CM). |

**Page flash:** Active MAJOR (CM **or** any G450 MJ) → red; else MINOR → yellow. WARNING / Acked → no flash. Gateway **DOWN** is a red pin; CM usually also raises MED-GTWY MAJOR so flash is already on.

---

## Deploy（最易食：一鍵）

**目標：** 下載 → 解壓 → `install.ps1` → 開網頁 Login

### 用戶自己先裝

1. **IIS**（Windows 功能）— 腳本只 detect，唔代裝

### 然後一鍵（Admin）

```powershell
# 解壓到任意目錄後（Admin）：
cd <你的解壓目錄>\scripts
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

腳本會：

1. **Detect IIS**（未裝就提示）
2. **檢查 / 自動裝 .NET 8 Hosting Bundle**
3. **檢查 / 自動裝 Python 3.12 + PATH**
4. **問 LOCAL ROOT path**（預設 = 呢個 package 目錄）
5. **IIS Nested / 寄生（預設）**
   - 你輸入 **現有 IIS port**
   - 只加 `/CM` + `/CM/api`
   - **永遠唔改** 該 site 嘅 ROOT / 首頁
6. 建 venv + 裝內置 `vendor\avaya-ossi`
7. 註冊 bridge 開機 Task（OSSI **0.0.0.0:18776**；CmApi 仍連 `127.0.0.1:18776`）
8. URL：`http://127.0.0.1:<port>/CM/`

可選：`-SkipDotNetInstall` / `-SkipPythonInstall`

### 日常

開網頁 → 填 **CM Host / Password** → **Login** → 自動 monitor。

唔使每次手動開 bridge。詳見 `INSTALL.txt`。

### 新裝 / 舊機升級 — 同一句

```powershell
cd <你的解壓目錄>\scripts
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

- 有 `.git` → **自動 `git pull`**
- 已有 `api` / venv / data → **upgrade**（重 publish、重配 IIS、重啟 bridge）
- **保留** `data\monitored_trunks.json`
- 或 `scripts\one-click-deploy.ps1`（Admin）

---

## API (under `/CM/api`)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | API + bridge (+ optional CDR ensure) |
| POST | `/session/connect` | OSSI login (also tries CDR logger ensure) |
| POST | `/session/disconnect` | Logoff |
| GET | `/session/status` | Connected? |
| POST | `/refresh` · `/refresh/one` | Poll monitored TGs (magic TGs: 9996 alarms, 9995 gateways, 9994 extensions, 990000+MG = GW config) |
| GET | `/trunk-data` | Snapshot |
| GET | `/alarms` · POST `/alarms/refresh` | Active alarms cache |
| GET | `/gateways` · POST `/gateways/refresh` | Media gateway list |
| GET | `/gateways/{mg}/config` | Media modules / ports |
| GET | `/extensions` · POST `/extensions/refresh` | Extension list |
| GET/PUT | `/monitored` | TG list |
| POST | `/monitored/add` · `/monitored/remove` | `{ "tg": 1 }` |
| GET | `/cdr/status` · `/cdr/logger` · POST `/cdr/logger/ensure` | CDR files + logger listen |
| GET | `/cdr/files` · `/cdr/scan-day` | Search / hourly |

---

## Safety

- OSSI commands are **list / display / status** only (RO CM login recommended).
- Do not put the CM password in files under the web root.
- Only **CDR** is written as call logs (`cdr-link/cdr/`). Do not log OSSI sessions.
- Default pack is **90s** + monitored TGs — do not poll every trunk every second.

---

## GitHub

Remote: `https://github.com/w1n555/Avaya-PABX-Network-Monitoring-for-NOC`
