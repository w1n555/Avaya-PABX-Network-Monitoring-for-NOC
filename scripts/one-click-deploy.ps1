#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-click deploy Avaya NOC dashboard to IIS C:\inetpub\wwwroot\CM

.EXAMPLE
  cd C:\inetpub\wwwroot\CM\scripts
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\one-click-deploy.ps1
#>

[CmdletBinding()]
param(
    [string]$TargetRoot = "C:\inetpub\wwwroot\CM",
    [int]$SitePort = 8888,
    [string]$SiteName = "CM-NOC",
    [string]$AppPoolName = "CmApiNoManaged",
    [switch]$SkipBundleDownload,
    [switch]$SkipIisFeatureInstall
)

$ErrorActionPreference = "Stop"
$script:StepIndex = 0
$script:TotalSteps = 10

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content.Trim() + "`r`n", $utf8)
}

function Write-StepBanner {
    param([string]$Message)
    $script:StepIndex++
    $pct = [math]::Min(99, [int](($script:StepIndex - 1) / $script:TotalSteps * 100))
    Write-Progress -Activity "Avaya NOC one-click deploy" -Status $Message -PercentComplete $pct
    Write-Host ""
    Write-Host ("[{0,3}%] Step {1}/{2}: {3}" -f $pct, $script:StepIndex, $script:TotalSteps, $Message) -ForegroundColor Cyan
}

function Complete-Progress {
    param([string]$Message = "Done")
    Write-Progress -Activity "Avaya NOC one-click deploy" -Status $Message -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Activity "Avaya NOC one-click deploy" -Completed
    Write-Host ""
    Write-Host $Message -ForegroundColor Green
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator."
    }
}

function Get-DotNetPath {
    $local = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
    if (Test-Path $local) { return $local }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) { return "dotnet" }
    return $null
}

function Test-AspNetCoreModule {
    $p1 = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    if (Test-Path $p1) { return $true }
    $p2 = Join-Path ${env:ProgramFiles(x86)} "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    return (Test-Path $p2)
}

function Get-AppCmd {
    $p = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
    if (-not (Test-Path $p)) { throw "appcmd.exe not found (install IIS)." }
    return $p
}

function Test-AppCmdName {
    param([string[]]$AppCmdArgs)
    $appcmd = Get-AppCmd
    $null = & $appcmd @AppCmdArgs 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-SafeWebConfig {
    # NOTE: do NOT use <httpLogging dontLog="true" /> here.
    # On some IIS/site locks it causes HTTP 500 for the whole /CM app.
    return @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <defaultDocument>
      <files>
        <clear />
        <add value="index.html" />
      </files>
    </defaultDocument>
    <staticContent>
      <remove fileExtension=".json" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
    </staticContent>
    <security>
      <requestFiltering>
        <hiddenSegments>
          <add segment="src" />
          <add segment="scripts" />
          <add segment=".git" />
        </hiddenSegments>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
'@
}

function Download-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Activity = "Downloading"
    )

    Write-Host "  URL: $Url" -ForegroundColor DarkGray
    Write-Host "  To : $OutFile" -ForegroundColor DarkGray

    # Prefer BITS (shows progress in console via Write-Progress wrapper)
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Write-Progress -Activity $Activity -Status "Starting BITS transfer..." -PercentComplete 0
            # BITS displays its own progress if interactive; also poll
            $job = Start-BitsTransfer -Source $Url -Destination $OutFile -Asynchronous -DisplayName "AvayaNOC-HostingBundle"
            while ($job.JobState -eq "Connecting" -or $job.JobState -eq "Transferring" -or $job.JobState -eq "Queued") {
                $pct = 0
                if ($job.BytesTotal -gt 0) {
                    $pct = [int](($job.BytesTransferred / [double]$job.BytesTotal) * 100)
                }
                $mbT = [math]::Round($job.BytesTransferred / 1MB, 1)
                $mbTot = if ($job.BytesTotal -gt 0) { [math]::Round($job.BytesTotal / 1MB, 1) } else { "?" }
                Write-Progress -Activity $Activity -Status ("BITS {0}%  {1} / {2} MB  state={3}" -f $pct, $mbT, $mbTot, $job.JobState) -PercentComplete $pct
                Start-Sleep -Milliseconds 500
                $job = Get-BitsTransfer -Id $job.JobId -ErrorAction SilentlyContinue
                if (-not $job) { break }
            }
            if ($job -and $job.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $job
                Write-Progress -Activity $Activity -Completed
                Write-Host "  Download complete (BITS)." -ForegroundColor Green
                return
            }
            if ($job) {
                $st = $job.JobState
                Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue
                throw "BITS failed state=$st"
            }
        }
        catch {
            Write-Host "  BITS failed ($($_.Exception.Message)), fallback to WebClient..." -ForegroundColor DarkYellow
        }
    }

    # WebClient + DownloadProgressChanged
    $wc = New-Object System.Net.WebClient
    $done = New-Object System.Threading.ManualResetEvent $false
    $err = $null
    $handler = {
        param($sender, $e)
        $pct = [int]$e.ProgressPercentage
        $mbT = [math]::Round($e.BytesReceived / 1MB, 1)
        $mbTot = [math]::Round($e.TotalBytesToReceive / 1MB, 1)
        Write-Progress -Activity $Activity -Status ("{0}%  {1} / {2} MB" -f $pct, $mbT, $mbTot) -PercentComplete $pct
    }
    $completed = {
        param($sender, $e)
        if ($e.Error) { $script:dlError = $e.Error }
        $done.Set() | Out-Null
    }

    $script:dlError = $null
    Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged -Action $handler | Out-Null
    Register-ObjectEvent -InputObject $wc -EventName DownloadFileCompleted -Action $completed | Out-Null
    try {
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        $wc.DownloadFileAsync([uri]$Url, $OutFile)
        while (-not $done.WaitOne(200)) { }
        if ($script:dlError) { throw $script:dlError }
        if (-not (Test-Path $OutFile)) { throw "Download finished but file missing" }
        Write-Progress -Activity $Activity -Completed
        Write-Host "  Download complete (WebClient)." -ForegroundColor Green
    }
    finally {
        $wc.Dispose()
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $wc } | Unregister-Event -Force -ErrorAction SilentlyContinue
        Get-Job | Where-Object { $_.State -ne "Running" } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# ===================== MAIN =====================
