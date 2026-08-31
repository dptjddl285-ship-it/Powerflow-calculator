# 목적: 로컬 모델(2026_07_01_03)에 Roboflow와 동일한 전처리(Auto-Orient + CLAHE + letterbox-white-640)를
#       적용한 뒤 640 추론을 돌려, 괴물박스가 사라지는지 확인한다.
#       => 사라지면 원인은 "추론 시 전처리 누락" (학습 분포 불일치).
import os, cv2, numpy as np
from PIL import Image, ImageOps
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
MODEL = os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt")
IMG_DIR = os.path.join(BASE, "학습 IEEE")
OUT = os.path.join(BASE, "backend_api", "temp_data", "diag_preproc")
os.makedirs(OUT, exist_ok=True)

PICKS = ["IEEE24bus.jpg", "14bus.jpg", "24bus.jpg", "39bus.jpg", "5bus.jpg",
         "2026-7-01-1.jpg", "2026-6-23-1.jpg", "circuit.jpg", "1_Original.jpg", "1234.jpg"]

model = YOLO(MODEL)

def auto_orient(path):
    # EXIF 방향 보정 (Roboflow Auto-Orient)
    img = Image.open(path)
    return ImageOps.exif_transpose(img)

def clahe(np_bgr):
    # Adaptive Equalization (Roboflow Auto-Adjust Contrast) - CLAHE on L channel
    lab = cv2.cvtColor(np_bgr, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    l = clahe.apply(l)
    lab = cv2.merge((l, a, b))
    return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

def letterbox_white(img, size=640):
    # Roboflow Resize: "Fit (white edges) in 640x640" - 종횡비 유지 + 흰색 패딩
    h, w = img.shape[:2]
    scale = size / max(w, h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)
    canvas = np.full((size, size, 3), 255, np.uint8)  # 흰 배경
    top = (size - nh) // 2
    left = (size - nw) // 2
    canvas[top:top+nh, left:left+nw] = resized
    return canvas

def run(img, imgsz=640, conf=0.25, iou=0.45):
    r = model.predict(source=img, imgsz=imgsz, conf=conf, iou=iou, verbose=False)[0]
    H, W = img.shape[:2]
    n, mx, mon = 0, 0.0, 0
    if r.boxes is not None and len(r.boxes):
        for b in r.boxes.xyxy.cpu().numpy():
            ra = ((b[2]-b[0])/W) * ((b[3]-b[1])/H)
            mx = max(mx, ra); n += 1
            if ra > 0.5: mon += 1
    return r, n, mx, mon

print(f"{'이미지':22} {'[1]원본640(괴물확인)':26} {'[2]전처리640(개선확인)':26} {'[3]전처리+1280':22}")
print("-" * 100)

for fname in PICKS:
    ip = os.path.join(IMG_DIR, fname)
    if not os.path.exists(ip):
        print(f"{fname:22} (없음)"); continue

    pil = auto_orient(ip)
    bgr = cv2.cvtColor(np.array(pil.convert("RGB")), cv2.COLOR_RGB2BGR)

    # [1] 원본 그대로 640 추론 (기존 = 괴물박스 예상)
    _, n1, mx1, mon1 = run(bgr, 640)

    # [2] Roboflow 동일 전처리: CLAHE + letterbox-white-640, then 640 추론
    proc = clahe(bgr)
    proc640 = letterbox_white(proc, 640)
    r2, n2, mx2, mon2 = run(proc640, 640)
    cv2.imwrite(os.path.join(OUT, f"2_preproc640__{os.path.splitext(fname)[0]}.jpg"), r2.plot())

    # [3] 전처리 + 1280 추론
    proc1280 = letterbox_white(proc, 1280)
    r3, n3, mx3, mon3 = run(proc1280, 1280)
    cv2.imwrite(os.path.join(OUT, f"3_preproc1280__{os.path.splitext(fname)[0]}.jpg"), r3.plot())

    f1 = "👹" if mon1 else "✅"
    f2 = "👹" if mon2 else "✅"
    f3 = "👹" if mon3 else "✅"
    print(f"{fname:22} {n1:>3}개/비{mx1:.2f}/괴물{mon1}{f1}{'':<14} {n2:>3}개/비{mx2:.2f}/괴물{mon2}{f2}{'':<14} {n3:>3}개/비{mx3:.2f}/괴물{mon3}{f3}")

print("-" * 100)
print(f"결과: {OUT}")
print("결론: [2]열에서 괴물박스가 0이 되면 -> 원인은 '추론 시 전처리 누락' 확정.")
