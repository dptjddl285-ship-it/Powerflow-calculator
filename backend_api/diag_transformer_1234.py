# 목적: 1234.jpg에서 로컬 모델이 변압기(transformer)를 잡는지, 잡는다면 conf가 얼마인지 확인.
#       conf를 매우 낮춰서(0.05) 돌려 "아예 못 배운 건지 vs 잡히는데 필터에 걸리는 건지" 판별.
import os, cv2
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
MODEL = os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt")
IMG = os.path.join(BASE, "학습 IEEE", "1234.jpg")
OUT = os.path.join(BASE, "backend_api", "temp_data", "diag_transformer")
os.makedirs(OUT, exist_ok=True)

model = YOLO(MODEL)
print("클래스:", model.names)
img = cv2.imread(IMG)
h, w = img.shape[:2]
print(f"이미지: 1234.jpg ({w}x{h})")
print("="*70)

# conf를 낮춰가며 변압기 검출 여부 확인
for conf in [0.05, 0.1, 0.25, 0.3, 0.5]:
    r = model.predict(source=IMG, imgsz=1280, conf=conf, iou=0.4, verbose=False)[0]
    counts = {}
    trans_confs = []
    if r.boxes is not None and len(r.boxes):
        clss = r.boxes.cls.cpu().numpy().astype(int)
        confs = r.boxes.conf.cpu().numpy()
        for c, cf in zip(clss, confs):
            name = model.names.get(c, c)
            counts[name] = counts.get(name, 0) + 1
            if name.lower() == 'transformer' or name.lower() == 'trans':
                trans_confs.append(cf)
    print(f"conf={conf:.2f} -> 총 {sum(counts.values())}개 | 클래스별: {counts}")
    if trans_confs:
        print(f"          변압기 conf: {[round(c,2) for c in sorted(trans_confs, reverse=True)]}")
    else:
        print(f"          변압기 검출 없음 (이 conf에서도 안 잡힘)")
    print("-"*70)
    if conf == 0.05:
        cv2.imwrite(os.path.join(OUT, "1234_conf005.jpg"), r.plot())
    if conf == 0.25:
        cv2.imwrite(os.path.join(OUT, "1234_conf025.jpg"), r.plot())

print(f"\n결과 이미지: {OUT}")
print("\n판독:")
print("- conf=0.05에서 변압기가 잡히면 -> 모델은 변압기를 배웠지만 conf가 낮아 0.3 필터에 걸려 안 보였던 것")
print("  (해결: 추론 conf를 0.15~0.2로 낮추거나, 재학습으로 변압기 conf를 올림)")
print("- conf=0.05에서도 변압기 0개 -> 모델이 변압기를 거의 안 배움 (aug=0 + 변압기 샘플 부족 추정)")
