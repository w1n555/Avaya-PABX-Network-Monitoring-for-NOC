#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-click IIS setup for Avaya NOC dashboard (easy path).

  User installs IIS themselves first. This script:
    1) Detects IIS
    2) Asks where the app root is (ZIP extract path)
    3) Points IIS site + /api to that path
    4) Prepares Python OSSI bridge (auto-start on Login / logon)
    5) Prints the URL to open

.EXAMPLE
  # After extracting ZIP to e.g. C:\inetpub\wwwroot\CM
  cd C:\inetpub\wwwroot\CM\scripts
  powershell -ExecutionPolicy Bypass -File .\install.ps1

  # Or non-interactive:
  .\install.ps1 -RootPath "C:\inetpub\wwwroot\CM" -SitePort 8888
#>

[CmdletBinding()]
param(
    [string]$RootPath = "",
    [int]$SitePort = 0,
    [string]$SiteName = "CM-NOC",
    [string]$AppPoolName = "CmApiNoManaged",
    [switch]$SkipPublish,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$script:HadError = $false

function Write-Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host "[X] $m" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run PowerShell as Administrator."
    }
}

function Get-AppCmd {
    $p = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
    if (-not (Test-Path $p)) { return $null }
    return $p
}

function Test-IisInstalled {
    $appcmd = Get-AppCmd
    if (-not $appcmd) { return $false }
    try {
        & $appcmd list site 2>$null | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Read-UserPath([string]$defaultPath) {
    if ($NonInteractive -and $RootPath) { return (Resolve-Path $RootPath).Path }
    if ($RootPath) {
        $p = $RootPath.Trim().Trim('"')
        if (Test-Path $p) { return (Resolve-Path $p).Path }
        throw "RootPath not found: $p"
    }
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor White
    Write-Host "  Avaya NOC — one-click IIS setup" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "Where did you put this app? (ZIP extract / local root path)"
    Write-Host "  Example: C:\inetpub\wwwroot\CM"
    Write-Host "  Default: $defaultPath"
    Write-Host ""
    $ans = Read-Host "Local ROOT path [Enter = default]"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $defaultPath }
    $ans = $ans.Trim().Trim('"')
    if (-not (Test-Path $ans)) {
        throw "Path does not exist: $ans  (extract the ZIP there first, then re-run)"
    }
    return (Resolve-Path $ans).Path
}

function Read-Port([int]$defaultPort) {
    if ($SitePort -gt 0) { return $SitePort }
    if ($NonInteractive) { return $defaultPort }
    $ans = Read-Host "IIS site port [Enter = $defaultPort]"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultPort }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
        throw "Invalid port: $ans"
    }
    return $n
}

