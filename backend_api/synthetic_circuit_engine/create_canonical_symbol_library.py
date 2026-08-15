import os, sys, json
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

out_dir = "feedback_artifacts/antigravity_independent_loop"
os.makedirs(out_dir, exist_ok=True)

# =========================================================================
# 1. CANONICAL SYMBOL DRAWING ENGINE
# =========================================================================

def draw_bus(ax, x1, y1, x2, y2, lw=5.5, label=None, label_pos="right"):
    """Draw solid busbar and return exact bounding box [cx, cy, w, h]."""
    ax.plot([x1, x2], [y1, y2], color='black', linewidth=lw, solid_capstyle='butt', zorder=3)
    if label:
        if label_pos == "right":
            ax.text(max(x1, x2) + 0.15, (y1 + y2) / 2, label, fontsize=9.5, fontweight='bold', va='center', ha='left')
        elif label_pos == "top":
            ax.text((x1 + x2) / 2, max(y1, y2) + 0.18, label, fontsize=9.5, fontweight='bold', va='bottom', ha='center')
        elif label_pos == "left":
            ax.text(min(x1, x2) - 0.15, (y1 + y2) / 2, label, fontsize=9.5, fontweight='bold', va='center', ha='right')
        elif label_pos == "bottom":
            ax.text((x1 + x2) / 2, min(y1, y2) - 0.18, label, fontsize=9.5, fontweight='bold', va='top', ha='center')
    return {"class": "bus", "coords": [min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1)]}

def draw_gen_wave(ax, cx, cy, radius=0.28, bus_contact=(None, None), label="G1"):
    """Single circle generator with sinusoidal wave ~."""
    if bus_contact[0] is not None:
        ax.plot([cx, bus_contact[0]], [cy + radius, bus_contact[1]], color='black', lw=1.5, zorder=2)
    circle = patches.Circle((cx, cy), radius, edgecolor='black', facecolor='white', linewidth=1.6, zorder=4)
    ax.add_patch(circle)
    # Sinusoidal wave
    t = np.linspace(-radius * 0.65, radius * 0.65, 40)
    wave_y = cy + (radius * 0.42) * np.sin((t / (radius * 0.65)) * np.pi)
    ax.plot(cx + t, wave_y, color='black', linewidth=1.4, zorder=5)
    if label:
        ax.text(cx, cy - radius - 0.12, label, fontsize=9, ha='center', va='top', fontweight='bold')
    return {"class": "generator", "type": "single_circle_wave", "center": [cx, cy], "radius": radius}

def draw_gen_letter(ax, cx, cy, radius=0.28, letter="G", bus_contact=(None, None), label="G2"):
    """Single circle generator with letter G / M."""
    if bus_contact[0] is not None:
        ax.plot([cx, bus_contact[0]], [cy + radius, bus_contact[1]], color='black', lw=1.5, zorder=2)
    circle = patches.Circle((cx, cy), radius, edgecolor='black', facecolor='white', linewidth=1.6, zorder=4)
    ax.add_patch(circle)
    ax.text(cx, cy, letter, fontsize=11, ha='center', va='center', fontweight='bold', fontfamily='serif', zorder=5)
    if label:
        ax.text(cx, cy - radius - 0.12, label, fontsize=9, ha='center', va='top', fontweight='bold')
    return {"class": "generator", "type": "single_circle_letter", "center": [cx, cy], "radius": radius}

def draw_load_terminal_triangle(ax, x, bus_y, length=0.65, tri_w=0.36, tri_h=0.35, label="40+j15", color="black"):
    """Exact terminal filled triangle load matching user screenshot (ends at tip)."""
    top_y = bus_y - length
    tip_y = top_y - tri_h
    # Lead wire from bus to triangle base
    ax.plot([x, x], [bus_y, top_y], color=color, lw=1.6, solid_capstyle='butt', zorder=2)
    # Filled triangle ending at tip_y
    triangle = patches.Polygon([[x - tri_w/2, top_y], [x + tri_w/2, top_y], [x, tip_y]],
                               closed=True, facecolor=color, edgecolor=color, linewidth=1.0, zorder=4)
    ax.add_patch(triangle)
    if label:
        ax.text(x, tip_y - 0.1, label, fontsize=8.5, ha='center', va='top')
    return {"class": "load", "type": "terminal_triangle_down", "bbox": [x, (top_y + tip_y)/2, tri_w, tri_h]}

