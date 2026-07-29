import os
import cv2
from ultralytics import YOLO

# 1. 아까 성공했던 모델 로드 
# (터미널 경로에 따라 backend_api\models\best3.pt 또는 models\best3.pt)
model_path = r'C:\Users\dptjd\Downloads\PowerLens\backend_api\models\2026_07_01_03.pt'
if not os.path.exists(model_path):
    model_path = r'models\2026_07_01_03.pt'

model = YOLO(model_path)
print("✅ YOLOv11 'best3.pt' 모델 로드 성공!")

# 2. 🚨 질문자님이 복사하신 딱 그 '사진' 1장의 절대 경로!
img_path = r'C:\Users\dptjd\Downloads\PowerLens\backend_api\models\IEEE24bus.jpg'

if not os.path.exists(img_path):
    print("❌ 사진 파일을 찾을 수 없습니다. 경로를 다시 확인해주세요.")
else:
    print(f"🔍 사진 발견! AI가 분석을 시작합니다...")
    
    # 3. 예측 및 시각화 (딱 1장이니까 반복문 필요 없음)
    results = model.predict(source=img_path, conf=0.3, imgsz=540)
    
    for r in results:
        im_array = r.plot()
        
        # 모니터 밖으로 나가지 않게 크기 조절
        h, w = im_array.shape[:2]
        if h > 800:
            im_array = cv2.resize(im_array, (int(w * (800/h)), 800))
            
        # 화면에 띄우기
        cv2.imshow('YOLO Result - IEEE 24 Bus', im_array)
        print("💡 도면 창이 떴습니다! 확인 후 창을 클릭하고 '아무 키'나 누르면 종료됩니다.")
        
        cv2.waitKey(0)
        cv2.destroyAllWindows()