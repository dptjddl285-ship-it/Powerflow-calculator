# -*- coding: utf-8 -*-
import os, json, shutil, cv2, numpy as np
from pathlib import Path
import core.env_loader
from ultralytics import YOLO
from core.adaptive_vision_pipeline import detect_sld_objects_adaptive
from core.bus_number_linker import link_and_validate_bus_numbers, draw_validated_bus_annotations

def run_comparison():
    print("\n" + "=" * 70)
    print(" 🔎 [Comparison Test] IEEE 24-Bus vs IEEE 39-Bus CV + Gemini Vision")
    print("=" * 70)
    
    model_path = str(Path(__file__).resolve().parent / "models" / "2026_07_30_coslr.pt")
    model = YOLO(model_path)
    
    artifact_dir = rcurs =r"C:\Users\dptjd\.gemini\antigravity\brain\28f4c2f7-8802-4c20-9182-3f860f31e3d0"
    
    targets = [
        ("IEEE 24-Bus", "../학습 IEEE/1_Original.jpg", "24bus_validated_result.jpg"),
        ("IEEE 39-Bus", "../학습 IEEE/39bus.jpg", "39bus_validated_result.jpg"),
    ]
    
    summaries = []
    
    for name, img_path, out_name in targets:
        print(f"\n\n➡ [Testing: {name}] -> {img_path}")
        if not os.path.exists(img_path):
            print(f"Error: {img_path} does not exist")
            continue
            
        with open(img_path, "rb") as f:
            img_bytes = f.read()
            
        # 1. CV detection
        det_res = detect_sld_objects_adaptive(img_bytes, model)
        nodes = det_res.get("nodes", [])
        buses = [n for n in nodes if (n.get("class") or n.get("class_name") or "").lower() == "bus"]
        print(f"  1. CV Detected: {len(buses)} Bus Bars (out of {len(nodes)} total elements)")
        
        # 2. Gemini Vision + Post-Validation
        print(f"  2. Querying Gemini Flash-Lite for Bus Numbers + Rule-based Post-Validation...")
        validated_nodes, report = link_and_validate_bus_numbers(img_bytes, nodes)
        
        verified = report.get("verified_count", 0)
        uncertain = report.get("uncertain_count", 0)
        dups = report.get("duplicate_numbers", [])
        v_rate = report.get("verified_rate_pct", 0.0)
        
        print(f"  3. Validation Result:")
        print(f"     -> ✅ verified (Auto-Approved): {verified}/{len(buses)} ({v_rate}%)")
        print(f"     -> ⚠ UNCERTAIN (Human Review Needed): {uncertain}")
        if dups:
            print(f"     -> ⨠ identified duplicates: {dups}")
            
        # 3. Draw Annotations
        draw_validated_bus_annotations(img_bytes, validated_nodes, out_name)
        
        # Copy to artifact dir
        art_path = os.path.join(artifact_dir, out_name)
        shutil.copyfile(out_name, art_path)
        print(f"  4. Saved visualization to: {art_path}")
        
        summaries.append({
            "name": name,
            "total_buses": len(buses),
            "verified": verified,
            "uncertain": uncertain,
            "rate": v_rate,
            "duplicates": dups,
            "image_path": art_path
        })
    
    print("\n" + "=" * 70)
    print(" 📊 Summary Comparison Table")
    print("=" * 70)
    print(f" {'Diagram':<16} | {'CV Buses':<10} | {'Verified [OK]':<16} | {'Uncertain [Review]':<20} | {'Auto-Rate':<10}")
    print("-" * 70)
    for sm in summaries:
        print(f" {sm['name']:<16} | {sm['total_buses']:<10} | {sm['verified']:<16} | {sm['uncertain']:<20} | {sm['rate']}%")
    print("=" * 70 + "\n")

if __name__ == '__main__':
    run_comparison()
