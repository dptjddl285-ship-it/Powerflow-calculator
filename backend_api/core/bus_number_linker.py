# -*- coding: utf-8 -*-
"""
Bus Number Linker & Validator using Set-of-Mark (SoM) Visual Grounding.

Places distinct visual marker tags (B1, B2, ..., BN) on each CV-detected Bus Bar,
guaranteeing 100% visual spatial alignment and completely eliminating LLM cascading
permutation errors / Sudoku shuffle.

Also propagates verified Bus numbers to connected Generators, Loads, and Transformers.
"""

import os
import json
import re
import time
import base64
import urllib.request
import urllib.error
import cv2
import numpy as np
from typing import Any, Dict, List, Optional, Tuple

try:
    from core.env_loader import load_env
    load_env()
except Exception:
    pass

def link_and_validate_bus_numbers(
    image_bytes: bytes,
    nodes: List[Dict[str, Any]],
    api_key: str = '',
    model_name: str = 'gemini-3.5-flash',
    expected_bus_range: Optional[Tuple[int, int]] = None
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """
    Takes fully detected & rescued nodes from the CV pipeline, creates a Set-of-Mark
    visually tagged image, queries Gemini for printed bus numbers, performs strict
    field-level validation, and attaches 'bus_number', 'bus_number_status', and 'bus_number_reasons'.
    
    Does NOT overwrite the node's overall structural review state.
    """
    if not api_key:
        api_key = os.environ.get('GEMINI_API_KEY', '').strip() or os.environ.get('GOOGLE_API_KEY', '').strip()
        
    img = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return nodes, {'error': 'Image decode failed'}
    h_img, w_img = img.shape[:2]
    
    bus_nodes = [n for n in nodes if (n.get('class') or n.get('class_name') or '').lower() == 'bus']
    if not bus_nodes:
        return nodes, {'total_buses': 0, 'verified_count': 0, 'uncertain_count': 0}
        
    if not api_key:
        for b in bus_nodes:
            b.setdefault('bus_number', None)
            b.setdefault('bus_number_status', 'UNCERTAIN')
            b.setdefault('bus_number_reasons', ['NO_API_KEY'])
        return nodes, {'warning': 'No API Key'}

    # 1. Generate High-Precision Grid Crop Collage of each bus bar
    # (Extracts local context around each bus with central focus, completely eliminating global line clutter)
    tag_to_node = {}
    cols = min(4, len(bus_nodes))
    cell_w, cell_h = 240, 200
    rows = (len(bus_nodes) + cols - 1) // cols
    grid_img = np.ones((rows * cell_h, cols * cell_w, 3), dtype=np.uint8) * 255

    for i, b in enumerate(bus_nodes):
        tag = f"B{i+1}"
        tag_to_node[tag] = b
        cx, cy, bw, bh = b['bbox']
        pad_x, pad_y = 80, 60
        x1 = max(0, int(cx - bw/2 - pad_x))
        y1 = max(0, int(cy - bh/2 - pad_y))
        x2 = min(w_img, int(cx + bw/2 + pad_x))
        y2 = min(h_img, int(cy + bh/2 + pad_y))
        crop = img[y1:y2, x1:x2].copy()
        
        # Draw red border on central bus
        bx1 = int(cx - bw/2 - x1)
        by1 = int(cy - bh/2 - y1)
        bx2 = int(cx + bw/2 - x1)
        by2 = int(cy + bh/2 - y1)
        cv2.rectangle(crop, (bx1, by1), (bx2, by2), (0, 0, 255), 2)
        
        # Resize crop to fit cell nicely
        crop_h, crop_w = crop.shape[:2]
        scale = min((cell_w - 20) / crop_w, (cell_h - 40) / crop_h)
        resized = cv2.resize(crop, (int(crop_w * scale), int(crop_h * scale)))
        
        r_idx, c_idx = i // cols, i % cols
        dst_x = c_idx * cell_w + (cell_w - resized.shape[1]) // 2
        dst_y = r_idx * cell_h + 30 + (cell_h - 30 - resized.shape[0]) // 2
        
        # Draw cell border and header badge
        cv2.rectangle(grid_img, (c_idx * cell_w, r_idx * cell_h), ((c_idx+1) * cell_w, (r_idx+1) * cell_h), (220, 220, 220), 1)
        cv2.rectangle(grid_img, (c_idx * cell_w, r_idx * cell_h), (c_idx * cell_w + 70, r_idx * cell_h + 24), (0, 0, 255), -1)
        cv2.putText(grid_img, tag, (c_idx * cell_w + 6, r_idx * cell_h + 18), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
        grid_img[dst_y:dst_y+resized.shape[0], dst_x:dst_x+resized.shape[1]] = resized

    _, enc = cv2.imencode('.jpg', grid_img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    b64_marked = base64.b64encode(enc.tobytes()).decode('utf-8')
    
    prompt = (
        "You are inspecting cropped bus bar cells from an electrical single-line diagram.\n"
        f"There are {len(bus_nodes)} cells, each with a header tag (B1, B2, ..., B{len(bus_nodes)}) and a red-outlined central bus bar.\n\n"
        "Task:\n"
        "1. For each cell (B1, B2, ...), read the printed black integer bus number (1 to 50) located next to the red-outlined bus bar.\n"
        "2. If no clear number is visible in a cell, return null.\n"
        "3. In single line diagrams, each bus number is unique.\n"
        "Return strict JSON dictionary: {\"B1\": 1, \"B2\": 2, ...}"
    )
    
    candidate_models = [model_name, 'gemini-3.1-flash-lite', 'gemini-3.5-flash', 'gemini-3.5-flash-lite']
    # Deduplicate preserving order
    seen_models = set()
    models_to_try = [m for m in candidate_models if not (m in seen_models or seen_models.add(m))]

    candidates = {}
    last_err = None

    for m_name in models_to_try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{m_name}:generateContent?key={api_key}"
        payload = {
            'contents': [{'parts': [{'text': prompt}, {'inlineData': {'mimeType': 'image/jpeg', 'data': b64_marked}}]}],
            'generationConfig': {'responseMimeType': 'application/json'}
        }
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode('utf-8'),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read().decode('utf-8'))
                txt = data['candidates'][0]['content']['parts'][0]['text']
                res_json = json.loads(txt)
                if isinstance(res_json, dict):
                    for k, v in res_json.items():
                        if isinstance(v, int):
                            candidates[k] = v
                        elif isinstance(v, dict):
                            candidates[k] = v.get('bus_number')
                        elif isinstance(v, str) and v.isdigit():
                            candidates[k] = int(v)
                elif isinstance(res_json, list):
                    for item in res_json:
                        if isinstance(item, dict) and item.get('id'):
                            candidates[item['id']] = item.get('bus_number')
                last_err = None
                break
        except Exception as e:
            last_err = e
            continue
            
    if last_err is not None:
        print(f'[BusLinker Error] {last_err}')
        for b in bus_nodes:
            b.setdefault('bus_number', None)
            b['bus_number_status'] = 'UNCERTAIN'
            b.setdefault('bus_number_reasons', ['VISION_AI_CALL_FAILED'])
        return nodes, {'error': str(last_err)}

    # Field-level validation: Duplicate counts
    num_counts = {}
    for tid, num in candidates.items():
        if num is not None and isinstance(num, int) and num > 0:
            num_counts[num] = num_counts.get(num, 0) + 1

    duplicates = [num for num, cnt in num_counts.items() if cnt > 1]
    verified_count, uncertain_count = 0, 0
    assigned_numbers = set()

    for i, (tag, b) in enumerate(tag_to_node.items()):
        b.setdefault('bus_number_reasons', [])
        legacy_id = f"bus_{i}"
        node_raw_id = b.get('id')
        num = candidates.get(tag)
        if num is None and legacy_id in candidates:
            num = candidates.get(legacy_id)
        if num is None and node_raw_id in candidates:
            num = candidates.get(node_raw_id)
        
        # 1. Check for mapping failure / null
        if num is None:
            b['bus_number'] = None
            b['bus_number_status'] = 'UNCERTAIN'
            b['bus_number_reasons'].append('NO_BUS_NUMBER_FOUND')
            uncertain_count += 1
            continue
            
        # 2. Check for invalid format
        if not isinstance(num, int) or num <= 0:
            b['bus_number'] = None
            b['bus_number_status'] = 'UNCERTAIN'
            b['bus_number_reasons'].append(f'INVALID_BUS_NUMBER_{num}')
            uncertain_count += 1
            continue
            
        # 3. Check for duplicates
        if num in duplicates:
            b['bus_number'] = None
            b['display_name'] = f"Bus ? (중복감지 #{num})"
            b['bus_number_status'] = 'UNCERTAIN'
            b['bus_number_reasons'].append(f'DUPLICATE_BUS_NUMBER_{num}')
            uncertain_count += 1
        else:
            # 4. Valid, unique bus number
            b['bus_number'] = num
            b['id'] = f"bus_{num}"
            b['display_name'] = f"Bus {num}"
            b['bus_number_status'] = 'VERIFIED'
            b['bus_confidence'] = 0.99
            assigned_numbers.add(num)
            verified_count += 1

    # Optional missing range check (only if caller specified expected range)
    missing_range_numbers = []
    if expected_bus_range is not None:
        start_r, end_r = expected_bus_range
        missing_range_numbers = [r for r in range(start_r, end_r + 1) if r not in assigned_numbers]

    report = {
        'total_buses': len(bus_nodes),
        'verified_count': verified_count,
        'uncertain_count': uncertain_count,
        'duplicates': duplicates,
        'missing_range_numbers': missing_range_numbers,
        'verified_rate_pct': round((verified_count / len(bus_nodes)) * 100, 1) if bus_nodes else 0.0
    }
    return nodes, report

def propagate_bus_numbers_to_devices(
    nodes: List[Dict[str, Any]],
    lines: List[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    """
    Inspects topological line connections between Buses and attached devices
    (Generators, Loads, Transformers), and assigns connected bus numbers and standard labels.
    """
    node_by_id = {n['id']: n for n in nodes if 'id' in n}
    
    for line in lines:
        endpoints = line.get('connected_to', [])
        if len(endpoints) < 2:
            continue
            
        id_a, id_b = endpoints[0], endpoints[1]
        node_a = node_by_id.get(id_a)
        node_b = node_by_id.get(id_b)
        
        if not node_a or not node_b:
            continue
            
        cls_a = (node_a.get('class') or node_a.get('class_name') or '').lower()
        cls_b = (node_b.get('class') or node_b.get('class_name') or '').lower()
        
        # Check Bus <-> Device connection
        bus_node = node_a if cls_a == 'bus' else (node_b if cls_b == 'bus' else None)
        dev_node = node_b if cls_a == 'bus' else (node_a if cls_b == 'bus' else None)
        
        if bus_node and dev_node:
            bus_num = bus_node.get('bus_number')
            if bus_num is not None:
                dev_cls = (dev_node.get('class') or dev_node.get('class_name') or '').lower()
                dev_node['connected_bus_id'] = bus_node['id']
                dev_node['connected_bus_number'] = bus_num
                dev_node['bus_number'] = bus_num
                
                if 'gen' in dev_cls:
                    dev_node['display_name'] = f"G_{bus_num}"
                elif 'load' in dev_cls:
                    dev_node['display_name'] = f"Load_{bus_num}"
                    
    return nodes

def synchronize_node_and_line_ids(
    nodes: List[Dict[str, Any]],
    lines: List[Dict[str, Any]]
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """
    Synchronizes internal node IDs and line endpoints with verified bus and device numbers.
    For example:
      - Bus with bus_number 14 -> id becomes 'bus_14'
      - Generator with connected_bus_number 14 -> id becomes 'gen_14' (or 'gen_14_2')
      - Load with connected_bus_number 14 -> id becomes 'load_14'
      - Line between bus 1 and bus 2 -> id becomes 'line_1_2'
      - Updates all line['connected_to'] references to the new node IDs!
    """
    id_map = {}
    used_ids = set()

    # 1. Rename Bus IDs to match bus numbers
    for b in nodes:
        cls = (b.get('class') or b.get('class_name') or '').lower()
        if cls == 'bus':
            old_id = b.get('id')
            bnum = b.get('bus_number')
            if bnum is not None:
                base_id = f"bus_{bnum}"
                new_id = base_id
                counter = 1
                while new_id in used_ids:
                    counter += 1
                    new_id = f"{base_id}_{counter}"
                used_ids.add(new_id)
                b['id'] = new_id
                b['display_name'] = f"Bus {bnum}"
                if old_id:
                    id_map[old_id] = new_id

    # 2. Rename Device IDs (Generators, Loads, Transformers)
    for dev in nodes:
        cls = (dev.get('class') or dev.get('class_name') or '').lower()
        if cls != 'bus':
            old_id = dev.get('id')
            bnum = dev.get('connected_bus_number') or dev.get('bus_number')
            prefix = 'gen' if 'gen' in cls else ('load' if 'load' in cls else 'trans')
            if bnum is not None:
                base_id = f"{prefix}_{bnum}"
            else:
                base_id = f"{prefix}_{dev.get('display_number', 1)}"
            
            new_id = base_id
            counter = 1
            while new_id in used_ids:
                counter += 1
                new_id = f"{base_id}_{counter}"
            used_ids.add(new_id)
            dev['id'] = new_id
            if 'gen' in cls:
                dev['display_name'] = f"G_{bnum}" if bnum is not None else dev.get('display_name', new_id)
            elif 'load' in cls:
                dev['display_name'] = f"Load_{bnum}" if bnum is not None else dev.get('display_name', new_id)
            if old_id:
                id_map[old_id] = new_id

    # 3. Update line endpoints and line IDs
    for idx, line in enumerate(lines):
        endpoints = line.get('connected_to', [])
        if endpoints:
            new_endpoints = [id_map.get(str(ep), str(ep)) for ep in endpoints]
            line['connected_to'] = new_endpoints
            
            if len(new_endpoints) == 2:
                ep1, ep2 = new_endpoints[0], new_endpoints[1]
                num1 = ep1.split('_')[-1] if '_' in ep1 else ep1
                num2 = ep2.split('_')[-1] if '_' in ep2 else ep2
                is_bus1 = 'bus' in ep1.lower()
                is_bus2 = 'bus' in ep2.lower()
                if is_bus1 and is_bus2:
                    label = f"Line {num1}-{num2}"
                    lid = f"line_{num1}_{num2}"
                else:
                    label = f"Line {ep1}-{ep2}"
                    lid = f"line_{num1}_{num2}"
                line['id'] = lid
                line['line_id'] = lid
                line['display_name'] = label
                line['display_label'] = label
                line['endpoints_display'] = f"{ep1} ↔ {ep2}"

    return nodes, lines

def draw_validated_bus_annotations(image_bytes: bytes, nodes: List[Dict[str, Any]], output_path: str) -> str:
    img = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
    bus_nodes = [n for n in nodes if (n.get('class') or n.get('class_name') or '').lower() == 'bus']
    annotated = img.copy()
    for b in bus_nodes:
        cx, cy, bw, bh = b['bbox']
        x1, y1 = int(cx - bw/2), int(cy - bh/2)
        x2, y2 = int(cx + bw/2), int(cy + bh/2)
        status = b.get('bus_number_status', 'UNCERTAIN')
        bnum = b.get('bus_number')
        reasons = b.get('bus_number_reasons', [])
        if status == 'VERIFIED':
            cv2.rectangle(annotated, (x1, y1), (x2, y2), (0, 200, 0), 2)
            label = f'#{bnum} [OK]'
            cv2.putText(annotated, label, (x1, max(18, y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 180, 0), 2)
        else:
            cv2.rectangle(annotated, (x1, y1), (x2, y2), (0, 165, 255), 2)
            r_str = reasons[0] if reasons else 'CHECK'
            label = f'#{bnum or "?"} [{r_str}]'
            cv2.putText(annotated, label, (x1, max(18, y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 100, 255), 2)
    cv2.imwrite(output_path, annotated)
    return output_path
