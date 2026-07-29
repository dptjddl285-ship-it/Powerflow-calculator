# 여러 이미지에 대해 640 vs 1280 비교 테스트 (두 모델)
import os, glob, cv2
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
IMG_DIR = os.path.join(BASE, "학습 IEEE")
OUT = os.path.join(BASE, "backend_api", "temp_data", "inference_test")
os.makedirs(OUT, exist_ok=True)

MODELS = {
    "best3": os.path.join(BASE, "backend_api", "models", "best3.pt"),
    "latest_2026_07_01_03": os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt"),
}

# 다양한 이미지 선택
PICKS = ["IEEE24bus.jpg", "14bus.jpg", "24bus.jpg", "36bus.jpg", "5bus.jpg",
         "2026-7-01-1.jpg", "2026-6-23-1.jpg", "circuit.jpg", "1_Original.jpg", "1234.jpg"]

def run(model, img_path, imgsz, conf=0.4, iou=0.45):
    r = model.predict(source=img_path, imgsz=imgsz, conf=conf, iou=iou, verbose=False)[0]
    img = cv2.imread(img_path); h, w = img.shape[:2]
    n = len(r.boxes) if r.boxes is not None else 0
    maxr = 0.0; nmon = 0
    if n:
        for b in r.boxes.xyxy.cpu().numpy():
            ra = ((b[2]-b[0])/w) * ((b[3]-b[1])/h)
            maxr = max(maxr, ra)
            if ra > 0.5: nmon += 1
    return r, n, maxr, nmon

print(f"{'이미지':24} {'모델':22} {'640:검출/괴물/최대비':26} {'1280:검출/괴물/최대비':26}")
print("-"*100)

loaded = {}
for mname, mp in MODELS.items():
    loaded[mname] = YOLO(mp)

for fname in PICKS:
    img_path = os.path.join(IMG_DIR, fname)
    if not os.path.exists(img_path):
        print(f"{fname:24} (없음)")
        continue
    for mname in MODELS:
        m = loaded[mname]
        _, n6, mx6, mon6 = run(m, img_path, 640)
        r12, n12, mx12, mon12 = run(m, img_path, 1280)
        flag6 = "👹" if mon6>0 else "✅"
        flag12 = "👹" if mon12>0 else "✅"
        print(f"{fname:24} {mname:22} {n6:>3}/{mon6}/{mx6:.2f}{flag6}{'':<14} {n12:>3}/{mon12}/{mx12:.2f}{flag12}")
        # 1280 결과 이미지 저장 (해결책 시연용)
        out_path = os.path.join(OUT, f"FIX_{mname}__{os.path.splitext(fname)[0]}__1280.jpg")
        cv2.imwrite(out_path, r12.plot())
        # 640에서 괴물박스가 있으면 그것도 저장 (비교용)
        if mon6 > 0:
            r6,_,_,_ = run(m, img_path, 640)
            out6 = os.path.join(OUT, f"BAD_{mname}__{os.path.splitext(fname)[0]}__640.jpg")
            cv2.imwrite(out6, r6.plot())