def draw_load_hollow_triangle(ax, x, bus_y, length=0.65, tri_w=0.36, tri_h=0.35, label="20+j10"):
    """Hollow outline triangle load."""
    top_y = bus_y - length
    tip_y = top_y - tri_h
    ax.plot([x, x], [bus_y, top_y], color='black', lw=1.6, solid_capstyle='butt', zorder=2)
    triangle = patches.Polygon([[x - tri_w/2, top_y], [x + tri_w/2, top_y], [x, tip_y]],
                               closed=True, facecolor='white', edgecolor='black', linewidth=1.6, zorder=4)
    ax.add_patch(triangle)
    if label:
        ax.text(x, tip_y - 0.1, label, fontsize=8.5, ha='center', va='top')
    return {"class": "load", "type": "hollow_triangle_down", "bbox": [x, (top_y + tip_y)/2, tri_w, tri_h]}

def draw_load_horizontal_right(ax, bus_x, y, length=0.65, tri_w=0.35, tri_h=0.36, label="30+j10"):
    """Horizontal rightward terminal load."""
    base_x = bus_x + length
    tip_x = base_x + tri_w
    ax.plot([bus_x, base_x], [y, y], color='black', lw=1.6, solid_capstyle='butt', zorder=2)
    triangle = patches.Polygon([[base_x, y + tri_h/2], [base_x, y - tri_h/2], [tip_x, y]],
                               closed=True, facecolor='black', edgecolor='black', linewidth=1.0, zorder=4)
    ax.add_patch(triangle)
    if label:
        ax.text(tip_x + 0.1, y, label, fontsize=8.5, ha='left', va='center')
    return {"class": "load", "type": "terminal_triangle_right", "bbox": [(base_x + tip_x)/2, y, tri_w, tri_h]}

def draw_transformer_two_circles(ax, cx, cy, orientation="vertical", radius=0.24, overlap=0.08, label="Tr1"):
    """2 intersecting circles transformer (vertical or horizontal)."""
    if orientation == "vertical":
        c1 = (cx, cy + (radius - overlap/2))
        c2 = (cx, cy - (radius - overlap/2))
        # Terminals
        ax.plot([cx, cx], [c1[1] + radius, c1[1] + radius + 0.25], color='black', lw=1.5, zorder=2)
        ax.plot([cx, cx], [c2[1] - radius, c2[1] - radius - 0.25], color='black', lw=1.5, zorder=2)
    else:
        c1 = (cx - (radius - overlap/2), cy)
        c2 = (cx + (radius - overlap/2), cy)
        ax.plot([c1[0] - radius, c1[0] - radius - 0.25], [cy, cy], color='black', lw=1.5, zorder=2)
        ax.plot([c2[0] + radius, c2[0] + radius + 0.25], [cy, cy], color='black', lw=1.5, zorder=2)
        
    p1 = patches.Circle(c1, radius, edgecolor='black', facecolor='white', linewidth=1.6, zorder=4)
    p2 = patches.Circle(c2, radius, edgecolor='black', facecolor='white', linewidth=1.6, zorder=4)
    ax.add_patch(p1)
    ax.add_patch(p2)
    if label:
        if orientation == "vertical":
            ax.text(cx + radius + 0.12, cy, label, fontsize=9, ha='left', va='center', fontweight='bold')
        else:
            ax.text(cx, cy + radius + 0.12, label, fontsize=9, ha='center', va='bottom', fontweight='bold')
    return {"class": "transformer", "type": f"two_circles_{orientation}", "center": [cx, cy]}

