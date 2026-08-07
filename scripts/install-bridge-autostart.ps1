#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install Windows Scheduled Task so OSSI bridge auto-starts at logon.
  Portable: paths derived from this script location (any install root).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-bridge-autostart.ps1
#>

param([string]$Root = "")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = (Resolve-Path (Join-Path $scriptDir "..")).Path }

$TaskName = "CM-NOC-OSSI-Bridge"
$Py = Join-Path $Root "python\.venv\Scripts\python.exe"
$Script = Join-Path $Root "python\ossi_service.py"
$DataDir = Join-Path $Root "data"
$WorkDir = Join-Path $Root "python"

if (-not (Test-Path $Py)) {
    throw "Site venv missing: $Py — run scripts\install.ps1 first."
}
if (-not (Test-Path $Script)) { throw "Missing $Script" }

$arg = "`"$Script`" --host 127.0.0.1 --port 18765 --data-dir `"$DataDir`""
$action = New-ScheduledTaskAction -Execute $Py -Argument $arg -WorkingDirectory $WorkDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
try {
    $r = Invoke-WebRequest "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "OK: bridge healthy — $($r.Content)"
} catch {
    Write-Warning "Task registered but health not yet OK: $_"
}
Write-Host "Done. Task: $TaskName  Root: $Root"
