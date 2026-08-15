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
# AUTHENTIC IEEE 5-BUS CIRCUIT GENERATOR (Matching test_image2.jpg layout)
# =========================================================================
def generate_authentic_ieee_5bus(output_path, yolo_path=None, json_path=None):
    fig, ax = plt.subplots(figsize=(10, 10), dpi=200)
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 10)
    ax.axis('off')
    
    gt_nodes = []
    
    # 1. Busbars (Top: Bus 1, Bus 3, Bus 4 | Bottom: Bus 2, Bus 5)
    # Bus 1 (top left horizontal)
    ax.plot([1.5, 3.2], [6.5, 6.5], color='black', lw=6.0, solid_capstyle='butt', zorder=3)
    ax.text(1.7, 6.75, "1", fontsize=15, fontweight='bold', color='red', ha='center', va='bottom', fontfamily='serif')
    gt_nodes.append({"class": "bus", "name": "Bus 1", "data_bbox": [2.35, 6.5, 1.7, 0.15]})
    
    # Bus 3 (top center horizontal)
    ax.plot([4.7, 6.4], [6.5, 6.5], color='black', lw=6.0, solid_capstyle='butt', zorder=3)
    ax.text(4.9, 6.75, "3", fontsize=15, fontweight='bold', color='red', ha='center', va='bottom', fontfamily='serif')
    gt_nodes.append({"class": "bus", "name": "Bus 3", "data_bbox": [5.55, 6.5, 1.7, 0.15]})
    
    # Bus 4 (top right horizontal)
    ax.plot([8.1, 9.6], [6.5, 6.5], color='black', lw=6.0, solid_capstyle='butt', zorder=3)
    ax.text(8.2, 6.75, "4", fontsize=15, fontweight='bold', color='red', ha='center', va='bottom', fontfamily='serif')
    gt_nodes.append({"class": "bus", "name": "Bus 4", "data_bbox": [8.85, 6.5, 1.5, 0.15]})
    
    # Bus 2 (bottom left horizontal)
    ax.plot([1.5, 3.2], [3.2, 3.2], color='black', lw=6.0, solid_capstyle='butt', zorder=3)
    ax.text(1.6, 3.45, "2", fontsize=15, fontweight='bold', color='red', ha='center', va='bottom', fontfamily='serif')
    gt_nodes.append({"class": "bus", "name": "Bus 2", "data_bbox": [2.35, 3.2, 1.7, 0.15]})
    
    # Bus 5 (bottom right horizontal)
    ax.plot([7.8, 9.4], [3.2, 3.2], color='black', lw=6.0, solid_capstyle='butt', zorder=3)
    ax.text(7.9, 3.45, "5", fontsize=15, fontweight='bold', color='red', ha='center', va='bottom', fontfamily='serif')
    gt_nodes.append({"class": "bus", "name": "Bus 5", "data_bbox": [8.6, 3.2, 1.6, 0.15]})
    
    # 2. Generators (G1 on Bus 1 top, G3 on Bus 3 top, G2 on Bus 2 bottom)
    # G1 (on Bus 1)
    ax.plot([2.4, 2.4], [6.5, 7.5], color='black', lw=2.0, zorder=2)
    circle_g1 = patches.Circle((2.4, 7.5), 0.5, edgecolor='black', facecolor='#FFF2CC', linewidth=2.0, zorder=4)
    ax.add_patch(circle_g1)
    ax.text(2.4, 7.5, "$G_1$", fontsize=15, fontweight='bold', color='red', ha='center', va='center', fontfamily='serif', zorder=5)
    gt_nodes.append({"class": "generator", "name": "G1", "data_bbox": [2.4, 7.5, 1.0, 1.0]})
    
    # G3 (on Bus 3)
    ax.plot([5.5, 5.5], [6.5, 7.5], color='black', lw=2.0, zorder=2)
    circle_g3 = patches.Circle((5.5, 7.5), 0.5, edgecolor='black', facecolor='#FFF2CC', linewidth=2.0, zorder=4)
    ax.add_patch(circle_g3)
    ax.text(5.5, 7.5, "$G_3$", fontsize=15, fontweight='bold', color='red', ha='center', va='center', fontfamily='serif', zorder=5)
    gt_nodes.append({"class": "generator", "name": "G3", "data_bbox": [5.5, 7.5, 1.0, 1.0]})
    
    # G2 (on Bus 2 bottom)
    ax.plot([2.1, 2.1], [3.2, 2.3], color='black', lw=2.0, zorder=2)
    circle_g2 = patches.Circle((2.1, 2.3), 0.5, edgecolor='black', facecolor='#FFF2CC', linewidth=2.0, zorder=4)
    ax.add_patch(circle_g2)
    ax.text(2.1, 2.3, "$G_2$", fontsize=15, fontweight='bold', color='red', ha='center', va='center', fontfamily='serif', zorder=5)
    gt_nodes.append({"class": "generator", "name": "G2", "data_bbox": [2.1, 2.3, 1.0, 1.0]})
    
    # 3. Loads (Downward blue terminal arrows matching test_image2.jpg)
    # Load on Bus 3
    ax.plot([5.7, 5.7], [6.5, 5.8], color='#3366CC', lw=3.0, solid_capstyle='butt', zorder=2)
    tri_l3 = patches.Polygon([[5.52, 5.8], [5.88, 5.8], [5.7, 5.4]], closed=True, facecolor='#3366CC', edgecolor='#3366CC', zorder=4)
    ax.add_patch(tri_l3)
    gt_nodes.append({"class": "load", "name": "Load Bus 3", "data_bbox": [5.7, 5.6, 0.36, 0.4]})
    
    # Load on Bus 2
    ax.plot([2.8, 2.8], [3.2, 2.4], color='#3366CC', lw=3.0, solid_capstyle='butt', zorder=2)
    tri_l2 = patches.Polygon([[2.62, 2.4], [2.98, 2.4], [2.8, 2.0]], closed=True, facecolor='#3366CC', edgecolor='#3366CC', zorder=4)
    ax.add_patch(tri_l2)
    gt_nodes.append({"class": "load", "name": "Load Bus 2", "data_bbox": [2.8, 2.2, 0.36, 0.4]})
    
    # Load 1 on Bus 4
    ax.plot([9.3, 9.3], [6.5, 5.6], color='#3366CC', lw=3.0, solid_capstyle='butt', zorder=2)
    tri_l4 = patches.Polygon([[9.12, 5.6], [9.48, 5.6], [9.3, 5.2]], closed=True, facecolor='#3366CC', edgecolor='#3366CC', zorder=4)
    ax.add_patch(tri_l4)
    gt_nodes.append({"class": "load", "name": "Load Bus 4", "data_bbox": [9.3, 5.4, 0.36, 0.4]})
    
    # Load on Bus 5
    ax.plot([8.5, 8.5], [3.2, 2.3], color='#3366CC', lw=3.0, solid_capstyle='butt', zorder=2)
    tri_l5 = patches.Polygon([[8.32, 2.3], [8.68, 2.3], [8.5, 1.9]], closed=True, facecolor='#3366CC', edgecolor='#3366CC', zorder=4)
    ax.add_patch(tri_l5)
    gt_nodes.append({"class": "load", "name": "Load Bus 5", "data_bbox": [8.5, 2.1, 0.36, 0.4]})
    
    # 4. Transmission Lines & Impedance Labels (Exact matching test_image2.jpg)
    # Line 1-2
    ax.plot([1.8, 1.8], [6.5, 3.2], color='#3366CC', lw=2.5)
    ax.text(1.9, 4.85, "0.02+j0.06", fontsize=11, fontweight='bold', color='black', va='center', rotation=90)
    
    # Line 1-3 (Stepped)
    ax.plot([2.95, 2.95, 4.95, 4.95], [6.5, 5.9, 5.9, 6.5], color='#3366CC', lw=2.5)
    ax.text(3.95, 6.15, "0.08+j0.24", fontsize=11, fontweight='bold', color='black', ha='center')
    
    # Line 3-4 (Stepped)
    ax.plot([6.1, 6.1, 8.1, 8.1], [6.5, 5.9, 5.9, 6.5], color='#3366CC', lw=2.5)
    ax.text(7.1, 6.15, "0.01+j0.03", fontsize=11, fontweight='bold', color='black', ha='center')
    
    # Line 2-3 (Diagonal)
    ax.plot([2.15, 2.15, 5.3, 5.3], [3.2, 3.6, 5.9, 6.5], color='#3366CC', lw=2.5)
    ax.text(3.7, 4.9, "0.06+j0.18", fontsize=11, fontweight='bold', color='black', ha='center', rotation=28)
    
    # Line 2-4 (Diagonal)
    ax.plot([2.5, 2.5, 8.5, 8.5], [3.2, 3.6, 5.9, 6.5], color='#3366CC', lw=2.5)
    ax.text(5.5, 4.4, "0.06+j0.18", fontsize=11, fontweight='bold', color='black', ha='center', rotation=22)
    
    # Line 4-5 (Vertical)
    ax.plot([8.9, 8.9], [6.5, 3.2], color='#3366CC', lw=2.5)
    ax.text(9.0, 4.85, "0.08+j0.24", fontsize=11, fontweight='bold', color='black', va='center', rotation=-90)
    
    # Line 2-5 (Horizontal bottom)
    ax.plot([2.95, 2.95, 8.1, 8.1], [3.2, 3.6, 3.6, 3.2], color='black', lw=2.5)
    ax.text(5.5, 3.85, "0.04+j0.12", fontsize=11, fontweight='bold', color='black', ha='center')
    
    # Power Injection Annotations
    ax.annotate('', xy=(4.7, 7.0), xytext=(4.7, 7.9), arrowprops=dict(arrowstyle="-|>", color='#3366CC', lw=2.5, mutation_scale=15))
    ax.text(3.9, 7.5, "30M\nW", fontsize=12, fontweight='bold', color='black', ha='center', va='center')
    
    ax.annotate('', xy=(1.3, 3.0), xytext=(1.3, 2.1), arrowprops=dict(arrowstyle="-|>", color='#3366CC', lw=2.5, mutation_scale=15))
    ax.text(0.7, 2.5, "40M\nW", fontsize=12, fontweight='bold', color='black', ha='center', va='center')
    
    fig.savefig(output_path, bbox_inches='tight', pad_inches=0.1)
    plt.close(fig)
    print(f"Successfully generated authentic IEEE 5-Bus Diagram at: {output_path}")

generate_authentic_ieee_5bus(os.path.join(out_dir, "authentic_ieee_5bus_generated.png"))