function Find-Python {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
        (Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\venv\Scripts\python.exe"),
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "python"
    )
    foreach ($c in $cands) {
        if ($c -eq "python") {
            $cmd = Get-Command python -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            continue
        }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-DotNet {
    $local = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Set-JsonAppSettings([string]$root, [string]$pythonExe) {
    $paths = @(
        (Join-Path $root "api\appsettings.json"),
        (Join-Path $root "src\CmApi\appsettings.json")
    )
    $jsonObj = [ordered]@{
        Logging = @{
            LogLevel = @{
                Default = "Warning"
                "Microsoft.AspNetCore" = "Warning"
                "CmApi.Services" = "Information"
            }
        }
        AllowedHosts = "*"
        OssiBridge = @{
            BaseUrl  = "http://127.0.0.1:18765"
            SiteRoot = $root.Replace('\', '\\')
            DataDir  = (Join-Path $root "data").Replace('\', '\\')
            OssiSrc  = (Join-Path $root "vendor\avaya-ossi\src").Replace('\', '\\')
            Python   = $pythonExe.Replace('\', '\\')
        }
    }
    # Use real paths without double-escape in file
    $payload = @{
        Logging = @{
            LogLevel = @{
                Default = "Warning"
                "Microsoft.AspNetCore" = "Warning"
                "CmApi.Services" = "Information"
            }
        }
        AllowedHosts = "*"
        OssiBridge = @{
            BaseUrl  = "http://127.0.0.1:18765"
            SiteRoot = $root
            DataDir  = (Join-Path $root "data")
            OssiSrc  = (Join-Path $root "vendor\avaya-ossi\src")
            Python   = $pythonExe
        }
    } | ConvertTo-Json -Depth 6

    foreach ($p in $paths) {
        $dir = Split-Path $p -Parent
        if (-not (Test-Path $dir)) { continue }
        [System.IO.File]::WriteAllText($p, $payload + "`r`n", [System.Text.UTF8Encoding]::new($false))
        Write-Ok "Wrote $p"
    }
}

function Ensure-DataFiles([string]$root) {
    $data = Join-Path $root "data"
    New-Item -ItemType Directory -Force -Path $data | Out-Null
    $mon = Join-Path $data "monitored_trunks.json"
    $td  = Join-Path $data "trunk_data.json"
    if (-not (Test-Path $mon)) {
        '{"trunks":[1],"updatedAt":null}' | Set-Content -Path $mon -Encoding UTF8
    }
    if (-not (Test-Path $td)) {
        @'
{
  "lastUpdate": null,
  "host": null,
  "username": null,
  "connected": false,
  "error": null,
  "source": "avaya-ossi",
  "items": []
}
'@ | Set-Content -Path $td -Encoding UTF8
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $data "logs") | Out-Null
}

function Ensure-PythonVenv([string]$root, [string]$basePython) {
    $venvPy = Join-Path $root "python\.venv\Scripts\python.exe"
    $vendor = Join-Path $root "vendor\avaya-ossi"
    if (-not (Test-Path $vendor)) {
        throw "Missing vendor\avaya-ossi — ZIP incomplete. Re-download full package."
    }
    if (-not (Test-Path $venvPy)) {
        Write-Info "Creating Python venv under site (first time, ~1 min)…"
        & $basePython -m venv (Join-Path $root "python\.venv")
        if ($LASTEXITCODE -ne 0) { throw "python -m venv failed" }
        & $venvPy -m pip install -U pip -q
        & $venvPy -m pip install -e $vendor -q
        if ($LASTEXITCODE -ne 0) { throw "pip install avaya-ossi failed" }
    } else {
        Write-Info "Refreshing avaya-ossi in site venv…"
        & $venvPy -m pip install -e $vendor -q
    }
    & $venvPy -c "import avaya_ossi; print(avaya_ossi.__version__)"
    if ($LASTEXITCODE -ne 0) { throw "avaya_ossi import failed in site venv" }
    Write-Ok "Python OSSI ready: $venvPy"
    return $venvPy
}

function Ensure-ApiPublish([string]$root) {
    $apiDll = Join-Path $root "api\CmApi.dll"
    $csproj = Join-Path $root "src\CmApi\CmApi.csproj"
    if ((Test-Path $apiDll) -and $SkipPublish) {
        Write-Ok "Using existing api\ publish"
        return
    }
    if (-not (Test-Path $csproj)) {
        if (Test-Path $apiDll) {
            Write-Warn "No src project; using prebuilt api\"
            return
        }
        throw "Neither api\CmApi.dll nor src\CmApi found."
    }
    $dotnet = Find-DotNet
    if (-not $dotnet) {
        if (Test-Path $apiDll) {
            Write-Warn "dotnet SDK not found; using existing api\"
            return
        }
        throw "dotnet not found. Install .NET 8 SDK or Hosting Bundle, or ship prebuilt api\."
    }
    Write-Info "Publishing CmApi…"
    $out = Join-Path $root "api"
    # stop pool briefly if same path
    $appcmd = Get-AppCmd
    try { & $appcmd stop apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null } catch {}
    Start-Sleep -Seconds 1
    & $dotnet publish $csproj -c Release -o $out --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
    Write-Ok "Published to $out"
}

function Set-IisSite([string]$root, [int]$port) {
    $appcmd = Get-AppCmd
    $apiPath = Join-Path $root "api"
    if (-not (Test-Path $apiPath)) { throw "api folder missing: $apiPath" }

    # App pool — No Managed Code for ANCM
    $pools = & $appcmd list apppool /text:APPPOOL.NAME 2>$null
    if ($pools -notcontains $AppPoolName) {
        Write-Info "Creating app pool $AppPoolName"
        & $appcmd add apppool /name:"$AppPoolName" /managedRuntimeVersion:"" /managedPipelineMode:Integrated | Out-Null
    } else {
        Write-Info "App pool exists: $AppPoolName"
        & $appcmd set apppool /apppool.name:"$AppPoolName" /managedRuntimeVersion:"" | Out-Null
    }
    & $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null

    $sites = & $appcmd list site /text:SITE.NAME 2>$null
    $binding = "http/*:${port}:"
    if ($sites -notcontains $SiteName) {
        Write-Info "Creating site $SiteName on port $port → $root"
        & $appcmd add site /name:"$SiteName" /bindings:"$binding" /physicalPath:"$root" | Out-Null
    } else {
        Write-Info "Updating site $SiteName path + binding"
        & $appcmd set site /site.name:"$SiteName" /-[bindings].protocol:http 2>$null | Out-Null
        # set physical path
        & $appcmd set vdir /vdir.name:"${SiteName}/" /physicalPath:"$root" | Out-Null
        # ensure binding
        $cur = & $appcmd list site /site.name:"$SiteName" /text:bindings 2>$null
        if ("$cur" -notmatch ":${port}:") {
            try {
                & $appcmd set site /site.name:"$SiteName" /+bindings.[protocol='http',bindingInformation='*:${port}:'] | Out-Null
            } catch {
                Write-Warn "Binding may already exist: $_"
            }
        }
    }
    & $appcmd set app /app.name:"${SiteName}/" /applicationPool:"$AppPoolName" | Out-Null

    # Application /api
    $apps = & $appcmd list app /text:APP.NAME 2>$null
    $apiApp = "${SiteName}/api"
    if ($apps -notcontains $apiApp) {
        Write-Info "Creating application /api → $apiPath"
        & $appcmd add app /site.name:"$SiteName" /path:/api /physicalPath:"$apiPath" /applicationPool:"$AppPoolName" | Out-Null
    } else {
        Write-Info "Updating /api path"
        & $appcmd set app /app.name:"$apiApp" /applicationPool:"$AppPoolName" | Out-Null
        & $appcmd set vdir /vdir.name:"${SiteName}/api/" /physicalPath:"$apiPath" | Out-Null
    }

    # api web.config for ANCM if missing
    $wc = Join-Path $apiPath "web.config"
    if (-not (Test-Path $wc)) {
        @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\CmApi.dll" stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout" hostingModel="InProcess" />
    </system.webServer>
  </location>
</configuration>
'@ | Set-Content -Path $wc -Encoding UTF8
    }

    & $appcmd start site /site.name:"$SiteName" 2>$null | Out-Null
    Write-Ok "IIS site $SiteName → $root  (port $port), /api → $apiPath"
}

function Set-Acls([string]$root) {
    Write-Info "Setting folder permissions for IIS…"
    $paths = @(
        $root,
        (Join-Path $root "data"),
        (Join-Path $root "python"),
        (Join-Path $root "api")
    )
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        & icacls $p /grant "IIS_IUSRS:(OI)(CI)M" /T /C /Q 2>$null | Out-Null
        & icacls $p /grant "IUSR:(OI)(CI)RX" /T /C /Q 2>$null | Out-Null
    }
    # data needs write for JSON
    $data = Join-Path $root "data"
    if (Test-Path $data) {
        & icacls $data /grant "IIS_IUSRS:(OI)(CI)M" /T /C /Q 2>$null | Out-Null
    }
    Write-Ok "ACLs updated"
}

function Install-BridgeTask([string]$root, [string]$venvPy) {
    $TaskName = "CM-NOC-OSSI-Bridge"
    $script = Join-Path $root "python\ossi_service.py"
    $data = Join-Path $root "data"
    $work = Join-Path $root "python"
    $arg = "`"$script`" --host 127.0.0.1 --port 18765 --data-dir `"$data`""

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute $venvPy -Argument $arg -WorkingDirectory $work
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    try { Start-ScheduledTask -TaskName $TaskName } catch { Write-Warn "Task start: $_" }
    Write-Ok "Scheduled task $TaskName (auto-start bridge at logon)"
}

function Start-BridgeNow([string]$root, [string]$venvPy) {
    # if already healthy, skip
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) {
            Write-Ok "OSSI bridge already running"
            return
        }
    } catch {}

    $script = Join-Path $root "python\ossi_service.py"
    $data = Join-Path $root "data"
    Start-Process -FilePath $venvPy -ArgumentList @(
        $script, "--host", "127.0.0.1", "--port", "18765", "--data-dir", $data
    ) -WorkingDirectory (Join-Path $root "python") -WindowStyle Hidden
    Start-Sleep -Seconds 2
    try {
        $r2 = Invoke-WebRequest "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 5
        Write-Ok "OSSI bridge health: $($r2.Content)"
    } catch {
        Write-Warn "Bridge not healthy yet (Login will retry auto-start): $_"
    }
}

function Test-AspNetCoreModule {
    $p1 = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    $p2 = Join-Path ${env:ProgramFiles(x86)} "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    return (Test-Path $p1) -or (Test-Path $p2)
}

# ---------------- main ----------------
try {
    Assert-Admin

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $defaultRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path

    if (-not (Test-IisInstalled)) {
        Write-Err "IIS not detected (appcmd missing or not working)."
        Write-Host ""
        Write-Host "Please install IIS yourself first, for example:"
        Write-Host "  - Windows Features → Internet Information Services"
        Write-Host "  - Include: IIS Management Console, World Wide Web Services"
        Write-Host "Then also install: .NET 8 Hosting Bundle (for ASP.NET Core)"
        Write-Host "Then re-run this script."
        exit 2
    }
    Write-Ok "IIS detected"

    if (-not (Test-AspNetCoreModule)) {
        Write-Warn ".NET ASP.NET Core Module (Hosting Bundle) not found."
        Write-Warn "API may not start until you install: .NET 8 Hosting Bundle"
    } else {
        Write-Ok "ASP.NET Core Module present"
    }

    $root = Read-UserPath -defaultPath $defaultRoot
    $port = Read-Port -defaultPort 8888

    # sanity checks
    $need = @("index.html", "app.js", "python\ossi_service.py", "vendor\avaya-ossi")
    foreach ($rel in $need) {
        $p = Join-Path $root $rel
        if (-not (Test-Path $p)) {
            throw "Missing $rel under $root — wrong folder or incomplete ZIP?"
        }
    }
    Write-Ok "App files found under $root"

    Ensure-DataFiles -root $root

    $basePy = Find-Python
    if (-not $basePy) {
        throw "Python not found. Install Python 3.11+ from python.org and re-run (check 'Add to PATH')."
    }
    Write-Ok "Python: $basePy"
    $venvPy = Ensure-PythonVenv -root $root -basePython $basePy

    Ensure-ApiPublish -root $root
    Set-JsonAppSettings -root $root -pythonExe $venvPy
    Set-IisSite -root $root -port $port
    Set-Acls -root $root
    Install-BridgeTask -root $root -venvPy $venvPy
    Start-BridgeNow -root $root -venvPy $venvPy

    # quick API probe
    Start-Sleep -Seconds 1
    $url = "http://127.0.0.1:${port}/"
    $apiHealth = "http://127.0.0.1:${port}/api/health"
    try {
        $h = Invoke-WebRequest $apiHealth -UseBasicParsing -TimeoutSec 15
        Write-Ok "API health: $($h.Content)"
    } catch {
        Write-Warn "API not answering yet (recycle app pool / check Hosting Bundle): $_"
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  DONE — easy path for users" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1. Open browser:  $url"
    Write-Host "  2. Enter your CM Host + Password"
    Write-Host "  3. Click Login  →  monitoring starts"
    Write-Host ""
    Write-Host "  Root:  $root"
    Write-Host "  Site:  $SiteName  port $port"
    Write-Host "  Bridge auto-starts at Windows logon (task CM-NOC-OSSI-Bridge)"
    Write-Host ""
    Write-Host "No need to run bridge manually every time."
    Write-Host ""
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
