@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Main Menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-here.ps1"
if errorlevel 1 pause
