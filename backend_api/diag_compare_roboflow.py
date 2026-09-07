# 목적: 로컬 2026_07_01_03 모델을 Roboflow 웹과 동일한 조건(학습 해상도 640, 표준 NMS,
#       후처리 필터 없음)으로 추론해서 "모델 자체 성능" vs "앱 추론 파이프라인"을 분리한다.
import os, cv2
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
MODEL = os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt")
IMG_DIR = os.path.join(BASE, "학습 IEEE")
OUT = os.path.join(BASE, "backend_api", "temp_data", "diag_roboflow_compare")
os.makedirs(OUT, exist_ok=True)

PICKS = ["IEEE24bus.jpg", "14bus.jpg", "24bus.jpg", "39bus.jpg", "5bus.jpg",
         "2026-7-01-1.jpg", "2026-6-23-1.jpg", "circuit.jpg", "1_Original.jpg", "1234.jpg"]

model = YOLO(MODEL)
print("클래스:", model.names)
print("비교 조건: (1) 640/표준NMS/필터없음 = Roboflow 웹과 유사조건")
print("           (2) 1280/conf0.3/iou0.4 = 현재 앱(vision_logic) 조건")
print("-" * 90)
print(f"{'이미지':24} {'[1]640표준: 검출/최대비/괴물':30} {'[2]앱조건: 검출/최대비/괴물':30}")
print("-" * 90)

for fname in PICKS:
    ip = os.path.join(IMG_DIR, fname)
    if not os.path.exists(ip):
        print(f"{fname:24} (없음)"); continue
    img = cv2.imread(ip); h, w = img.shape[:2]

    # [1] Roboflow 유사 조건: 학습해상도 640, 표준 conf/iou, 후처리 없음
    r1 = model.predict(source=ip, imgsz=640, conf=0.25, iou=0.45, verbose=False)[0]
    n1, mx1, mon1 = 0, 0.0, 0
    if r1.boxes is not None and len(r1.boxes):
        for b in r1.boxes.xyxy.cpu().numpy():
            ra = ((b[2]-b[0])/w) * ((b[3]-b[1])/h)
            mx1 = max(mx1, ra); n1 += 1
            if ra > 0.5: mon1 += 1
    cv2.imwrite(os.path.join(OUT, f"1_roboflow_like__{os.path.splitext(fname)[0]}.jpg"), r1.plot())

    # [2] 현재 앱 조건: 1280, conf0.3, iou0.4 (필터는 결과 비교를 위해 동일하게 미적용)
    r2 = model.predict(source=ip, imgsz=1280, conf=0.3, iou=0.4, verbose=False)[0]
    n2, mx2, mon2 = 0, 0.0, 0
    if r2.boxes is not None and len(r2.boxes):
        for b in r2.boxes.xyxy.cpu().numpy():
            ra = ((b[2]-b[0])/w) * ((b[3]-b[1])/h)
            mx2 = max(mx2, ra); n2 += 1
            if ra > 0.5: mon2 += 1
    cv2.imwrite(os.path.join(OUT, f"2_app_like__{os.path.splitext(fname)[0]}.jpg"), r2.plot())

    f1 = "👹" if mon1 else "✅"
    f2 = "👹" if mon2 else "✅"
    print(f"{fname:24} {n1:>3}개/비{mx1:.2f}/괴물{mon1}{f1}{'':<15} {n2:>3}개/비{mx2:.2f}/괴물{mon2}{f2}")

print("-" * 90)
print(f"결과 이미지 저장됨: {OUT}")
print("=> [1]로보플로우유사 결과 이미지를 Roboflow 웹 결과와 눈으로 비교하세요.")
print("   [1]이 Roboflow와 비슷하면 -> 모델은 정상, 앱 추론 설정(1280/필터)이 원인")
print("   [1]이 Roboflow보다 현저히 나쁘면 -> 학습 단계(전처리/하이퍼파라미터)가 원인")
