@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Export Personal Data
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export-data.ps1"
pause
