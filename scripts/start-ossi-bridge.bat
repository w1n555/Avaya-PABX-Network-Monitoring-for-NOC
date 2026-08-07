@echo off
REM Durable OSSI bridge starter (sets PYTHONPATH for vendored avaya-ossi)
setlocal
set "SITE=C:\inetpub\wwwroot\CM"
set "PYTHONPATH=%SITE%\vendor\avaya-ossi\src"
set "PYTHONUNBUFFERED=1"
set "PY=%SITE%\python\.venv\Scripts\python.exe"
if not exist "%PY%" set "PY=python"
cd /d "%SITE%\python"
REM Default port 18765; override with args: start-ossi-bridge.bat 18767 data_live
set "PORT=18765"
set "DATA=%SITE%\data"
if not "%~1"=="" set "PORT=%~1"
if not "%~2"=="" set "DATA=%SITE%\%~2"
if not exist "%DATA%" mkdir "%DATA%"
start "CM-OSSI-Bridge" /B "%PY%" "%SITE%\python\ossi_service.py" --host 127.0.0.1 --port %PORT% --data-dir "%DATA%"
endlocal
