# -*- coding: utf-8 -*-
"""PowerLens Pro - One-Click Integrated Launcher
Runs both the FastAPI backend server and the Flutter Web production server,
then automatically opens your default web browser at http://localhost:58640.
"""

import os
import sys
import subprocess
import time
import webbrowser
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
BACKEND_DIR = PROJECT_ROOT / "backend_api"
WEB_DIR = PROJECT_ROOT / "frontend_app" / "build" / "web"

def free_port(port: int):
    try:
        import socket
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(('127.0.0.1', port)) != 0:
                return
        out = subprocess.check_output(f"netstat -ano | findstr :{port}", shell=True, text=True)
        for line in out.strip().splitlines():
            parts = line.strip().split()
            if len(parts) >= 5 and f":{port}" in parts[1] and parts[3] == "LISTENING":
                pid = parts[4]
                if pid != str(os.getpid()):
                    subprocess.run(f"taskkill /F /PID {pid}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    print(f"  ↳ 이전 실행으로 점유 중이던 포트 {port} (PID: {pid})를 자동 해제했습니다.")
    except Exception:
        pass


def open_in_incognito(url: str):
    """Opens the target URL in an incognito / private browsing window to prevent stale cache and residual data."""
    candidates = [
        # Chrome
        (r"C:\Program Files\Google\Chrome\Application\chrome.exe", ["--incognito"]),
        (r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe", ["--incognito"]),
        (os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"), ["--incognito"]),
        # Edge (Windows native)
        (r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", ["--inprivate"]),
        (r"C:\Program Files\Microsoft\Edge\Application\msedge.exe", ["--inprivate"]),
        # Brave
        (r"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe", ["--incognito"]),
        (os.path.expandvars(r"%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"), ["--incognito"]),
        # Firefox
        (r"C:\Program Files\Mozilla Firefox\firefox.exe", ["-private-window"]),
        (r"C:\Program Files (x86)\Mozilla Firefox\firefox.exe", ["-private-window"]),
    ]

    for exe_path, flags in candidates:
        if os.path.exists(exe_path):
            try:
                subprocess.Popen([exe_path] + flags + [url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                browser_name = Path(exe_path).stem.capitalize()
                print(f"\n🔒 {browser_name} 시크릿 모드(Incognito)로 브라우저를 실행했습니다: {url}")
                return
            except Exception:
                continue

    # Fallback to shell start commands
    for cmd in [f'start chrome --incognito "{url}"', f'start msedge --inprivate "{url}"']:
        try:
            res = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode == 0:
                print(f"\n🔒 시크릿 모드 브라우저로 자동 실행했습니다: {url}")
                return
        except Exception:
            continue

    # Ultimate fallback to default browser
    print(f"\n🌐 기본 웹 브라우저로 실행합니다: {url}")
    webbrowser.open(url)

def main():
    print("=" * 65)
    print("⚡ PowerLens Pro - 원클릭 통합 실행기 (One-Click Launcher)")
    print("=" * 65)

    # Free ports if previously running
    free_port(8000)
    free_port(58640)

    # 1. Start Backend Server
    backend_script = BACKEND_DIR / "main_server.py"
    backend_cmd = [sys.executable, str(backend_script)]
    print("▶ [1/2] FastAPI 백엔드 서버 구동 중... (http://127.0.0.1:8000)")
    backend_proc = subprocess.Popen(backend_cmd, cwd=str(BACKEND_DIR))

    # 2. Check & Start Frontend Web Server
    if not WEB_DIR.is_dir():
        print(f"❌ 웹 빌드 폴더를 찾을 수 없습니다: {WEB_DIR}")
        backend_proc.terminate()
        sys.exit(1)

    frontend_script = SCRIPT_DIR / "frontend_server.py"
    frontend_cmd = [sys.executable, str(frontend_script)]
    print("▶ [2/2] Flutter 웹 프론트엔드 서버 구동 중... (http://localhost:58640)")
    frontend_proc = subprocess.Popen(frontend_cmd, cwd=str(PROJECT_ROOT))

    # 3. Wait and open browser in Incognito / InPrivate mode
    time.sleep(2)
    url = "http://localhost:58640"
    open_in_incognito(url)

    print("\n" + "=" * 65)
    print("✅ PowerLens Pro 시스템이 정상 가동되었습니다!")
    print("💡 프로그램을 종료하려면 이 창에서 [Ctrl + C]를 누르거나 창을 닫으세요.")
    print("=" * 65 + "\n")

    try:
        backend_proc.wait()
        frontend_proc.wait()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down PowerLens Pro servers...")
        try:
            backend_proc.terminate()
            frontend_proc.terminate()
        except Exception:
            pass
        print("Done. Goodbye!")

if __name__ == "__main__":
    main()
