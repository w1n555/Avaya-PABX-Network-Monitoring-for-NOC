# Publish in-place to this IIS site folder:
#   C:\inetpub\wwwroot\CM  →  http://127.0.0.1:8888/CM
$ErrorActionPreference = "Stop"

# Project root = parent of scripts\
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root "src\CmApi\CmApi.csproj"))) {
  throw "CmApi project not found under $root"
}

$dotnet = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
if (-not (Test-Path $dotnet)) { $dotnet = "dotnet" }

Write-Host "Project root : $root"
Write-Host "IIS URL      : http://127.0.0.1:8888/CM"

# 1) Static UI at site root (served as /CM/)
Copy-Item -Path (Join-Path $root "web\*") -Destination $root -Force
Write-Host "Copied web/* → site root"

# 2) API → /CM/api
$apiOut = Join-Path $root "api"
& $dotnet publish (Join-Path $root "src\CmApi\CmApi.csproj") -c Release -o $apiOut --self-contained false
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Write-Host "Published API → $apiOut"

# 3) Root web.config (static + hide source)
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
'@ | Set-Content -Path (Join-Path $root "web.config") -Encoding UTF8

Write-Host ""
Write-Host "DONE."
Write-Host "Open: http://127.0.0.1:8888/CM/"
Write-Host "Ensure IIS Application exists for /CM/api (No Managed Code pool + ASP.NET Core 8 Hosting Bundle)."
