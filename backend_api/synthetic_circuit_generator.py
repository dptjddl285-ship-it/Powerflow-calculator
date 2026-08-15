import os
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


class CircuitDrawer:
    def __init__(self, fig_size=(11, 10), dpi=220):
        self.fig, self.ax = plt.subplots(figsize=fig_size, dpi=dpi)
        self.buses = {}

    def draw_bus(self, bus_id, x1, y1, x2, y2, name=None, label_pos="right", linewidth=5.5):
        """수평 또는 수직 모선(Bus Bar)을 그립니다."""
        name = name or f"Bus {bus_id}"
        self.ax.plot([x1, x2], [y1, y2], color='black', linewidth=linewidth, solid_capstyle='butt', zorder=3)
        self.buses[bus_id] = {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'is_vertical': (x1 == x2)}

        # 라벨 위치 지정
        if label_pos == "right":
            self.ax.text(max(x1, x2) + 0.18, (y1 + y2) / 2, name, fontsize=11, fontweight='bold', va='center', ha='left')
        elif label_pos == "left":
            self.ax.text(min(x1, x2) - 0.18, (y1 + y2) / 2, name, fontsize=11, fontweight='bold', va='center', ha='right')
        elif label_pos == "top":
            self.ax.text((x1 + x2) / 2, max(y1, y2) + 0.22, name, fontsize=11, fontweight='bold', va='bottom', ha='center')
        elif label_pos == "bottom":
            self.ax.text((x1 + x2) / 2, min(y1, y2) - 0.22, name, fontsize=11, fontweight='bold', va='top', ha='center')

    def draw_generator(self, x, bus_y, orientation="up", label=None, p_mw=None, radius=0.25):
        """발전기 심볼 (원 + 내부 사인파 물결선)"""
        if orientation == "up":
            cx, cy = x, bus_y + 0.65
            self.ax.plot([x, x], [bus_y, cy - radius], color='black', linewidth=1.5)
        elif orientation == "down":
            cx, cy = x, bus_y - 0.65
            self.ax.plot([x, x], [bus_y, cy + radius], color='black', linewidth=1.5)
        elif orientation == "left":
            cx, cy = x - 0.65, bus_y
            self.ax.plot([x, cx + radius], [bus_y, bus_y], color='black', linewidth=1.5)
        elif orientation == "right":
            cx, cy = x + 0.65, bus_y
            self.ax.plot([x, cx - radius], [bus_y, bus_y], color='black', linewidth=1.5)

        circle = patches.Circle((cx, cy), radius, edgecolor='black', facecolor='white', linewidth=1.5, zorder=4)
        self.ax.add_patch(circle)

        # 내부 정현파 (~)
        t = np.linspace(-radius * 0.65, radius * 0.65, 40)
        wave_y = cy + (radius * 0.42) * np.sin((t / (radius * 0.65)) * np.pi)
        self.ax.plot(cx + t, wave_y, color='black', linewidth=1.3, zorder=5)

        if label:
            if orientation == "up":
                self.ax.text(cx, cy + radius + 0.12, label, fontsize=9.5, ha='center', va='bottom', fontweight='bold')
            elif orientation == "down":
                self.ax.text(cx, cy - radius - 0.15, label, fontsize=9.5, ha='center', va='top', fontweight='bold')
            elif orientation in ("left", "right"):
                self.ax.text(cx, cy + radius + 0.12, label, fontsize=9.5, ha='center', va='bottom', fontweight='bold')

        if p_mw is not None:
            if orientation == "down":
                self.ax.annotate('', xy=(cx, cy - radius - 0.05), xytext=(cx, cy - radius - 0.35),
                                 arrowprops=dict(arrowstyle="-|>", color='black', lw=1.3, mutation_scale=10))
                self.ax.text(cx, cy - radius - 0.48, str(p_mw), fontsize=9, ha='center', va='top')
            elif orientation == "left":
                self.ax.annotate('', xy=(cx - radius - 0.05, cy), xytext=(cx - radius - 0.4, cy),
                                 arrowprops=dict(arrowstyle="-|>", color='black', lw=1.3, mutation_scale=10))
                self.ax.text(cx - radius - 0.45, cy, str(p_mw), fontsize=9, ha='right', va='center')

    def draw_load(self, x, bus_y, orientation="up", label="30+j10", length=0.85):
        """부하 심볼 (모선 인출 화살표 + 복소전력 라벨)"""
        if orientation == "up":
            tip_y = bus_y + length
            self.ax.plot([x, x], [bus_y, tip_y], color='black', linewidth=1.5)
            self.ax.annotate('', xy=(x, tip_y), xytext=(x, bus_y),
                             arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=12))
            if label:
                self.ax.text(x, tip_y + 0.1, label, fontsize=9.5, ha='center', va='bottom')
        elif orientation == "down":
            tip_y = bus_y - length
            self.ax.plot([x, x], [bus_y, tip_y], color='black', linewidth=1.5)
            self.ax.annotate('', xy=(x, tip_y), xytext=(x, bus_y),
                             arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=12))
            if label:
                self.ax.text(x, tip_y - 0.12, label, fontsize=9.5, ha='center', va='top')
        elif orientation == "left":
            tip_x = x - length
            self.ax.plot([x, tip_x], [bus_y, bus_y], color='black', linewidth=1.5)
            self.ax.annotate('', xy=(tip_x, bus_y), xytext=(x, bus_y),
                             arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=12))
            if label:
                self.ax.text(tip_x - 0.1, bus_y, label, fontsize=9.5, ha='right', va='center')
        elif orientation == "right":
            tip_x = x + length
            self.ax.plot([x, tip_x], [bus_y, bus_y], color='black', linewidth=1.5)
            self.ax.annotate('', xy=(tip_x, bus_y), xytext=(x, bus_y),
                             arrowprops=dict(arrowstyle="-|>", color='black', lw=1.5, mutation_scale=12))
            if label:
                self.ax.text(tip_x + 0.1, bus_y, label, fontsize=9.5, ha='left', va='center')

    def draw_transformer(self, x, y, orientation="vertical", radius=0.22, label="Tr1"):
        """변압기 심볼 (두 개의 겹친 원 ⚯)"""
        if orientation == "vertical":
            c1_y = y + radius * 0.65
            c2_y = y - radius * 0.65
            c1 = patches.Circle((x, c1_y), radius, edgecolor='black', facecolor='white', linewidth=1.4, zorder=4)
            c2 = patches.Circle((x, c2_y), radius, edgecolor='black', facecolor='white', linewidth=1.4, zorder=4)
            self.ax.add_patch(c1)
            self.ax.add_patch(c2)
            if label:
                self.ax.text(x + radius + 0.15, y, label, fontsize=9.5, ha='left', va='center', fontweight='bold')
        else:  # horizontal
            c1_x = x - radius * 0.65
            c2_x = x + radius * 0.65
            c1 = patches.Circle((c1_x, y), radius, edgecolor='black', facecolor='white', linewidth=1.4, zorder=4)
            c2 = patches.Circle((c2_x, y), radius, edgecolor='black', facecolor='white', linewidth=1.4, zorder=4)
            self.ax.add_patch(c1)
            self.ax.add_patch(c2)
            if label:
                self.ax.text(x, y + radius + 0.15, label, fontsize=9.5, ha='center', va='bottom', fontweight='bold')

    def draw_line(self, pts, linewidth=1.5, label=None, label_pos=None):
        """절곡/직선 선로 연결선 및 임피던스/선로명 라벨"""
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        self.ax.plot(xs, ys, color='black', linewidth=linewidth, zorder=2)
        if label:
            if label_pos:
                lx, ly = label_pos
            else:
                mid_idx = len(pts) // 2
                lx = (xs[mid_idx - 1] + xs[mid_idx]) / 2
                ly = (ys[mid_idx - 1] + ys[mid_idx]) / 2 + 0.15
            self.ax.text(lx, ly, label, fontsize=9, ha='center', va='bottom', color='black',
                         bbox=dict(boxstyle="square,pad=0.1", facecolor="white", edgecolor="none"))

    def save(self, output_path, xlim=(0, 16), ylim=(0, 11)):
        self.ax.set_xlim(xlim)
        self.ax.set_ylim(ylim)
        self.ax.set_aspect('equal')
        self.ax.axis('off')
        plt.tight_layout()
        plt.savefig(output_path, bbox_inches='tight', facecolor='white', dpi=220)
        plt.close(self.fig)
        print(f"✅ 회로도 생성 완료: {output_path}")


