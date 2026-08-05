#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-click deploy: Avaya PABX Network Monitoring for NOC to IIS wwwroot\CM

.DESCRIPTION
  Progress 0-100%. Enables IIS if needed, installs ASP.NET Core 8 Hosting Bundle,
  publishes UI+API to C:\inetpub\wwwroot\CM, creates App Pool (No Managed Code),
  creates /CM and /CM/api applications.

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
    Start-Sleep -Milliseconds 400
    Write-Progress -Activity "Avaya NOC one-click deploy" -Completed
    Write-Host ""
    Write-Host $Message -ForegroundColor Green
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator (right-click -> Run as administrator)."
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
    if (-not (Test-Path $p)) {
        throw "appcmd.exe not found. Install IIS Management Tools."
    }
    return $p
}

function Test-AppCmdName {
    param([string[]]$Args)
    $appcmd = Get-AppCmd
    $null = & $appcmd @Args 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ===== MAIN =====
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

# Step 1
Write-StepBanner "Administrator check OK"

# Step 2 - IIS
Write-StepBanner "Checking / enabling IIS"
$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if ((-not $svc) -and (-not $SkipIisFeatureInstall)) {
    Write-Host "  Enabling IIS features (may take several minutes)..." -ForegroundColor DarkYellow
    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-CommonHttpFeatures",
        "IIS-StaticContent",
        "IIS-DefaultDocument",
        "IIS-DirectoryBrowsing",
        "IIS-HttpErrors",
        "IIS-ApplicationDevelopment",
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
        $sub = [int](10 + ($i / [double]$features.Count) * 15)
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "IIS feature: $f" -PercentComplete $sub
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
}
elseif ($SkipIisFeatureInstall) {
    Write-Host "  SkipIisFeatureInstall set." -ForegroundColor DarkYellow
}

$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "IIS (W3SVC) not available. Enable IIS Web Server role, then re-run."
}
if ($svc.Status -ne "Running") {
    Start-Service W3SVC
}
Write-Host "  IIS W3SVC: $((Get-Service W3SVC).Status)" -ForegroundColor Green

# Step 3 - Hosting Bundle
Write-StepBanner "ASP.NET Core 8 Hosting Bundle"
if (Test-AspNetCoreModule) {
    Write-Host "  ANCM already installed." -ForegroundColor Green
}
elseif ($SkipBundleDownload) {
    Write-Host "  WARNING: Hosting Bundle missing and -SkipBundleDownload set." -ForegroundColor Red
}
else {
    Write-Host "  Downloading Hosting Bundle..." -ForegroundColor DarkYellow
    Write-Progress -Activity "Avaya NOC one-click deploy" -Status "Downloading Hosting Bundle..." -PercentComplete 30
    $tmp = Join-Path $env:TEMP "dotnet-hosting-8-win.exe"
    $okDl = $false
    try {
        Invoke-WebRequest -Uri "https://aka.ms/dotnetcore-8-0-windowshosting" -OutFile $tmp -UseBasicParsing
        $okDl = $true
    }
    catch {
        try {
            Invoke-WebRequest -Uri "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe" -OutFile $tmp -UseBasicParsing
            $okDl = $true
        }
        catch {
            Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($okDl -and (Test-Path $tmp)) {
        Write-Host "  Installing Hosting Bundle (quiet)..." -ForegroundColor DarkYellow
        Write-Progress -Activity "Avaya NOC one-click deploy" -Status "Installing Hosting Bundle..." -PercentComplete 38
        $p = Start-Process -FilePath $tmp -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
        Write-Host "  Installer exit: $($p.ExitCode)" -ForegroundColor DarkYellow
        try { & iisreset | Out-Null } catch { }
        Start-Sleep -Seconds 2
    }
    if (Test-AspNetCoreModule) {
        Write-Host "  ANCM OK." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: ANCM still missing. Install Hosting Bundle manually from dotnet.microsoft.com" -ForegroundColor Red
    }
}

# Step 4 - folders
Write-StepBanner "Prepare folder $TargetRoot"
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $TargetRoot "api") -Force | Out-Null

# Step 5 - copy project
Write-StepBanner "Copy project files to wwwroot\CM"
$projResolved = (Resolve-Path $ProjectRoot).Path
$tgtResolved = $TargetRoot
if (-not (Test-Path $tgtResolved)) { New-Item -ItemType Directory -Path $tgtResolved -Force | Out-Null }
$tgtResolved = (Resolve-Path $tgtResolved).Path

if ($projResolved -ne $tgtResolved) {
    Write-Host "  Syncing $projResolved -> $tgtResolved" -ForegroundColor DarkYellow
    robocopy $projResolved $tgtResolved /E /XD api bin obj .git deploy /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
}
else {
    Write-Host "  Project already under TargetRoot." -ForegroundColor Green
}

# Step 6 - static UI
Write-StepBanner "Publish static UI (web to site root)"
$webDir = Join-Path $TargetRoot "web"
if (-not (Test-Path $webDir)) {
    $webDir = Join-Path $ProjectRoot "web"
}
if (-not (Test-Path $webDir)) {
    throw "web folder not found"
}
Copy-Item -Path (Join-Path $webDir "*") -Destination $TargetRoot -Force
Write-Host "  Copied index.html / app.js / style.css" -ForegroundColor Green

$webConfig = @'
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
'@
Set-Content -Path (Join-Path $TargetRoot "web.config") -Value $webConfig -Encoding UTF8

# Step 7 - publish API
Write-StepBanner "Publish ASP.NET Core API to api folder"
$dotnet = Get-DotNetPath
if (-not $dotnet) {
    Write-Host "  Installing .NET SDK 8 (user-local)..." -ForegroundColor DarkYellow
    $installPs1 = Join-Path $env:TEMP "dotnet-install.ps1"
    Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installPs1 -UseBasicParsing
    $sdkDir = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Channel 8.0 -InstallDir $sdkDir
    $dotnet = Join-Path $sdkDir "dotnet.exe"
}
if (-not $dotnet) {
    throw "dotnet SDK not available"
}

$csproj = Join-Path $TargetRoot "src\CmApi\CmApi.csproj"
if (-not (Test-Path $csproj)) {
    $csproj = Join-Path $ProjectRoot "src\CmApi\CmApi.csproj"
}
$apiOut = Join-Path $TargetRoot "api"
Write-Progress -Activity "Avaya NOC one-click deploy" -Status "dotnet publish..." -PercentComplete 70
& $dotnet publish $csproj -c Release -o $apiOut --self-contained false
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed (exit $LASTEXITCODE)"
}
if (-not (Test-Path (Join-Path $apiOut "CmApi.dll"))) {
    throw "CmApi.dll missing after publish"
}
Write-Host "  API published: $apiOut" -ForegroundColor Green

