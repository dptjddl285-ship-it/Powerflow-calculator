import sys, os
sys.path.insert(0, os.path.abspath('.'))
import cv2
from backend_api.validation_tests.auto_tune_evaluator import labels_for, iou
from pathlib import Path
import importlib.util
from backend_api.line_recognition.logic.vision_logic_topology_hybrid import analyze_circuit_image_topology_hybrid

spec = importlib.util.spec_from_file_location('ref_logic', 'C:/Users/hpo20/Desktop/Powerflow-calculator/backend_api/line_recognition/logic/vision_logic_topology_hybrid.py')
ref_logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref_logic)

for name in ['test_image15', 'test_image44']:
    img_path = Path(f'backend_api/icon_recognition/datasets/auto_tune_train_images/{name}.jpg')
    lbl_path = Path(f'backend_api/icon_recognition/datasets/auto_tune_train_labels/{name}.txt')
    truth = labels_for(lbl_path, 1280, 1280)
    res_ref = ref_logic.analyze_circuit_image_topology_hybrid(img_path.read_bytes())
    res_our = analyze_circuit_image_topology_hybrid(img_path.read_bytes())
    
    print(f"=== {name} ===")
    print("REF nodes:", len(res_ref.get('nodes', [])))
    for p in res_ref.get('nodes', []):
        cand = [(iou(p['bbox'], t['bbox']), i) for i, t in enumerate(truth) if t['class'] == p['class']]
        best_iou, best_i = max(cand, default=(0.0, None))
        print("  Ref:", p['class'], [round(v, 1) for v in p['bbox']], f"best_iou={best_iou:.3f}")
        
    print("OUR nodes:", len(res_our.get('nodes', [])))
    for p in res_our.get('nodes', []):
        cand = [(iou(p['bbox'], t['bbox']), i) for i, t in enumerate(truth) if t['class'] == p['class']]
        best_iou, best_i = max(cand, default=(0.0, None))
        print("  Our:", p['class'], [round(v, 1) for v in p['bbox']], f"best_iou={best_iou:.3f}")