# =========================================================================
# 변형 1: 5-모선 루프 & 대각선 분기 결선도
# =========================================================================
def generate_variation_1(output_path):
    d = CircuitDrawer(fig_size=(11, 10))
    
    d.draw_bus(1, x1=1.5, y1=7.5, x2=3.5, y2=7.5, name="Bus 1", label_pos="left")
    d.draw_generator(2.5, 7.5, orientation="up", label="G1")

    d.draw_bus(2, x1=7.0, y1=7.5, x2=9.0, y2=7.5, name="Bus 2", label_pos="top")
    d.draw_load(8.0, 7.5, orientation="up", label="50+j20")

    d.draw_bus(3, x1=12.5, y1=7.5, x2=14.5, y2=7.5, name="Bus 3", label_pos="right")
    d.draw_generator(13.5, 7.5, orientation="up", label="G2")
    d.draw_load(14.2, 7.5, orientation="down", label="30+j10")

    d.draw_bus(4, x1=12.0, y1=3.0, x2=14.0, y2=3.0, name="Bus 4", label_pos="right")
    d.draw_load(13.0, 3.0, orientation="down", label="40+j15")

    d.draw_bus(5, x1=2.0, y1=3.0, x2=4.0, y2=3.0, name="Bus 5", label_pos="left")
    d.draw_load(2.5, 3.0, orientation="down", label="35+j12")

    # 배선 연결
    d.draw_line([(3.2, 7.5), (3.2, 6.7), (7.3, 6.7), (7.3, 7.5)], label="Line 1-2")
    d.draw_line([(8.7, 7.5), (8.7, 6.7), (12.8, 6.7), (12.8, 7.5)], label="Line 2-3")
    d.draw_line([(13.5, 7.5), (13.5, 5.5)])
    d.draw_transformer(13.5, 5.25, orientation="vertical", label="Tr1")
    d.draw_line([(13.5, 5.0), (13.5, 3.0)])
    d.draw_line([(12.2, 3.0), (12.2, 2.1), (3.8, 2.1), (3.8, 3.0)], label="Line 4-5")
    d.draw_line([(1.8, 7.5), (1.8, 3.0)], label="Line 1-5")
    d.draw_line([(3.5, 3.0), (3.5, 4.0), (7.8, 5.8), (7.8, 7.5)], label="Tie Line 5-2")

    d.save(output_path, xlim=(0, 16), ylim=(1, 9.5))


