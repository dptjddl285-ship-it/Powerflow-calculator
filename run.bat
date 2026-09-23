@echo off
chcp 65001 > nul
title PowerLens Pro Launcher
cd /d "%~dp0"
echo =================================================================
echo [PowerLens Pro] Starting Backend and Frontend Web App...
echo =================================================================
python scripts\run_powerlens.py
if errorlevel 1 (
    echo.
    echo [Error] Failed to run PowerLens Pro.
    pause
)
