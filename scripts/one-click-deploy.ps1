#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-click deploy: Avaya PABX Network Monitoring for NOC → IIS wwwroot\CM

.DESCRIPTION
  - Progress bar 0–100%
  - Detect / enable IIS features
  - Install ASP.NET Core 8 Hosting Bundle (if missing)
  - Publish static UI + API to C:\inetpub\wwwroot\CM
  - Create App Pool (No Managed Code)
  - Convert /CM/api to IIS Application
  - Ensure site can serve http://127.0.0.1:8888/CM/ (creates site if needed)

.NOTES
  Run in elevated PowerShell:
    cd C:\inetpub\wwwroot\CM\scripts
    .\one-click-deploy.ps1

  Optional:
    .\one-click-deploy.ps1 -SitePort 8888 -SkipBundleDownload
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
$ProgressPreference = "Continue"

# ---------------------------------------------------------------------------
# Progress UI
# ---------------------------------------------------------------------------
$script:StepIndex = 0
$script:TotalSteps = 10

function Write-StepBanner([string]$Message) {
    $script:StepIndex++
    $pct = [math]::Min(99, [int](($script:StepIndex - 1) / $script:TotalSteps * 100))
    Write-Progress -Activity "Avaya NOC one-click deploy" -Status $Message -PercentComplete $pct
    Write-Host ""
    Write-Host ("[{0,3}%] Step {1}/{2}: {3}" -f $pct, $script:StepIndex, $script:TotalSteps, $Message) -ForegroundColor Cyan
}

function Complete-Progress([string]$Message = "Done") {
    Write-Progress -Activity "Avaya NOC one-click deploy" -Status $Message -PercentComplete 100
    Start-Sleep -Milliseconds 400
    Write-Progress -Activity "Avaya NOC one-click deploy" -Completed
    Write-Host ""
    Write-Host $Message -ForegroundColor Green
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run PowerShell as Administrator (right-click → Run as administrator)."
    }
}

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DotNetPath {
    $local = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
    if (Test-Path $local) { return $local }
    if (Test-CommandExists "dotnet") { return "dotnet" }
    return $null
}

function Test-AspNetCoreModule {
    # ANCM v2 is registered after Hosting Bundle install
    $dll = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    if (Test-Path $dll) { return $true }
    $dll2 = Join-Path ${env:ProgramFiles(x86)} "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    return (Test-Path $dll2)
}

function Get-AppCmd {
    $p = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
    if (-not (Test-Path $p)) { throw "appcmd.exe not found. IIS Management tools may be missing." }
    return $p
}

function Invoke-AppCmd {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $appcmd = Get-AppCmd
    & $appcmd @Args
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        # appcmd often returns non-zero for "already exists" — callers handle
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-Admin

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
# If script lives inside TargetRoot already, ProjectRoot == TargetRoot after first deploy
if (-not (Test-Path (Join-Path $ProjectRoot "src\CmApi\CmApi.csproj"))) {
    if (Test-Path (Join-Path $TargetRoot "src\CmApi\CmApi.csproj")) {
        $ProjectRoot = $TargetRoot
    }
    else {
        throw "Cannot find src\CmApi\CmApi.csproj under $ProjectRoot or $TargetRoot"
    }
}

Write-Host "========================================================" -ForegroundColor Yellow
Write-Host " Avaya PABX Network Monitoring for NOC — one-click deploy" -ForegroundColor Yellow
Write-Host " Target : $TargetRoot" -ForegroundColor Yellow
Write-Host " URL    : http://127.0.0.1:$SitePort/CM/" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow

# ---- 1. Admin OK ----
Write-StepBanner "Administrator check OK"

# ---- 2. Enable IIS features ----
Write-StepBanner "Checking / enabling IIS features"
$iisEnabled = $false
try {
    $svc = Get-Service W3SVC -ErrorAction SilentlyContinue
    if ($svc) { $iisEnabled = $true }
}
catch { $iisEnabled = $false }

if (-not $iisEnabled -and -not $SkipIisFeatureInstall) {
    Write-Host "  Enabling IIS (this can take several minutes)..." -ForegroundColor DarkYellow
    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-CommonHttpFeatures",
        "IIS-StaticContent",
        "IIS-DefaultDocument",
        "IIS-DirectoryBrowsing",
        "IIS-HttpErrors",
        "IIS-ApplicationDevelopment",
        "IIS-NetFxExtensibility45",
        "IIS-HealthAndDiagnostics",
        "IIS-HttpLogging",
        "IIS-Security",
        "IIS-RequestFiltering",
        "IIS-Performance",
        "IIS-HttpCompressionStatic",
        "IIS-WebServerManagementTools",
        "IIS-ManagementConsole"
    )
    $i = 0
    foreach ($f in $features) {
        $i++
        $sub = [int](10 + ($i / $features.Count) * 15)
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "IIS feature: $f" -PercentComplete $sub
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # Server SKUs sometimes use Install-WindowsFeature
            if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
                try { Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
        }
    }
    Start-Service W3SVC -ErrorAction SilentlyContinue
}
elseif ($SkipIisFeatureInstall) {
    Write-Host "  SkipIisFeatureInstall set — assuming IIS present." -ForegroundColor DarkYellow
}

