import sys
import json
import os

sys.stdout.reconfigure(encoding='utf-8')
sys.path.append('backend_api')

from core.excel_case_importer import ExcelCaseImporter
from core.adaptive_vision_pipeline import analyze_circuit_image_adaptive
from core.bus_number_linker import link_and_validate_bus_numbers, propagate_bus_numbers_to_devices, synchronize_node_and_line_ids
from ultralytics import YOLO

# 1. Load image and detect
model = YOLO('backend_api/models/2026_07_30_coslr.pt')
with open('C:/Users/dptjd/Downloads/KakaoTalk_20260907_125200908.jpg', 'rb') as f:
    img_bytes = f.read()

res = analyze_circuit_image_adaptive(img_bytes, model)
nodes = res['nodes']
lines = res.get('lines', [])

# Simulate backend main_server.py /analyze_image pipeline:
try:
    nodes, _ = link_and_validate_bus_numbers(img_bytes, nodes)
    nodes = propagate_bus_numbers_to_devices(nodes, lines)
    nodes, lines = synchronize_node_and_line_ids(nodes, lines)
except Exception as e:
    print('Bus linker error:', e)

print(f'Detected {len(nodes)} nodes, {len(lines)} lines.')

# 2. Parse excel
importer = ExcelCaseImporter()
with open('backend_api/sample_cases/ac_case25.xlsx', 'rb') as f:
    case = importer.parse_excel(f)

# 3. Simulate apply_to_elements or frontend _applyExcelDataToCanvas
buses = case['buses']
branches = case['branches']
transformers = case['transformers']

# Let's inspect bus IDs:
print('Buses in circuit:')
for b in nodes:
    if 'bus' in (b.get('class') or b.get('class_name') or '').lower():
        print(f"  {b.get('id')}: num={b.get('bus_number')} label={b.get('display_name')}")

print('\nTransformers in circuit:')
for t in nodes:
    if 'trans' in (t.get('class') or b.get('class_name') or '').lower():
        print(f"  {t.get('id')}: label={t.get('display_name')}")

print('\nLines in circuit:')
for i, l in enumerate(lines):
    conn = l.get('connected_to', [])
    lid = l.get('id') or l.get('line_id')
    label = l.get('display_name') or l.get('display_label')
    print(f"  Line {i}: id={lid} conn={conn} label={label}")
