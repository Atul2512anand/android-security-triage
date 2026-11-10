@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Remote Setup (Tailscale)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-here.ps1" -RemoteSetup
pause
