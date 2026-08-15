import os
import sys
import io
import json
import base64
import numpy as np
import pandas as pd
import networkx as nx
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend for server environments
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors

import pandapower as pp
import pandapower.networks as nw
import pandapower.plotting as plot
import pandapower.topology as top

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def _extract_coord(pos_obj):
    """Offset 또는 딕셔너리에서 x, y 좌표를 안전하게 추출합니다."""
    if not pos_obj:
        return None
    if isinstance(pos_obj, (list, tuple)) and len(pos_obj) >= 2:
        return float(pos_obj[0]), float(pos_obj[1])
    if isinstance(pos_obj, dict):
        x = pos_obj.get('dx', pos_obj.get('x', None))
        y = pos_obj.get('dy', pos_obj.get('y', None))
        if x is not None and y is not None:
            return float(x), float(y)
    return None


def ensure_bus_coordinates(net):
    """
    모든 모선에 유효한 시각화 좌표(GeoJSON Point)가 있도록 보장합니다.
    좌표가 없는 경우 NetworkX Layout을 이용해 자동으로 미려한 토폴로지 좌표를 배치합니다.
    """
    coords_dict = {}
    missing_indices = []

    for b_idx in net.bus.index:
        c = None
        if 'geo' in net.bus.columns:
            val = net.bus.at[b_idx, 'geo']
            if pd.notna(val) and val:
                if isinstance(val, str):
                    try:
                        parsed = json.loads(val)
                        if isinstance(parsed, dict) and 'coordinates' in parsed:
                            c = parsed['coordinates']
                    except Exception:
                        pass
                elif isinstance(val, dict) and 'coordinates' in val:
                    c = val['coordinates']
        
        if c is not None and len(c) >= 2:
            coords_dict[b_idx] = (float(c[0]), float(c[1]))
        else:
            missing_indices.append(b_idx)

    # 누락된 좌표가 있는 경우 NetworkX 스프링 레이아웃으로 계산
    if missing_indices:
        try:
            mg = top.create_nxgraph(net, include_lines=True, include_trafos=True)
            if len(mg.nodes) > 0:
                pos = nx.spring_layout(mg, seed=42, k=1.5 / max(1, np.sqrt(len(net.bus))))
                for b_idx in net.bus.index:
                    if b_idx in pos:
                        coords_dict[b_idx] = (float(pos[b_idx][0] * 10.0), float(pos[b_idx][1] * 10.0))
                    else:
                        coords_dict[b_idx] = (float(b_idx * 2.0), 0.0)
            else:
                for idx, b_idx in enumerate(net.bus.index):
                    coords_dict[b_idx] = (float(idx * 2.0), 0.0)
        except Exception:
            for idx, b_idx in enumerate(net.bus.index):
                coords_dict[b_idx] = (float(idx * 2.0), 0.0)

        # net.bus['geo']에 일괄 저장
        geo_list = []
        for b_idx in net.bus.index:
            pt = coords_dict.get(b_idx, (0.0, 0.0))
            geo_list.append(json.dumps({"type": "Point", "coordinates": [pt[0], pt[1]]}))
        net.bus['geo'] = geo_list

    return coords_dict


