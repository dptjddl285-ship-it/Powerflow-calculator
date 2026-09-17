@echo off
chcp 65001 > nul
title PowerLens Pro Launcher
echo =========================================================
echo ⚡ Starting PowerLens Pro (Backend + Frontend Web)
echo =========================================================
cd /d "%~dp0\.."
python scripts\run_powerlens.py
pause
