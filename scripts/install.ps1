#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-click IIS setup for Avaya NOC dashboard (easy path).

  User installs IIS themselves. This script:
    1) Detects IIS
    2) Checks / installs .NET 8 Hosting Bundle if missing
    3) Checks / installs Python 3.12 (with PATH) if missing
    4) Asks local ROOT path (ZIP extract folder)
    5) Points IIS site + /api to that path
    6) OPTIONAL: pull latest code from GitHub if folder is a git repo (or -Update)
    7) Site venv + bundled vendor/avaya-ossi + bridge autostart
    8) Re-publish API, recycle pool, restart bridge
    9) Prints browser URL

  On a machine that already has the OLD repo running:
    re-run this same script on the SAME root path = upgrade in one click
    (git pull + reconfig IIS + refresh venv + republish + restart bridge)
    data\monitored_trunks.json is kept.

.EXAMPLE
  cd C:\inetpub\wwwroot\CM\scripts
  powershell -ExecutionPolicy Bypass -File .\install.ps1

  # Old install - one-click upgrade:
  .\install.ps1 -RootPath "C:\inetpub\wwwroot\CM" -Update -NonInteractive

  .\install.ps1 -RootPath "C:\inetpub\wwwroot\CM" -SitePort 8888 -NonInteractive
#>

[CmdletBinding()]
param(
    [string]$RootPath = "",
    [int]$SitePort = 0,
    [string]$SiteName = "CM-NOC",
    [string]$AppPoolName = "CmApiNoManaged",
    [switch]$SkipPublish,
    [switch]$SkipDotNetInstall,
    [switch]$SkipPythonInstall,
    [switch]$Update,
    [switch]$SkipUpdate,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

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

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Get-DownloadDir {
    $d = Join-Path $env:TEMP "cm-noc-install"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Test-AspNetCoreModule {
    $p1 = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    $p2 = Join-Path ${env:ProgramFiles(x86)} "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    return (Test-Path $p1) -or (Test-Path $p2)
}

function Test-DotNetHosting {
    if (Test-AspNetCoreModule) { return $true }
    $fx = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.AspNetCore.App"
    if (Test-Path $fx) {
        $v8 = Get-ChildItem $fx -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "8.*" }
        if ($v8) { return $true }
    }
    return $false
}

function Restart-IisSafe {
    Write-Info "Restarting IIS so ASP.NET Core Module loads..."
    try {
        & iisreset 2>&1 | Out-Host
    } catch {
        try {
            Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
            Restart-Service WAS -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Could not restart IIS automatically: $_"
        }
    }
}

function Install-DotNetHostingBundle {
    if ($SkipDotNetInstall) {
        Write-Warn "SkipDotNetInstall set - not installing Hosting Bundle"
        return
    }
    Write-Info ".NET 8 Hosting Bundle / ANCM not found - installing..."

    if (Test-Winget) {
        Write-Info "Trying winget: Microsoft.DotNet.HostingBundle.8"
        try {
            & winget install -e --id Microsoft.DotNet.HostingBundle.8 --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Host
            Start-Sleep -Seconds 2
            if (Test-DotNetHosting) {
                Write-Ok ".NET Hosting Bundle installed via winget"
                Restart-IisSafe
                return
            }
        } catch {
            Write-Warn "winget Hosting Bundle failed: $_"
        }
    }

    $dl = Get-DownloadDir
    $installer = Join-Path $dl "dotnet-hosting-win.exe"
    $urls = @(
        "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe",
        "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.11/dotnet-hosting-8.0.11-win.exe"
    )
    $ok = $false
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in $urls) {
        try {
            Write-Info "Downloading Hosting Bundle..."
            Write-Host "  $url"
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
            if ((Get-Item $installer).Length -gt 1MB) { $ok = $true; break }
        } catch {
            Write-Warn "Download failed: $_"
        }
    }
    if (-not $ok) {
        throw "Could not download .NET Hosting Bundle. Install manually from https://dotnet.microsoft.com/download/dotnet/8.0 (Hosting Bundle), then re-run."
    }

    Write-Info "Running Hosting Bundle installer (quiet)..."
    $p = Start-Process -FilePath $installer -ArgumentList @("/install", "/quiet", "/norestart") -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warn "Hosting Bundle installer exit code $($p.ExitCode)"
    }
    Restart-IisSafe
    if (-not (Test-DotNetHosting)) {
        throw "Hosting Bundle still not detected. Install manually from https://dotnet.microsoft.com/download/dotnet/8.0 then re-run."
    }
    Write-Ok ".NET Hosting Bundle ready"
}

