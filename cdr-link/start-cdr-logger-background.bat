@echo off
REM Detached start (no console window required)
setlocal
set "DIR=C:\inetpub\wwwroot\CM\cdr-link"
set "PY=C:\inetpub\wwwroot\CM\python\.venv\Scripts\python.exe"
if not exist "%PY%" set "PY=C:\inetpub\wwwroot\CM\python\runtime\python.exe"
if not exist "%PY%" set "PY=python"
if not exist "%DIR%\cdr" mkdir "%DIR%\cdr"
if not exist "%DIR%\logs" mkdir "%DIR%\logs"
cd /d "%DIR%"
start "CM-CDR-Logger" /B "%PY%" "%DIR%\cdr_logger.py" --host 0.0.0.0 --port 9000 --log-dir "%DIR%\cdr"
echo CDR logger started in background (port 9000).
echo Daily files: %DIR%\cdr\YYYYMMDD.TXT
endlocal