$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne "Running") {
    try { Start-Service W3SVC -ErrorAction Stop } catch {
        throw "IIS (W3SVC) is not available. Enable IIS Web Server role manually, then re-run."
    }
}
Write-Host "  IIS W3SVC: $((Get-Service W3SVC).Status)" -ForegroundColor Green

# ---- 3. Hosting Bundle ----
Write-StepBanner "ASP.NET Core 8 Hosting Bundle"
$hasAncm = Test-AspNetCoreModule
if ($hasAncm) {
    Write-Host "  ANCM already installed." -ForegroundColor Green
}
elseif ($SkipBundleDownload) {
    Write-Host "  WARNING: Hosting Bundle not detected and -SkipBundleDownload set." -ForegroundColor Red
}
else {
    Write-Host "  Downloading Hosting Bundle (large file)..." -ForegroundColor DarkYellow
    $bundleUrl = "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe"
    # Fallback known good pattern — try latest 8.0 hosting via aka.ms
    $bundleUrlAlt = "https://aka.ms/dotnetcore-8-0-windowshosting"
    $tmp = Join-Path $env:TEMP "dotnet-hosting-8-win.exe"
    try {
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "Downloading Hosting Bundle..." -PercentComplete 30
        try {
            Invoke-WebRequest -Uri $bundleUrlAlt -OutFile $tmp -UseBasicParsing
        }
        catch {
            Invoke-WebRequest -Uri $bundleUrl -OutFile $tmp -UseBasicParsing
        }
        Write-Host "  Installing Hosting Bundle silently..." -ForegroundColor DarkYellow
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "Installing Hosting Bundle..." -PercentComplete 38
        $p = Start-Process -FilePath $tmp -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
        Write-Host "  Installer exit code: $($p.ExitCode)" -ForegroundColor DarkYellow
        # Restart IIS to load ANCM
        & iisreset | Out-Null
        Start-Sleep -Seconds 2
    }
    catch {
        Write-Host "  WARNING: Hosting Bundle install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Download manually: https://dotnet.microsoft.com/download/dotnet/8.0 (Hosting Bundle)" -ForegroundColor Red
    }
    if (Test-AspNetCoreModule) {
        Write-Host "  ANCM OK after install." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: ANCM still not detected — API may fail until Hosting Bundle is installed." -ForegroundColor Red
    }
}

# ---- 4. Ensure target folder ----
Write-StepBanner "Prepare folder $TargetRoot"
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $TargetRoot "api") -Force | Out-Null

# ---- 5. Sync project files if source != target ----
Write-StepBanner "Copy project files to wwwroot\CM"
if ((Resolve-Path $ProjectRoot).Path -ne (Resolve-Path $TargetRoot).Path) {
    Write-Host "  Syncing from $ProjectRoot → $TargetRoot" -ForegroundColor DarkYellow
    robocopy $ProjectRoot $TargetRoot /E /XD api bin obj .git deploy /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
}
else {
    Write-Host "  Project already lives under TargetRoot." -ForegroundColor Green
}

# ---- 6. Publish static UI to site root ----
Write-StepBanner "Publish static UI (web → site root)"
$webDir = Join-Path $TargetRoot "web"
if (-not (Test-Path $webDir)) { $webDir = Join-Path $ProjectRoot "web" }
if (-not (Test-Path $webDir)) { throw "web\ folder not found" }
Copy-Item -Path (Join-Path $webDir "*") -Destination $TargetRoot -Force
Write-Host "  Copied index.html / app.js / style.css" -ForegroundColor Green

