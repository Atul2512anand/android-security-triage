@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Connect Phone
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-here.ps1" -ConnectOnly
pause