# Step 8 - App Pool
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

# Step 9 - Site + applications
Write-StepBanner "Configure IIS site, /CM, /CM/api Application"
$wwwroot = "C:\inetpub\wwwroot"
New-Item -ItemType Directory -Path $wwwroot -Force | Out-Null

$parentSite = $null
$siteLines = & $appcmd list site
foreach ($line in $siteLines) {
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
    $bindings = "http/*:${SitePort}:"
    & $appcmd add site /name:"$SiteName" /physicalPath:"$wwwroot" /bindings:$bindings 2>$null | Out-Null
    $parentSite = $SiteName
    & $appcmd start site /site.name:"$SiteName" 2>$null | Out-Null
}
else {
    Write-Host "  Using existing site on port ${SitePort}: $parentSite" -ForegroundColor Green
}

# /CM application
$cmAppName = "$parentSite/CM"
if (-not (Test-AppCmdName @("list","app","/app.name:$cmAppName"))) {
    Write-Host "  Adding Application /CM" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:/CM /physicalPath:"$TargetRoot" 2>$null | Out-Null
}
else {
    & $appcmd set app /app.name:"$cmAppName" "/[path='/'].physicalPath:$TargetRoot" 2>$null | Out-Null
    Write-Host "  Application /CM exists - path updated" -ForegroundColor Green
}

# /CM/api application
$apiAppName = "$parentSite/CM/api"
$apiPhysical = Join-Path $TargetRoot "api"
if (-not (Test-AppCmdName @("list","app","/app.name:$apiAppName"))) {
    Write-Host "  Adding Application /CM/api (Convert to Application)" -ForegroundColor DarkYellow
    & $appcmd add app /site.name:"$parentSite" /path:/CM/api /physicalPath:"$apiPhysical" /applicationPool:"$AppPoolName" 2>$null | Out-Null
}
else {
    Write-Host "  Application /CM/api exists - updating" -ForegroundColor Green
}

& $appcmd set app /app.name:"$apiAppName" /applicationPool:"$AppPoolName" 2>$null | Out-Null
& $appcmd set app /app.name:"$apiAppName" "/[path='/'].physicalPath:$apiPhysical" 2>$null | Out-Null

Write-Host "  Current CM apps:" -ForegroundColor Green
& $appcmd list app | ForEach-Object { if ($_ -match "CM") { Write-Host "    $_" } }

# Step 10 - smoke test
Write-StepBanner "Smoke test"
Start-Sleep -Seconds 2
$healthUrl = "http://127.0.0.1:${SitePort}/CM/api/health"
$uiUrl = "http://127.0.0.1:${SitePort}/CM/"
$healthOk = $false

try {
    $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 20
    Write-Host "  GET $healthUrl -> $($r.StatusCode) $($r.Content)" -ForegroundColor Green
    $healthOk = $true
}
catch {
    Write-Host "  GET $healthUrl FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Check Hosting Bundle, App Pool, Application /CM/api" -ForegroundColor Red
}

try {
    $r2 = Invoke-WebRequest -Uri $uiUrl -UseBasicParsing -TimeoutSec 15
    Write-Host "  GET $uiUrl -> $($r2.StatusCode)" -ForegroundColor Green
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
    Write-Host " Health : OK" -ForegroundColor Green
}
else {
    Write-Host " Health : FAILED" -ForegroundColor Red
}
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next: open $uiUrl then Connect (172.29.88.12 / monitor / password)" -ForegroundColor Cyan

if ($healthOk) { exit 0 } else { exit 2 }
