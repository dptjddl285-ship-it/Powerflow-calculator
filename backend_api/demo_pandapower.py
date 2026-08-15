import os
import sys

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

import pandapower as pp
import pandapower.networks as nw
import pandapower.plotting as plot
import matplotlib.pyplot as plt
import pandas as pd

def run_pandapower_demo():
    print("=" * 65)
    print(" [Pandapower Demonstration] IEEE 30-Bus System Power Flow")
    print("=" * 65)

    # 1. IEEE 30-bus 계통 로드
    net = nw.case30()
    print(f"\n[1] 계통 로드 완료:")
    print(f"   - 총 모선(Bus) 수: {len(net.bus)}개")
    print(f"   - 총 선로(Line) 수: {len(net.line)}개")
    print(f"   - 총 발전기(Gen/Ext Grid) 수: {len(net.gen) + len(net.ext_grid)}개")
    print(f"   - 총 부하(Load) 수: {len(net.load)}개")
    print(f"   - 총 변압기(Trafo) 수: {len(net.trafo)}개")

    # 2. AC 조류 계산 (Newton-Raphson)
    print(f"\n[2] AC 조류 계산(Power Flow) 실행 중...")
    pp.runpp(net, algorithm='nr', max_iteration=20, tolerance_mva=1e-5)
    print(f"   -> 조류 계산 수렴 성공! (Converged: {net.converged})")

    # 3. 결과 요약 출력
    print(f"\n[3] 주요 모선(Bus) 조류 계산 결과 (상위 8개):")
    bus_res = net.res_bus[['vm_pu', 'va_degree', 'p_mw', 'q_mvar']].head(8)
    print(bus_res.to_string())

    print(f"\n[4] 주요 선로(Line) 조류 및 부하율 (상위 8개):")
    line_res = net.res_line[['p_from_mw', 'q_from_mvar', 'p_to_mw', 'q_to_mvar', 'loading_percent']].head(8)
    print(line_res.to_string())

    # 4. 단선도(Single Line Diagram) 시각화 생성 및 저장
    output_dir = os.path.dirname(os.path.abspath(__file__))
    output_img_path = os.path.join(output_dir, "demo_ieee30_powerflow.png")
    
    print(f"\n[5] 단선도 및 조류 계산 시각화 생성 중...")
    fig, ax = plt.subplots(figsize=(12, 10), dpi=150)
    
    # Pandapower 내장 플로팅으로 모선, 선로, 발전기, 부하 시각화
    plot.simple_plot(
        net,
        ax=ax,
        bus_size=1.2,
        bus_color='royalblue',
        line_width=2.0,
        line_color='dimgray',
        trafo_color='darkorange',
        ext_grid_size=2.0,
        plot_loads=True,
        plot_gens=True,
        plot_sgens=True,
        show_plot=False
    )
    
    ax.set_title("IEEE 30-Bus System - Pandapower Power Flow & Single Line Diagram", fontsize=14, fontweight='bold', pad=15)
    plt.tight_layout()
    plt.savefig(output_img_path, bbox_inches='tight')
    plt.close()
    
    print(f"   -> 단선도 이미지 저장 완료: {output_img_path}")
    print("=" * 65)

if __name__ == "__main__":
    run_pandapower_demo()
