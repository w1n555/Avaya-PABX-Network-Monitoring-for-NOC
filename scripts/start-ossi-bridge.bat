@echo off
REM Durable OSSI bridge starter — uses site-local Python only (IIS-safe)
setlocal EnableExtensions
set "SITE=C:\inetpub\wwwroot\CM"
set "PYTHONPATH=%SITE%\vendor\avaya-ossi\src"
set "PYTHONUNBUFFERED=1"

REM Prefer venv (has paramiko); fallback to site runtime
set "PY=%SITE%\python\.venv\Scripts\python.exe"
if not exist "%PY%" set "PY=%SITE%\python\runtime\python.exe"
if not exist "%PY%" (
  echo ERROR: No site Python. Expected: %SITE%\python\.venv\Scripts\python.exe
  exit /b 1
)

set "PORT=18767"
set "DATA=%SITE%\data_live"
if not "%~1"=="" set "PORT=%~1"
if not "%~2"=="" (
  REM 2nd arg: leaf under SITE (data / data_live) or absolute path
  echo %~2| findstr /R "^[A-Za-z]:\\.*" >nul
  if errorlevel 1 (set "DATA=%SITE%\%~2") else (set "DATA=%~2")
)
if not exist "%DATA%" mkdir "%DATA%"

cd /d "%SITE%\python"
REM start: first quoted token is window title — keep it
start "CM-OSSI-Bridge" /B "%PY%" "%SITE%\python\ossi_service.py" --host 127.0.0.1 --port %PORT% --data-dir "%DATA%"
endlocal
exit /b 0