def build_net_from_elements(elements, base_mva=100.0, base_kv=110.0):
    """
    플러터(Flutter) 또는 도면 인식(Vision)에서 전달된 elements 리스트를
    pandapower 네트워크(net) 객체로 변환합니다.
    """
    net = pp.create_empty_network(sn_mva=base_mva)
    
    # 1. 요소 분류
    buses_data = [el for el in elements if el.get('type') == 'bus']
    lines_data = [el for el in elements if el.get('type') == 'line']
    gens_data = [el for el in elements if el.get('type') in ('generator', 'gen')]
    loads_data = [el for el in elements if el.get('type') == 'load']
    trafos_data = [el for el in elements if el.get('type') in ('transformer', 'trafo')]
    
    bus_map = {}
    element_to_bus = {}
    
    # 2. 모선(Bus) 생성
    for b in buses_data:
        b_id = str(b.get('id', f'B_{len(bus_map)+1}'))
        vn_kv = float(b.get('vnKv', base_kv))
        v_pu = float(b.get('vPu', 1.0))
        theta_deg = float(b.get('thetaDeg', 0.0))
        is_slack = bool(b.get('isSlack', False))
        
        # 위치 좌표 확인
        pos = _extract_coord(b.get('position'))
        geo_str = json.dumps({"type": "Point", "coordinates": [pos[0], -pos[1]]}) if pos else None
        
        bus_idx = pp.create_bus(
            net,
            vn_kv=vn_kv,
            name=b_id,
            min_vm_pu=0.9,
            max_vm_pu=1.1
        )
        if geo_str:
            net.bus.at[bus_idx, 'geo'] = geo_str
            
        bus_map[b_id] = bus_idx
        element_to_bus[b_id] = b_id
        
        if is_slack:
            pp.create_ext_grid(net, bus=bus_idx, vm_pu=v_pu, va_degree=theta_deg, name=f"Slack_{b_id}")
            
    # 요소 -> 부모 모선 ID 매핑
    for el in elements:
        el_id = str(el.get('id', ''))
        parent_id = el.get('parentBusId')
        if parent_id and str(parent_id) in bus_map:
            element_to_bus[el_id] = str(parent_id)
        elif el.get('type') == 'bus':
            element_to_bus[el_id] = el_id

    # 3. 발전기(Generator) 생성
    for g in gens_data:
        g_id = str(g.get('id', f'G_{len(net.gen)+1}'))
        parent = str(g.get('parentBusId', ''))
        bus_id = element_to_bus.get(parent, parent)
        
        if bus_id in bus_map:
            bus_idx = bus_map[bus_id]
            p_mw = float(g.get('pPu', g.get('pMw', 0.0))) * (base_mva if 'pPu' in g else 1.0)
            v_pu = float(g.get('vPu', 1.0))
            is_slack = bool(g.get('isSlack', False))
            
            if is_slack and len(net.ext_grid[net.ext_grid.bus == bus_idx]) == 0:
                pp.create_ext_grid(net, bus=bus_idx, vm_pu=v_pu, va_degree=float(g.get('thetaDeg', 0.0)), name=g_id)
            else:
                pp.create_gen(net, bus=bus_idx, p_mw=p_mw, vm_pu=v_pu, name=g_id)

    # 4. 부하(Load) 생성
    for ld in loads_data:
        ld_id = str(ld.get('id', f'Load_{len(net.load)+1}'))
        parent = str(ld.get('parentBusId', ''))
        bus_id = element_to_bus.get(parent, parent)
        
        if bus_id in bus_map:
            bus_idx = bus_map[bus_id]
            p_mw = float(ld.get('pPu', ld.get('pMw', 0.0))) * (base_mva if 'pPu' in ld else 1.0)
            q_mvar = float(ld.get('qPu', ld.get('qMvar', 0.0))) * (base_mva if 'qPu' in ld else 1.0)
            pp.create_load(net, bus=bus_idx, p_mw=p_mw, q_mvar=q_mvar, name=ld_id)

    # 5. 선로(Line) 생성
    for l in lines_data:
        l_id = str(l.get('id', f'Line_{len(net.line)+1}'))
        start_raw = str(l.get('startElementId', ''))
        end_raw = str(l.get('endElementId', ''))
        
        from_bus_id = element_to_bus.get(start_raw, start_raw)
        to_bus_id = element_to_bus.get(end_raw, end_raw)
        
        if from_bus_id in bus_map and to_bus_id in bus_map:
            from_idx = bus_map[from_bus_id]
            to_idx = bus_map[to_bus_id]
            
            if from_idx != to_idx:
                r_pu = float(l.get('rPu', 0.01))
                x_pu = float(l.get('xPu', 0.05))
                z_base = (base_kv ** 2) / base_mva
                r_ohm = max(1e-4, r_pu * z_base)
                x_ohm = max(1e-4, x_pu * z_base)
                
                pp.create_line_from_parameters(
                    net,
                    from_bus=from_idx,
                    to_bus=to_idx,
                    length_km=1.0,
                    r_ohm_per_km=r_ohm,
                    x_ohm_per_km=x_ohm,
                    c_nf_per_km=0.0,
                    max_i_ka=1.0,
                    name=l_id
                )

    # 6. 변압기(Transformer) 생성
    for t in trafos_data:
        t_id = str(t.get('id', f'Trafo_{len(net.trafo)+1}'))
        start_raw = str(t.get('startElementId', t.get('hvBusId', '')))
        end_raw = str(t.get('endElementId', t.get('lvBusId', '')))
        
        hv_id = element_to_bus.get(start_raw, start_raw)
        lv_id = element_to_bus.get(end_raw, end_raw)
        
        if hv_id in bus_map and lv_id in bus_map:
            hv_idx = bus_map[hv_id]
            lv_idx = bus_map[lv_id]
            if hv_idx != lv_idx:
                pp.create_transformer_from_parameters(
                    net,
                    hv_bus=hv_idx,
                    lv_bus=lv_idx,
                    sn_mva=base_mva,
                    vn_hv_kv=base_kv,
                    vn_lv_kv=base_kv,
                    vkr_percent=1.0,
                    vk_percent=10.0,
                    pfe_kw=0.0,
                    i0_percent=0.0,
                    name=t_id
                )

    # 슬랙 모선이 없으면 0번 모선을 기본 슬랙으로 지정
    if len(net.ext_grid) == 0 and len(net.bus) > 0:
        pp.create_ext_grid(net, bus=0, vm_pu=1.0, va_degree=0.0, name="Auto_Slack_0")

    return net, bus_map


