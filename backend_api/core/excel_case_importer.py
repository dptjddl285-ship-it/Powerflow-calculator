# -*- coding: utf-8 -*-
"""
Excel Power Flow Case Importer & Auto-Mapper
Supports standard power system Excel cases (e.g. ac_case25, IEEE 24, IEEE 39, MATPOWER format).
Automatically identifies the Slack/Swing Bus, assigns load (P, Q), generator (PG, QG, Vset),
branch impedances (R, X, B), and transformer tap ratios to verified diagram elements.
"""

import io
import os
import pandas as pd
import numpy as np
from typing import Any, Dict, List, Optional, Tuple, Union

class ExcelCaseImporter:
    def __init__(self, sbase_default: float = 100.0):
        self.sbase_default = sbase_default

    def parse_excel(self, excel_source: Union[str, bytes, io.BytesIO]) -> Dict[str, Any]:
        """
        Parses all sheets in the Excel workbook and extracts standardized power flow data.
        """
        if isinstance(excel_source, bytes):
            excel_source = io.BytesIO(excel_source)
            
        xl = pd.ExcelFile(excel_source)
        sheet_names_lower = {s.lower().strip(): s for s in xl.sheet_names}
        
        # 1. Base MVA
        sbase = self.sbase_default
        if 'param' in sheet_names_lower:
            try:
                df_param = pd.read_excel(xl, sheet_name=sheet_names_lower['param'])
                for col in df_param.columns:
                    col_str = str(col).lower()
                    if 'sbase' in col_str or '100' in col_str:
                        val = str(df_param.columns[1]) if len(df_param.columns) > 1 else None
                        if val and val.replace('.', '', 1).isdigit():
                            sbase = float(val)
            except Exception:
                pass

        # 2. Bus Sheet
        bus_dict = {}
        slack_bus_no = None
        if 'bus' in sheet_names_lower:
            df_bus = pd.read_excel(xl, sheet_name=sheet_names_lower['bus'])
            bus_col = next((c for c in df_bus.columns if 'bus' in c.lower()), df_bus.columns[0])
            type_col = next((c for c in df_bus.columns if 'type' in c.lower()), None)
            pload_col = next((c for c in df_bus.columns if 'pload' in c.lower()), None)
            qload_col = next((c for c in df_bus.columns if 'qload' in c.lower()), None)
            vm_col = next((c for c in df_bus.columns if c.lower().startswith('vm')), None)
            va_col = next((c for c in df_bus.columns if c.lower().startswith('va')), None)
            max_vm_col = next((c for c in df_bus.columns if 'maxvm' in c.lower()), None)
            min_vm_col = next((c for c in df_bus.columns if 'minvm' in c.lower()), None)

            for _, row in df_bus.iterrows():
                try:
                    b_no = int(row[bus_col])
                except (ValueError, TypeError):
                    continue
                    
                b_type_str = str(row[type_col]).strip() if type_col else 'PQ'
                is_slack = 'swing' in b_type_str.lower() or 'slack' in b_type_str.lower() or b_type_str == '3'
                is_pv = 'pv' in b_type_str.lower() or b_type_str == '2' or 'condenser' in b_type_str.lower() or 'syn' in b_type_str.lower() or 'sc' in b_type_str.lower()
                if is_slack:
                    slack_bus_no = b_no
                    
                p_mw = float(row[pload_col]) if pload_col and pd.notna(row[pload_col]) else 0.0
                q_mvar = float(row[qload_col]) if qload_col and pd.notna(row[qload_col]) else 0.0
                vm = float(row[vm_col]) if vm_col and pd.notna(row[vm_col]) else 1.0
                va = float(row[va_col]) if va_col and pd.notna(row[va_col]) else 0.0
                max_vm = float(row[max_vm_col]) if max_vm_col and pd.notna(row[max_vm_col]) else 1.05
                min_vm = float(row[min_vm_col]) if min_vm_col and pd.notna(row[min_vm_col]) else 0.95

                bus_info = {
                    'bus_number': b_no,
                    'type': 'Swing' if is_slack else ('PV' if is_pv else 'PQ'),
                    'is_slack': is_slack,
                    'pload_mw': p_mw,
                    'qload_mvar': q_mvar,
                    'pload_pu': round(p_mw / sbase, 5),
                    'qload_pu': round(q_mvar / sbase, 5),
                    'vm_pu': vm,
                    'va_deg': va,
                    'max_vm': max_vm,
                    'min_vm': min_vm,
                }
                bus_dict[str(b_no)] = bus_info

        # 3. Generator Sheet
        gen_by_bus = {}
        if 'generator' in sheet_names_lower:
            df_gen = pd.read_excel(xl, sheet_name=sheet_names_lower['generator'])
            bus_col = next((c for c in df_gen.columns if 'bus' in c.lower()), None)
            pg_col = next((c for c in df_gen.columns if 'pg' in c.lower()), None)
            qg_col = next((c for c in df_gen.columns if 'qg' in c.lower()), None)
            vset_col = next((c for c in df_gen.columns if 'voltage setpoint' in c.lower() or 'vset' in c.lower() or 'vg' in c.lower()), None)
            status_col = next((c for c in df_gen.columns if 'status' in c.lower()), None)

            for _, row in df_gen.iterrows():
                if status_col and row[status_col] == 0:
                    continue
                try:
                    b_no = int(row[bus_col])
                except (ValueError, TypeError):
                    continue
                    
                pg = float(row[pg_col]) if pg_col and pd.notna(row[pg_col]) else 0.0
                qg = float(row[qg_col]) if qg_col and pd.notna(row[qg_col]) else 0.0
                vset = float(row[vset_col]) if vset_col and pd.notna(row[vset_col]) else 1.0

                s_b_no = str(b_no)
                if s_b_no not in gen_by_bus:
                    gen_by_bus[s_b_no] = {
                        'bus_number': b_no,
                        'is_slack': (b_no == slack_bus_no),
                        'pg_mw': 0.0,
                        'qg_mvar': 0.0,
                        'voltage_setpoint': vset,
                        'gen_count': 0
                    }
                # For slack generator, P and Q are determined by power flow balance, not input constraints
                if b_no != slack_bus_no:
                    gen_by_bus[s_b_no]['pg_mw'] += pg
                    gen_by_bus[s_b_no]['qg_mvar'] += qg
                gen_by_bus[s_b_no]['gen_count'] += 1
                gen_by_bus[s_b_no]['voltage_setpoint'] = vset

            # Calculate per unit
            for s_b_no, g in gen_by_bus.items():
                g['pg_pu'] = round(g['pg_mw'] / sbase, 5)
                g['qg_pu'] = round(g['qg_mvar'] / sbase, 5)

        # 4. Branch / Line Sheet
        branch_dict = {}
        if 'branch' in sheet_names_lower:
            df_br = pd.read_excel(xl, sheet_name=sheet_names_lower['branch'])
            from_col = next((c for c in df_br.columns if 'from' in c.lower()), df_br.columns[0])
            to_col = next((c for c in df_br.columns if 'to' in c.lower()), df_br.columns[1])
            r_col = next((c for c in df_br.columns if c.strip().lower().startswith('r')), None)
            x_col = next((c for c in df_br.columns if c.strip().lower().startswith('x')), None)
            b_col = next((c for c in df_br.columns if c.strip().lower().startswith('b')), None)

            pair_branches = {}
            for _, row in df_br.iterrows():
                try:
                    f_b = int(row[from_col])
                    t_b = int(row[to_col])
                except (ValueError, TypeError):
                    continue
                r_val = float(row[r_col]) if r_col and pd.notna(row[r_col]) else 0.01
                x_val = float(row[x_col]) if x_col and pd.notna(row[x_col]) else 0.05
                b_val = float(row[b_col]) if b_col and pd.notna(row[b_col]) else 0.0
                pair_key = (min(f_b, t_b), max(f_b, t_b))
                pair_branches.setdefault(pair_key, []).append({'r': r_val, 'x': x_val, 'b': b_val})

            for (fb, tb), c_list in pair_branches.items():
                if len(c_list) == 1:
                    r_eq, x_eq, b_eq = c_list[0]['r'], c_list[0]['x'], c_list[0]['b']
                else:
                    y_tot = sum(1.0 / complex(c['r'], c['x']) for c in c_list)
                    z_eq = 1.0 / y_tot
                    r_eq = z_eq.real
                    x_eq = z_eq.imag
                    b_eq = sum(c['b'] for c in c_list)

                br_info = {
                    'from_bus': fb, 'to_bus': tb,
                    'r_pu': r_eq, 'x_pu': x_eq, 'b_pu': b_eq,
                    'circuit_count': len(c_list)
                }
                branch_dict[f"{fb}_{tb}"] = br_info
                branch_dict[f"{tb}_{fb}"] = br_info

        # 5. Transformer Sheet
        trans_dict = {}
        if 'transformer' in sheet_names_lower:
            df_tr = pd.read_excel(xl, sheet_name=sheet_names_lower['transformer'])
            from_col = next((c for c in df_tr.columns if 'from' in c.lower()), df_tr.columns[0])
            to_col = next((c for c in df_tr.columns if 'to' in c.lower()), df_tr.columns[1])
            tap_col = next((c for c in df_tr.columns if 'tap' in c.lower()), None)

            for _, row in df_tr.iterrows():
                try:
                    f_b = int(row[from_col])
                    t_b = int(row[to_col])
                except (ValueError, TypeError):
                    continue
                tap = float(row[tap_col]) if tap_col and pd.notna(row[tap_col]) else 1.0
                tr_info = {'from_bus': f_b, 'to_bus': t_b, 'tap': tap}
                trans_dict[f"{f_b}_{t_b}"] = tr_info
                trans_dict[f"{t_b}_{f_b}"] = tr_info

        return {
            'sbase_mva': sbase,
            'slack_bus_number': slack_bus_no,
            'buses': bus_dict,
            'generators': gen_by_bus,
            'branches': branch_dict,
            'transformers': trans_dict,
            'total_buses': len(bus_dict),
            'total_generators': len(gen_by_bus),
            'total_branches': len(branch_dict) // 2
        }

    def apply_to_elements(
        self,
        elements: List[Dict[str, Any]],
        excel_data: Dict[str, Any]
    ) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        """
        Maps the parsed Excel case parameters directly onto the Flutter canvas DrawingElement list.
        """
        bus_dict = excel_data.get('buses', {})
        gen_by_bus = excel_data.get('generators', {})
        branch_dict = excel_data.get('branches', {})
        trans_dict = excel_data.get('transformers', {})
        slack_bus_no = excel_data.get('slack_bus_number')
        sbase = float(excel_data.get('sbase_mva', 100.0))

        applied_counts = {'bus': 0, 'generator': 0, 'load': 0, 'line': 0, 'transformer': 0}
        
        # Build ID lookup and type lookup
        el_by_id = {str(el.get('id')): el for el in elements if el.get('id') is not None}

        def get_el_type(e):
            if not e:
                return ''
            return str(e.get('type') or e.get('class') or e.get('class_name') or '').lower()

        def get_line_endpoints(l):
            s_id = l.get('startElementId')
            e_id = l.get('endElementId')
            conns = l.get('connected_to') or []
            if s_id is None and len(conns) > 0:
                s_id = conns[0]
            if e_id is None and len(conns) > 1:
                e_id = conns[1]
            return (str(s_id) if s_id is not None else None, str(e_id) if e_id is not None else None)

        el_id_to_bus_num = {}
        for el in elements:
            el_type = get_el_type(el)
            if 'bus' in el_type and not any(k in el_type for k in ('gen', 'load', 'trans')):
                b_num = el.get('bus_number')
                if b_num is None and el.get('label'):
                    import re
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is None and el.get('id'):
                    import re
                    m = re.search(r'bus_(\d+)', str(el.get('id')))
                    if m:
                        b_num = int(m.group(1))
                    else:
                        digits = ''.join(c for c in str(el.get('id')) if c.isdigit())
                        if digits:
                            b_num = int(digits)
                if b_num is not None and el.get('id') is not None:
                    el_id_to_bus_num[str(el['id'])] = b_num

        # Pre-resolve Transformers and their connecting lines
        trans_branch_map = {}
        trans_lead_line_ids = set()

        for tr in elements:
            tr_type = get_el_type(tr)
            if 'trans' in tr_type:
                t_id = str(tr.get('id'))
                conn_buses = []
                conn_lines = []

                for l in elements:
                    if 'line' in get_el_type(l):
                        s_id, e_id = get_line_endpoints(l)
                        if s_id == t_id or e_id == t_id:
                            conn_lines.append(l)
                            if l.get('id') is not None:
                                trans_lead_line_ids.add(str(l.get('id')))
                            other_id = e_id if s_id == t_id else s_id
                            b = el_id_to_bus_num.get(other_id)
                            if b is not None and b not in conn_buses:
                                conn_buses.append(b)

                fb = conn_buses[0] if len(conn_buses) > 0 else None
                tb = conn_buses[1] if len(conn_buses) > 1 else None

                if fb is None or tb is None:
                    import re
                    m = re.search(r'(\d+)\s*[-~_↔]\s*(\d+)', str(tr.get('label') or tr.get('id') or ''))
                    if m:
                        fb = fb or int(m.group(1))
                        tb = tb or int(m.group(2))

                if fb is not None and tb is None:
                    for k, v in trans_dict.items():
                        if v.get('from_bus') == fb or v.get('to_bus') == fb:
                            tb = v.get('to_bus') if v.get('from_bus') == fb else v.get('from_bus')
                            break

                trans_branch_map[t_id] = {
                    'fb': fb,
                    'tb': tb,
                    'conn_lines': conn_lines,
                }

        applied_gen_buses = set()
        for el in elements:
            el_type = get_el_type(el)
            
            # 1. Bus
            if 'bus' in el_type and not any(k in el_type for k in ('gen', 'load', 'trans')):
                b_num = el_id_to_bus_num.get(str(el.get('id')))
                b_info = bus_dict.get(str(b_num)) or bus_dict.get(b_num)
                if b_info:
                    el['isSlack'] = b_info['is_slack']
                    el['vPu'] = b_info['vm_pu']
                    el['thetaDeg'] = b_info['va_deg']
                    el['pPu'] = b_info['pload_pu']
                    el['qPu'] = b_info['qload_pu']
                    el['bus_type'] = b_info['type']
                    el['maxVm'] = b_info['max_vm']
                    el['minVm'] = b_info['min_vm']
                    applied_counts['bus'] += 1

            # 2. Generator
            elif 'gen' in el_type:
                parent_id = str(el.get('parentBusId') or '')
                b_num = el.get('bus_number') or el.get('connected_bus_number') or el_id_to_bus_num.get(parent_id)
                if b_num is None and el.get('label'):
                    import re
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m: b_num = int(m.group(1))
                if b_num is None and el.get('id'):
                    import re
                    m = re.search(r'(\d+)', str(el.get('id')))
                    if m: b_num = int(m.group(1))

                g_info = gen_by_bus.get(str(b_num)) or gen_by_bus.get(b_num)
                if g_info:
                    el['isSlack'] = g_info['is_slack']
                    el['pPu'] = g_info['pg_pu']
                    el['qPu'] = g_info['qg_pu']
                    el['vPu'] = g_info['voltage_setpoint']
                    is_sc = (not g_info['is_slack']) and (g_info['pg_pu'] == 0 or abs(g_info['pg_pu']) < 1e-4)
                    el['isSynchronousCondenser'] = is_sc
                    if is_sc:
                        el['label'] = f"SC_{b_num} (동기조상기)"
                    else:
                        el['label'] = f"G_{b_num}" + (" (Slack)" if g_info['is_slack'] else "")
                    applied_counts['generator'] += 1
                    if b_num is not None:
                        applied_gen_buses.add(int(b_num))

            # 3. Load
            elif 'load' in el_type:
                parent_id = str(el.get('parentBusId') or '')
                b_num = el.get('bus_number') or el.get('connected_bus_number') or el_id_to_bus_num.get(parent_id)
                if b_num is None and el.get('label'):
                    import re
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m: b_num = int(m.group(1))
                if b_num is None and el.get('id'):
                    import re
                    m = re.search(r'(\d+)', str(el.get('id')))
                    if m: b_num = int(m.group(1))

                b_info = bus_dict.get(str(b_num)) or bus_dict.get(b_num)
                if b_info:
                    el['pPu'] = b_info['pload_pu']
                    el['qPu'] = b_info['qload_pu']
                    el['label'] = f"Load_{b_num}"
                    applied_counts['load'] += 1

            # 4. Transformer
            elif 'trans' in el_type:
                t_id = str(el.get('id'))
                t_branch = trans_branch_map.get(t_id, {})
                fb = t_branch.get('fb')
                tb = t_branch.get('tb')
                conn_lines = t_branch.get('conn_lines', [])

                tr_info = trans_dict.get(f"{fb}_{tb}") or trans_dict.get(f"{tb}_{fb}") or trans_dict.get((fb, tb))
                br_info = branch_dict.get(f"{fb}_{tb}") or branch_dict.get(f"{tb}_{fb}") or branch_dict.get((fb, tb))

                tap = tr_info['tap'] if tr_info else 1.0
                r_val = br_info['r_pu'] if br_info else 0.0023
                x_val = br_info['x_pu'] if br_info else 0.0839
                b_val = br_info.get('b_pu', 0.0) if br_info else 0.0

                el['tapRatio'] = tap
                el['tap'] = tap
                el['rPu'] = r_val
                el['xPu'] = x_val
                el['bPu'] = b_val
                if fb is not None and tb is not None:
                    el['label'] = f"T {fb}-{tb} (Tap: {tap})"
                applied_counts['transformer'] += 1

                # Connecting lines to a transformer reflect the branch impedance
                for l in conn_lines:
                    l['rPu'] = r_val
                    l['xPu'] = x_val
                    l['bPu'] = b_val
                    l['tapRatio'] = tap
                    l['tap'] = tap
                    if fb is not None and tb is not None:
                        l['label'] = f"Line {fb}-{tb} (T: {tap})"
                    applied_counts['line'] += 1

            # 5. Normal Line (not connected to a transformer)
            elif 'line' in el_type:
                if str(el.get('id')) in trans_lead_line_ids:
                    # Already updated via its transformer
                    continue

                start_id, end_id = get_line_endpoints(el)
                s_el = el_by_id.get(start_id)
                e_el = el_by_id.get(end_id)
                s_type = get_el_type(s_el)
                e_type = get_el_type(e_el)
                s_str = str(start_id or '').lower()
                e_str = str(end_id or '').lower()
                lbl_str = str(el.get('label') or '').lower()
                id_str = str(el.get('id') or '').lower()

                fb = el_id_to_bus_num.get(start_id)
                tb = el_id_to_bus_num.get(end_id)

                # Check if this line is a terminal connection lead to a Generator or Load
                is_gen = 'gen' in s_type or 'gen' in e_type or 'gen' in s_str or 'gen' in e_str or 'g_' in s_str or 'g_' in e_str or 'gen' in lbl_str or 'gen' in id_str
                is_load = 'load' in s_type or 'load' in e_type or 'load' in s_str or 'load' in e_str or 'load' in lbl_str or 'load' in id_str

                if is_gen:
                    gen_el = s_el if ('gen' in s_type or 'gen' in s_str or 'g_' in s_str) else e_el
                    bus_el = e_el if gen_el == s_el else s_el
                    b_num = el_id_to_bus_num.get(str(bus_el.get('id'))) if bus_el and bus_el.get('id') is not None else (fb if fb is not None else tb)
                    if b_num is None and gen_el:
                        b_num = gen_el.get('bus_number') or gen_el.get('connected_bus_number')
                        if b_num is None and gen_el.get('parentBusId'):
                            b_num = el_id_to_bus_num.get(str(gen_el.get('parentBusId')))
                        if b_num is None and gen_el.get('label'):
                            import re
                            m = re.search(r'(\d+)', str(gen_el.get('label')))
                            if m: b_num = int(m.group(1))
                        if b_num is None and gen_el.get('id'):
                            import re
                            m = re.search(r'(\d+)', str(gen_el.get('id')))
                            if m: b_num = int(m.group(1))
                    if b_num is None and el.get('label'):
                        import re
                        m = re.search(r'(\d+)', str(el.get('label')))
                        if m: b_num = int(m.group(1))

                    el['rPu'] = 0.0
                    el['xPu'] = 0.0
                    el['bPu'] = 0.0
                    el['tapRatio'] = 1.0
                    if b_num is not None:
                        g_info = gen_by_bus.get(str(b_num)) or gen_by_bus.get(b_num)
                        if g_info:
                            el['pPu'] = g_info.get('pg_pu', 0.0)
                            el['qPu'] = g_info.get('qg_pu', 0.0)
                            p_mw = g_info.get('pg_mw', round(el['pPu'] * sbase, 1))
                            el['label'] = f"Line Bus {b_num} ↔ G_{b_num} ({p_mw:.1f} MW)"
                        else:
                            el['pPu'] = 0.0
                            el['qPu'] = 0.0
                            el['label'] = f"Line Bus {b_num} ↔ G_{b_num}"
                    else:
                        el['pPu'] = 0.0
                        el['qPu'] = 0.0
                    applied_counts['line'] += 1
                    continue

                if is_load:
                    load_el = s_el if ('load' in s_type or 'load' in s_str) else e_el
                    bus_el = e_el if load_el == s_el else s_el
                    b_num = el_id_to_bus_num.get(str(bus_el.get('id'))) if bus_el and bus_el.get('id') is not None else (fb if fb is not None else tb)
                    if b_num is None and load_el:
                        b_num = load_el.get('bus_number') or load_el.get('connected_bus_number')
                        if b_num is None and load_el.get('parentBusId'):
                            b_num = el_id_to_bus_num.get(str(load_el.get('parentBusId')))
                        if b_num is None and load_el.get('label'):
                            import re
                            m = re.search(r'(\d+)', str(load_el.get('label')))
                            if m: b_num = int(m.group(1))
                        if b_num is None and load_el.get('id'):
                            import re
                            m = re.search(r'(\d+)', str(load_el.get('id')))
                            if m: b_num = int(m.group(1))
                    if b_num is None and el.get('label'):
                        import re
                        m = re.search(r'(\d+)', str(el.get('label')))
                        if m: b_num = int(m.group(1))

                    el['rPu'] = 0.0
                    el['xPu'] = 0.0
                    el['bPu'] = 0.0
                    el['tapRatio'] = 1.0
                    if b_num is not None:
                        b_info = bus_dict.get(str(b_num)) or bus_dict.get(b_num)
                        if b_info:
                            el['pPu'] = b_info.get('pload_pu', 0.0)
                            el['qPu'] = b_info.get('qload_pu', 0.0)
                            p_mw = b_info.get('pload_mw', round(el['pPu'] * sbase, 1))
                            el['label'] = f"Line Bus {b_num} ↔ Load_{b_num} ({p_mw:.1f} MW)"
                        else:
                            el['pPu'] = 0.0
                            el['qPu'] = 0.0
                            el['label'] = f"Line Bus {b_num} ↔ Load_{b_num}"
                    else:
                        el['pPu'] = 0.0
                        el['qPu'] = 0.0
                    applied_counts['line'] += 1
                    continue

                # Also skip lead lines that have lead prefix or ↔ in name
                is_lead = ('lead' in id_str or '↔' in str(el.get('label') or '') or 'lead' in lbl_str)
                if is_lead:
                    el['rPu'] = 0.0
                    el['xPu'] = 0.0
                    el['bPu'] = 0.0
                    el['tapRatio'] = 1.0
                    continue

                if fb is None or tb is None:
                    import re
                    m = re.search(r'(\d+)\s*[-~_]\s*(\d+)', str(el.get('label') or el.get('id') or ''))
                    if m:
                        fb, tb = int(m.group(1)), int(m.group(2))

                br_info = branch_dict.get(f"{fb}_{tb}") or branch_dict.get(f"{tb}_{fb}") or branch_dict.get((fb, tb))
                if br_info:
                    el['rPu'] = br_info['r_pu']
                    el['xPu'] = br_info['x_pu']
                    el['bPu'] = br_info.get('b_pu', 0.0)
                    c_count = br_info.get('circuit_count', 1)
                    el['circuitCount'] = c_count
                    if c_count > 1:
                        el['isDoubleCircuit'] = True
                        el['label'] = f"Line {fb}-{tb} ({c_count}회선 병렬 등가)"
                    applied_counts['line'] += 1

                # Check if this branch is also a transformer with off-nominal tap
                tr_info = trans_dict.get(f"{fb}_{tb}") or trans_dict.get(f"{tb}_{fb}") or trans_dict.get((fb, tb))
                if tr_info:
                    el['tapRatio'] = tr_info['tap']
                    el['tap'] = tr_info['tap']
                    applied_counts['transformer'] += 1
        # Ensure all generators from Excel exist in elements (e.g. Bus 14 missing on diagram)
        for b_str, g_info in gen_by_bus.items():
            b_num = int(b_str)
            if b_num not in applied_gen_buses:
                target_bus_id = None
                for bid, bno in el_id_to_bus_num.items():
                    if bno == b_num:
                        target_bus_id = bid
                        break
                if target_bus_id:
                    auto_gen = {
                        'id': f"gen_auto_{b_num}",
                        'type': 'generator',
                        'parentBusId': target_bus_id,
                        'bus_number': b_num,
                        'isSlack': g_info['is_slack'],
                        'pPu': g_info['pg_pu'],
                        'qPu': g_info['qg_pu'],
                        'vPu': g_info['voltage_setpoint'],
                        'label': f"G_{b_num}" + (" (Slack)" if g_info['is_slack'] else ""),
                    }
                    elements.append(auto_gen)
                    applied_counts['generator'] += 1

        summary = {
            'slack_bus_number': slack_bus_no,
            'applied_counts': applied_counts,
            'total_elements_updated': sum(applied_counts.values())
        }
        return elements, summary