def draw_transformer_coils(ax, cx, cy, orientation="horizontal", label="Tr2"):
    """4-coil inductor transformer ('33' or '3E' style)."""
    r = 0.08
    if orientation == "horizontal":
        # Left coils (2 loops)
        t = np.linspace(-np.pi/2, np.pi/2, 20)
        ax.plot(cx - 0.08 + r*np.cos(t), cy + r + r*np.sin(t), color='black', lw=1.6, zorder=4)
        ax.plot(cx - 0.08 + r*np.cos(t), cy - r + r*np.sin(t), color='black', lw=1.6, zorder=4)
        # Right coils (2 loops)
        t_rev = np.linspace(np.pi/2, 3*np.pi/2, 20)
        ax.plot(cx + 0.08 + r*np.cos(t_rev), cy + r + r*np.sin(t_rev), color='black', lw=1.6, zorder=4)
        ax.plot(cx + 0.08 + r*np.cos(t_rev), cy - r + r*np.sin(t_rev), color='black', lw=1.6, zorder=4)
        # Core lines
        ax.plot([cx - 0.02, cx - 0.02], [cy - 2*r, cy + 2*r], color='black', lw=1.2, zorder=3)
        ax.plot([cx + 0.02, cx + 0.02], [cy - 2*r, cy + 2*r], color='black', lw=1.2, zorder=3)
        # Terminal leads
        ax.plot([cx - 0.35, cx - 0.08], [cy + 2*r, cy + 2*r], color='black', lw=1.5, zorder=2)
        ax.plot([cx + 0.08, cx + 0.35], [cy + 2*r, cy + 2*r], color='black', lw=1.5, zorder=2)
    if label:
        ax.text(cx, cy + 0.35, label, fontsize=9, ha='center', va='bottom', fontweight='bold')
    return {"class": "transformer", "type": "coil_transformer", "center": [cx, cy]}


# =========================================================================
# 2. GENERATE FULL SHOWCASE SHEET
# =========================================================================

fig, axes = plt.subplots(4, 4, figsize=(14, 13), dpi=220)
fig.suptitle("⚡ Canonical Powerflow Symbol Library (Programmatic Vector Implementations)", fontsize=14, fontweight='bold', y=0.98)

# Row 0: Busbars
ax = axes[0, 0]; ax.set_title("1-1. Horizontal Thick Bus (실제 모선)", fontsize=9, fontweight='bold')
draw_bus(ax, -0.6, 0.0, 0.6, 0.0, lw=6.0, label="Bus 1 (Slack)", label_pos="right")
ax.set_xlim(-0.9, 1.2); ax.set_ylim(-0.6, 0.6); ax.axis('off')

ax = axes[0, 1]; ax.set_title("1-2. Vertical Busbar (수직 모선)", fontsize=9, fontweight='bold')
draw_bus(ax, 0.0, -0.6, 0.0, 0.6, lw=6.0, label="Bus 2 (Load)", label_pos="top")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.8, 1.0); ax.axis('off')

ax = axes[0, 2]; ax.set_title("1-3. Bus with Port Stubs (인출 돌기 모선)", fontsize=9, fontweight='bold')
draw_bus(ax, -0.6, 0.0, 0.6, 0.0, lw=5.5, label="Bus 3", label_pos="left")
ax.plot([-0.3, -0.3], [0.0, 0.25], color='black', lw=2.0)
ax.plot([0.3, 0.3], [0.0, -0.25], color='black', lw=2.0)
ax.set_xlim(-1.1, 0.9); ax.set_ylim(-0.6, 0.6); ax.axis('off')

ax = axes[0, 3]; ax.set_title("1-4. Medium Thickness Bus (중간 두께 모선)", fontsize=9, fontweight='bold')
draw_bus(ax, -0.5, 0.0, 0.5, 0.0, lw=4.0, label="Bus 4", label_pos="right")
ax.set_xlim(-0.8, 1.1); ax.set_ylim(-0.6, 0.6); ax.axis('off')

# Row 1: Generators
ax = axes[1, 0]; ax.set_title("2-1. Single Circle Wave (물결 발전기)", fontsize=9, fontweight='bold')
draw_gen_wave(ax, 0.0, 0.0, radius=0.32, bus_contact=(0.0, 0.65), label="G1 (100MW)")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

ax = axes[1, 1]; ax.set_title("2-2. Single Circle Letter 'G' ('G' 발전기)", fontsize=9, fontweight='bold')
draw_gen_letter(ax, 0.0, 0.0, radius=0.32, letter="G", bus_contact=(0.0, 0.65), label="G2")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

