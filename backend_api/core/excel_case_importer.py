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
                    'type': 'Swing' if is_slack else ('PV' if 'pv' in b_type_str.lower() else 'PQ'),
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

            for _, row in df_br.iterrows():
                try:
                    f_b = int(row[from_col])
                    t_b = int(row[to_col])
                except (ValueError, TypeError):
                    continue
                r_val = float(row[r_col]) if r_col and pd.notna(row[r_col]) else 0.01
                x_val = float(row[x_col]) if x_col and pd.notna(row[x_col]) else 0.05
                b_val = float(row[b_col]) if b_col and pd.notna(row[b_col]) else 0.0
                
                br_info = {'from_bus': f_b, 'to_bus': t_b, 'r_pu': r_val, 'x_pu': x_val, 'b_pu': b_val}
                branch_dict[f"{f_b}_{t_b}"] = br_info
                branch_dict[f"{t_b}_{f_b}"] = br_info

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

        applied_counts = {'bus': 0, 'generator': 0, 'load': 0, 'line': 0, 'transformer': 0}
        
        el_id_to_bus_num = {}
        for el in elements:
            el_type = str(el.get('type', '')).lower()
            if 'bus' in el_type:
                b_num = el.get('bus_number')
                if b_num is None and el.get('label'):
                    digits = ''.join(c for c in str(el.get('label')) if c.isdigit())
                    if digits:
                        b_num = int(digits)
                if b_num is None and el.get('id'):
                    digits = ''.join(c for c in str(el.get('id')).split('_')[-1] if c.isdigit())
                    if digits:
                        b_num = int(digits)
                if b_num is not None:
                    el_id_to_bus_num[el['id']] = b_num

        for el in elements:
            el_type = str(el.get('type', '')).lower()
            
            # 1. Bus
            if 'bus' in el_type and not ('gen' in el_type or 'load' in el_type):
                b_num = el_id_to_bus_num.get(el['id'])
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
                parent_id = el.get('parentBusId')
                b_num = el.get('bus_number') or el.get('connected_bus_number') or el_id_to_bus_num.get(parent_id)
                g_info = gen_by_bus.get(str(b_num)) or gen_by_bus.get(b_num)
                if g_info:
                    el['isSlack'] = g_info['is_slack']
                    el['pPu'] = g_info['pg_pu']
                    el['qPu'] = g_info['qg_pu']
                    el['vPu'] = g_info['voltage_setpoint']
                    el['label'] = f"G_{b_num}" + (" (Slack)" if g_info['is_slack'] else "")
                    applied_counts['generator'] += 1

            # 3. Load
            elif 'load' in el_type:
                parent_id = el.get('parentBusId')
                b_num = el.get('bus_number') or el.get('connected_bus_number') or el_id_to_bus_num.get(parent_id)
                b_info = bus_dict.get(str(b_num)) or bus_dict.get(b_num)
                if b_info:
                    el['pPu'] = b_info['pload_pu']
                    el['qPu'] = b_info['qload_pu']
                    el['label'] = f"Load_{b_num}"
                    applied_counts['load'] += 1

            # 4. Line
            elif 'line' in el_type:
                start_id = el.get('startElementId')
                end_id = el.get('endElementId')
                fb = el_id_to_bus_num.get(start_id)
                tb = el_id_to_bus_num.get(end_id)
                br_info = branch_dict.get(f"{fb}_{tb}") or branch_dict.get(f"{tb}_{fb}") or branch_dict.get((fb, tb))
                if br_info:
                    el['rPu'] = br_info['r_pu']
                    el['xPu'] = br_info['x_pu']
                    applied_counts['line'] += 1

            # 5. Transformer
            elif 'trans' in el_type:
                start_id = el.get('startElementId')
                end_id = el.get('endElementId')
                fb = el_id_to_bus_num.get(start_id)
                tb = el_id_to_bus_num.get(end_id)
                tr_info = trans_dict.get(f"{fb}_{tb}") or trans_dict.get(f"{tb}_{fb}") or trans_dict.get((fb, tb))
                if tr_info:
                    el['tapRatio'] = tr_info['tap']
                    el['tap'] = tr_info['tap']
                    applied_counts['transformer'] += 1

        summary = {
            'slack_bus_number': slack_bus_no,
            'applied_counts': applied_counts,
            'total_elements_updated': sum(applied_counts.values())
        }
        return elements, summary
