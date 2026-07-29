# 최종 비교 폴더: 640(괴물박스) vs 1280+필터(최종해결)
import os, cv2
from ultralytics import YOLO

BASE = r"C:\Users\dptjd\Downloads\PowerLens"
IMG_DIR = os.path.join(BASE, "학습 IEEE")
OUT = os.path.join(BASE, "괴물박스_비교결과")
os.makedirs(OUT, exist_ok=True)
model = YOLO(os.path.join(BASE, "backend_api", "models", "2026_07_01_03.pt"))
PICKS = ["IEEE24bus.jpg", "14bus.jpg", "24bus.jpg", "circuit.jpg", "1_Original.jpg", "1234.jpg", "36bus.jpg"]

def is_monster(w, h, ww, hh, name):
    wr = w/ww; hr = h/hh; area = wr*hr
    if area > 0.12: return True
    if name.lower()=='bus' and wr>0.08 and hr>0.08: return True
    return False

def draw_filtered(img_path, imgsz, conf, apply_filter):
    r = model.predict(source=img_path, imgsz=imgsz, conf=conf, iou=0.4, verbose=False)[0]
    img = cv2.imread(img_path); h,w = img.shape[:2]
    out = img.copy()
    names = model.names
    colors = {'bus':(0,0,255),'generator':(0,165,255),'load':(0,255,255),'transformer':(255,0,255)}
    xy = r.boxes.xyxy.cpu().numpy(); clss = r.boxes.cls.cpu().numpy().astype(int); confs = r.boxes.conf.cpu().numpy()
    n=0
    for b,c,cf in zip(xy,clss,confs):
        bw=b[2]-b[0]; bh=b[3]-b[1]; nm=names[c]
        if apply_filter and is_monster(bw,bh,w,h,nm):
            continue
        col=colors.get(nm.lower(),(255,255,255))
        cv2.rectangle(out,(int(b[0]),int(b[1])),(int(b[2]),int(b[3])),col,2)
        cv2.putText(out,f'{nm} {cf:.2f}',(int(b[0]),int(b[1])-4),cv2.FONT_HERSHEY_SIMPLEX,0.4,col,1)
        n+=1
    return out, n

def label(img, text):
    canvas = cv2.copyMakeBorder(img, 40, 0, 0, 0, cv2.BORDER_CONSTANT, value=(0,0,0))
    cv2.putText(canvas, text, (10,30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0,255,255), 2)
    return canvas

summary=[]
for f in PICKS:
    p = os.path.join(IMG_DIR, f)
    if not os.path.exists(p): continue
    bad,_ = draw_filtered(p, 640, 0.4, apply_filter=False)
    good,ng = draw_filtered(p, 1280, 0.3, apply_filter=True)
    H=min(bad.shape[0], good.shape[0])
    sc=lambda im,hh: cv2.resize(im,(int(im.shape[1]*hh/im.shape[0]),hh))
    a=label(sc(bad,H),  "BEFORE: imgsz=640 (괴물박스)")
    b=label(sc(good,H), f"AFTER: imgsz=1280 + filter ({ng} symbols)")
    combo=cv2.hconcat([a, cv2.copyMakeBorder(b,0,0,10,0,cv2.BORDER_CONSTANT,value=(255,255,255))])
    cv2.imwrite(os.path.join(OUT, os.path.splitext(f)[0]+"__비교.jpg"), combo)
    cv2.imwrite(os.path.join(OUT, os.path.splitext(f)[0]+"__최종_1280필터.jpg"), good)
    summary.append((f, ng))

print("생성 완료:")
for f,n in summary: print(f"  {f}: {n} symbols")
