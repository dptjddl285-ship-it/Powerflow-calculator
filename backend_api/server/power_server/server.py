from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import numpy as np

# engine.py에서 함수 가져오기
try:
    from engine import construct_y_bus
except ImportError:
    print("❌ 에러: engine.py 파일이 같은 폴더에 있는지 확인하세요!")

app = FastAPI()

@app.on_event("startup")
async def startup_event():
    print("\n" + "★"*60)
    print(" 🚀 [완벽 준비] 파이썬 서버가 통신을 기다리고 있습니다! 🚀")
    print(" 플러터 앱에서 그림을 그리고 [파이썬으로 전송]을 누르세요!")
    print("★"*60 + "\n")

# 보안 설정 (CORS)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/run_simulation")
async def run_simulation(request: Request):
    data = await request.json()
    elements = data.get("elements", [])

    print("\n" + "✨"*25)
    print(" 📥 [데이터 수신] 플러터에서 넘어온 전력망 정보 요약")
    print("✨"*25)
    
    buses = [e for e in elements if e.get('type') == 'bus']
    lines = [e for e in elements if e.get('type') == 'line']
    
    print(f"\n📌 [모선(Bus) 데이터: 총 {len(buses)}개]")
    for b in buses:
        node_type = "⭐ Slack" if b.get('isSlack') else "📍 Normal"
        print(f"  [{b.get('id')}] {node_type} | V: {b.get('vPu', 1.0)}pu, 위상각: {b.get('thetaDeg', 0.0)}° | P: {b.get('pPu', 0.0)}, Q: {b.get('qPu', 0.0)}")

    print(f"\n🔗 [선로(Line) 데이터: 총 {len(lines)}개]")
    for l in lines:
        print(f"  [{l.get('id', '선로')}] 연결: {l.get('startElementId')} ↔ {l.get('endElementId')} | R: {l.get('rPu', 0.0)}, X: {l.get('xPu', 0.0)}")
    print("\n" + "="*60)

    try:
        y_bus, bus_ids = construct_y_bus(elements)
        print(f"\n✅ 분석된 모선 순서: {bus_ids}")
        print("-" * 60)
        print("🔢 구성된 Y-Bus Matrix (Admittance):")
        for row in y_bus:
            formatted_row = [f"{val.real:+.3f}{val.imag:+.3f}j" for val in row]
            print(f"[{'  '.join(formatted_row)}]")
        print("-" * 60)
        print(f"💡 행렬 크기: {len(bus_ids)} x {len(bus_ids)}")
        
        # 정상 결과 반환
        return {
            "status": "success", 
            "message": f"파이썬: {len(bus_ids)}개 모선의 Y-Bus 행렬 구성 완료!"
        }
        
    except Exception as e:
        print(f"❌ 계산 중 오류 발생: {e}")
        return {"status": "error", "message": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)