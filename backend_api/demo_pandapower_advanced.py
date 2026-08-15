import os
import sys
import json

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

import pandapower as pp
import pandapower.networks as nw
import pandapower.plotting as plot
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import numpy as np

def run_advanced_demo():
    print("=" * 65)
    print(" [Pandapower Advanced] IEEE 30-Bus Rich Power Flow Visualization")
    print("=" * 65)

    # 1. IEEE 30-bus 계통 로드
    net = nw.case30()
    
    # 2. AC 조류 계산
    pp.runpp(net)
    print(f"✅ AC Power Flow 계산 완료 (수렴 여부: {net.converged})")

    # 3. 고급 시각화 생성 (전압 및 선로 부하율 컬러맵 오버레이)
    fig, ax = plt.subplots(figsize=(14, 11), dpi=180)

    # (1) 선로 컬렉션 생성 (부하율 %에 따른 색상 매핑)
    cmap_lines = plt.cm.autumn_r
    norm_lines = mcolors.Normalize(vmin=0, vmax=max(50, float(net.res_line.loading_percent.max())))
    line_lc = plot.create_line_collection(
        net,
        net.line.index,
        z=net.res_line.loading_percent,
        cmap=cmap_lines,
        norm=norm_lines,
        linewidths=3.0,
        cbar_title="Line Loading [%]"
    )

    # (2) 모선 컬렉션 생성 (전압 크기 pu에 따른 색상 매핑)
    cmap_buses = plt.cm.coolwarm
    norm_buses = mcolors.Normalize(vmin=0.95, vmax=1.05)
    bus_bc = plot.create_bus_collection(
        net,
        net.bus.index,
        size=0.08,
        z=net.res_bus.vm_pu,
        cmap=cmap_buses,
        norm=norm_buses,
        cbar_title="Bus Voltage [p.u.]"
    )

    # (3) 발전기, 부하, 외부계통 컬렉션
    ext_grid_ec = plot.create_ext_grid_collection(net, size=0.15, orientation=0)
    load_lc = plot.create_load_collection(net, size=0.10)
    gen_gc = plot.create_gen_collection(net, size=0.10)

    # 플롯 그리기
    collections = [c for c in [line_lc, bus_bc, ext_grid_ec, load_lc, gen_gc] if c is not None]
    plot.draw_collections(collections, ax=ax)

    # (4) 주요 모선 번호 및 전압 수치 텍스트 표시
    for bus_id, row in net.bus.iterrows():
        coords = None
        if 'geo' in row and row['geo'] is not None:
            try:
                geo_obj = json.loads(row['geo']) if isinstance(row['geo'], str) else row['geo']
                coords = geo_obj.get('coordinates')
            except Exception:
                coords = None
        
        if coords:
            x, y = coords[0], coords[1]
            v_val = net.res_bus.loc[bus_id, 'vm_pu']
            ax.text(
                x, y + 0.12,
                f"Bus {bus_id+1}\n{v_val:.3f}pu",
                fontsize=7,
                fontweight='bold',
                color='#0d47a1',
                ha='center',
                bbox=dict(boxstyle="round,pad=0.2", facecolor="white", alpha=0.9, edgecolor="#b0bec5")
            )

    ax.set_title("IEEE 30-Bus System - Power Flow Heatmap & Single Line Diagram", fontsize=15, fontweight='bold', pad=15)
    
    ax.autoscale_view()
    ax.set_aspect('equal')
    ax.axis('off')

    output_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(output_dir, "demo_ieee30_rich_powerflow.png")
    plt.savefig(output_path, bbox_inches='tight', facecolor='white')
    plt.close()

    print(f"✅ 고급 단선도 이미지 저장 완료: {output_path}")
    print("=" * 65)

if __name__ == "__main__":
    run_advanced_demo()