ax = axes[1, 2]; ax.set_title("2-3. Single Circle Letter 'M' (전동/발전기)", fontsize=9, fontweight='bold')
draw_gen_letter(ax, 0.0, 0.0, radius=0.32, letter="M", bus_contact=(0.0, 0.65), label="M1 (Sync)")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

ax = axes[1, 3]; ax.set_title("2-4. Bus Connected Generator (모선 직결)", fontsize=9, fontweight='bold')
draw_bus(ax, -0.5, 0.55, 0.5, 0.55, lw=5.0)
draw_gen_wave(ax, 0.0, 0.0, radius=0.28, bus_contact=(0.0, 0.55), label="G3")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

# Row 2: Loads
ax = axes[2, 0]; ax.set_title("3-1. Solid Terminal Triangle (검정 역삼각 부하 ⭐)", fontsize=9, fontweight='bold')
draw_load_terminal_triangle(ax, 0.0, 0.6, length=0.45, label="40+j15 MW")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

ax = axes[2, 1]; ax.set_title("3-2. Hollow Outline Triangle (윤곽선 부하)", fontsize=9, fontweight='bold')
draw_load_hollow_triangle(ax, 0.0, 0.6, length=0.45, label="20+j10 MW")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

ax = axes[2, 2]; ax.set_title("3-3. Horizontal Rightward Load (우향 부하)", fontsize=9, fontweight='bold')
draw_load_horizontal_right(ax, -0.4, 0.0, length=0.45, label="30+j12")
ax.set_xlim(-0.6, 1.1); ax.set_ylim(-0.6, 0.6); ax.axis('off')

ax = axes[2, 3]; ax.set_title("3-4. Blue Accent Load (파란색 부하)", fontsize=9, fontweight='bold')
draw_load_terminal_triangle(ax, 0.0, 0.6, length=0.45, color="#0066CC", label="50+j20 MW")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.8); ax.axis('off')

# Row 3: Transformers
ax = axes[3, 0]; ax.set_title("4-1. 2-Circles Vertical (2원형 수직 변압기 ⭐)", fontsize=9, fontweight='bold')
draw_transformer_two_circles(ax, 0.0, 0.0, orientation="vertical", radius=0.25, label="Tr1 (154/345kV)")
ax.set_xlim(-0.8, 1.2); ax.set_ylim(-0.7, 0.7); ax.axis('off')

ax = axes[3, 1]; ax.set_title("4-2. 2-Circles Horizontal (2원형 수평 변압기)", fontsize=9, fontweight='bold')
draw_transformer_two_circles(ax, 0.0, 0.0, orientation="horizontal", radius=0.25, label="Tr2")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.7, 0.7); ax.axis('off')

ax = axes[3, 2]; ax.set_title("4-3. 4-Coil Inductor (코일형 변압기 '33')", fontsize=9, fontweight='bold')
draw_transformer_coils(ax, 0.0, 0.0, orientation="horizontal", label="Tr3")
ax.set_xlim(-0.8, 0.8); ax.set_ylim(-0.6, 0.7); ax.axis('off')

ax = axes[3, 3]; ax.set_title("4-4. Bus-to-Bus Transformer (선로 연결)", fontsize=9, fontweight='bold')
draw_bus(ax, -0.65, 0.45, -0.65, -0.45, lw=5.0)
draw_bus(ax, 0.65, 0.45, 0.65, -0.45, lw=5.0)
ax.plot([-0.65, -0.25], [0.0, 0.0], color='black', lw=1.5)
ax.plot([0.25, 0.65], [0.0, 0.0], color='black', lw=1.5)
draw_transformer_two_circles(ax, 0.0, 0.0, orientation="horizontal", radius=0.22, label="Tr4")
ax.set_xlim(-0.9, 0.9); ax.set_ylim(-0.6, 0.6); ax.axis('off')

plt.tight_layout(rect=[0.02, 0.02, 0.98, 0.95])
showcase_path = os.path.join(out_dir, "canonical_symbols_showcase.png")
fig.savefig(showcase_path, bbox_inches='tight')
plt.close(fig)

print(f"Successfully generated Canonical Symbol Showcase Image: {showcase_path}")
