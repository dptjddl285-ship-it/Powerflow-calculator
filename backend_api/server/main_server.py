# 파일명: server/main_server.py
from fastapi import FastAPI, Request, File, UploadFile, Response
from fastapi.middleware.cors import CORSMiddleware
try:
    from ultralytics import YOLO
except ImportError:
    YOLO = None
import pandas as pd
import io
import os
import sys

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PARENT_DIR = os.path.dirname(CURRENT_DIR)
for p in [CURRENT_DIR, PARENT_DIR]:
    if p not in sys.path:
        sys.path.insert(0, p)

try:
    from core.power_logic import construct_y_bus
    from core.pandapower_engine import run_power_flow_simulation, render_single_line_diagram
    from line_recognition.logic.vision_logic import analyze_circuit_image
except ImportError:
    from server.power_logic import construct_y_bus
    from server.pandapower_engine import run_power_flow_simulation, render_single_line_diagram
    try:
        from core.vision_logic import analyze_circuit_image
    except ImportError:
        pass

import pandapower as pp

app = FastAPI(title="PowerLens Powerflow & Vision API")
yolo_model = None

@app.on_event("startup")
async def startup_event():
    global yolo_model
    print("\n" + "★"*60)
    print(" 🚀 [PowerLens] Pandapower 통합 전력망 서버 가동 시작!")
    
    candidate_model_paths = [
        os.path.join(PARENT_DIR, "icon_recognition", "models", "2026_07_30_coslr.pt"),
        os.path.join(PARENT_DIR, "models", "2026_07_30_coslr.pt"),
        os.path.join(PARENT_DIR, "yolo11s.pt")
    ]
    for m_path in candidate_model_paths:
        if os.path.exists(m_path):
            try:
                yolo_model = YOLO(m_path)
                print(f" ✅ AI 모델(YOLO) 로딩 완료: {m_path}")
                break
            except Exception as e:
                print(f" ⚠️ 모델 로딩 실패 ({m_path}): {e}")
                
    if yolo_model is None:
        print(" ℹ️ AI Vision 모델이 로드되지 않았습니다 (조류 계산 엔진은 정상 동작).")
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
        result_data = analyze_circuit_image(image_bytes, yolo_model, filename=file.filename)
        return {"status": "success", "data": result_data}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ==========================================
# 🎯 [API 2 - 엑셀 업로드]
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
        return {"status": "success", "data": excel_data}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ==========================================
# ⚡ [API 3 - 조류 계산 시뮬레이션]
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
                "message": "⚠️ 전송된 전력망 요소가 없습니다.",
                "summary": None,
                "bus_results": [],
                "line_results": [],
                "plot_image_base64": None
            }
        
        y_bus, bus_ids = construct_y_bus(elements)
        pf_result = run_power_flow_simulation(elements=elements, return_plot=True)
        
        if pf_result.get("status") == "success":
            pf_result["y_bus_ids"] = bus_ids
            pf_result["y_bus_size"] = len(bus_ids)
            return pf_result
        else:
            return {
                "status": "partial_success",
                "message": f"Y-Bus 구성 완료 ({len(bus_ids)}개 모선). AC 조류 계산 비수렴: {pf_result.get('message')}",
                "y_bus_ids": bus_ids,
                "summary": None,
                "bus_results": [],
                "line_results": []
            }
    except Exception as e:
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