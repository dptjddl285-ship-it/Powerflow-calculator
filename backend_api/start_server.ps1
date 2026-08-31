$ErrorActionPreference = "Stop"

$backendRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonPath = Join-Path $backendRoot ".venv\Scripts\python.exe"
$serverPort = 8000
$env:YOLO_CONFIG_DIR = Join-Path $backendRoot ".ultralytics"
New-Item -ItemType Directory -Force -Path $env:YOLO_CONFIG_DIR | Out-Null

if (-not (Test-Path -LiteralPath $pythonPath)) {
    throw "가상환경이 없습니다. 먼저 backend_api에서 python -m venv .venv 후 requirements.txt를 설치하세요."
}

Push-Location $backendRoot
try {
    & $pythonPath -m uvicorn main_server:app --host 127.0.0.1 --port $serverPort
}
finally {
    Pop-Location
}
