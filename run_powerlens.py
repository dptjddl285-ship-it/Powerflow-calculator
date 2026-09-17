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

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def main():
    print("=" * 65)
    print("⚡ PowerLens Pro - Integrated System Launcher")
    print("=" * 65)

    # 1. Start Backend Server
    backend_cmd = [sys.executable, os.path.join(BASE_DIR, "main_server.py")]
    print("▶ [1/2] Starting FastAPI Backend on http://127.0.0.1:8000 ...")
    backend_proc = subprocess.Popen(backend_cmd, cwd=BASE_DIR)

    # 2. Start Frontend Web Server
    web_dir = os.path.join(BASE_DIR, "frontend_app", "build", "web")
    if not os.path.isdir(web_dir):
        print(f"❌ Web build directory not found: {web_dir}")
        backend_proc.terminate()
        sys.exit(1)

    frontend_cmd = [sys.executable, os.path.join(BASE_DIR, "frontend_server.py")]
    print("▶ [2/2] Starting Frontend Web Server on http://localhost:58640 (No-Cache) ...")
    frontend_proc = subprocess.Popen(frontend_cmd, cwd=BASE_DIR)

    # 3. Wait and open browser
    time.sleep(2)
    url = "http://localhost:58640"
    print(f"\n🌐 Opening web browser at {url} ...")
    webbrowser.open(url)

    print("\n✅ PowerLens Pro is running smoothly!")
    print("💡 Press Ctrl+C in this terminal to stop both servers at any time.\n")

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
