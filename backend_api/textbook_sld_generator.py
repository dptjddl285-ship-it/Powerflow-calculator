import os
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

# Ensure UTF-8 output encoding
if sys.platform.startswith('win'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def draw_bus(ax, x1, x2, y, name="Bus 1", label_pos="right", linewidth=6.0):
    """두꺼운 모선(Bus Bar)을 그립니다."""
    ax.plot([x1, x2], [y, y], color='black', linewidth=linewidth, solid_capstyle='butt')
    if label_pos == "right":
        ax.text(x2 + 0.18, y, name, fontsize=12, fontweight='bold', va='center', ha='left', family='sans-serif')
    elif label_pos == "left":
        ax.text(x1 - 0.18, y, name, fontsize=12, fontweight='bold', va='center', ha='right', family='sans-serif')
    elif label_pos == "top":
        ax.text((x1 + x2)/2, y + 0.25, name, fontsize=12, fontweight='bold', va='bottom', ha='center', family='sans-serif')
    elif label_pos == "bottom":
        ax.text((x1 + x2)/2, y - 0.25, name, fontsize=12, fontweight='bold', va='top', ha='center', family='sans-serif')


def draw_generator(ax, x, bus_y, orientation="up", label=None, radius=0.25):
    """전형적인 교과서 발전기 심볼(원 + 내부 물결표 ~)을 그립니다."""
    if orientation == "up":
        cy = bus_y + 0.65
        ax.plot([x, x], [bus_y, cy - radius], color='black', linewidth=1.5)
    else:  # down
        cy = bus_y - 0.65
        ax.plot([x, x], [bus_y, cy + radius], color='black', linewidth=1.5)

    # 원형
    circle = patches.Circle((x, cy), radius, edgecolor='black', facecolor='white', linewidth=1.5, zorder=4)
    ax.add_patch(circle)

    # 내부 물결선(~)
    t = np.linspace(-radius * 0.65, radius * 0.65, 50)
    wave_y = cy + (radius * 0.42) * np.sin((t / (radius * 0.65)) * np.pi)
    ax.plot(x + t, wave_y, color='black', linewidth=1.4, zorder=5)

    # 라벨 / 유효전력(P)
    if label:
        if orientation == "up":
            ax.text(x, cy + radius + 0.15, label, fontsize=10, ha='center', va='bottom', family='sans-serif')
        else:
            # 아래에서 들어오는 화살표와 텍스트
            ax.annotate('', xy=(x, cy - radius - 0.05), xytext=(x, cy - radius - 0.35),
                        arrowprops=dict(arrowstyle="-|>", color='black', lw=1.3, mutation_scale=11))
            ax.text(x, cy - radius - 0.48, label, fontsize=10, ha='center', va='top', family='sans-serif')


def draw_load(ax, x, bus_y, orientation="up", label="45+j15", length=0.9):
    """교과서 부하(Load) 화살표 심볼 및 P+jQ 복소전력 라벨을 그립니다."""
    if orientation == "up":
        tip_y = bus_y + length
        ax.plot([x, x], [bus_y, tip_y], color='black', linewidth=1.5)
        ax.annotate('', xy=(x, tip_y), xytext=(x, bus_y),
                    arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=13))
        ax.text(x, tip_y + 0.12, label, fontsize=10.5, ha='center', va='bottom', family='sans-serif')
    else:  # down
        tip_y = bus_y - length
        ax.plot([x, x], [bus_y, tip_y], color='black', linewidth=1.5)
        ax.annotate('', xy=(x, tip_y), xytext=(x, bus_y),
                    arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=13))
        ax.text(x, tip_y - 0.15, label, fontsize=10.5, ha='center', va='top', family='sans-serif')