function Ensure-DotNetHosting {
    if (Test-DotNetHosting) {
        Write-Ok ".NET ASP.NET Core Hosting / ANCM present"
        return
    }
    Write-Warn ".NET 8 Hosting Bundle not detected"
    if (-not $NonInteractive) {
        $ans = Read-Host "Install .NET 8 Hosting Bundle now? [Y/n]"
        if ($ans -match '^[nN]') {
            throw "Hosting Bundle is required for /api. Install from https://dotnet.microsoft.com/download/dotnet/8.0 and re-run."
        }
    }
    Install-DotNetHostingBundle
}

function Find-Python {
    Refresh-Path
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
        "C:\Program Files\Python312\python.exe",
        "C:\Program Files\Python311\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        (Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\venv\Scripts\python.exe")
    )
    foreach ($c in $cands) {
        if (-not (Test-Path $c)) { continue }
        try {
            $ver = & $c --version 2>&1 | Out-String
            if ($ver -match "Python 3\.(1[1-9]|[2-9]\d)") { return $c }
        } catch {}
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $ver = & $cmd.Source --version 2>&1 | Out-String
            if ($ver -match "Python 3\.(1[1-9]|[2-9]\d)") { return $cmd.Source }
        } catch {}
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($v in @("-3.12", "-3.11", "-3")) {
            try {
                $out = & py $v -c "import sys; print(sys.executable)" 2>$null
                if ($out -and (Test-Path $out.Trim())) { return $out.Trim() }
            } catch {}
        }
    }
    return $null
}

function Install-Python311 {
    if ($SkipPythonInstall) {
        Write-Warn "SkipPythonInstall set - not installing Python"
        return
    }
    Write-Info "Python 3.11+ not found - installing..."

    if (Test-Winget) {
        Write-Info "Trying winget: Python.Python.3.12"
        try {
            & winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Host
            Start-Sleep -Seconds 2
            Refresh-Path
            if (Find-Python) {
                Write-Ok "Python installed via winget: $(Find-Python)"
                return
            }
        } catch {
            Write-Warn "winget Python install failed: $_"
        }
    }

    $dl = Get-DownloadDir
    $ver = "3.12.8"
    $url = "https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe"
    $exe = Join-Path $dl "python-$ver-amd64.exe"
    Write-Info "Downloading Python $ver from python.org..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    } catch {
        throw "Failed to download Python. Install Python 3.11+ manually (check Add to PATH), then re-run. $_"
    }
    Write-Info "Running Python installer (quiet, AllUsers, PrependPath)..."
    $p = Start-Process -FilePath $exe -ArgumentList @(
        "/quiet",
        "InstallAllUsers=1",
        "PrependPath=1",
        "Include_test=0",
        "Include_launcher=1",
        "SimpleInstall=1"
    ) -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warn "Python installer exit code $($p.ExitCode)"
    }
    Refresh-Path
    if (-not (Find-Python)) {
        throw "Python still not found after install. Open a NEW Admin PowerShell and re-run install.ps1."
    }
    Write-Ok "Python ready: $(Find-Python)"
}

function Ensure-Python {
    $py = Find-Python
    if ($py) {
        Write-Ok "Python 3.11+ found: $py"
        return
    }
    Write-Warn "Python 3.11+ not detected"
    if (-not $NonInteractive) {
        $ans = Read-Host "Install Python 3.12 now? [Y/n]"
        if ($ans -match '^[nN]') {
            throw "Python is required. Install from https://www.python.org (check Add to PATH) and re-run."
        }
    }
    Install-Python311
}