# =========================================================================
# 변형 2: 4-모선 발전소-변전소-수전단 계통 (변압기 2대 + 수직/수평 모선 혼합)
# =========================================================================
def generate_variation_2(output_path):
    d = CircuitDrawer(fig_size=(12, 9))

    # 모선 1 (좌측 수직 발전 모선)
    d.draw_bus(1, x1=2.5, y1=6.2, x2=2.5, y2=3.5, name="Bus 1 (Gen)", label_pos="top")
    d.draw_generator(2.5, 4.85, orientation="left", label="G1", p_mw="100MW")

    # 모선 2 (고압 송전 모선 1)
    d.draw_bus(2, x1=5.5, y1=7.0, x2=7.5, y2=7.0, name="Bus 2 (345kV)", label_pos="top")

    # 모선 3 (고압 송전 모선 2)
    d.draw_bus(3, x1=10.0, y1=7.0, x2=12.0, y2=7.0, name="Bus 3 (345kV)", label_pos="top")
    d.draw_load(11.5, 7.0, orientation="down", label="20+j5")

    # 모선 4 (우측 수직 배전/부하 모선)
    d.draw_bus(4, x1=14.0, y1=6.2, x2=14.0, y2=3.5, name="Bus 4 (Load)", label_pos="top")
    d.draw_load(14.0, 5.2, orientation="right", label="80+j30")
    d.draw_load(14.0, 4.0, orientation="right", label="40+j15")

    # 연결: Bus 1 -> Tr1 (승압) -> Bus 2
    d.draw_line([(2.5, 5.8), (3.8, 5.8), (3.8, 6.2)])
    d.draw_transformer(3.8, 6.55, orientation="vertical", label="Tr1 (154/345kV)")
    d.draw_line([(3.8, 6.9), (3.8, 7.0), (5.7, 7.0)])

    # 이중 송전선로 (Bus 2 <-> Bus 3)
    d.draw_line([(7.0, 7.0), (7.0, 8.0), (10.5, 8.0), (10.5, 7.0)], label="Line 1 (Double Circuit)")
    d.draw_line([(7.2, 7.0), (7.2, 6.0), (10.2, 6.0), (10.2, 7.0)], label="Line 2")

    # 연결: Bus 3 -> Tr2 (강압) -> Bus 4
    d.draw_line([(11.8, 7.0), (12.8, 7.0), (12.8, 5.2)])
    d.draw_transformer(13.3, 5.2, orientation="horizontal", label="Tr2 (345/22.9kV)")
    d.draw_line([(13.7, 5.2), (14.0, 5.2)])

    # 하단 직결 루프 선로 (Bus 1 하단 -> Bus 4 하단)
    d.draw_line([(2.5, 3.8), (2.5, 2.0), (14.0, 2.0), (14.0, 3.8)], label="Sub-transmission Line (Tie)")

    d.save(output_path, xlim=(0, 16.5), ylim=(1, 9.5))


