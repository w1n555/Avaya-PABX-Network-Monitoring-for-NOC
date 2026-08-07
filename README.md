# Avaya PABX Network Monitoring for NOC

IIS web UI for **read-only** Avaya CM monitoring.

**Install anywhere** (any Windows folder). OSSI client is **bundled** under `vendor/avaya-ossi` — not SAT scraping.

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
<your-extract-folder>/
  index.html style.css app.js web.config
  data/                 # runtime JSON (per machine)
  python/               # OSSI bridge
  vendor/avaya-ossi/    # bundled OSSI library
  api/                  # published CmApi
  src/CmApi/            # source
  scripts/install.ps1   # one-click setup (any machine)
  README.md INSTALL.txt
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
2. **檢查 / 自動裝 .NET 8 Hosting Bundle**（缺先問再裝；winget 或官網下載）  
3. **檢查 / 自動裝 Python 3.12 + PATH**（缺先問再裝）  
4. **問 LOCAL ROOT path**（預設 = 呢個 package 目錄）  
5. **IIS Nested / 寄生（預設，所有機一樣）**  
   - 你輸入 **現有 IIS port**（已有其他 Web 都得）  
   - 只加 `/CM` + `/CM/api` 指去你填嘅 ROOT  
   - **永遠唔改** 該 site 嘅 ROOT path / 首頁  
6. 建 site venv + 裝內置 `vendor\avaya-ossi`  
7. 註冊 bridge 開機 Task  
8. URL：`http://127.0.0.1:<port>/CM/`  

可選：`-SkipDotNetInstall` / `-SkipPythonInstall`  

### 日常

開網頁 → 填 **CM Host / Password** → **Login** → 自動 monitor  

唔使每次手動開 bridge。詳見 `INSTALL.txt`。

### 新裝 / 舊機升級 — 同一句（自動 detect）

```powershell
cd <你的解壓目錄>\scripts
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

- 有 `.git` → **自動 `git pull`**  
- 已有 `api` / venv / data → 當 **upgrade**（重 publish、重配 IIS、重啟 bridge）  
- **保留** `data\monitored_trunks.json`  
- **唔使** 加 `-Update`
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
