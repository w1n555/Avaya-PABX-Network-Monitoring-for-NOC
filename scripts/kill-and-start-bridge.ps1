taskkill /F /PID 2868
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "ossi_service" } | ForEach-Object { taskkill /F /PID $_.ProcessId }
Start-Sleep 2
$env:PYTHONPATH="C:\inetpub\wwwroot\CM\vendor\avaya-ossi\src"
$env:PYTHONUNBUFFERED="1"
Start-Process "C:\inetpub\wwwroot\CM\python\.venv\Scripts\python.exe" -ArgumentList "C:\inetpub\wwwroot\CM\python\ossi_service.py","--host","0.0.0.0","--port","18765","--data-dir","C:\inetpub\wwwroot\CM\data" -WorkingDirectory "C:\inetpub\wwwroot\CM\python" -WindowStyle Hidden
Start-Sleep 2
try { $r=Invoke-RestMethod http://127.0.0.1:18765/monitored -TimeoutSec 5; "KEYS=$($r.PSObject.Properties.Name -join ',')" | Out-File C:\inetpub\wwwroot\CM\data\logs\kill-result.txt } catch { "ERR $_" | Out-File C:\inetpub\wwwroot\CM\data\logs\kill-result.txt }