def draw_wire(ax, pts, linewidth=1.5):
    """선로 배선을 그립니다."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    ax.plot(xs, ys, color='black', linewidth=linewidth, zorder=2)


def generate_exact_textbook_diagram(output_path):
    """
    test_image1.jpg와 동일한 구조와 스타일의 교과서 단선도를 생성합니다.
    """
    fig, ax = plt.subplots(figsize=(11, 10), dpi=220)

    # 1. 모선(Bus 1 ~ Bus 5) 배치
    # Bus 1 (상단 좌측)
    draw_bus(ax, x1=1.0, x2=2.8, y=7.0, name="Bus 1", label_pos="right")
    draw_generator(ax, x=1.9, bus_y=7.0, orientation="up")

    # Bus 3 (상단 중앙)
    draw_bus(ax, x1=6.5, x2=8.3, y=6.9, name="Bus 3", label_pos="right")
    draw_load(ax, x=7.4, bus_y=6.9, orientation="up", label="45+j15")

    # Bus 4 (상단 우측)
    draw_bus(ax, x1=12.2, x2=14.1, y=6.8, name="Bus 4", label_pos="left")
    draw_load(ax, x=13.1, bus_y=6.8, orientation="up", label="40+j5")

    # Bus 2 (하단 좌측)
    draw_bus(ax, x1=1.0, x2=2.6, y=3.0, name="Bus 2", label_pos="right")
    draw_generator(ax, x=1.8, bus_y=3.0, orientation="down", label="40")
    draw_load(ax, x=1.2, bus_y=3.0, orientation="down", label="20+j10")

    # Bus 5 (하단 우측)
    draw_bus(ax, x1=12.3, x2=14.1, y=3.0, name="Bus 5", label_pos="left")
    draw_load(ax, x=13.7, bus_y=3.0, orientation="down", label="60+j10")

    # 2. 선로(Transmission Lines) 배선 연결
    # Line 1: Bus 1 좌측(1.2) -> Bus 2 좌측(1.2)
    draw_wire(ax, [(1.2, 7.0), (1.2, 3.0)])

    # Line 2: Bus 1 우측(2.6) -> 계단형 -> Bus 3 좌측(6.7)
    draw_wire(ax, [(2.6, 7.0), (2.6, 6.0), (6.7, 6.0), (6.7, 6.9)])

    # Line 3: Bus 3 우측(8.1) -> 계단형 -> Bus 4 좌측(12.4)
    draw_wire(ax, [(8.1, 6.9), (8.1, 5.9), (12.4, 5.9), (12.4, 6.8)])

    # Line 4: Bus 2 (1.5) -> 수직 인출 -> 대각선 -> 수직 연결 -> Bus 3 (7.4)
    draw_wire(ax, [(1.5, 3.0), (1.5, 3.8), (7.4, 5.2), (7.4, 6.9)])

    # Line 5: Bus 2 (2.1) -> 수직 인출 -> 대각선 -> 수직 연결 -> Bus 4 (13.1)
    draw_wire(ax, [(2.1, 3.0), (2.1, 3.5), (13.1, 4.9), (13.1, 6.8)])

    # Line 6: Bus 2 하단(2.3) -> 계단형 -> Bus 5 좌측(12.5)
    draw_wire(ax, [(2.3, 3.0), (2.3, 2.3), (12.5, 2.3), (12.5, 3.0)])

    # Line 7: Bus 4 우측(13.9) -> Bus 5 우측(13.9)
    draw_wire(ax, [(13.9, 6.8), (13.9, 3.0)])

    # 3. 뷰포트 및 여백 설정 (교과서 전기도면 스타일)
    ax.set_xlim(0, 15.5)
    ax.set_ylim(1.2, 8.8)
    ax.set_aspect('equal')
    ax.axis('off')

    plt.tight_layout()
    plt.savefig(output_path, bbox_inches='tight', facecolor='white', dpi=220)
    plt.close(fig)
    print(f"✅ 교과서 스타일 회로도 생성 완료: {output_path}")


if __name__ == "__main__":
    out_dir = os.path.dirname(os.path.abspath(__file__))
    out_file = os.path.join(out_dir, "textbook_style_circuit_generated.png")
    generate_exact_textbook_diagram(out_file)