def render_single_line_diagram(net, title="Power Flow Single Line Diagram", return_format="base64"):
    """
    Pandapower 네트워크 및 조류 계산 결과를 단선도(Heatmap SLD) 이미지로 렌더링합니다.
    """
    # 1. 모든 모선에 유효한 시각화 좌표 생성/확인
    coords_dict = ensure_bus_coordinates(net)

    fig, ax = plt.subplots(figsize=(12, 9), dpi=160)
    
    # 2. 선로 부하율 컬러맵 컬렉션 생성
    if hasattr(net, 'res_line') and not net.res_line.empty and 'loading_percent' in net.res_line:
        max_load = max(50.0, float(net.res_line.loading_percent.max()) if len(net.res_line) > 0 else 50.0)
        norm_lines = mcolors.Normalize(vmin=0, vmax=max_load)
        line_lc = plot.create_line_collection(
            net,
            net.line.index,
            z=net.res_line.loading_percent,
            cmap=plt.cm.autumn_r,
            norm=norm_lines,
            linewidths=3.0,
            cbar_title="Line Loading [%]"
        )
    else:
        line_lc = plot.create_line_collection(net, net.line.index, color='dimgray', linewidths=2.0)

    # 3. 모선 전압 컬러맵 컬렉션 생성
    if hasattr(net, 'res_bus') and not net.res_bus.empty and 'vm_pu' in net.res_bus:
        norm_buses = mcolors.Normalize(vmin=0.94, vmax=1.06)
        bus_bc = plot.create_bus_collection(
            net,
            net.bus.index,
            size=0.07,
            z=net.res_bus.vm_pu,
            cmap=plt.cm.coolwarm,
            norm=norm_buses,
            cbar_title="Bus Voltage [p.u.]"
        )
    else:
        bus_bc = plot.create_bus_collection(net, net.bus.index, size=0.07, color='royalblue')

    ext_grid_ec = plot.create_ext_grid_collection(net, size=0.12, orientation=0) if len(net.ext_grid) > 0 else None
    load_lc = plot.create_load_collection(net, size=0.08) if len(net.load) > 0 else None
    gen_gc = plot.create_gen_collection(net, size=0.08) if len(net.gen) > 0 else None
    trafo_tc = plot.create_trafo_collection(net, size=0.08) if len(net.trafo) > 0 else None

    collections = [c for c in [line_lc, bus_bc, ext_grid_ec, load_lc, gen_gc, trafo_tc] if c is not None]
    plot.draw_collections(collections, ax=ax)

    # 4. 모선 라벨 및 전압 텍스트 오버레이
    for bus_id in net.bus.index:
        coords = coords_dict.get(bus_id)
        if coords:
            x, y = coords[0], coords[1]
            bus_name = net.bus.at[bus_id, 'name'] if 'name' in net.bus.columns else f'B{bus_id+1}'
            if hasattr(net, 'res_bus') and bus_id in net.res_bus.index:
                v_val = net.res_bus.at[bus_id, 'vm_pu']
                label_text = f"{bus_name}\n{v_val:.3f}pu"
            else:
                label_text = str(bus_name)
                
            ax.text(
                x, y + 0.10,
                label_text,
                fontsize=7,
                fontweight='bold',
                color='#0d47a1',
                ha='center',
                bbox=dict(boxstyle="round,pad=0.2", facecolor="white", alpha=0.85, edgecolor="#b0bec5")
            )

    ax.set_title(title, fontsize=14, fontweight='bold', pad=12)
    ax.autoscale_view()
    ax.set_aspect('equal')
    ax.axis('off')

    buf = io.BytesIO()
    plt.savefig(buf, format='png', bbox_inches='tight', facecolor='white')
    plt.close(fig)
    buf.seek(0)

    if return_format == "bytes":
        return buf.getvalue()
    elif return_format == "base64":
        return base64.b64encode(buf.getvalue()).decode('utf-8')
    return buf.getvalue()


