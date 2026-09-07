# 테스트 1: 기존 Colab 학습 모델로 추론 설정만 바꿔서 괴물박스 확인
import os
import sys
from ultralytics import YOLO

MODELS = [
    r"C:\Users\dptjd\Downloads\PowerLens\backend_api\models\2026_07_01_03.pt",
    r"C:\Users\dptjd\Downloads\PowerLens\backend_api\models\best3.pt",
]
TEST_IMGS = [
    r"C:\Users\dptjd\Downloads\PowerLens\학습 IEEE\IEEE24bus.jpg",
    r"C:\Users\dptjd\Downloads\PowerLens\학습 IEEE\14bus.jpg",
    r"C:\Users\dptjd\Downloads\PowerLens\학습 IEEE\24bus.jpg",
]
OUT_DIR = r"C:\Users\dptjd\Downloads\PowerLens\backend_api\temp_data\inference_test"
os.makedirs(OUT_DIR, exist_ok=True)

SETTINGS = [
    {"name": "A_default",     "imgsz": 640,  "conf": 0.25, "iou": 0.45},
    {"name": "B_1280_conf50", "imgsz": 1280, "conf": 0.50, "iou": 0.45},
    {"name": "C_1280_conf60", "imgsz": 1280, "conf": 0.60, "iou": 0.45},
]

def monster_ratio(box, w_img, h_img):
    # 바운딩박스가 이미지 대비 얼마나 큰지 (0~1). 0.5 넘으면 괴물박스 의심
    x1, y1, x2, y2 = box
    bw = (x2 - x1) / w_img
    bh = (y2 - y1) / h_img
    return bw * bh, bw, bh

for mp in MODELS:
    if not os.path.exists(mp):
        print(f"\n[건너뜀] 모델 없음: {mp}")
        continue
    print("\n" + "="*70)
    print(f"모델: {os.path.basename(mp)}")
    model = YOLO(mp)
    print(f"클래스: {model.names}")

    for img_path in TEST_IMGS:
        if not os.path.exists(img_path):
            print(f"  [건너뜀] 이미지 없음: {img_path}")
            continue
        print(f"\n  이미지: {os.path.basename(img_path)}")

        for s in SETTINGS:
            res = model.predict(source=img_path, imgsz=s["imgsz"], conf=s["conf"], iou=s["iou"], verbose=False)
            r = res[0]
            import cv2
            img = cv2.imread(img_path)
            h_img, w_img = img.shape[:2]
            boxes = r.boxes
            n = len(boxes) if boxes is not None else 0

            max_ratio = 0.0
            detail = []
            if n > 0:
                xyxy = boxes.xyxy.cpu().numpy()
                clss = boxes.cls.cpu().numpy().astype(int)
                confs = boxes.conf.cpu().numpy()
                for (b, c, cf) in zip(xyxy, clss, confs):
                    ratio, bw, bh = monster_ratio(b, w_img, h_img)
                    max_ratio = max(max_ratio, ratio)
                    flag = "  👹괴물박스!" if ratio > 0.5 else ""
                    detail.append(f"    cls={model.names.get(c,c)} conf={cf:.2f} box=({b[0]:.0f},{b[1]:.0f},{b[2]:.0f},{b[3]:.0f}) 면적비={ratio:.2f} (w{bw:.2f}xh{bh:.2f}){flag}")

            print(f"    [{s['name']}] imgsz={s['imgsz']} conf={s['conf']} -> 검출 {n}개, 최대면적비={max_ratio:.2f}")
            for d in detail:
                print(d)

            # 결과 이미지 저장 (가장 큰 세팅만)
            if s["name"] == "B_1280_conf50":
                annotated = r.plot()
                out_name = f"{os.path.basename(mp)[:-3]}__{os.path.basename(img_path)[:-4]}__{s['name']}.jpg"
                out_path = os.path.join(OUT_DIR, out_name)
                cv2.imwrite(out_path, annotated)
                print(f"      -> 저장: {out_path}")