function Read-UserPath([string]$defaultPath) {
    if ($RootPath) {
        $p = $RootPath.Trim().Trim('"')
        if (Test-Path $p) { return (Resolve-Path $p).Path }
        throw "RootPath not found: $p"
    }
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor White
    Write-Host "  Avaya NOC - one-click IIS setup" -ForegroundColor White
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

function Find-DotNet {
    $local = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Set-JsonAppSettings([string]$root, [string]$pythonExe) {
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

    foreach ($rel in @("api\appsettings.json", "src\CmApi\appsettings.json")) {
        $p = Join-Path $root $rel
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
        $monJson = @{ trunks = @(1); updatedAt = $null } | ConvertTo-Json -Compress
        Set-Content -Path $mon -Value $monJson -Encoding UTF8
    }
    if (-not (Test-Path $td)) {
        $tdObj = [ordered]@{
            lastUpdate = $null
            host = $null
            username = $null
            connected = $false
            error = $null
            source = "avaya-ossi"
            items = @()
        }
        Set-Content -Path $td -Value ($tdObj | ConvertTo-Json -Depth 4) -Encoding UTF8
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $data "logs") | Out-Null
}

function Ensure-PythonVenv([string]$root, [string]$basePython) {
    $venvPy = Join-Path $root "python\.venv\Scripts\python.exe"
    $vendor = Join-Path $root "vendor\avaya-ossi"
    if (-not (Test-Path $vendor)) {
        throw "Missing vendor\avaya-ossi - ZIP incomplete. Re-download full package."
    }
    if (-not (Test-Path $venvPy)) {
        Write-Info "Creating Python venv under site (first time, may take ~1 min)..."
        & $basePython -m venv (Join-Path $root "python\.venv")
        if ($LASTEXITCODE -ne 0) { throw "python -m venv failed" }
        & $venvPy -m pip install -U pip -q
        & $venvPy -m pip install -e $vendor -q
        if ($LASTEXITCODE -ne 0) { throw "pip install avaya-ossi failed" }
    } else {
        Write-Info "Refreshing avaya-ossi in site venv..."
        & $venvPy -m pip install -e $vendor -q
    }
    & $venvPy -c "import avaya_ossi; print(avaya_ossi.__version__)"
    if ($LASTEXITCODE -ne 0) { throw "avaya_ossi import failed in site venv" }
    Write-Ok "Python OSSI ready: $venvPy"
    return $venvPy
}

function Ensure-ApiPublish([string]$root, [switch]$Force) {
    $apiDll = Join-Path $root "api\CmApi.dll"
    $csproj = Join-Path $root "src\CmApi\CmApi.csproj"
    if ((Test-Path $apiDll) -and $SkipPublish -and -not $Force) {
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
        throw "dotnet not found. Install .NET 8 SDK (or ship prebuilt api\)."
    }
    Write-Info "Publishing CmApi..."
    $out = Join-Path $root "api"
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

    $pools = @(& $appcmd list apppool /text:APPPOOL.NAME 2>$null)
    if ($pools -notcontains $AppPoolName) {
        Write-Info "Creating app pool $AppPoolName"
        & $appcmd add apppool /name:"$AppPoolName" /managedRuntimeVersion:"" /managedPipelineMode:Integrated | Out-Null
    } else {
        Write-Info "App pool exists: $AppPoolName"
        & $appcmd set apppool /apppool.name:"$AppPoolName" /managedRuntimeVersion:"" | Out-Null
    }
    & $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null

    $sites = @(& $appcmd list site /text:SITE.NAME 2>$null)
    $binding = "http/*:${port}:"
    if ($sites -notcontains $SiteName) {
        Write-Info "Creating site $SiteName on port $port -> $root"
        & $appcmd add site /name:"$SiteName" /bindings:"$binding" /physicalPath:"$root" | Out-Null
    } else {
        Write-Info "Updating site $SiteName path + binding"
        & $appcmd set vdir /vdir.name:"${SiteName}/" /physicalPath:"$root" | Out-Null
        $cur = & $appcmd list site /site.name:"$SiteName" /text:bindings 2>$null
        if ("$cur" -notmatch ":${port}:") {
            try {
                & $appcmd set site /site.name:"$SiteName" "/+bindings.[protocol='http',bindingInformation='*:${port}:']" | Out-Null
            } catch {
                Write-Warn "Binding may already exist: $_"
            }
        }
    }
    & $appcmd set app /app.name:"${SiteName}/" /applicationPool:"$AppPoolName" | Out-Null

    $apps = @(& $appcmd list app /text:APP.NAME 2>$null)
    $apiApp = "${SiteName}/api"
    if ($apps -notcontains $apiApp) {
        Write-Info "Creating application /api -> $apiPath"
        & $appcmd add app /site.name:"$SiteName" /path:/api /physicalPath:"$apiPath" /applicationPool:"$AppPoolName" | Out-Null
    } else {
        Write-Info "Updating /api path"
        & $appcmd set app /app.name:"$apiApp" /applicationPool:"$AppPoolName" | Out-Null
        & $appcmd set vdir /vdir.name:"${SiteName}/api/" /physicalPath:"$apiPath" | Out-Null
    }

    $wc = Join-Path $apiPath "web.config"
    if (-not (Test-Path $wc)) {
        $webConfig = @"
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
"@
        Set-Content -Path $wc -Value $webConfig -Encoding UTF8
    }

    & $appcmd start site /site.name:"$SiteName" 2>$null | Out-Null
    Write-Ok "IIS site $SiteName -> $root  (port $port), /api -> $apiPath"
}

function Set-Acls([string]$root) {
    Write-Info "Setting folder permissions for IIS..."
    foreach ($rel in @("", "data", "python", "api")) {
        $p = if ($rel) { Join-Path $root $rel } else { $root }
        if (-not (Test-Path $p)) { continue }
        & icacls $p /grant "IIS_IUSRS:(OI)(CI)M" /T /C /Q 2>$null | Out-Null
        & icacls $p /grant "IUSR:(OI)(CI)RX" /T /C /Q 2>$null | Out-Null
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

function Stop-BridgeOnPort([int]$port = 18765) {
    try {
        Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
            }
    } catch {}
}

function Start-BridgeNow([string]$root, [string]$venvPy, [switch]$ForceRestart) {
    if ($ForceRestart) {
        Write-Info "Restarting OSSI bridge..."
        Stop-BridgeOnPort 18765
        Start-Sleep -Seconds 1
    } else {
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) {
                Write-Ok "OSSI bridge already running"
                return
            }
        } catch {}
    }

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

function Test-GitRepo([string]$root) {
    return (Test-Path (Join-Path $root ".git"))
}

function Update-CodeFromGit([string]$root) {
    if ($SkipUpdate) {
        Write-Info "SkipUpdate set - leaving files as-is on disk"
        return $false
    }

    $isGit = Test-GitRepo $root
    $doUpdate = $false
    if ($Update) {
        $doUpdate = $true
    } elseif ($isGit) {
        if ($NonInteractive) {
            $doUpdate = $true
        } else {
            $ans = Read-Host "This folder looks like an existing install (git). Pull latest from GitHub + upgrade? [Y/n]"
            if ($ans -notmatch '^[nN]') { $doUpdate = $true }
        }
    }

    if (-not $doUpdate) {
        Write-Info "Using existing files on disk (no git pull)"
        return $false
    }

    if (-not $isGit) {
        Write-Warn "Not a git clone - cannot auto-pull code."
        Write-Warn "For one-click upgrades later, use git clone once, or overwrite folder from ZIP then re-run install.ps1"
        Write-Host "  git clone https://github.com/w1n555/Avaya-PABX-Network-Monitoring-for-NOC.git `"$root`""
        return $false
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Warn "git not found - skip pull. Install Git for Windows for one-click upgrades."
        return $false
    }

    Write-Info "Updating code from GitHub (git fetch + pull)..."
    # Preserve local monitoring list
    $dataDir = Join-Path $root "data"
    $backup = Join-Path $env:TEMP ("cm-noc-data-backup-" + [guid]::NewGuid().ToString("N"))
    if (Test-Path $dataDir) {
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Copy-Item (Join-Path $dataDir "*") $backup -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Backed up data\ to $backup"
    }

    Push-Location $root
    try {
        # stop API lock before file updates when possible
        $appcmd = Get-AppCmd
        try { & $appcmd stop apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null } catch {}
        Stop-BridgeOnPort 18765

        & git fetch --all --prune 2>&1 | Out-Host
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
        if (-not $branch) { $branch = "main" }
        # Prefer fast-forward; if dirty, stash data-related only is hard - stash all local non-data changes
        $status = & git status --porcelain 2>$null
        if ($status) {
            Write-Warn "Local changes detected - stashing before pull (data\ backup kept separately)"
            & git stash push -u -m "cm-noc-install-auto-stash" 2>&1 | Out-Host
        }
        & git pull --ff-only origin $branch 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "ff-only pull failed - trying merge pull"
            & git pull origin $branch 2>&1 | Out-Host
        }
        $head = & git log -1 --oneline 2>$null
        Write-Ok "Code updated: $head"
    } finally {
        Pop-Location
    }

    # Restore monitored_trunks if pull wiped or reset data
    if (Test-Path $backup) {
        $monSrc = Join-Path $backup "monitored_trunks.json"
        $monDst = Join-Path $dataDir "monitored_trunks.json"
        if (Test-Path $monSrc) {
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            Copy-Item $monSrc $monDst -Force
            Write-Ok "Restored data\monitored_trunks.json"
        }
    }
    return $true
}

function Restart-AppPool {
    $appcmd = Get-AppCmd
    if (-not $appcmd) { return }
    try {
        & $appcmd stop apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null
        Start-Sleep -Seconds 2
        & $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null
        Write-Ok "Recycled app pool $AppPoolName"
    } catch {
        Write-Warn "Could not recycle app pool: $_"
    }
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
        Write-Host "  - Windows Features -> Internet Information Services"
        Write-Host "  - Include: IIS Management Console, World Wide Web Services"
        Write-Host "Then re-run this script (it can install Hosting Bundle + Python for you)."
        exit 2
    }
    Write-Ok "IIS detected"

    Ensure-DotNetHosting
    Ensure-Python

    $root = Read-UserPath -defaultPath $defaultRoot
    $port = Read-Port -defaultPort 8888

    # One-click upgrade path for machines that already have an old copy
    $didUpdate = Update-CodeFromGit -root $root

    $need = @("index.html", "app.js", "python\ossi_service.py")
    foreach ($rel in $need) {
        $p = Join-Path $root $rel
        if (-not (Test-Path $p)) {
            throw "Missing $rel under $root - wrong folder or incomplete package?"
        }
    }
    if (-not (Test-Path (Join-Path $root "vendor\avaya-ossi"))) {
        Write-Warn "vendor\avaya-ossi missing - OSSI package may be incomplete after old install"
    }
    Write-Ok "App files found under $root"

    Ensure-DataFiles -root $root

    $basePy = Find-Python
    if (-not $basePy) { throw "Python still not found after install step." }
    Write-Ok "Python: $basePy"
    $venvPy = Ensure-PythonVenv -root $root -basePython $basePy

    # Always republish on update so new C# code is live (DLL unlock via stopped pool)
    if ($didUpdate) {
        Ensure-ApiPublish -root $root -Force
    } else {
        Ensure-ApiPublish -root $root
    }
    Set-JsonAppSettings -root $root -pythonExe $venvPy
    Set-IisSite -root $root -port $port
    Set-Acls -root $root
    Install-BridgeTask -root $root -venvPy $venvPy
    if ($didUpdate) {
        Start-BridgeNow -root $root -venvPy $venvPy -ForceRestart
    } else {
        Start-BridgeNow -root $root -venvPy $venvPy
    }
    Restart-AppPool

    Start-Sleep -Seconds 2
    $url = "http://127.0.0.1:${port}/"
    $apiHealth = "http://127.0.0.1:${port}/api/health"
    try {
        $h = Invoke-WebRequest $apiHealth -UseBasicParsing -TimeoutSec 15
        Write-Ok "API health: $($h.Content)"
    } catch {
        Write-Warn "API not answering yet (recycle app pool if needed): $_"
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    if ($didUpdate) {
        Write-Host "  DONE - UPGRADED existing install (code + IIS + bridge)" -ForegroundColor Green
    } else {
        Write-Host "  DONE - install / reconfigure complete" -ForegroundColor Green
    }
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1. Open browser:  $url"
    Write-Host "  2. Enter your CM Host + Password"
    Write-Host "  3. Click Login  ->  monitoring starts"
    Write-Host ""
    Write-Host "  Root:  $root"
    Write-Host "  Site:  $SiteName  port $port"
    Write-Host "  Bridge auto-starts at Windows logon (task CM-NOC-OSSI-Bridge)"
    Write-Host ""
    Write-Host "Next time you want latest GitHub code on this machine:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\install.ps1 -RootPath `"$root`" -Update"
    Write-Host ""
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