Assert-Admin

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
if (-not (Test-Path (Join-Path $ProjectRoot "src\CmApi\CmApi.csproj"))) {
    if (Test-Path (Join-Path $TargetRoot "src\CmApi\CmApi.csproj")) {
        $ProjectRoot = $TargetRoot
    }
    else {
        throw "Cannot find src\CmApi\CmApi.csproj"
    }
}

Write-Host "========================================================" -ForegroundColor Yellow
Write-Host " Avaya PABX Network Monitoring for NOC - one-click deploy" -ForegroundColor Yellow
Write-Host " Target : $TargetRoot" -ForegroundColor Yellow
Write-Host " URL    : http://127.0.0.1:$SitePort/CM/" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow

# 1
Write-StepBanner "Administrator check OK"

# 2 IIS
Write-StepBanner "Checking / enabling IIS"
$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if ((-not $svc) -and (-not $SkipIisFeatureInstall)) {
    Write-Host "  Enabling IIS features..." -ForegroundColor DarkYellow
    $features = @(
        "IIS-WebServerRole", "IIS-WebServer", "IIS-CommonHttpFeatures",
        "IIS-StaticContent", "IIS-DefaultDocument", "IIS-DirectoryBrowsing",
        "IIS-HttpErrors", "IIS-ApplicationDevelopment", "IIS-HealthAndDiagnostics",
        "IIS-HttpLogging", "IIS-Security", "IIS-RequestFiltering",
        "IIS-Performance", "IIS-HttpCompressionStatic",
        "IIS-WebServerManagementTools", "IIS-ManagementConsole"
    )
    $i = 0
    foreach ($f in $features) {
        $i++
        $sub = [int](10 + ($i / [double]$features.Count) * 12)
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "IIS feature: $f" -PercentComplete $sub
        try { Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        try { Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}
$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if (-not $svc) { throw "IIS (W3SVC) not available." }
if ($svc.Status -ne "Running") { Start-Service W3SVC }
Write-Host "  IIS W3SVC: $((Get-Service W3SVC).Status)" -ForegroundColor Green

# 3 Hosting Bundle
Write-StepBanner "ASP.NET Core 8 Hosting Bundle"
if (Test-AspNetCoreModule) {
    Write-Host "  ANCM already installed - skip download." -ForegroundColor Green
}
elseif ($SkipBundleDownload) {
    Write-Host "  WARNING: ANCM missing and -SkipBundleDownload set." -ForegroundColor Red
}
else {
    $tmp = Join-Path $env:TEMP "dotnet-hosting-8-win.exe"
    $urls = @(
        "https://aka.ms/dotnetcore-8-0-windowshosting",
        "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe"
    )
    $downloaded = $false
    foreach ($u in $urls) {
        try {
            Download-FileWithProgress -Url $u -OutFile $tmp -Activity "Download Hosting Bundle"
            $downloaded = $true
            break
        }
        catch {
            Write-Host "  Download attempt failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    if ($downloaded) {
        Write-Host "  Installing Hosting Bundle (quiet)..." -ForegroundColor DarkYellow
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "Installing Hosting Bundle..." -PercentComplete 38
        $p = Start-Process -FilePath $tmp -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
        Write-Host "  Installer exit: $($p.ExitCode)" -ForegroundColor DarkYellow
        try { & iisreset | Out-Null } catch {}
        Start-Sleep -Seconds 2
    }
    if (Test-AspNetCoreModule) {
        Write-Host "  ANCM OK." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: ANCM still missing after install." -ForegroundColor Red
    }
}

# 4 folders
Write-StepBanner "Prepare folder $TargetRoot"
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $TargetRoot "api") -Force | Out-Null

# 5 copy project
Write-StepBanner "Copy project files to wwwroot\CM"
$projResolved = (Resolve-Path $ProjectRoot).Path
if (-not (Test-Path $TargetRoot)) { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
$tgtResolved = (Resolve-Path $TargetRoot).Path
if ($projResolved -ne $tgtResolved) {
    Write-Host "  Syncing $projResolved -> $tgtResolved" -ForegroundColor DarkYellow
    robocopy $projResolved $tgtResolved /E /XD api bin obj .git deploy /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
}
else {
    Write-Host "  Project already under TargetRoot." -ForegroundColor Green
}

# 6 static UI + SAFE web.config (no BOM, no httpLogging)
Write-StepBanner "Publish static UI (web to site root)"
$webDir = Join-Path $TargetRoot "web"
if (-not (Test-Path $webDir)) { $webDir = Join-Path $ProjectRoot "web" }
if (-not (Test-Path $webDir)) { throw "web folder not found" }
Copy-Item -Path (Join-Path $webDir "*") -Destination $TargetRoot -Force
Write-Utf8NoBom -Path (Join-Path $TargetRoot "web.config") -Content (Get-SafeWebConfig)
Write-Host "  Copied UI + safe web.config (UTF-8 no BOM)" -ForegroundColor Green

# 7 publish API
Write-StepBanner "Publish ASP.NET Core API to api folder"
$dotnet = Get-DotNetPath
if (-not $dotnet) {
    Write-Host "  Installing .NET SDK 8 (user-local)..." -ForegroundColor DarkYellow
    $installPs1 = Join-Path $env:TEMP "dotnet-install.ps1"
    Download-FileWithProgress -Url "https://dot.net/v1/dotnet-install.ps1" -OutFile $installPs1 -Activity "Download dotnet-install.ps1"
    $sdkDir = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Channel 8.0 -InstallDir $sdkDir
    $dotnet = Join-Path $sdkDir "dotnet.exe"
}
$csproj = Join-Path $TargetRoot "src\CmApi\CmApi.csproj"
if (-not (Test-Path $csproj)) { $csproj = Join-Path $ProjectRoot "src\CmApi\CmApi.csproj" }
$apiOut = Join-Path $TargetRoot "api"
Write-Progress -Activity "Avaya NOC one-click deploy" -Status "dotnet publish..." -PercentComplete 70
# Unlock DLL locked by w3wp
$appcmdTmp = Get-AppCmd
try { & $appcmdTmp stop apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null } catch {}
Start-Sleep -Seconds 1
& $dotnet publish $csproj -c Release -o $apiOut --self-contained false
$pubExit = $LASTEXITCODE
try { & $appcmdTmp start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null } catch {}
if ($pubExit -ne 0) { throw "dotnet publish failed" }
if (-not (Test-Path (Join-Path $apiOut "CmApi.dll"))) { throw "CmApi.dll missing" }
Write-Host "  API published: $apiOut" -ForegroundColor Green

# 8 App Pool
Write-StepBanner "Create App Pool $AppPoolName (No Managed Code)"
$appcmd = Get-AppCmd
if (-not (Test-AppCmdName @("list","apppool","/name:$AppPoolName"))) {
    & $appcmd add apppool /name:"$AppPoolName" /managedRuntimeVersion:"" /managedPipelineMode:Integrated | Out-Null
    Write-Host "  Created App Pool $AppPoolName" -ForegroundColor Green
}
else {
    & $appcmd set apppool /apppool.name:"$AppPoolName" /managedRuntimeVersion:"" | Out-Null
    Write-Host "  App Pool exists - set No Managed Code" -ForegroundColor Green
}
& $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null

# 9 Site apps
Write-StepBanner "Configure IIS site, /CM, /CM/api Application"
$wwwroot = "C:\inetpub\wwwroot"
New-Item -ItemType Directory -Path $wwwroot -Force | Out-Null

$parentSite = $null
foreach ($line in (& $appcmd list site)) {
    $lineStr = [string]$line
    if ($lineStr -match [regex]::Escape(":${SitePort}:")) {
        if ($lineStr -match 'SITE "([^"]+)"') {
            $parentSite = $Matches[1]
            break
        }
    }
}
if (-not $parentSite) {
    Write-Host "  Creating site $SiteName on port $SitePort" -ForegroundColor DarkYellow
    & $appcmd add site /name:"$SiteName" /physicalPath:"$wwwroot" /bindings:"http/*:${SitePort}:" 2>$null | Out-Null
    $parentSite = $SiteName
    & $appcmd start site /site.name:"$SiteName" 2>$null | Out-Null
}
else {
    Write-Host "  Using existing site on port ${SitePort}: $parentSite" -ForegroundColor Green
}

$cmAppName = "$parentSite/CM"
if (-not (Test-AppCmdName @("list","app","/app.name:$cmAppName"))) {
    Write-Host "  Adding Application /CM" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:/CM /physicalPath:"$TargetRoot" 2>$null | Out-Null
}
else {
    & $appcmd set app /app.name:"$cmAppName" "/[path='/'].physicalPath:$TargetRoot" 2>$null | Out-Null
    Write-Host "  Application /CM exists - path updated" -ForegroundColor Green
}

$apiAppName = "$parentSite/CM/api"
$apiPhysical = Join-Path $TargetRoot "api"
if (-not (Test-AppCmdName @("list","app","/app.name:$apiAppName"))) {
    Write-Host "  Adding Application /CM/api" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:/CM/api /physicalPath:"$apiPhysical" /applicationPool:"$AppPoolName" 2>$null | Out-Null
}
else {
    Write-Host "  Application /CM/api exists - updating" -ForegroundColor Green
}
& $appcmd set app /app.name:"$apiAppName" /applicationPool:"$AppPoolName" 2>$null | Out-Null
& $appcmd set app /app.name:"$apiAppName" "/[path='/'].physicalPath:$apiPhysical" 2>$null | Out-Null

Write-Host "  Current CM apps:" -ForegroundColor Green
& $appcmd list app | ForEach-Object { if ("$_" -match "CM") { Write-Host "    $_" } }

# 10 smoke test
Write-StepBanner "Smoke test"
Start-Sleep -Seconds 2
$healthUrl = "http://127.0.0.1:${SitePort}/CM/api/health"
$uiUrl = "http://127.0.0.1:${SitePort}/CM/"
$healthOk = $false
$uiOk = $false

try {
    $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 20
    Write-Host "  GET $healthUrl -> $($r.StatusCode) $($r.Content)" -ForegroundColor Green
    $healthOk = $true
}
catch {
    Write-Host "  GET $healthUrl FAILED: $($_.Exception.Message)" -ForegroundColor Red
}

try {
    $r2 = Invoke-WebRequest -Uri $uiUrl -UseBasicParsing -TimeoutSec 15
    Write-Host "  GET $uiUrl -> $($r2.StatusCode) (bytes $($r2.RawContentLength))" -ForegroundColor Green
    $uiOk = $true
}
catch {
    Write-Host "  GET $uiUrl FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Tip: web.config must be UTF-8 without BOM; httpLogging section removed." -ForegroundColor DarkYellow
}

Complete-Progress "Deploy finished."

Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Yellow
Write-Host " Folder : $TargetRoot"
Write-Host " UI     : $uiUrl"
Write-Host " API    : $healthUrl"
Write-Host " Pool   : $AppPoolName (No Managed Code)"
Write-Host " Site   : $parentSite  port $SitePort"
Write-Host (" Health : {0}" -f ($(if ($healthOk) { "OK" } else { "FAILED" }))) -ForegroundColor ($(if ($healthOk) { "Green" } else { "Red" }))
Write-Host (" UI     : {0}" -f ($(if ($uiOk) { "OK" } else { "FAILED" }))) -ForegroundColor ($(if ($uiOk) { "Green" } else { "Red" }))
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next: open $uiUrl then Connect (172.29.88.12 / monitor / password)" -ForegroundColor Cyan

if ($healthOk -and $uiOk) { exit 0 } else { exit 2 }
