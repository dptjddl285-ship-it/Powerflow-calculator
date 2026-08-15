# 파일명: main_server.py
from fastapi import FastAPI, Request, File, UploadFile, Response
from fastapi.middleware.cors import CORSMiddleware
import pandas as pd
import io
import os
import sys

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

# 프로젝트 루트 경로 추가
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if CURRENT_DIR not in sys.path:
    sys.path.insert(0, CURRENT_DIR)

try:
    from ultralytics import YOLO
except ImportError:
    YOLO = None

try:
    from core.power_logic import construct_y_bus
except ImportError:
    construct_y_bus = None

try:
    from core.pandapower_engine import run_power_flow_simulation, render_single_line_diagram
except ImportError:
    run_power_flow_simulation = None
    render_single_line_diagram = None

try:
    from core.vision_logic import analyze_circuit_image
except ImportError:
    analyze_circuit_image = None

app = FastAPI(title="PowerLens Powerflow & Vision API")
yolo_model = None

@app.on_event("startup")
async def startup_event():
    global yolo_model
    print("\n" + "★"*60)
    print(" 🚀 [PowerLens] Pandapower 통합 전력망 서버 가동 시작!")
    
    # 모델 경로 탐색 (로컬 경로 우선, 없으면 models 폴더 탐색)
    if YOLO is not None:
        candidate_model_paths = [
            os.path.join(CURRENT_DIR, "models", "2026_07_30_coslr.pt"),
            os.path.join(CURRENT_DIR, "icon_recognition", "models", "2026_07_30_coslr.pt"),
            os.path.join(os.path.dirname(CURRENT_DIR), "yolo11s.pt"),
            r"C:\Users\dptjd\Downloads\PowerLens\backend_api\models\2026_07_30_coslr.pt"
        ]
        for m_path in candidate_model_paths:
            if os.path.exists(m_path):
                try:
                    yolo_model = YOLO(m_path)
                    print(f" ✅ AI 모델(YOLO) 로딩 완료: {m_path}")
                    break
                except Exception as e:
                    print(f" ⚠️ 모델 로딩 시도 실패 ({m_path}): {e}")
        
        if yolo_model is None:
            print(" ℹ️ AI Vision 모델이 로드되지 않았습니다 (조류 계산 및 Pandapower 엔진은 정상 동작).")
    else:
        print(" ℹ️ YOLO 패키지 미설치 (조류 계산 및 Pandapower 엔진은 정상 동작).")
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
    if analyze_circuit_image is None:
        return {"status": "error", "message": "Vision 분석 모듈이 설치되지 않았습니다."}
    try:
        image_bytes = await file.read()
        result_data = analyze_circuit_image(image_bytes, yolo_model, filename=file.filename)
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
        contents = await file.read()
        df_gen = pd.read_excel(io.BytesIO(contents), sheet_name='Generator')
        generators = df_gen.set_index('Gen_ID').to_dict(orient='index')
        
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

# ==========================================
# ⚡ [API 3 - 조류 계산 시뮬레이션]
# 플러터 UI에서 보낸 커스텀 전력망 데이터로 정밀 조류 계산 및 단선도 히트맵 생성
# ==========================================
@app.post("/run_simulation")
async def run_simulation(request: Request):
    try:
        data = await request.json()
        elements = data.get("elements", [])
        print(f"\n⚡ [조류계산 요청] {len(elements)}개의 부품 데이터를 받았습니다.")
        
        if not elements:
            return {
                "status": "warning",
                "message": "⚠️ 전송된 전력망 요소(elements)가 없습니다.",
                "summary": None,
                "bus_results": [],
                "line_results": [],
                "plot_image_base64": None
            }
        
        # 1. Y-Bus 행렬 계산 (하위 호환성 유지)
        bus_ids = []
        if construct_y_bus is not None:
            _, bus_ids = construct_y_bus(elements)
        
        # 2. Pandapower 정밀 조류 계산 및 단선도 시각화
        if run_power_flow_simulation is None:
            return {"status": "error", "message": "Pandapower 엔진이 로드되지 않았습니다."}
            
        pf_result = run_power_flow_simulation(elements=elements, return_plot=True)
        
        if pf_result.get("status") == "success":
            pf_result["y_bus_ids"] = bus_ids
            pf_result["y_bus_size"] = len(bus_ids)
            print(f"✅ Pandapower 조류 계산 성공! 모선 {len(pf_result.get('bus_results', []))}개 분석 완료.")
            return pf_result
        else:
            return {
                "status": "partial_success",
                "message": f"Y-Bus 행렬 구성 완료({len(bus_ids)}개 모선). AC 조류 계산 비수렴: {pf_result.get('message')}",
                "y_bus_ids": bus_ids,
                "summary": None,
                "bus_results": [],
                "line_results": []
            }
            
    except Exception as e:
        print(f"❌ 조류 계산 에러: {e}")
        return {"status": "error", "message": str(e)}

# ==========================================
# 🌐 [API 4 - IEEE 표준 계통 목록 조회]
# ==========================================
@app.get("/ieee_cases")
async def get_ieee_cases():
    cases = [
        {"id": "case4gs", "name": "IEEE 4-Bus (Gauss-Seidel Test)", "buses": 4},
        {"id": "case14", "name": "IEEE 14-Bus Standard System", "buses": 14},
        {"id": "case30", "name": "IEEE 30-Bus Standard System", "buses": 30},
        {"id": "case39", "name": "IEEE 39-Bus New England System", "buses": 39},
        {"id": "case57", "name": "IEEE 57-Bus Standard System", "buses": 57},
        {"id": "case118", "name": "IEEE 118-Bus Large System", "buses": 118},
    ]
    return {"status": "success", "cases": cases}

# ==========================================
# 🚀 [API 5 - IEEE 표준 계통 즉시 시뮬레이션]
# ==========================================
@app.post("/run_ieee_case")
async def run_ieee_case(request: Request):
    try:
        data = await request.json()
        case_name = data.get("case", "case30")
        print(f"\n🌐 [IEEE 시뮬레이션 요청] Case: {case_name}")
        
        if run_power_flow_simulation is None:
            return {"status": "error", "message": "Pandapower 엔진이 로드되지 않았습니다."}
            
        result = run_power_flow_simulation(case_name=case_name, return_plot=True)
        return result
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ==========================================
# 🖼️ [API 6 - 단선도 이미지 직접 다운로드/조회]
# ==========================================
@app.get("/render_ieee_image/{case_name}")
async def render_ieee_image(case_name: str):
    try:
        import pandapower as pp
        import pandapower.networks as nw
        case_lower = case_name.lower().replace('-', '').replace('_', '')
        case_loaders = {
            'case4gs': nw.case4gs,
            'case14': nw.case14,
            'case30': nw.case30,
            'case39': nw.case39,
            'case57': nw.case57,
            'case118': nw.case118,
        }
        loader = case_loaders.get(case_lower, nw.case30)
        net = loader()
        pp.runpp(net, numba=False)
        img_bytes = render_single_line_diagram(net, title=f"IEEE {case_name.upper()} Power Flow SLD", return_format="bytes")
        return Response(content=img_bytes, media_type="image/png")
    except Exception as e:
        return {"status": "error", "message": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)