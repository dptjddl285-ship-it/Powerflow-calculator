# 타일 추론(SAHI 방식) 테스트: 전체 추론 vs 타일 추론 심볼 수 비교
import cv2, numpy as np, os
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
IMG_DIR = os.path.join(BASE, "학습 IEEE")
OUT = os.path.join(BASE, "backend_api", "temp_data", "tile_test")
os.makedirs(OUT, exist_ok=True)
model = YOLO(os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt"))
NAMES = model.names  # {0:bus,1:generator,2:load,3:transformer}

def is_monster(w, h, W, H, name):
    wr, hr = w/W, h/H; area = wr*hr
    if area > 0.12: return True
    if name.lower()=='bus' and wr>0.08 and hr>0.08: return True
    return False

def nms_per_class(boxes, confs, clss, iou=0.4):
    # boxes: xyxy in original coords (list of [x1,y1,x2,y2])
    kept = []
    for c in set(clss):
        idx = [i for i,cc in enumerate(clss) if cc==c]
        b = [boxes[i] for i in idx]
        cf = [confs[i] for i in idx]
        xy = np.array(b, dtype=np.float32)
        scores = np.array(cf, dtype=np.float32)
        keep_idx = cv2.dnn.NMSBoxes(xy.tolist(), scores.tolist(), 0.0, iou)
        keep_idx = keep_idx.flatten() if hasattr(keep_idx,'flatten') else keep_idx
        for ki in keep_idx:
            kept.append((b[ki], cf[ki], c))
    return kept

def whole_infer(img, W, H):
    r = model.predict(source=img, imgsz=1280, conf=0.3, iou=0.4, verbose=False)[0]
    boxes, confs, clss = [], [], []
    for b,c,cf in zip(r.boxes.xyxy.cpu().numpy(), r.boxes.cls.cpu().numpy().astype(int), r.boxes.conf.cpu().numpy()):
        w=b[2]-b[0]; h=b[3]-b[1]; nm=NAMES[c]
        if is_monster(w,h,W,H,nm): continue
        boxes.append([b[0],b[1],b[2],b[3]]); confs.append(cf); clss.append(c)
    return nms_per_class(boxes, confs, clss)

def tile_infer(img, W, H, grid=2, overlap=0.25):
    tiles = []
    step_x = W / grid; step_y = H / grid
    pad = overlap
    for gy in range(grid):
        for gx in range(grid):
            x1 = int(max(0, gx*step_x - pad*step_x))
            y1 = int(max(0, gy*step_y - pad*step_y))
            x2 = int(min(W, (gx+1)*step_x + pad*step_x))
            y2 = int(min(H, (gy+1)*step_y + pad*step_y))
            tiles.append((x1,y1,x2,y2))
    boxes, confs, clss = [], [], []
    for (tx1,ty1,tx2,ty2) in tiles:
        tile = img[ty1:ty2, tx1:tx2]
        r = model.predict(source=tile, imgsz=1280, conf=0.3, iou=0.4, verbose=False)[0]
        for b,c,cf in zip(r.boxes.xyxy.cpu().numpy(), r.boxes.cls.cpu().numpy().astype(int), r.boxes.conf.cpu().numpy()):
            # 타일 로컬 좌표 -> 전체 좌표
            gx1,gy1,gx2,gy2 = b[0]+tx1, b[1]+ty1, b[2]+tx1, b[3]+ty1
            w=gx2-gx1; h=gy2-gy1; nm=NAMES[c]
            if is_monster(w,h,W,H,nm): continue
            boxes.append([gx1,gy1,gx2,gy2]); confs.append(cf); clss.append(c)
    return nms_per_class(boxes, confs, clss)

def count_by_class(dets):
    from collections import Counter
    cnt = Counter(NAMES[c] for _,_,c in dets)
    return {k:cnt.get(k,0) for k in ['bus','generator','load','transformer']}

PICKS = ["IEEE24bus.jpg","14bus.jpg","24bus.jpg","36bus.jpg","circuit.jpg","1_Original.jpg","1234.jpg"]
print(f"{'이미지':18} {'방식':8} {'bus':>4} {'gen':>4} {'load':>5} {'trans':>5} {'합계':>4}")
print("-"*60)
for f in PICKS:
    p = os.path.join(IMG_DIR, f)
    if not os.path.exists(p): continue
    img = cv2.imdecode(np.fromfile(p, np.uint8), cv2.IMREAD_COLOR)
    H,W = img.shape[:2]
    d_whole = whole_infer(img, W, H)
    d_tile = tile_infer(img, W, H, grid=2, overlap=0.25)
    cw = count_by_class(d_whole); ct = count_by_class(d_tile)
    sw = sum(cw.values()); st = sum(ct.values())
    print(f"{f:18} {'전체':8} {cw['bus']:>4} {cw['generator']:>4} {cw['load']:>5} {cw['transformer']:>5} {sw:>4}")
    print(f"{'':18} {'타일':8} {ct['bus']:>4} {ct['generator']:>4} {ct['load']:>5} {ct['transformer']:>5} {st:>4}  (Δ{st-sw:+d})")
    # 타일 결과 이미지 저장 (IEEE24bus만)
    if f=="IEEE24bus.jpg":
        vis = img.copy()
        colors={'bus':(0,0,255),'generator':(0,165,255),'load':(0,255,255),'transformer':(255,0,255)}
        for b,cf,c in d_tile:
            col=colors.get(NAMES[c].lower(),(255,255,255))
            cv2.rectangle(vis,(int(b[0]),int(b[1])),(int(b[2]),int(b[3])),col,2)
        cv2.imencode('.jpg',vis)[1].tofile(os.path.join(OUT,"IEEE24bus_tile.jpg"))
