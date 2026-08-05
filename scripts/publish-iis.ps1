# Publish static web + API into deploy\CM for xcopy to C:\inetpub\wwwroot\CM
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dotnet = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
if (-not (Test-Path $dotnet)) { $dotnet = "dotnet" }

$out = Join-Path $root "deploy\CM"
Write-Host "Publishing to $out"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $out "api") -Force | Out-Null

# Static frontend
Copy-Item -Path (Join-Path $root "web\*") -Destination $out -Recurse -Force

# API
& $dotnet publish (Join-Path $root "src\CmApi\CmApi.csproj") -c Release -o (Join-Path $out "api") --self-contained false
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# Root web.config: default document only (API is sub-app)
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
  </system.webServer>
</configuration>
'@ | Set-Content -Path (Join-Path $out "web.config") -Encoding UTF8

Write-Host ""
Write-Host "DONE. Copy deploy\CM\* to C:\inetpub\wwwroot\CM\"
Write-Host "Then in IIS Manager: convert 'api' folder to Application (ASP.NET Core, No Managed Code pool)."
Write-Host "Requires: ASP.NET Core 8 Hosting Bundle on server."
