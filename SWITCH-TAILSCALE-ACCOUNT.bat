@echo off
setlocal
cd /d "%~dp0"
title Android Triage - Switch Tailscale Account
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-tailscale-account.ps1"
pause
