@echo off
chcp 65001 > nul
title PowerLens Pro 통합 실행기
cd /d "%~dp0"
echo =================================================================
echo ⚡ PowerLens Pro 시스템을 시작합니다... (백엔드 + 웹앱)
echo =================================================================
python scripts\run_powerlens.py
if errorlevel 1 (
    echo.
    echo ❌ 실행 중 오류가 발생했습니다.
    pause
)