# Root web.config
@'
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
    <httpLogging dontLog="true" />
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
'@ | Set-Content -Path (Join-Path $TargetRoot "web.config") -Encoding UTF8

# ---- 7. Publish API ----
Write-StepBanner "Publish ASP.NET Core API → api\"
$dotnet = Get-DotNetPath
if (-not $dotnet) {
    Write-Host "  dotnet SDK not found — downloading SDK 8 (user-local)..." -ForegroundColor DarkYellow
    $installPs1 = Join-Path $env:TEMP "dotnet-install.ps1"
    Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installPs1 -UseBasicParsing
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Channel 8.0 -InstallDir (Join-Path $env:LOCALAPPDATA "Microsoft\dotnet")
    $dotnet = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
}
if (-not (Test-Path $dotnet) -and $dotnet -ne "dotnet") {
    throw "dotnet SDK still not available. Install .NET 8 SDK and re-run."
}

$csproj = Join-Path $TargetRoot "src\CmApi\CmApi.csproj"
if (-not (Test-Path $csproj)) { $csproj = Join-Path $ProjectRoot "src\CmApi\CmApi.csproj" }
$apiOut = Join-Path $TargetRoot "api"
Write-Progress -Activity "Avaya NOC one-click deploy" -Status "dotnet publish..." -PercentComplete 70
& $dotnet publish $csproj -c Release -o $apiOut --self-contained false
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)" }
if (-not (Test-Path (Join-Path $apiOut "CmApi.dll"))) { throw "CmApi.dll missing after publish" }
Write-Host "  API published: $apiOut" -ForegroundColor Green

# ---- 8. App Pool (No Managed Code) ----
Write-StepBanner "Create App Pool: $AppPoolName (No Managed Code)"
Import-Module WebAdministration -ErrorAction SilentlyContinue
$appcmd = Get-AppCmd

$poolExists = $false
try {
    $null = & $appcmd list apppool /name:"$AppPoolName" 2>$null
    if ($LASTEXITCODE -eq 0) { $poolExists = $true }
}
catch { $poolExists = $false }

if (-not $poolExists) {
    & $appcmd add apppool /name:"$AppPoolName" /managedRuntimeVersion:"" /managedPipelineMode:Integrated | Out-Null
    Write-Host "  Created App Pool $AppPoolName" -ForegroundColor Green
}
else {
    & $appcmd set apppool /apppool.name:"$AppPoolName" /managedRuntimeVersion:"" | Out-Null
    Write-Host "  App Pool already exists — set No Managed Code" -ForegroundColor Green
}
& $appcmd start apppool /apppool.name:"$AppPoolName" 2>$null | Out-Null

# ---- 9. Site + /CM path + /CM/api Application ----
Write-StepBanner "Configure IIS site / CM / api Application"

# Ensure wwwroot exists
$wwwroot = "C:\inetpub\wwwroot"
New-Item -ItemType Directory -Path $wwwroot -Force | Out-Null

# Find site on port or create CM-NOC
$siteOnPort = $null
$sites = & $appcmd list site
foreach ($line in $sites) {
    if ($line -match ":${SitePort}:") { $siteOnPort = $line; break }
}

if (-not $siteOnPort) {
    # Create dedicated site pointing at wwwroot so /CM works
    $bindings = "http/*:${SitePort}:"
    Write-Host "  Creating site '$SiteName' on port $SitePort → $wwwroot" -ForegroundColor DarkYellow
    & $appcmd add site /name:"$SiteName" /physicalPath:"$wwwroot" /bindings:$bindings 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # maybe name exists with different port
        Write-Host "  add site returned $LASTEXITCODE — trying set site / start" -ForegroundColor DarkYellow
    }
    & $appcmd start site /site.name:"$SiteName" 2>$null | Out-Null
    $parentSite = $SiteName
}
else {
    # Parse site name: SITE "Default Web Site" (id:1,...)
    if ($siteOnPort -match 'SITE "([^"]+)"') { $parentSite = $Matches[1] }
    else { $parentSite = "Default Web Site" }
    Write-Host "  Using existing site on port ${SitePort}: $parentSite" -ForegroundColor Green
}

