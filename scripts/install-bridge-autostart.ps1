#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install Windows Scheduled Task so OSSI bridge auto-starts at logon.
  After this, opening the web UI + Login does not need manual bridge start.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\inetpub\wwwroot\CM\scripts\install-bridge-autostart.ps1
#>

$ErrorActionPreference = "Stop"
$TaskName = "CM-NOC-OSSI-Bridge"
$Py = "C:\inetpub\wwwroot\CM\python\.venv\Scripts\python.exe"
$Script = "C:\inetpub\wwwroot\CM\python\ossi_service.py"
$DataDir = "C:\inetpub\wwwroot\CM\data"
$WorkDir = "C:\inetpub\wwwroot\CM\python"

if (-not (Test-Path $Py)) {
    throw "Site venv missing: $Py — run: python -m venv C:\inetpub\wwwroot\CM\python\.venv ; pip install -e AVAYA-OSSI-2026"
}
if (-not (Test-Path $Script)) { throw "Missing $Script" }

$arg = "`"$Script`" --host 127.0.0.1 --port 18765 --data-dir `"$DataDir`""
$action = New-ScheduledTaskAction -Execute $Py -Argument $arg -WorkingDirectory $WorkDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# start now
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
try {
    $r = Invoke-WebRequest "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "OK: bridge healthy — $($r.Content)"
} catch {
    Write-Warning "Task registered but health not yet OK: $_"
}

Write-Host ""
Write-Host "Done. Bridge will auto-start at logon (task: $TaskName)."
Write-Host "Web UI: open page → enter Host/Password → Login → monitoring starts."
