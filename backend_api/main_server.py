# 파일명: main_server.py
from fastapi import FastAPI, Request, File, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from ultralytics import YOLO
import pandas as pd
import io
import os

try:
    from core.power_logic import construct_y_bus
    from core.vision_logic import analyze_circuit_image
except ImportError as e:
    print(f"❌ 에러: 파일을 찾을 수 없습니다. {e}")

app = FastAPI()
yolo_model = None

@app.on_event("startup")
async def startup_event():
    global yolo_model
    print("\n" + "★"*60)
    print(" 🚀 [PowerLens] 통합 서버 가동 시작!")
    try:
        # best3.pt(640 안정)도 있으나, 2026_07_01_03.pt가 imgsz=1280에서 괴물박스 없이 검출 수가 더 많음.
        # vision_logic.py의 추론 imgsz=1280과 반드시 함께 사용해야 함.
        yolo_model = YOLO(r"C:\Users\dptjd\Downloads\PowerLens\backend_api\models\2026_07_01_03.pt")
        print(" ✅ AI 모델(YOLO) 로딩 완료!")
    except Exception as e:
        print(f" ❌ 모델 로딩 실패: {e}")
    print("★"*60 + "\n")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# [API 1] 사진 분석 
@app.post("/analyze_image")
async def process_image(file: UploadFile = File(...)):
    print("\n📸 [사진 수신] 분석 요청이 들어왔습니다.")
    try:
        image_bytes = await file.read()
        result_data = analyze_circuit_image(image_bytes, yolo_model)
        return {"status": "success", "data": result_data}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ==========================================
# 🎯 [API 2 - 엑셀 업로드] 플러터에서 엑셀 파일이 날아오면 바로 읽어서 돌려줌!
# ==========================================
@app.post("/upload_excel")
async def upload_excel(file: UploadFile = File(...)):
    print(f"\n📂 [엑셀 수신] 업로드된 파일명: {file.filename}")
    try:
        # 파일을 하드디스크에 저장하지 않고 메모리(BytesIO)에서 바로 엑셀 파싱!
        contents = await file.read()
        
        # 발전기 시트 읽기
        df_gen = pd.read_excel(io.BytesIO(contents), sheet_name='Generator')
        generators = df_gen.set_index('Gen_ID').to_dict(orient='index')
        
        # 선로 시트 읽기
        df_line = pd.read_excel(io.BytesIO(contents), sheet_name='Line')
        lines = df_line.set_index('Line_ID').to_dict(orient='index')
        
        excel_data = {
            "generators": generators,
            "lines": lines
        }
        
        print(f"✅ 엑셀 업로드 및 파싱 성공! 발전기({len(generators)}개), 선로({len(lines)}개) 데이터 전송.")
        return {"status": "success", "data": excel_data}
        
    except Exception as e:
        print(f"❌ 엑셀 처리 중 에러 발생: {e}")
        return {"status": "error", "message": str(e)}

# [API 3] 조류 계산 
@app.post("/run_simulation")
async def run_simulation(request: Request):
    data = await request.json()
    elements = data.get("elements", [])
    print(f"\n⚡ [조류계산 요청] {len(elements)}개의 부품 데이터를 받았습니다.")
    return {"status": "success", "message": "조류 계산 성공!"}