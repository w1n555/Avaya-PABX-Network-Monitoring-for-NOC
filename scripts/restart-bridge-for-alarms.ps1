# Run as Administrator — restarts OSSI bridge with Alarm form support + recycles CM API
$ErrorActionPreference = "Continue"
$SITE = "C:\inetpub\wwwroot\CM"
$PORT = 18776
$log = "$SITE\data_live\logs\restart-bridge-alarms.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function L($m){ $line = "{0} {1}" -f (Get-Date -Format o), $m; Add-Content $log $line; Write-Host $line }

L "begin alarm-capable bridge restart port=$PORT"

# Kill listeners on bridge ports
foreach ($p in 18765..18780) {
  Get-NetTCPConnection -LocalPort $p -State Listen -EA SilentlyContinue | ForEach-Object {
    L "kill port=$p pid=$($_.OwningProcess)"
    taskkill /F /PID $_.OwningProcess 2>&1 | ForEach-Object { L $_ }
  }
}
Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.CommandLine -like "*ossi_service.py*" } | ForEach-Object {
  L "kill ossi pid=$($_.ProcessId)"
  taskkill /F /PID $_.ProcessId 2>&1 | ForEach-Object { L $_ }
}
Start-Sleep 2

# appsettings
$cfg = @"
{
  "Logging": { "LogLevel": { "Default": "Warning", "Microsoft.AspNetCore": "Warning", "CmApi.Services": "Information" } },
  "AllowedHosts": "*",
  "OssiBridge": {
    "BaseUrl": "http://127.0.0.1:$PORT",
    "SiteRoot": "C:\\inetpub\\wwwroot\\CM",
    "DataDir": "C:\\inetpub\\wwwroot\\CM\\data_live",
    "OssiSrc": "C:\\inetpub\\wwwroot\\CM\\vendor\\avaya-ossi\\src",
    "Python": "C:\\inetpub\\wwwroot\\CM\\python\\.venv\\Scripts\\python.exe"
  }
}
"@
Set-Content "$SITE\api\appsettings.json" $cfg -Encoding UTF8
L "appsettings BaseUrl :$PORT"

$env:PYTHONPATH = "$SITE\vendor\avaya-ossi\src"
$env:PYTHONUNBUFFERED = "1"
$py = "$SITE\python\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "$SITE\python\runtime\python.exe" }
$p = Start-Process -FilePath $py -ArgumentList @(
  "$SITE\python\ossi_service.py","--host","0.0.0.0","--port","$PORT","--data-dir","$SITE\data_live"
) -WorkingDirectory "$SITE\python" -WindowStyle Hidden -PassThru
L "started bridge pid=$($p.Id)"
Start-Sleep 2
try {
  $h = Invoke-RestMethod "http://127.0.0.1:$PORT/health" -TimeoutSec 5
  L ("health " + ($h | ConvertTo-Json -Compress))
} catch { L "health err $_" }

# Recycle IIS workers so CmApi reloads BaseUrl
Get-Process w3wp -EA SilentlyContinue | ForEach-Object {
  L "kill w3wp pid=$($_.Id)"
  taskkill /F /PID $_.Id 2>&1 | ForEach-Object { L $_ }
}
Start-Sleep 2
try {
  $h = Invoke-RestMethod "http://127.0.0.1:8888/CM/api/health?ensure=1" -TimeoutSec 20
  L ("api health " + ($h | ConvertTo-Json -Compress))
} catch { L "api health err $_" }
try {
  $a = Invoke-RestMethod "http://127.0.0.1:8888/CM/api/alarms" -TimeoutSec 8
  L ("alarms route ok total=" + ($a.summary.activeTotal))
} catch { L "alarms route still 404 (old DLL) — UI uses refresh/one tg=9999" }
L "done — Login again, open Alarm tab"
