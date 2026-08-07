# Start local OSSI bridge (127.0.0.1:18765) for NOC dashboard
# Requires: pip install -e C:\Users\W1NGGG\source\AVAYA-OSSI-2026

param(
    [string]$DataDir = "C:\inetpub\wwwroot\CM\data",
    [string]$Script = "C:\inetpub\wwwroot\CM\python\ossi_service.py",
    [int]$Port = 18765
)

$ErrorActionPreference = "Stop"

$pythonCandidates = @(
    "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "python"
)
$py = $null
foreach ($c in $pythonCandidates) {
    if ($c -eq "python") { $py = $c; break }
    if (Test-Path $c) { $py = $c; break }
}
if (-not $py) { throw "Python not found" }
# Prefer interpreter that can import avaya_ossi
foreach ($c in $pythonCandidates) {
    $exe = if ($c -eq "python") { "python" } elseif (Test-Path $c) { $c } else { $null }
    if (-not $exe) { continue }
    & $exe -c "import avaya_ossi" 2>$null
    if ($LASTEXITCODE -eq 0) { $py = $exe; break }
}

# already up?
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) {
        Write-Host "OSSI bridge already running on :$Port"
        exit 0
    }
} catch { }

Write-Host "Starting OSSI bridge with $py ..."
$argList = @($Script, "--host", "127.0.0.1", "--port", "$Port", "--data-dir", $DataDir)
Start-Process -FilePath $py -ArgumentList $argList -WorkingDirectory (Split-Path $Script) -WindowStyle Hidden
Start-Sleep -Seconds 1
try {
    $r2 = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "Bridge health: $($r2.Content)"
} catch {
    Write-Warning "Bridge may still be starting: $_"
}