def run_power_flow_simulation(elements=None, case_name=None, base_mva=100.0, base_kv=110.0, return_plot=True):
    """
    AC 조류 계산(Power Flow)을 수행하고 상세 결과 및 시각화 이미지를 반환합니다.
    """
    try:
        # 1. 계통 불러오기
        if case_name:
            case_lower = case_name.lower().replace('-', '').replace('_', '')
            case_loaders = {
                'case4gs': nw.case4gs,
                'case14': nw.case14,
                'case30': nw.case30,
                'case39': nw.case39,
                'case57': nw.case57,
                'case118': nw.case118,
            }
            loader = case_loaders.get(case_lower, nw.case30)
            net = loader()
            system_name = f"IEEE {case_name.upper()}"
        elif elements:
            net, bus_map = build_net_from_elements(elements, base_mva=base_mva, base_kv=base_kv)
            system_name = f"Custom Network ({len(net.bus)} Buses, {len(net.line)} Lines)"
        else:
            raise ValueError("elements 또는 case_name 중 하나를 제공해야 합니다.")

        if len(net.bus) == 0:
            raise ValueError("모선(Bus)이 존재하지 않아 조류 계산을 실행할 수 없습니다.")

        # 2. AC 조류 계산 실행 (Newton-Raphson)
        pp.runpp(net, algorithm='nr', max_iteration=25, tolerance_mva=1e-5, numba=False)

        # 3. 결과 파싱
        # (1) 모선 결과
        bus_results = []
        for idx in net.res_bus.index:
            bus_name = net.bus.at[idx, 'name'] if 'name' in net.bus.columns else f"Bus_{idx+1}"
            bus_results.append({
                "bus_index": int(idx),
                "name": str(bus_name),
                "vm_pu": round(float(net.res_bus.at[idx, 'vm_pu']), 4),
                "va_degree": round(float(net.res_bus.at[idx, 'va_degree']), 2),
                "p_mw": round(float(net.res_bus.at[idx, 'p_mw']), 4),
                "q_mvar": round(float(net.res_bus.at[idx, 'q_mvar']), 4)
            })

        # (2) 선로 결과
        line_results = []
        total_line_loss_mw = 0.0
        for idx in net.res_line.index:
            line_name = net.line.at[idx, 'name'] if 'name' in net.line.columns else f"Line_{idx+1}"
            from_b = int(net.line.at[idx, 'from_bus'])
            to_b = int(net.line.at[idx, 'to_bus'])
            p_from = float(net.res_line.at[idx, 'p_from_mw'])
            p_to = float(net.res_line.at[idx, 'p_to_mw'])
            loss_mw = abs(p_from + p_to)
            total_line_loss_mw += loss_mw
            
            line_results.append({
                "line_index": int(idx),
                "name": str(line_name),
                "from_bus": from_b,
                "to_bus": to_b,
                "p_from_mw": round(p_from, 4),
                "q_from_mvar": round(float(net.res_line.at[idx, 'q_from_mvar']), 4),
                "p_to_mw": round(p_to, 4),
                "q_to_mvar": round(float(net.res_line.at[idx, 'q_to_mvar']), 4),
                "loading_percent": round(float(net.res_line.at[idx, 'loading_percent']), 2),
                "loss_mw": round(loss_mw, 4)
            })

        # (3) 요약 메트릭
        total_gen_p = float(net.res_gen['p_mw'].sum()) if len(net.res_gen) > 0 else 0.0
        total_ext_grid_p = float(net.res_ext_grid['p_mw'].sum()) if len(net.res_ext_grid) > 0 else 0.0
        total_load_p = float(net.res_load['p_mw'].sum()) if len(net.res_load) > 0 else 0.0

        summary = {
            "converged": bool(net.converged),
            "total_buses": len(net.bus),
            "total_lines": len(net.line),
            "total_generation_mw": round(total_gen_p + total_ext_grid_p, 4),
            "total_load_mw": round(total_load_p, 4),
            "total_losses_mw": round(total_line_loss_mw, 4),
            "min_vm_pu": round(float(net.res_bus['vm_pu'].min()), 4),
            "max_vm_pu": round(float(net.res_bus['vm_pu'].max()), 4),
            "max_line_loading_pct": round(float(net.res_line['loading_percent'].max()), 2) if len(net.res_line) > 0 else 0.0
        }

        # (4) 단선도 이미지 렌더링
        plot_base64 = None
        if return_plot:
            plot_base64 = render_single_line_diagram(net, title=f"{system_name} - Power Flow Heatmap", return_format="base64")

        return {
            "status": "success",
            "message": f"⚡ {system_name} 조류 계산 완료! (수렴 성공)",
            "summary": summary,
            "bus_results": bus_results,
            "line_results": line_results,
            "plot_image_base64": plot_base64
        }

    except Exception as e:
        return {
            "status": "error",
            "message": f"❌ 조류 계산 실패: {str(e)}"
        }
