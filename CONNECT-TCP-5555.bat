@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Connect over TCP 5555
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-tcp-5555.ps1"
pause
