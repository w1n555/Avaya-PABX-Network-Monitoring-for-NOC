$log = "C:\inetpub\wwwroot\CM\data\logs\restart-bridge.log"
function L($m){ Add-Content $log ("{0} {1}" -f (Get-Date -Format o), $m) }
L "restart begin"
Get-NetTCPConnection -LocalPort 18765,18766 -State Listen -EA SilentlyContinue | ForEach-Object {
  L "kill listen pid=$($_.OwningProcess)"
  taskkill /F /PID $_.OwningProcess 2>&1 | ForEach-Object { L $_ }
}
Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.CommandLine -match "ossi_service" } | ForEach-Object {
  L "kill ossi pid=$($_.ProcessId)"
  taskkill /F /PID $_.ProcessId 2>&1 | ForEach-Object { L $_ }
}
Start-Sleep 3
$left = Get-NetTCPConnection -LocalPort 18765 -State Listen -EA SilentlyContinue
L "left listeners=$($left.OwningProcess -join ',')"
$env:PYTHONPATH="C:\inetpub\wwwroot\CM\vendor\avaya-ossi\src"
$env:PYTHONUNBUFFERED="1"
# prove new code with a marker endpoint by running python -c import check first
& "C:\inetpub\wwwroot\CM\python\.venv\Scripts\python.exe" -c "import pathlib; t=pathlib.Path(r'C:\inetpub\wwwroot\CM\python\ossi_service.py').read_text(encoding='utf-8'); print('NEWCODE', 'load_monitored_items' in t)" 2>&1 | ForEach-Object { L $_ }
$p = Start-Process -FilePath "C:\inetpub\wwwroot\CM\python\.venv\Scripts\python.exe" -ArgumentList @("C:\inetpub\wwwroot\CM\python\ossi_service.py","--host","127.0.0.1","--port","18765","--data-dir","C:\inetpub\wwwroot\CM\data") -WorkingDirectory "C:\inetpub\wwwroot\CM\python" -WindowStyle Hidden -PassThru
L "started pid=$($p.Id)"
Start-Sleep 3
try {
  $r = Invoke-RestMethod http://127.0.0.1:18765/monitored -TimeoutSec 5
  L ("monitored keys=" + ($r.PSObject.Properties.Name -join ','))
} catch { L "monitored err $_" }
L "restart end"