# =========================================================================
# 변형 3: 6-모선 메시(Mesh) 계통 (IEEE 6-Bus 형태)
# =========================================================================
def generate_variation_3(output_path):
    d = CircuitDrawer(fig_size=(12, 10))

    # 상단 모선 3개 (Bus 1, 2, 3)
    d.draw_bus(1, x1=1.5, y1=7.8, x2=3.5, y2=7.8, name="Bus 1", label_pos="left")
    d.draw_generator(2.5, 7.8, orientation="up", label="G1 (Slack)")

    d.draw_bus(2, x1=6.5, y1=7.8, x2=8.5, y2=7.8, name="Bus 2", label_pos="top")
    d.draw_generator(7.5, 7.8, orientation="up", label="G2")

    d.draw_bus(3, x1=11.5, y1=7.8, x2=13.5, y2=7.8, name="Bus 3", label_pos="right")
    d.draw_generator(12.5, 7.8, orientation="up", label="G3")

    # 하단 부하 모선 3개 (Bus 4, 5, 6)
    d.draw_bus(4, x1=1.5, y1=3.2, x2=3.5, y2=3.2, name="Bus 4", label_pos="left")
    d.draw_load(2.5, 3.2, orientation="down", label="P_L4 = 70+j30")

    d.draw_bus(5, x1=6.5, y1=3.2, x2=8.5, y2=3.2, name="Bus 5", label_pos="bottom")
    d.draw_load(7.5, 3.2, orientation="down", label="P_L5 = 50+j20")

    d.draw_bus(6, x1=11.5, y1=3.2, x2=13.5, y2=3.2, name="Bus 6", label_pos="right")
    d.draw_load(12.5, 3.2, orientation="down", label="P_L6 = 60+j25")

    # 선로 연결
    d.draw_line([(3.3, 7.8), (3.3, 6.9), (6.7, 6.9), (6.7, 7.8)], label="L12")
    d.draw_line([(8.3, 7.8), (8.3, 6.9), (11.7, 6.9), (11.7, 7.8)], label="L23")
    d.draw_line([(1.8, 7.8), (1.8, 3.2)], label="L14")
    d.draw_line([(7.0, 7.8), (7.0, 3.2)], label="L25")
    d.draw_line([(13.2, 7.8), (13.2, 3.2)], label="L36")
    d.draw_line([(3.3, 3.2), (3.3, 4.0), (6.7, 4.0), (6.7, 3.2)], label="L45")
    d.draw_line([(8.3, 3.2), (8.3, 4.0), (11.7, 4.0), (11.7, 3.2)], label="L56")
    d.draw_line([(3.0, 7.8), (3.0, 6.2), (7.5, 4.8), (7.5, 3.2)], label="L15 (Cross)")
    d.draw_line([(8.0, 7.8), (8.0, 6.2), (12.0, 4.8), (12.0, 3.2)], label="L26 (Cross)")

    d.save(output_path, xlim=(0, 15.5), ylim=(1.5, 9.8))


if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated_circuits")
    os.makedirs(out_dir, exist_ok=True)
    
    p1 = os.path.join(out_dir, "variant_1_ring_5bus.png")
    p2 = os.path.join(out_dir, "variant_2_radial_transformer_4bus.png")
    p3 = os.path.join(out_dir, "variant_3_meshed_6bus.png")

    generate_variation_1(p1)
    generate_variation_2(p2)
    generate_variation_3(p3)