# Application /CM → TargetRoot (optional; folder under wwwroot often enough)
# Prefer application so path is explicit
$cmAppPath = "/CM"
$cmAppFull = "${parentSite}${cmAppPath}"
$cmExists = $false
try {
    $out = & $appcmd list app /app.name:"$cmAppFull" 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { $cmExists = $true }
}
catch { $cmExists = $false }

if (-not $cmExists) {
    Write-Host "  Adding Application $cmAppFull → $TargetRoot" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:$cmAppPath /physicalPath:"$TargetRoot" 2>$null | Out-Null
}
else {
    & $appcmd set app /app.name:"$cmAppFull" /[path='/'].physicalPath:"$TargetRoot" 2>$null | Out-Null
    Write-Host "  Application /CM already exists — path updated" -ForegroundColor Green
}

# Application /CM/api → api folder + No Managed pool
# Note: nested app under /CM
$apiAppPath = "/CM/api"
$apiAppFull = "${parentSite}${apiAppPath}"
$apiExists = $false
try {
    $out = & $appcmd list app /app.name:"$apiAppFull" 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { $apiExists = $true }
}
catch { $apiExists = $false }

$apiPhysical = Join-Path $TargetRoot "api"
if (-not $apiExists) {
    Write-Host "  Convert/Add Application $apiAppFull → $apiPhysical" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:$apiAppPath /physicalPath:"$apiPhysical" /applicationPool:"$AppPoolName" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Fallback: path relative under /CM only works if /CM is app — try add under CM app
        Write-Host "  Retry add app with explicit pool..." -ForegroundColor DarkYellow
        & $appcmd add app /site.name:"$parentSite" /path:"/CM/api" /physicalPath:"$apiPhysical" 2>$null | Out-Null
    }
}
else {
    Write-Host "  Application /CM/api already exists — updating path & pool" -ForegroundColor Green
}

# Always force pool + path
& $appcmd set app /app.name:"$apiAppFull" /applicationPool:"$AppPoolName" 2>$null | Out-Null
& $appcmd set app /app.name:"$apiAppFull" /[path='/'].physicalPath:"$apiPhysical" 2>$null | Out-Null
# If nested name format differs:
& $appcmd set app /app.name:"${parentSite}/CM/api" /applicationPool:"$AppPoolName" 2>$null | Out-Null
& $appcmd set app /app.name:"${parentSite}/CM/api" /[path='/'].physicalPath:"$apiPhysical" 2>$null | Out-Null

Write-Host "  Apps:" -ForegroundColor Green
& $appcmd list app | Select-String -Pattern "CM"

# ---- 10. Health check ----
Write-StepBanner "Smoke test"
Start-Sleep -Seconds 2
$healthUrl = "http://127.0.0.1:${SitePort}/CM/api/health"
$uiUrl = "http://127.0.0.1:${SitePort}/CM/"
$healthOk = $false
try {
    $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 15
    Write-Host "  GET $healthUrl → $($r.StatusCode) $($r.Content)" -ForegroundColor Green
    $healthOk = $true
}
catch {
    Write-Host "  GET $healthUrl FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Check: Hosting Bundle, App Pool, Application /CM/api" -ForegroundColor Red
}

try {
    $r2 = Invoke-WebRequest -Uri $uiUrl -UseBasicParsing -TimeoutSec 10
    Write-Host "  GET $uiUrl → $($r2.StatusCode)" -ForegroundColor Green
}
catch {
    Write-Host "  GET $uiUrl FAILED: $($_.Exception.Message)" -ForegroundColor Red
}

Complete-Progress "Deploy finished."

Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Yellow
Write-Host " Folder : $TargetRoot"
Write-Host " UI     : $uiUrl"
Write-Host " API    : $healthUrl"
Write-Host " Pool   : $AppPoolName (No Managed Code)"
Write-Host " Site   : $parentSite  port $SitePort"
if ($healthOk) {
    Write-Host " Health : OK — open UI and Connect to 172.29.88.12" -ForegroundColor Green
}
else {
    Write-Host " Health : FAILED — see messages above" -ForegroundColor Red
}
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next: browser → $uiUrl → Connect (monitor / RO password)" -ForegroundColor Cyan
exit $(if ($healthOk) { 0 } else { 2 })
