@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_turnip_suite.ps1"
timeout /t 2 >nul
start "" http://localhost:8862/
endlocal
