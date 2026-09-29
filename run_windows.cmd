@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if errorlevel 1 (
  echo Python 3.10 or later is required.
  echo Download it from https://www.python.org/downloads/windows/
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" py -3 -m venv .venv
if errorlevel 1 goto :error

".venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
if errorlevel 1 goto :error
".venv\Scripts\python.exe" -m pip install --quiet -e .
if errorlevel 1 goto :error
".venv\Scripts\pythonw.exe" -m kindle_capture gui
exit /b %errorlevel%

:error
echo.
echo Setup failed. Review the message above.
pause
exit /b 1
