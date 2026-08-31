# 목적: 새 모델(2026_07_30_aug) vs 구 모델(2026_07_01_03) 비교.
#       결정적 테스트: 640 추론 + conf=0.3 (예전에 변압기 0개, 괴물박스 폭발했던 설정)
#       새 모델이 변압기 잡고 괴물박스 없으면 -> aug=0 원인 확정 + 해결.
import os, cv2, numpy as np
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
MODELS = {
    "구(2026_07_01_03,aug0)": os.path.join(BASE,"backend_api","models","2026_07_01_03.pt"),
    "신(2026_07_30_aug)":      os.path.join(BASE,"backend_api","models","2026_07_30_aug.pt"),
}
IMG_DIR = os.path.join(BASE,"학습 IEEE")
OUT = os.path.join(BASE,"backend_api","temp_data","diag_newmodel")
os.makedirs(OUT, exist_ok=True)

PICKS = ["IEEE24bus.jpg","14bus.jpg","24bus.jpg","39bus.jpg","5bus.jpg",
         "2026-7-01-1.jpg","2026-6-23-1.jpg","circuit.jpg","1_Original.jpg","1234.jpg"]

loaded = {k: YOLO(v) for k,v in MODELS.items()}

print("결정적 테스트: imgsz=640, conf=0.3 (예전 앱 설정 - 구모델은 여기서 변압기0/괴물박스폭발)")
print("="*95)
print(f"{'이미지':22} {'모델':26} {'총/변압기/괴물/최대비':24} {'변압기conf':24}")
print("-"*95)

for fname in PICKS:
    ip = os.path.join(IMG_DIR, fname)
    if not os.path.exists(ip):
        print(f"{fname:22} (없음)"); continue
    img = cv2.imread(ip); h,w = img.shape[:2]
    for mname, m in loaded.items():
        r = m.predict(source=ip, imgsz=640, conf=0.3, iou=0.45, verbose=False)[0]
        n, mon, mx, trans_c = 0, 0, 0.0, []
        if r.boxes is not None and len(r.boxes):
            xyxy = r.boxes.xyxy.cpu().numpy()
            clss = r.boxes.cls.cpu().numpy().astype(int)
            confs = r.boxes.conf.cpu().numpy()
            for b,c,cf in zip(xyxy,clss,confs):
                ra = ((b[2]-b[0])/w)*((b[3]-b[1])/h)
                mx = max(mx,ra); n += 1
                if ra>0.5: mon += 1
                if m.names.get(c)=='transformer':
                    trans_c.append(round(float(cf),2))
        flag = "👹" if mon else "✅"
        tc = str(sorted(trans_c,reverse=True)) if trans_c else "없음"
        print(f"{fname:22} {mname:26} {n:>3}/{len(trans_c)}/{mon}{flag}/비{mx:.2f}{'':<8} {tc}")
    print()

# 1234만 1280도 저장(변압기 박스 크기 시각 비교용)
for mname, m in loaded.items():
    r = m.predict(source=os.path.join(IMG_DIR,'1234.jpg'), imgsz=1280, conf=0.2, iou=0.4, verbose=False)[0]
    outn = f"1234_1280__{'신' if '신' in mname else '구'}.jpg"
    cv2.imwrite(os.path.join(OUT, outn), r.plot())
print(f"1234 1280결과 저장: {OUT} (1234_1280__신.jpg vs 1234_1280__구.jpg)")
print("\n판정: 신모델 640/conf0.3에서 변압기>0 & 괴물박스0 -> 성공")
