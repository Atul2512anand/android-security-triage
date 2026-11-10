@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Full Scan
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-here.ps1" -FullScan
pause
