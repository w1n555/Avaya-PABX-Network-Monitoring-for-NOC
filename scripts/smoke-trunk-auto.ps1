<#
.SYNOPSIS
  Smoke test for 60s OSSI trunk update path (bridge :18768 + IIS /CM/api).

.DESCRIPTION
  Always runs offline checks (health, app.js deploy markers, monitored).
  If OSSI session is already connected (user logged in via UI), also runs live:
    - refresh/one TG1 with util/timestamp change
    - full progressive refresh all monitored TGs
    - trunk-data lastUpdate advances
#>
$ErrorActionPreference = "Continue"
$Api = "http://127.0.0.1:8888/CM/api"
$Bridge = "http://127.0.0.1:18768"
$script:pass = 0
$script:fail = 0

function Ok($name, $cond, $detail = "") {
  if ($cond) {
    if ($detail) { Write-Host "PASS  $name - $detail" } else { Write-Host "PASS  $name" }
    $script:pass++
  } else {
    if ($detail) { Write-Host "FAIL  $name - $detail" } else { Write-Host "FAIL  $name" }
    $script:fail++
  }
}

Write-Host "=== SMOKE trunk auto / OSSI ==="
Write-Host ""

# 1) Health
try {
  $h = Invoke-RestMethod "$Api/health" -TimeoutSec 8
  Ok "IIS health" ($h.ok -eq $true -and $h.bridgeHealthy -eq $true) "bridgeHealthy=$($h.bridgeHealthy)"
} catch { Ok "IIS health" $false "$_" }

try {
  $b = Invoke-RestMethod "$Bridge/health" -TimeoutSec 5
  Ok "Bridge :18768" ($b.ok -eq $true) "connected=$($b.connected)"
} catch { Ok "Bridge :18768" $false "$_" }

# 2) Deployed app.js markers (frozen-UI fix)
try {
  $js = (Invoke-WebRequest "http://127.0.0.1:8888/CM/app.js" -UseBasicParsing -TimeoutSec 10).Content
  Ok "app.js onSessionLive" ($js -match "onSessionLive")
  Ok "app.js startLivePoll wired" ($js -match "function startLivePoll" -and $js -match "onSessionLive")
  Ok "app.js tgListForRefresh" ($js -match "tgListForRefresh")
  Ok "app.js flashChanges poll" ($js -match "flashChanges")
  Ok "app.js resume loads monitored first" ($js -match "Load list \+ cache FIRST")
  Ok "app.js stuck guard 180s" ($js -match "180_000" -or $js -match "180000")
} catch { Ok "app.js served" $false "$_" }

# 3) Monitored + trunk-data readable
try {
  $mon = Invoke-RestMethod "$Api/monitored" -TimeoutSec 8
  $nMon = @($mon.items).Count
  Ok "monitored list" ($nMon -ge 1) "count=$nMon"
} catch { Ok "monitored list" $false "$_"; $nMon = 0; $mon = $null }

try {
  $td = Invoke-RestMethod "$Api/trunk-data" -TimeoutSec 8
  $items = @($td.data.items)
  Ok "trunk-data readable" ($true) "items=$($items.Count) last=$($td.data.lastUpdate)"
} catch { Ok "trunk-data readable" $false "$_" }

# 4) Session
$connected = $false
try {
  $st = Invoke-RestMethod "$Api/session/status" -TimeoutSec 8
  $connected = [bool]$st.connected
  Ok "session/status" $true "connected=$connected host=$($st.host)"
} catch { Ok "session/status" $false "$_" }

if (-not $connected) {
  Write-Host ""
  Write-Host "NOTE: OSSI not connected - skip live status trunk checks."
  Write-Host "      Login in browser (Ctrl+F5), then re-run this script for full live smoke."
  Write-Host ""
  Write-Host "SUMMARY pass=$($script:pass) fail=$($script:fail) connected=False"
  exit $(if ($script:fail -gt 0) { 1 } else { 0 })
}

# --- LIVE (connected) ---
Write-Host ""
Write-Host "=== LIVE OSSI (session connected) ==="

try {
  Invoke-RestMethod "$Api/session/heartbeat" -Method POST -ContentType "application/json" -Body "{}" -TimeoutSec 10 | Out-Null
  Ok "heartbeat" $true
} catch { Ok "heartbeat" $false "$_" }

$before = Invoke-RestMethod "$Api/trunk-data" -TimeoutSec 8
$beforeTg1 = @($before.data.items | Where-Object { [int]$_.tg -eq 1 } | Select-Object -First 1)
$beforeTs = if ($beforeTg1) { $beforeTg1.lastUpdate } else { $before.data.lastUpdate }

try {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $one = Invoke-RestMethod "$Api/refresh/one" -Method POST -ContentType "application/json" -Body '{"tg":1}' -TimeoutSec 120
  $sw.Stop()
  $item = $one.item
  $tsChanged = $item.lastUpdate -and $item.lastUpdate -ne $beforeTs
  $hasCounts = [int]$item.total -gt 0
  Ok "refresh/one TG1" ($one.ok -ne $false -and $item.tg -eq 1) "util=$($item.utilizationPct) busy=$($item.busy)/$($item.total) ms=$($sw.ElapsedMilliseconds)"
  Ok "refresh/one timestamp advanced" $tsChanged "was=$beforeTs now=$($item.lastUpdate)"
  Ok "refresh/one total>0" $hasCounts "total=$($item.total)"
  Ok "refresh/one has utilizationPct field" ($null -ne $item.utilizationPct)
} catch { Ok "refresh/one TG1" $false "$_" }

$tgs = @($mon.items | ForEach-Object { [int]$_.tg })
$okCount = 0
$swAll = [Diagnostics.Stopwatch]::StartNew()
foreach ($tg in $tgs) {
  try {
    $r = Invoke-RestMethod "$Api/refresh/one" -Method POST -ContentType "application/json" -Body (@{tg=$tg} | ConvertTo-Json) -TimeoutSec 120
    if ($r.item -and $r.item.lastUpdate) { $okCount++ }
  } catch {
    Write-Host "  warn TG$tg : $_"
  }
}
$swAll.Stop()
Ok "progressive all TGs" ($okCount -eq $tgs.Count) "ok=$okCount/$($tgs.Count) ms=$($swAll.ElapsedMilliseconds)"

$after = Invoke-RestMethod "$Api/trunk-data" -TimeoutSec 8
$busyAny = @($after.data.items | Where-Object { [int]$_.busy -gt 0 }).Count
$utilAny = @($after.data.items | Where-Object { [double]$_.utilizationPct -gt 0 }).Count
Ok "trunk-data after refresh" ($after.data.items.Count -ge $tgs.Count) "items=$($after.data.items.Count) last=$($after.data.lastUpdate)"
if ($busyAny -gt 0) {
  Ok "util>0 when busy>0" ($utilAny -gt 0) "busyTGs=$busyAny utilTGs=$utilAny"
} else {
  Ok "all trunks idle (util 0 expected)" $true
}

Write-Host ""
Write-Host "Per-TG snapshot:"
$after.data.items | ForEach-Object {
  Write-Host ("  TG{0,3} busy={1,2}/{2,2} util={3,5:N1}%  {4}" -f $_.tg,$_.busy,$_.total,$_.utilizationPct,$_.lastUpdate)
}

Write-Host ""
Write-Host "SUMMARY pass=$($script:pass) fail=$($script:fail) connected=True"
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
