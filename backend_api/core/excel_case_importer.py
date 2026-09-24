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
                    'provided_fields': [
                        name for name, column in (
                            ('type', type_col),
                            ('is_slack', type_col),
                            ('pload_pu', pload_col),
                            ('qload_pu', qload_col),
                            ('vm_pu', vm_col),
                            ('va_deg', va_col),
                        ) if column is not None and pd.notna(row[column])
                    ],
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
                provided_gen_fields = [
                    name for name, column in (
                        ('pg_pu', pg_col),
                        ('qg_pu', qg_col),
                        ('voltage_setpoint', vset_col),
                    ) if column is not None and pd.notna(row[column])
                ]

                s_b_no = str(b_no)
                if s_b_no not in gen_by_bus:
                    gen_by_bus[s_b_no] = {
                        'bus_number': b_no,
                        'is_slack': (b_no == slack_bus_no),
                        'pg_mw': 0.0,
                        'qg_mvar': 0.0,
                        'voltage_setpoint': vset,
                        'gen_count': 0,
                        'provided_fields': set(provided_gen_fields),
                    }
                else:
                    gen_by_bus[s_b_no]['provided_fields'].intersection_update(provided_gen_fields)
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
                g['provided_fields'] = sorted(g['provided_fields'])

        # 4. Branch / Line Sheet
        branch_dict = {}
        if 'branch' in sheet_names_lower:
            df_br = pd.read_excel(xl, sheet_name=sheet_names_lower['branch'])
            if not df_br.empty and len(df_br.columns) >= 2:
                from_col = next((c for c in df_br.columns if 'from' in c.lower()), df_br.columns[0])
                to_col = next((c for c in df_br.columns if 'to' in c.lower()), df_br.columns[1])
                r_col = next((c for c in df_br.columns if c.strip().lower().startswith('r')), None)
                x_col = next((c for c in df_br.columns if c.strip().lower().startswith('x')), None)
                b_col = next((c for c in df_br.columns if c.strip().lower().startswith('b')), None)
                tap_col = next((c for c in df_br.columns if 'tap' in c.lower() or 'ratio' in c.lower()), None)

                pair_branches = {}
                for _, row in df_br.iterrows():
                    try:
                        f_b = int(row[from_col])
                        t_b = int(row[to_col])
                    except (ValueError, TypeError):
                        continue
                    r_val = float(row[r_col]) if r_col and pd.notna(row[r_col]) else None
                    x_val = float(row[x_col]) if x_col and pd.notna(row[x_col]) else None
                    b_provided = bool(b_col and pd.notna(row[b_col]))
                    b_val = float(row[b_col]) if b_provided else 0.0
                    tap_provided = bool(tap_col and pd.notna(row[tap_col]))
                    tap_val = float(row[tap_col]) if tap_provided else None
                    pair_key = (min(f_b, t_b), max(f_b, t_b))
                    pair_branches.setdefault(pair_key, []).append({
                        'r': r_val,
                        'x': x_val,
                        'b': b_val,
                        'b_provided': b_provided,
                        'tap': tap_val,
                        'tap_provided': tap_provided,
                    })

                for (fb, tb), c_list in pair_branches.items():
                    has_missing = any(c['r'] is None or c['x'] is None for c in c_list)
                    if has_missing:
                        r_eq, x_eq = None, None
                    elif len(c_list) == 1:
                        r_eq, x_eq = c_list[0]['r'], c_list[0]['x']
                    else:
                        if any(abs(c['r']) < 1e-9 and abs(c['x']) < 1e-9 for c in c_list):
                            r_eq, x_eq = 0.0, 0.0
                        else:
                            y_tot = sum(1.0 / complex(c['r'], c['x']) for c in c_list)
                            z_eq = 1.0 / y_tot
                            r_eq = z_eq.real
                            x_eq = z_eq.imag
                    b_eq = sum(c['b'] for c in c_list) if all(c['b_provided'] for c in c_list) else None
                    provided_taps = [c['tap'] for c in c_list if c['tap_provided']]
                    tap_is_consistent = (
                        len(provided_taps) == len(c_list)
                        and bool(provided_taps)
                        and all(abs(value - provided_taps[0]) <= 1e-9 for value in provided_taps)
                    )
                    tap_eq = provided_taps[0] if tap_is_consistent else None

                    br_info = {
                        'from_bus': fb, 'to_bus': tb,
                        'r_pu': r_eq, 'x_pu': x_eq, 'b_pu': b_eq,
                        'circuit_count': len(c_list),
                        'tap': tap_eq,
                        'requires_tap': bool(provided_taps),
                        'provided_fields': [
                            name for name, value in (
                                ('r_pu', r_eq), ('x_pu', x_eq), ('b_pu', b_eq), ('tap', tap_eq),
                            ) if value is not None
                        ],
                    }
                    branch_dict[f"{fb}_{tb}"] = br_info
                    branch_dict[f"{tb}_{fb}"] = br_info

        # 5. Transformer Sheet
        trans_dict = {}
        if 'transformer' in sheet_names_lower:
            df_tr = pd.read_excel(xl, sheet_name=sheet_names_lower['transformer'])
            if not df_tr.empty and len(df_tr.columns) >= 2:
                from_col = next((c for c in df_tr.columns if 'from' in c.lower()), df_tr.columns[0])
                to_col = next((c for c in df_tr.columns if 'to' in c.lower()), df_tr.columns[1])
                tap_col = next((c for c in df_tr.columns if 'tap' in c.lower() or 'ratio' in c.lower()), None)
                r_col = next((c for c in df_tr.columns if c.strip().lower().startswith('r')), None)
                x_col = next((c for c in df_tr.columns if c.strip().lower().startswith('x')), None)
                b_col = next((c for c in df_tr.columns if c.strip().lower().startswith('b')), None)

                for _, row in df_tr.iterrows():
                    try:
                        f_b = int(row[from_col])
                        t_b = int(row[to_col])
                    except (ValueError, TypeError):
                        continue
                    tap_provided = bool(tap_col and pd.notna(row[tap_col]))
                    tap = float(row[tap_col]) if tap_provided else 1.0
                    r_val = float(row[r_col]) if r_col and pd.notna(row[r_col]) else None
                    x_val = float(row[x_col]) if x_col and pd.notna(row[x_col]) else None
                    b_val = float(row[b_col]) if b_col and pd.notna(row[b_col]) else None
                    provided_tr_fields = set()
                    if tap_provided:
                        provided_tr_fields.add('tap')
                    if r_val is not None:
                        provided_tr_fields.add('r_pu')
                    if x_val is not None:
                        provided_tr_fields.add('x_pu')
                    if b_val is not None:
                        provided_tr_fields.add('b_pu')

                    # If r, x, b were not in transformer sheet, look up in branch_dict
                    if r_val is None or x_val is None:
                        br = branch_dict.get(f"{f_b}_{t_b}") or branch_dict.get(f"{t_b}_{f_b}")
                        if br:
                            r_val = br.get('r_pu') if r_val is None else r_val
                            x_val = br.get('x_pu') if x_val is None else x_val
                            b_val = br.get('b_pu', 0.0) if b_val is None else b_val
                            branch_fields = set(br.get('provided_fields', []))
                            for field in ('r_pu', 'x_pu', 'b_pu'):
                                if field in branch_fields:
                                    provided_tr_fields.add(field)
                            if 'tap' not in provided_tr_fields and 'tap' in branch_fields:
                                tap = br.get('tap')
                                provided_tr_fields.add('tap')

                    tr_info = {
                        'from_bus': f_b,
                        'to_bus': t_b,
                        'tap': tap,
                        'r_pu': r_val,
                        'x_pu': x_val,
                        'b_pu': b_val if b_val is not None else 0.0,
                        'provided_fields': sorted(provided_tr_fields),
                    }
                    trans_dict[f"{f_b}_{t_b}"] = tr_info
                    trans_dict[f"{t_b}_{f_b}"] = tr_info

        # Also check if branch sheet has a tap column indicating in-line transformers
        if 'branch' in sheet_names_lower:
            df_br = pd.read_excel(xl, sheet_name=sheet_names_lower['branch'])
            if not df_br.empty and len(df_br.columns) >= 2:
                from_col = next((c for c in df_br.columns if 'from' in c.lower()), df_br.columns[0])
                to_col = next((c for c in df_br.columns if 'to' in c.lower()), df_br.columns[1])
                tap_col = next((c for c in df_br.columns if 'tap' in c.lower() or 'ratio' in c.lower()), None)
                if tap_col:
                    for _, row in df_br.iterrows():
                        try:
                            f_b = int(row[from_col])
                            t_b = int(row[to_col])
                            if not pd.notna(row[tap_col]):
                                continue
                            tap_val = float(row[tap_col])
                        except (ValueError, TypeError):
                            continue
                        if abs(tap_val - 1.0) > 1e-4 and f"{f_b}_{t_b}" not in trans_dict:
                            br = branch_dict.get(f"{f_b}_{t_b}") or branch_dict.get(f"{t_b}_{f_b}")
                            tr_info = {
                                'from_bus': f_b,
                                'to_bus': t_b,
                                'tap': tap_val,
                                'r_pu': br.get('r_pu') if br else None,
                                'x_pu': br.get('x_pu') if br else None,
                                'b_pu': br.get('b_pu', 0.0) if br else 0.0,
                                'provided_fields': sorted(
                                    set(br.get('provided_fields', [])) | {'tap'} if br else {'tap'}
                                ),
                            }
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

        def source_fields(record: Dict[str, Any] | None) -> set[str] | None:
            if not isinstance(record, dict):
                return None
            provided = record.get('provided_fields')
            if isinstance(provided, (list, tuple, set)):
                return {str(field) for field in provided}
            return None

        def mark_import_state(
            element: Dict[str, Any],
            record: Dict[str, Any] | None,
            requirements: Dict[str, str],
        ) -> List[str]:
            fields = source_fields(record)
            missing = [
                target for source, target in requirements.items()
                if (
                    source not in fields
                    if fields is not None
                    else not isinstance(record, dict) or record.get(source) is None
                )
            ]
            element['parameterMissingFields'] = missing
            element['parameterStatus'] = 'MISSING' if missing else 'VALID'
            return missing

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
                if b_num is None:
                    b_num = el.get('busNumber')
                if b_num is not None:
                    try:
                        b_num = int(b_num)
                    except (ValueError, TypeError):
                        b_num = None
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

                tr_s = str(tr.get('startElementId') or tr.get('start_element_id') or '')
                tr_e = str(tr.get('endElementId') or tr.get('end_element_id') or '')
                b_s = el_id_to_bus_num.get(tr_s)
                b_e = el_id_to_bus_num.get(tr_e)
                if b_s is not None and b_s not in conn_buses:
                    conn_buses.append(b_s)
                if b_e is not None and b_e not in conn_buses:
                    conn_buses.append(b_e)

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
                    el['isSlack'] = bool(b_info.get('is_slack', False))
                    el['vPu'] = float(b_info.get('vm_pu', 1.0))
                    el['thetaDeg'] = float(b_info.get('va_deg', 0.0))
                    el['pPu'] = float(b_info.get('pload_pu', 0.0))
                    el['qPu'] = float(b_info.get('qload_pu', 0.0))
                    el['bus_type'] = str(b_info.get('type') or b_info.get('bus_type') or ('3' if el['isSlack'] else '1'))
                    if 'max_vm' in b_info: el['maxVm'] = b_info['max_vm']
                    if 'min_vm' in b_info: el['minVm'] = b_info['min_vm']
                    mark_import_state(el, b_info, {
                        'is_slack': 'isSlack',
                        'type': 'bus_type',
                        'vm_pu': 'vPu',
                        'va_deg': 'thetaDeg',
                        'pload_pu': 'pPu',
                        'qload_pu': 'qPu',
                    })
                    applied_counts['bus'] += 1
                else:
                    el['parameterStatus'] = 'MISSING'
                    el['parameterMissingFields'] = [
                        'isSlack', 'bus_type', 'vPu', 'thetaDeg', 'pPu', 'qPu'
                    ]

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
                    el['isSlack'] = bool(g_info.get('is_slack', False))
                    el['pPu'] = float(g_info.get('pg_pu', 0.0))
                    el['qPu'] = float(g_info.get('qg_pu', 0.0))
                    el['vPu'] = float(g_info.get('voltage_setpoint', 1.0))
                    g_type_lower = str(g_info.get('type', '')).strip().lower()
                    g_label_str = str(g_info.get('label', '')).strip()
                    is_explicit_sc = bool(
                        el.get('isSynchronousCondenser') or 
                        el.get('is_synchronous_condenser') or
                        'condenser' in g_type_lower or
                        g_type_lower == 'sc' or
                        g_type_lower.startswith('sc_') or
                        g_label_str.startswith('SC_') or
                        g_label_str.startswith('SC ') or
                        g_label_str == 'SC' or
                        '동기조상기' in g_label_str
                    )
                    is_sc = (not el['isSlack']) and is_explicit_sc
                    el['isSynchronousCondenser'] = is_sc
                    if is_sc:
                        el['label'] = f"SC_{b_num} (동기조상기)"
                    else:
                        el['label'] = f"G_{b_num}" + (" (Slack)" if el['isSlack'] else "")
                    mark_import_state(el, g_info, {
                        'pg_pu': 'pPu',
                        'qg_pu': 'qPu',
                        'voltage_setpoint': 'vPu',
                    })
                    applied_counts['generator'] += 1
                else:
                    el['parameterStatus'] = 'MISSING'
                    el['parameterMissingFields'] = ['pPu', 'qPu', 'vPu']
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
                    el['pPu'] = float(b_info.get('pload_pu', 0.0))
                    el['qPu'] = float(b_info.get('qload_pu', 0.0))
                    el['label'] = f"Load_{b_num}"
                    mark_import_state(el, b_info, {
                        'pload_pu': 'pPu',
                        'qload_pu': 'qPu',
                    })
                    applied_counts['load'] += 1
                else:
                    el['parameterStatus'] = 'MISSING'
                    el['parameterMissingFields'] = ['pPu', 'qPu']

            # 4. Transformer
            elif 'trans' in el_type:
                t_id = str(el.get('id'))
                t_branch = trans_branch_map.get(t_id, {})
                fb = t_branch.get('fb')
                tb = t_branch.get('tb')
                conn_lines = t_branch.get('conn_lines', [])

                tr_info = trans_dict.get(f"{fb}_{tb}") or trans_dict.get(f"{tb}_{fb}") or trans_dict.get((fb, tb))
                br_info = branch_dict.get(f"{fb}_{tb}") or branch_dict.get(f"{tb}_{fb}") or branch_dict.get((fb, tb))

                r_val = None
                x_val = None
                b_val = 0.0
                tap = 1.0

                if tr_info:
                    tap = tr_info.get('tap', 1.0)
                    r_val = tr_info.get('r_pu')
                    x_val = tr_info.get('x_pu')
                    b_val = tr_info.get('b_pu', 0.0)

                if r_val is None or x_val is None:
                    if br_info:
                        if r_val is None:
                            r_val = br_info.get('r_pu')
                        if x_val is None:
                            x_val = br_info.get('x_pu')
                        if b_val is None:
                            b_val = br_info.get('b_pu', 0.0)

                provenance = tr_info or br_info
                provided = source_fields(provenance)
                def transformer_field_present(field: str, value: Any) -> bool:
                    if provided is not None:
                        return field in provided
                    return value is not None

                missing_transformer_fields = []
                for field, value, target in (
                    ('r_pu', r_val, 'rPu'),
                    ('x_pu', x_val, 'xPu'),
                    ('b_pu', b_val, 'bPu'),
                    ('tap', tap if tr_info else None, 'tapRatio'),
                ):
                    if transformer_field_present(field, value):
                        el[target] = value
                    else:
                        el[target] = None
                        missing_transformer_fields.append(target)

                if not missing_transformer_fields:
                    el['parameterStatus'] = 'VALID'
                    el['parameterMissingFields'] = []
                    applied_counts['transformer'] += 1
                else:
                    el['parameterStatus'] = 'MISSING'
                    el['parameterMissingFields'] = missing_transformer_fields
                    el['tap'] = tap if tr_info else None

                if tr_info:
                    el['from_bus'] = tr_info['from_bus']
                    el['to_bus'] = tr_info['to_bus']
                    el['tapFromBus'] = tr_info['from_bus']
                    el['tapToBus'] = tr_info['to_bus']
                    fb_disp, tb_disp = tr_info['from_bus'], tr_info['to_bus']
                else:
                    el['from_bus'] = fb
                    el['to_bus'] = tb
                    el['tapFromBus'] = fb
                    el['tapToBus'] = tb
                    fb_disp, tb_disp = fb, tb

                if fb_disp is not None and tb_disp is not None:
                    if el.get('parameterStatus') == 'MISSING':
                        el['label'] = f"T {fb_disp}-{tb_disp} (파라미터 누락)"
                    else:
                        el['label'] = f"T {fb_disp}-{tb_disp} (Tap: {tap})"

                # Connecting lines to a transformer are physical leads, NOT separate transmission branches
                for l in conn_lines:
                    l['is_transformer_lead'] = True
                    l['isTransformerLead'] = True
                    l['rPu'] = 0.0
                    l['xPu'] = 0.0
                    l['bPu'] = 0.0
                    l['tapRatio'] = 1.0
                    other_id = l.get('startElementId') if str(l.get('endElementId')) == t_id else l.get('endElementId')
                    l['label'] = f"Lead {other_id} ↔ {t_id}"

            # 5. Normal Line (not connected to a transformer)
            elif 'line' in el_type:
                if str(el.get('id')) in trans_lead_line_ids or el.get('is_transformer_lead') or el.get('isTransformerLead'):
                    # Already processed as transformer lead line
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

                br_info = branch_dict.get(f"{fb}_{tb}") or branch_dict.get(f"{tb}_{fb}") or branch_dict.get((fb, tb)) or branch_dict.get((tb, fb))
                if not br_info and (fb is not None and tb is not None):
                    for br_v in branch_dict.values():
                        if isinstance(br_v, dict):
                            if (br_v.get('from_bus') == fb and br_v.get('to_bus') == tb) or (br_v.get('from_bus') == tb and br_v.get('to_bus') == fb):
                                br_info = br_v
                                break
                branch_fields = source_fields(br_info)
                required_branch_fields = ['r_pu', 'x_pu', 'b_pu']
                requires_tap = bool(br_info and br_info.get('requires_tap'))
                if requires_tap:
                    required_branch_fields.append('tap')
                missing_branch_fields = [
                    {'r_pu': 'rPu', 'x_pu': 'xPu', 'b_pu': 'bPu', 'tap': 'tapRatio'}[field]
                    for field in required_branch_fields
                    if (
                        field not in branch_fields
                        if branch_fields is not None
                        else not br_info or br_info.get(field) is None
                    )
                ]
                if br_info:
                    el['rPu'] = br_info.get('r_pu')
                    el['xPu'] = br_info.get('x_pu')
                    el['bPu'] = br_info.get('b_pu') if 'bPu' not in missing_branch_fields else None
                    if requires_tap:
                        el['tapRatio'] = br_info.get('tap') if 'tapRatio' not in missing_branch_fields else None
                if br_info and not missing_branch_fields:
                    el['parameterStatus'] = 'VALID'
                    el['parameterMissingFields'] = []
                    c_count = br_info.get('circuit_count', 1)
                    el['circuitCount'] = c_count
                    if c_count > 1:
                        el['isDoubleCircuit'] = True
                        el['label'] = f"Line {fb}-{tb} ({c_count}회선 병렬 등가)"
                    applied_counts['line'] += 1
                else:
                    el['parameterStatus'] = 'MISSING'
                    el['parameterMissingFields'] = missing_branch_fields or ['rPu', 'xPu', 'bPu']
                    if fb is not None and tb is not None:
                        el['label'] = f"Line {fb}-{tb} (파라미터 누락)"

                # Check if this branch is also a transformer with off-nominal tap
                tr_info = trans_dict.get(f"{fb}_{tb}") or trans_dict.get(f"{tb}_{fb}") or trans_dict.get((fb, tb))
                if tr_info and tr_info.get('tap') is not None:
                    el['tapRatio'] = tr_info['tap']
                    el['tap'] = tr_info['tap']
                    applied_counts['transformer'] += 1
        # =========================================================================
        # BUS VALIDATION GATEKEEPER (Must execute BEFORE generator auto-supplementation)
        # =========================================================================
        diagram_buses = set(el_id_to_bus_num.values())
        excel_buses = {int(k) for k in bus_dict.keys()}
        missing_buses = sorted(list(excel_buses - diagram_buses))
        surplus_buses = sorted(list(diagram_buses - excel_buses))
        bus_validation_passed = (len(missing_buses) == 0 and len(surplus_buses) == 0)

        added_auto_generators = []
        added_auto_leads = []
        generator_bus_errors = []

        if not bus_validation_passed:
            # SAFETY RULE:
            # When Bus count / numbers / matching fails, NEVER auto-supplement generators or leads!
            # Never create synthetic buses or attempt to bridge topology defects.
            # Maintain strict ERROR / REVIEW state.
            pass
        else:
            # Bus validation PASSED: Cross-check generators and auto-supplement if missed by Vision
            for b_str, g_info in gen_by_bus.items():
                b_num = int(b_str)
                # Generator status check: if status is 0 (out of service), skip
                if g_info.get('status') == 0:
                    continue
                if b_num not in applied_gen_buses:
                    target_bus_id = None
                    for bid, bno in el_id_to_bus_num.items():
                        if bno == b_num:
                            target_bus_id = bid
                            break
                    if not target_bus_id:
                        # Section 13: Do NOT silently ignore! Record explicit validation issue.
                        generator_bus_errors.append({
                            "category": "generator",
                            "type": "error",
                            "code": "EXCEL_GENERATOR_BUS_NOT_FOUND",
                            "target": f"Bus {b_num}",
                            "message": f"Bus {b_num}: Excel Generator exists but matching verified Canvas Bus was not found."
                        })
                        continue

                    # Duplicate prevention check
                    already_exists = any(
                        str(e.get('id')) == f"gen_auto_{b_num}" or
                        (get_el_type(e) in ('generator', 'tool.generator') and (
                            e.get('bus_number') == b_num or 
                            e.get('busNumber') == b_num or 
                            str(e.get('parentBusId') or '') == str(target_bus_id)
                        ))
                        for e in elements
                    )
                    if already_exists:
                        applied_gen_buses.add(b_num)
                        continue

                    is_slack = bool(g_info.get('is_slack', False))
                    is_explicit_sc = bool(
                        g_info.get('is_synchronous_condenser') or
                        g_info.get('isSynchronousCondenser') or
                        'condenser' in str(g_info.get('type', '')).lower() or
                        str(g_info.get('type', '')).lower() == 'sc' or
                        '동기조상기' in str(g_info.get('label', ''))
                    )
                    is_sc = (not is_slack) and is_explicit_sc

                    target_bus_el = el_by_id.get(str(target_bus_id), {})
                    b_pos = target_bus_el.get('position')
                    if isinstance(b_pos, dict):
                        bx = float(b_pos.get('dx', 100.0 * b_num))
                        by = float(b_pos.get('dy', 200.0))
                    else:
                        bx, by = 100.0 * b_num, 200.0

                    auto_gen = {
                        'id': f"gen_auto_{b_num}",
                        'type': 'generator',
                        'parentBusId': target_bus_id,
                        'bus_number': b_num,
                        'busNumber': b_num,
                        'position': {'dx': bx, 'dy': by - 60.0},
                        'width': 44.0,
                        'height': 44.0,
                        'isSlack': is_slack,
                        'isSynchronousCondenser': is_sc,
                        'pPu': float(g_info.get('pg_pu', 0.0)),
                        'qPu': float(g_info.get('qg_pu', 0.0)),
                        'vPu': float(g_info.get('voltage_setpoint', 1.0)),
                        'label': f"G_{b_num}" + (" (Slack)" if is_slack else ""),
                        'source': 'excel_auto',
                    }
                    elements.append(auto_gen)
                    applied_counts['generator'] += 1
                    applied_gen_buses.add(b_num)
                    added_auto_generators.append({
                        'id': auto_gen['id'],
                        'bus_number': b_num,
                        'parent_bus_id': target_bus_id,
                        'pg_mw': g_info.get('pg_mw', 0.0),
                        'pg_pu': auto_gen['pPu'],
                        'qg_mvar': g_info.get('qg_mvar', 0.0),
                        'qg_pu': auto_gen['qPu'],
                        'v_pu': auto_gen['vPu'],
                        'is_slack': is_slack,
                        'label': auto_gen['label'],
                        'source': 'excel_auto',
                    })

                    # Auto-supplement equipment lead line connecting generator to its parent bus
                    lead_id = f"lead_gen_auto_{b_num}"
                    lead_already_exists = any(
                        str(e.get('id')) == lead_id or
                        (get_el_type(e) in ('line', 'tool.line') and (
                            (str(e.get('startElementId')) == auto_gen['id'] and str(e.get('endElementId')) == str(target_bus_id)) or
                            (str(e.get('startElementId')) == str(target_bus_id) and str(e.get('endElementId')) == auto_gen['id'])
                        ))
                        for e in elements
                    )
                    if not lead_already_exists:
                        auto_lead = {
                            'id': lead_id,
                            'type': 'line',
                            'position': {'dx': bx, 'dy': by - 60.0},
                            'endPosition': {'dx': bx, 'dy': by},
                            'startElementId': auto_gen['id'],
                            'endElementId': target_bus_id,
                            'connected_to': [auto_gen['id'], target_bus_id],
                            'label': f"Lead G_{b_num} ↔ Bus_{b_num}",
                            'isEquipmentLead': True,
                            'isGenLead': True,
                            'electricalBranch': False,
                            'rPu': 0.0,
                            'xPu': 0.0,
                            'bPu': 0.0,
                            'tapRatio': 1.0,
                            'source': 'excel_auto',
                        }
                        elements.append(auto_lead)
                        added_auto_leads.append(lead_id)

        mismatch_report = self.compare_elements_with_excel(elements, excel_data)
        if generator_bus_errors:
            mismatch_report['is_matched'] = False
            mismatch_report.setdefault('discrepancies', []).extend(generator_bus_errors)

        summary = {
            'slack_bus_number': slack_bus_no,
            'applied_counts': applied_counts,
            'total_elements_updated': sum(applied_counts.values()),
            'mismatch_report': mismatch_report,
            'added_auto_generators': added_auto_generators,
            'added_auto_leads': added_auto_leads,
            'bus_validation_passed': bus_validation_passed,
        }
        return elements, summary

    def apply_verified_sld_to_elements(
        self,
        elements: List[Dict[str, Any]],
        excel_data: Dict[str, Any],
    ) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        """Bind parsed Excel values using only explicit IDs and bus numbers.

        Unlike the legacy canvas importer this method never creates topology,
        derives numbers from labels/IDs, or changes element geometry.
        """
        from copy import deepcopy

        updated = deepcopy(elements)
        buses = excel_data.get('buses', {}) or {}
        generators = excel_data.get('generators', {}) or {}
        branches = excel_data.get('branches', {}) or {}
        transformers = excel_data.get('transformers', {}) or {}
        elements_by_id = {
            str(element['id']): element
            for element in updated
            if isinstance(element, dict) and element.get('id') is not None
        }

        def element_type(element: Dict[str, Any]) -> str:
            return str(element.get('type') or '').lower().replace('tool.', '')

        def explicit_bus_number(element: Dict[str, Any]) -> int | None:
            value = element.get('bus_number')
            if value is None:
                value = element.get('connected_bus_number')
            if value is None:
                value = element.get('busNumber')
            try:
                return int(value) if value is not None else None
            except (TypeError, ValueError):
                return None

        def explicit_node_bus_number(element: Dict[str, Any]) -> int | None:
            value = element.get('bus_number')
            if value is None:
                value = element.get('busNumber')
            try:
                return int(value) if value is not None else None
            except (TypeError, ValueError):
                return None

        bus_number_counts: Dict[int, int] = {}
        bus_id_to_number: Dict[str, int] = {}
        for element in updated:
            if element_type(element) != 'bus':
                continue
            bus_number = explicit_node_bus_number(element)
            if bus_number is None:
                continue
            bus_number_counts[bus_number] = bus_number_counts.get(bus_number, 0) + 1
            if element.get('id') is not None:
                bus_id_to_number[str(element['id'])] = bus_number

        def unique_bus_number(element: Dict[str, Any]) -> int | None:
            bus_number = explicit_bus_number(element)
            if bus_number is None or bus_number_counts.get(bus_number) != 1:
                return None
            parent_id = element.get('parentBusId')
            if parent_id is not None:
                parent_number = bus_id_to_number.get(str(parent_id))
                if parent_number is None or parent_number != bus_number:
                    return None
            return bus_number

        def record_for_pair(records: Dict[str, Any], first: int, second: int) -> Dict[str, Any] | None:
            matches = []
            seen_records = set()
            for record in records.values():
                if not isinstance(record, dict):
                    continue
                try:
                    from_bus = int(record.get('from_bus'))
                    to_bus = int(record.get('to_bus'))
                except (TypeError, ValueError):
                    continue
                if {from_bus, to_bus} == {first, second} and first != second:
                    signature = (
                        from_bus,
                        to_bus,
                        record.get('r_pu'),
                        record.get('x_pu'),
                        record.get('b_pu'),
                        record.get('tap'),
                        record.get('requires_tap'),
                        tuple(sorted(record.get('provided_fields', [])))
                        if isinstance(record.get('provided_fields'), (list, tuple, set))
                        else None,
                    )
                    if signature not in seen_records:
                        seen_records.add(signature)
                        matches.append(record)
            return matches[0] if len(matches) == 1 else None

        def has_excel_value(record: Dict[str, Any] | None, field: str) -> bool:
            if not isinstance(record, dict):
                return False
            if isinstance(record.get('provided_fields'), (list, tuple, set)):
                return field in record['provided_fields']
            return record.get(field) is not None

        missing_parameters_by_id: Dict[str, List[str]] = {}

        def set_missing_parameters(element: Dict[str, Any], fields: List[str]) -> None:
            if fields:
                element['parameterStatus'] = 'MISSING'
                element['parameterMissingFields'] = fields
                missing_parameters_by_id[str(element.get('id') or '<unknown>')] = fields
            else:
                element['parameterStatus'] = 'VALID'
                element['parameterMissingFields'] = []

        def bind_branch_values(
            element: Dict[str, Any], record: Dict[str, Any] | None, *, include_tap: bool
        ) -> bool:
            required = ['r_pu', 'x_pu', 'b_pu'] + (['tap'] if include_tap else [])
            missing = [
                {'r_pu': 'rPu', 'x_pu': 'xPu', 'b_pu': 'bPu', 'tap': 'tapRatio'}[field]
                for field in required if not has_excel_value(record, field)
            ]
            r_value = record.get('r_pu') if has_excel_value(record, 'r_pu') else None
            x_value = record.get('x_pu') if has_excel_value(record, 'x_pu') else None
            if has_excel_value(record, 'b_pu'):
                element['bPu'] = record['b_pu']
            else:
                element['bPu'] = None
            if include_tap:
                tap = record.get('tap') if has_excel_value(record, 'tap') else None
                element['tapRatio'] = tap
                element['tap'] = tap
                if record:
                    element['from_bus'] = record.get('from_bus')
                    element['to_bus'] = record.get('to_bus')
                    element['tapFromBus'] = record.get('from_bus')
                    element['tapToBus'] = record.get('to_bus')
                else:
                    element['from_bus'] = None
                    element['to_bus'] = None
                    element['tapFromBus'] = None
                    element['tapToBus'] = None
            element['rPu'] = r_value
            element['xPu'] = x_value
            set_missing_parameters(element, missing)
            if missing:
                return False
            return True

        applied = {'bus': 0, 'generator': 0, 'load': 0, 'line': 0, 'transformer': 0}
        missing_parameter_ids: List[str] = []
        unresolved_topology_ids: List[str] = []
        device_counts: Dict[tuple[str, int], int] = {}
        for element in updated:
            element_kind = element_type(element)
            if element_kind in {'generator', 'load'}:
                bus_number = unique_bus_number(element)
                if bus_number is not None:
                    key = (element_kind, bus_number)
                    device_counts[key] = device_counts.get(key, 0) + 1

        for element in updated:
            kind = element_type(element)
            element_id = str(element.get('id') or '<unknown>')
            if kind == 'bus':
                bus_number = explicit_node_bus_number(element)
                if bus_number is None or bus_number_counts.get(bus_number) != 1:
                    set_missing_parameters(element, ['bus_number'])
                    unresolved_topology_ids.append(element_id)
                    missing_parameter_ids.append(element_id)
                    continue
                bus_data = buses.get(str(bus_number), buses.get(bus_number))
                if not isinstance(bus_data, dict):
                    set_missing_parameters(element, ['bus_data'])
                    unresolved_topology_ids.append(element_id)
                    missing_parameter_ids.append(element_id)
                    continue
                for source_key, target_key in (
                    ('is_slack', 'isSlack'),
                    ('vm_pu', 'vPu'),
                    ('va_deg', 'thetaDeg'),
                    ('pload_pu', 'pPu'),
                    ('qload_pu', 'qPu'),
                ):
                    if has_excel_value(bus_data, source_key):
                        element[target_key] = bus_data[source_key]
                bus_missing = [
                    target_key for source_key, target_key in (
                        ('is_slack', 'isSlack'),
                        ('type', 'bus_type'),
                        ('vm_pu', 'vPu'),
                        ('va_deg', 'thetaDeg'),
                        ('pload_pu', 'pPu'),
                        ('qload_pu', 'qPu'),
                    ) if not has_excel_value(bus_data, source_key)
                ]
                set_missing_parameters(element, bus_missing)
                if bus_missing:
                    missing_parameter_ids.append(element_id)
                if has_excel_value(bus_data, 'type') or has_excel_value(bus_data, 'bus_type'):
                    element['bus_type'] = bus_data.get('type') or bus_data.get('bus_type')
                if not bus_missing:
                    applied['bus'] += 1

            elif kind in {'generator', 'load'}:
                bus_number = unique_bus_number(element)
                count_key = (kind, bus_number) if bus_number is not None else None
                if bus_number is None or device_counts.get(count_key, 0) != 1:
                    set_missing_parameters(element, ['bus_number', 'pPu', 'qPu'])
                    unresolved_topology_ids.append(element_id)
                    missing_parameter_ids.append(element_id)
                    continue
                if kind == 'generator':
                    data = generators.get(str(bus_number), generators.get(bus_number))
                    fields = (('pg_pu', 'pPu'), ('qg_pu', 'qPu'), ('voltage_setpoint', 'vPu'))
                else:
                    bus_data = buses.get(str(bus_number), buses.get(bus_number))
                    data = bus_data if isinstance(bus_data, dict) else None
                    fields = (('pload_pu', 'pPu'), ('qload_pu', 'qPu'))
                if not isinstance(data, dict):
                    set_missing_parameters(element, ['pPu', 'qPu'])
                    missing_parameter_ids.append(element_id)
                    continue
                missing_device_fields = []
                for source_key, target_key in fields:
                    if has_excel_value(data, source_key):
                        element[target_key] = data[source_key]
                    else:
                        missing_device_fields.append(target_key)
                if kind == 'generator' and not has_excel_value(data, 'voltage_setpoint'):
                    missing_device_fields.append('vPu')
                elif kind == 'generator':
                    element['vPu'] = data['voltage_setpoint']
                if kind == 'generator' and data.get('is_slack') is not None:
                    element['isSlack'] = bool(data['is_slack'])
                set_missing_parameters(element, missing_device_fields)
                if not missing_device_fields:
                    applied[kind] += 1
                else:
                    missing_parameter_ids.append(element_id)

        # Transformer branches are bound from the two exact bus IDs reached by
        # their verified incident line endpoints. No labels or ID patterns are
        # considered, and ambiguous degree remains explicitly missing.
        for element in updated:
            if element_type(element) != 'transformer':
                continue
            element_id = str(element.get('id') or '<unknown>')
            connected_bus_numbers = []
            for line in updated:
                if element_type(line) != 'line':
                    continue
                endpoints = [
                    line.get('startElementId'),
                    line.get('endElementId'),
                ]
                if endpoints[0] is None or endpoints[1] is None:
                    connected = line.get('connected_to')
                    if isinstance(connected, list) and len(connected) == 2:
                        endpoints = connected
                if element_id not in {str(endpoint) for endpoint in endpoints if endpoint is not None}:
                    continue
                other_id = str(endpoints[1] if str(endpoints[0]) == element_id else endpoints[0])
                other_number = bus_id_to_number.get(other_id)
                if other_number is not None and bus_number_counts.get(other_number) == 1:
                    if other_number not in connected_bus_numbers:
                        connected_bus_numbers.append(other_number)
            if len(connected_bus_numbers) != 2:
                bind_branch_values(element, None, include_tap=True)
                unresolved_topology_ids.append(element_id)
                missing_parameter_ids.append(element_id)
                continue
            record = record_for_pair(transformers, connected_bus_numbers[0], connected_bus_numbers[1])
            if bind_branch_values(element, record, include_tap=True):
                applied['transformer'] += 1
            else:
                missing_parameter_ids.append(element_id)

        # A verified line is an electrical branch only when its explicit
        # endpoint IDs name two uniquely numbered buses.
        for element in updated:
            if element_type(element) != 'line':
                continue
            element_id = str(element.get('id') or '<unknown>')
            endpoints = [element.get('startElementId'), element.get('endElementId')]
            if endpoints[0] is None or endpoints[1] is None:
                connected = element.get('connected_to')
                if isinstance(connected, list) and len(connected) == 2:
                    endpoints = connected
            start_id, end_id = (str(value) if value is not None else None for value in endpoints)
            start = elements_by_id.get(start_id) if start_id is not None else None
            end = elements_by_id.get(end_id) if end_id is not None else None
            if element.get('electricalBranch') is False or not start or not end or \
                    element_type(start) != 'bus' or element_type(end) != 'bus':
                element['electricalBranch'] = False
                element['isEquipmentLead'] = True
                element['parameterStatus'] = 'NOT_APPLICABLE'
                continue
            first = bus_id_to_number.get(start_id)
            second = bus_id_to_number.get(end_id)
            if first is None or second is None or first == second or \
                    bus_number_counts.get(first) != 1 or bus_number_counts.get(second) != 1:
                element['parameterStatus'] = 'MISSING'
                element['rPu'] = None
                element['xPu'] = None
                element['bPu'] = None
                unresolved_topology_ids.append(element_id)
                missing_parameter_ids.append(element_id)
                continue
            element['from_bus'] = first
            element['to_bus'] = second
            branch_record = record_for_pair(branches, first, second)
            transformer_record = record_for_pair(transformers, first, second)
            record = transformer_record or branch_record
            include_tap = transformer_record is not None or bool(
                branch_record and branch_record.get('requires_tap')
            )
            if not bind_branch_values(element, record, include_tap=include_tap):
                missing_parameter_ids.append(element_id)
            else:
                applied['line'] += 1

        return updated, {
            'binding_mode': 'verified_sld_strict',
            'topology_mutated': False,
            'applied_counts': applied,
            'missing_parameter_ids': sorted(set(missing_parameter_ids)),
            'missing_parameters_by_id': missing_parameters_by_id,
            'unresolved_topology_ids': sorted(set(unresolved_topology_ids)),
            'power_flow_ready': not missing_parameter_ids and not unresolved_topology_ids,
        }

    def apply_verified_sld_with_excel(
        self,
        elements: List[Dict[str, Any]],
        excel_data: Dict[str, Any],
    ) -> Tuple[List[Dict[str, Any]], Dict[str, Any], Dict[str, Any]]:
        mismatch_report = self.compare_elements_with_excel(
            elements,
            excel_data,
            structured_bus_numbers_only=True,
        )
        if not mismatch_report.get('is_matched'):
            from copy import deepcopy
            return deepcopy(elements), {
                'binding_mode': 'verified_sld_strict',
                'blocked': True,
                'topology_mutated': False,
                'power_flow_ready': False,
            }, mismatch_report

        updated, summary = self.apply_verified_sld_to_elements(elements, excel_data)
        summary['blocked'] = False
        summary['mismatch_report'] = mismatch_report
        return updated, summary, mismatch_report

    def compare_elements_with_excel(
        self,
        elements: list,
        excel_data: dict,
        *,
        structured_bus_numbers_only: bool = False,
    ) -> dict:
        """도면의 캔버스 요소와 엑셀 계통 사양을 정밀 비교하여 불일치 내역 리포트를 생성합니다."""
        import re

        def get_el_type(e):
            if not e or not isinstance(e, dict):
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

        el_by_id = {str(el['id']): el for el in elements if el.get('id') is not None}

        # 1. Map element ID to bus number
        el_id_to_bus_num = {}
        diagram_buses = set()
        diagram_bus_counts = {}
        unmapped_bus_ids = []
        for el in elements:
            el_type = get_el_type(el)
            if 'bus' in el_type and not any(k in el_type for k in ('gen', 'load', 'trans')):
                b_num = el.get('bus_number')
                if b_num is None:
                    b_num = el.get('busNumber')
                if b_num is not None:
                    try:
                        b_num = int(b_num)
                    except (ValueError, TypeError):
                        b_num = None
                if b_num is None and not structured_bus_numbers_only and el.get('label'):
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is None and not structured_bus_numbers_only and el.get('id'):
                    m = re.search(r'bus_(\d+)', str(el.get('id')))
                    if m:
                        b_num = int(m.group(1))
                    else:
                        digits = ''.join(c for c in str(el.get('id')) if c.isdigit())
                        if digits:
                            b_num = int(digits)
                if b_num is not None:
                    b_num = int(b_num)
                    diagram_buses.add(b_num)
                    diagram_bus_counts[b_num] = diagram_bus_counts.get(b_num, 0) + 1
                    if el.get('id') is not None:
                        el_id_to_bus_num[str(el['id'])] = b_num
                elif structured_bus_numbers_only:
                    unmapped_bus_ids.append(str(el.get('id') or '<unknown>'))

        # 2. Extract diagram generators
        diagram_gens = set()
        unmapped_device_ids = []
        for el in elements:
            el_type = get_el_type(el)
            if 'gen' in el_type:
                parent_id = str(el.get('parentBusId') or '')
                b_num = el.get('bus_number')
                if b_num is None:
                    b_num = el.get('connected_bus_number')
                if b_num is None:
                    b_num = el.get('busNumber')
                if b_num is None:
                    b_num = el_id_to_bus_num.get(parent_id)
                if b_num is None and not structured_bus_numbers_only and el.get('label'):
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is None and not structured_bus_numbers_only and el.get('id'):
                    m = re.search(r'(\d+)', str(el.get('id')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is not None:
                    try:
                        diagram_gens.add(int(b_num))
                    except (ValueError, TypeError):
                        if structured_bus_numbers_only:
                            unmapped_device_ids.append(str(el.get('id') or '<unknown>'))
                elif structured_bus_numbers_only:
                    unmapped_device_ids.append(str(el.get('id') or '<unknown>'))

        # 3. Extract diagram loads
        diagram_loads = set()
        for el in elements:
            el_type = get_el_type(el)
            if 'load' in el_type:
                parent_id = str(el.get('parentBusId') or '')
                b_num = el.get('bus_number')
                if b_num is None:
                    b_num = el.get('connected_bus_number')
                if b_num is None:
                    b_num = el.get('busNumber')
                if b_num is None:
                    b_num = el_id_to_bus_num.get(parent_id)
                if b_num is None and not structured_bus_numbers_only and el.get('label'):
                    m = re.search(r'(\d+)', str(el.get('label')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is None and not structured_bus_numbers_only and el.get('id'):
                    m = re.search(r'(\d+)', str(el.get('id')))
                    if m:
                        b_num = int(m.group(1))
                if b_num is not None:
                    try:
                        diagram_loads.add(int(b_num))
                    except (ValueError, TypeError):
                        if structured_bus_numbers_only:
                            unmapped_device_ids.append(str(el.get('id') or '<unknown>'))
                elif structured_bus_numbers_only:
                    unmapped_device_ids.append(str(el.get('id') or '<unknown>'))

        # 4. Extract Excel expectations first (to assist in branch/transformer matching)
        excel_buses = {int(k) for k in excel_data.get('buses', {}).keys()}
        excel_gens = {int(k) for k in excel_data.get('generators', {}).keys()}
        excel_loads = {
            int(k) for k, v in excel_data.get('buses', {}).items()
            if float(v.get('pload_pu', 0) or v.get('pload_mw', 0)) > 0 or float(v.get('qload_pu', 0) or v.get('qload_mvar', 0)) > 0
        }

        excel_branches = set()
        excel_transformers = set()
        for br in excel_data.get('branches', {}).values():
            fb = int(br.get('from_bus'))
            tb = int(br.get('to_bus'))
            excel_branches.add(tuple(sorted([fb, tb])))
        for tr in excel_data.get('transformers', {}).values():
            fb = int(tr.get('from_bus'))
            tb = int(tr.get('to_bus'))
            pair = tuple(sorted([fb, tb]))
            excel_branches.add(pair)
            excel_transformers.add(pair)

        # 5. Extract diagram branches (Lines between buses + Transformers)
        diagram_branches = set()
        trans_lead_line_ids = set()
        all_trans_buses = set()
        unmapped_branch_ids = []

        for tr in elements:
            if 'trans' in get_el_type(tr):
                t_id = str(tr.get('id'))
                conn_buses = []
                for l in elements:
                    if 'line' in get_el_type(l):
                        s_id, e_id = get_line_endpoints(l)
                        if s_id == t_id or e_id == t_id:
                            if l.get('id') is not None:
                                trans_lead_line_ids.add(str(l.get('id')))
                            other_id = e_id if s_id == t_id else s_id
                            b = el_id_to_bus_num.get(other_id)
                            if b is not None and b not in conn_buses:
                                conn_buses.append(b)
                                all_trans_buses.add(int(b))

                tr_s = str(tr.get('startElementId') or tr.get('start_element_id') or '')
                tr_e = str(tr.get('endElementId') or tr.get('end_element_id') or '')
                b_s = el_id_to_bus_num.get(tr_s)
                b_e = el_id_to_bus_num.get(tr_e)
                if b_s is not None and b_s not in conn_buses:
                    conn_buses.append(b_s)
                    all_trans_buses.add(int(b_s))
                if b_e is not None and b_e not in conn_buses:
                    conn_buses.append(b_e)
                    all_trans_buses.add(int(b_e))

                # A verified two-winding transformer must resolve to exactly
                # two explicit bus endpoints.  In strict SLD comparison,
                # enumerating every pair from an over-connected transformer
                # can make unrelated nearby branches look like Excel matches.
                if structured_bus_numbers_only and len(conn_buses) > 2:
                    unmapped_branch_ids.append(t_id)
                elif len(conn_buses) >= 2:
                    found_any = False
                    for i in range(len(conn_buses)):
                        for j in range(i + 1, len(conn_buses)):
                            pair = tuple(sorted([int(conn_buses[i]), int(conn_buses[j])]))
                            if pair in excel_branches:
                                diagram_branches.add(pair)
                                found_any = True
                    if not found_any and len(conn_buses) == 2:
                        diagram_branches.add(tuple(sorted([int(conn_buses[0]), int(conn_buses[1])])))
                elif len(conn_buses) == 1 and not structured_bus_numbers_only:
                    m = re.search(r'(\d+)\s*[-~_↔]\s*(\d+)', str(tr.get('label') or tr.get('id') or ''))
                    if m:
                        diagram_branches.add(tuple(sorted([int(m.group(1)), int(m.group(2))])))

        # Legacy comparison supports multi-bus substation transformers.  A
        # verified SLD comparison must not use Excel transformer pairs to
        # infer topology that its explicit endpoints did not establish.
        if not structured_bus_numbers_only:
            for fb, tb in excel_transformers:
                if fb in all_trans_buses and tb in all_trans_buses:
                    diagram_branches.add(tuple(sorted([fb, tb])))

        for el in elements:
            if 'line' in get_el_type(el):
                if str(el.get('id')) in trans_lead_line_ids:
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

                # Check if this is a lead to a generator or load
                if el.get('isEquipmentLead') or el.get('is_equipment_lead') or el.get('isGenLead') or el.get('is_gen_lead') or el.get('electricalBranch') is False:
                    continue
                if not structured_bus_numbers_only and (
                    id_str.startswith('lead_') or 'lead' in id_str or '↔' in lbl_str
                ):
                    continue
                if structured_bus_numbers_only:
                    is_gen = 'gen' in s_type or 'gen' in e_type
                    is_load = 'load' in s_type or 'load' in e_type
                else:
                    is_gen = 'gen' in s_type or 'gen' in e_type or 'gen' in s_str or 'gen' in e_str or 'g_' in s_str or 'g_' in e_str or 'gen' in lbl_str or 'gen' in id_str
                    is_load = 'load' in s_type or 'load' in e_type or 'load' in s_str or 'load' in e_str or 'load' in lbl_str or 'load' in id_str
                is_lead = (is_gen or is_load) and (
                    structured_bus_numbers_only or 'lead' in id_str or 'lead' in lbl_str
                )

                if is_lead:
                    continue

                fb = el_id_to_bus_num.get(start_id)
                tb = el_id_to_bus_num.get(end_id)
                if (fb is None or tb is None) and structured_bus_numbers_only:
                    unmapped_branch_ids.append(str(el.get('id') or '<unknown>'))
                elif fb is None or tb is None:
                    m = re.search(r'(\d+)\s*[-~_]\s*(\d+)', str(el.get('label') or el.get('id') or ''))
                    if m:
                        fb = fb or int(m.group(1))
                        tb = tb or int(m.group(2))

                if fb is not None and tb is not None:
                    if int(fb) != int(tb):
                        diagram_branches.add(tuple(sorted([int(fb), int(tb)])))

        # 6. Compute Discrepancies
        missing_buses = sorted(list(excel_buses - diagram_buses))
        surplus_buses = sorted(list(diagram_buses - excel_buses))

        missing_branches = sorted(list(excel_branches - diagram_branches))
        surplus_branches = sorted(list(diagram_branches - excel_branches))

        missing_gens = sorted(list(excel_gens - diagram_gens))
        surplus_gens = sorted(list(diagram_gens - excel_gens))

        missing_loads = sorted(list(excel_loads - diagram_loads))
        surplus_loads = sorted(list(diagram_loads - excel_loads))

        discrepancies = []
        for b in missing_buses:
            discrepancies.append({
                "category": "bus",
                "type": "missing",
                "target": f"Bus {b}",
                "message": f"모선 {b}번이 도면에 누락되었습니다 (엑셀에는 정의됨)."
            })
        for b in surplus_buses:
            discrepancies.append({
                "category": "bus",
                "type": "surplus",
                "target": f"Bus {b}",
                "message": f"도면에 모선 {b}번이 있으나 엑셀 파일에는 없습니다."
            })
        for fb, tb in missing_branches:
            discrepancies.append({
                "category": "branch",
                "type": "missing",
                "target": f"Line {fb}-{tb}",
                "message": f"선로 {fb}-{tb}번이 도면에 연결되어 있지 않습니다 (엑셀에는 존재)."
            })
        for fb, tb in surplus_branches:
            discrepancies.append({
                "category": "branch",
                "type": "surplus",
                "target": f"Line {fb}-{tb}",
                "message": f"도면에 선로 {fb}-{tb}번이 연결되어 있으나 엑셀 선로 목록에는 없습니다."
            })
        for b in missing_gens:
            discrepancies.append({
                "category": "generator",
                "type": "missing",
                "target": f"G_{b}",
                "message": f"{b}번 모선의 발전기가 도면에 누락되었습니다."
            })
        for b in surplus_gens:
            discrepancies.append({
                "category": "generator",
                "type": "surplus",
                "target": f"G_{b}",
                "message": f"도면 {b}번 모선에 발전기가 있으나 엑셀에는 발전기가 없습니다."
            })
        for b in missing_loads:
            discrepancies.append({
                "category": "load",
                "type": "missing",
                "target": f"Load_{b}",
                "message": f"{b}번 모선의 부하 심볼이 도면에 누락되었습니다."
            })

        duplicate_bus_numbers = sorted(
            bus_number
            for bus_number, count in diagram_bus_counts.items()
            if count > 1
        ) if structured_bus_numbers_only else []
        for bus_number in duplicate_bus_numbers:
            discrepancies.append({
                "category": "bus",
                "type": "duplicate",
                "target": f"Bus {bus_number}",
                "message": f"도면에 모선 번호 {bus_number}가 중복되어 있습니다."
            })
        for bus_id in unmapped_bus_ids:
            discrepancies.append({
                "category": "bus",
                "type": "unmapped",
                "target": bus_id,
                "message": f"모선 {bus_id}에 구조화된 bus_number가 없어 엑셀과 안전하게 대조할 수 없습니다."
            })
        for element_id in unmapped_device_ids:
            discrepancies.append({
                "category": "device",
                "type": "unmapped",
                "target": element_id,
                "message": f"설비 {element_id}의 연결 모선 번호가 명시되어 있지 않아 엑셀과 안전하게 대조할 수 없습니다."
            })
        for line_id in unmapped_branch_ids:
            discrepancies.append({
                "category": "branch",
                "type": "unmapped",
                "target": line_id,
                "message": f"결선 {line_id}의 검증된 모선 종단을 확인할 수 없어 엑셀과 안전하게 대조할 수 없습니다."
            })

        is_matched = (len(discrepancies) == 0)

        # Summary string
        summary_parts = []
        if missing_buses: summary_parts.append(f"누락 모선: {len(missing_buses)}개 ({missing_buses})")
        if surplus_buses: summary_parts.append(f"초과 모선: {len(surplus_buses)}개 ({surplus_buses})")
        if missing_branches: summary_parts.append(f"누락 선로: {len(missing_branches)}개")
        if surplus_branches: summary_parts.append(f"초과 선로: {len(surplus_branches)}개")
        if missing_gens: summary_parts.append(f"누락 발전기: {len(missing_gens)}개")
        if missing_loads: summary_parts.append(f"누락 부하: {len(missing_loads)}개")
        if structured_bus_numbers_only and (unmapped_bus_ids or unmapped_device_ids or unmapped_branch_ids):
            summary_parts.append(
                f"구조화된 연결 번호 확인 필요: {len(unmapped_bus_ids) + len(unmapped_device_ids) + len(unmapped_branch_ids)}개"
            )

        summary_text = " • ".join(summary_parts) if summary_parts else "모든 모선, 선로, 발전기, 부하가 일치합니다."

        return {
            "is_matched": is_matched,
            "summary": summary_text,
            "discrepancies": discrepancies,
            "stats": {
                "excel": {
                    "buses": len(excel_buses),
                    "branches": len(excel_branches),
                    "generators": len(excel_gens),
                    "loads": len(excel_loads),
                },
                "diagram": {
                    "buses": len(diagram_buses),
                    "branches": len(diagram_branches),
                    "generators": len(diagram_gens),
                    "loads": len(diagram_loads),
                }
            },
            "details": {
                "missing_buses": missing_buses,
                "surplus_buses": surplus_buses,
                "missing_branches": [[fb, tb] for fb, tb in missing_branches],
                "surplus_branches": [[fb, tb] for fb, tb in surplus_branches],
                "missing_generators": missing_gens,
                "surplus_generators": surplus_gens,
                "missing_loads": missing_loads,
                "surplus_loads": surplus_loads,
                "unmapped_buses": unmapped_bus_ids,
                "unmapped_devices": unmapped_device_ids,
                "unmapped_branches": unmapped_branch_ids,
                "duplicate_bus_numbers": duplicate_bus_numbers,
            }
        }
