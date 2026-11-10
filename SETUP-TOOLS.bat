@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Setup Tools
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-here.ps1" -SetupOnly
pause
