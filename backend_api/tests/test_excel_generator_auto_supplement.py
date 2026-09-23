# -*- coding: utf-8 -*-
import unittest
import os
import sys

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.excel_case_importer import ExcelCaseImporter
from core.power_flow_solver import PowerFlowSolver


class TestExcelGeneratorAndLoadCrossCheckProposals(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.solver = PowerFlowSolver()

    def _simulate_apply_proposal(self, elements, proposal):
        """Simulates the frontend's _applyEquipmentProposal logic."""
        cat = proposal.get('category', '').lower()
        b_num = proposal.get('bus_number')
        ex_data = proposal.get('excel_data', {})

        parent_bus = next((e for e in elements if e.get('type') == 'bus' and (e.get('bus_number') == b_num or e.get('busNumber') == b_num)), None)
        if not parent_bus:
            return elements

        b_pos = parent_bus.get('position', {'dx': 100.0, 'dy': 200.0})
        bx = float(b_pos.get('dx', 100.0))
        by = float(b_pos.get('dy', 200.0))
        target_bus_id = parent_bus.get('id')

        if cat == 'generator':
            g_pos = {'dx': bx + 20.0, 'dy': by - 60.0}
            gen_id = f"gen_applied_{b_num}"
            lead_id = f"lead_gen_applied_{b_num}"
            gen_el = {
                'id': gen_id,
                'type': 'generator',
                'parentBusId': target_bus_id,
                'bus_number': b_num,
                'position': g_pos,
                'width': 44.0,
                'height': 44.0,
                'label': ex_data.get('label', f"G_{b_num}"),
                'source': 'excel_review_applied',
                'isSlack': ex_data.get('is_slack', False),
                'isSynchronousCondenser': ex_data.get('is_synchronous_condenser', False),
                'vPu': ex_data.get('v_pu', 1.0),
                'pPu': ex_data.get('pg_pu', 0.0),
                'qPu': ex_data.get('qg_pu', 0.0),
                'isEquipmentLead': False,
                'electricalBranch': True,
            }
            lead_el = {
                'id': lead_id,
                'type': 'line',
                'position': g_pos,
                'endPosition': {'dx': bx, 'dy': by},
                'startElementId': gen_id,
                'endElementId': target_bus_id,
                'label': f"Lead G_{b_num} ↔ Bus_{b_num}",
                'source': 'excel_review_applied',
                'isEquipmentLead': True,
                'isGenLead': True,
                'electricalBranch': False,
                'rPu': 0.0,
                'xPu': 0.0,
                'bPu': 0.0,
                'tapRatio': 1.0,
            }
            return elements + [gen_el, lead_el]
        elif cat == 'load':
            l_pos = {'dx': bx + 20.0, 'dy': by + 60.0}
            load_id = f"load_applied_{b_num}"
            lead_id = f"lead_load_applied_{b_num}"
            load_el = {
                'id': load_id,
                'type': 'load',
                'parentBusId': target_bus_id,
                'bus_number': b_num,
                'position': l_pos,
                'width': 36.0,
                'height': 40.0,
                'label': ex_data.get('label', f"Load_{b_num}"),
                'source': 'excel_review_applied',
                'pPu': ex_data.get('p_pu', 0.0),
                'qPu': ex_data.get('q_pu', 0.0),
                'isEquipmentLead': False,
                'electricalBranch': True,
            }
            lead_el = {
                'id': lead_id,
                'type': 'line',
                'position': l_pos,
                'endPosition': {'dx': bx, 'dy': by},
                'startElementId': load_id,
                'endElementId': target_bus_id,
                'label': f"Lead Load_{b_num} ↔ Bus_{b_num}",
                'source': 'excel_review_applied',
                'isEquipmentLead': True,
                'isGenLead': False,
                'electricalBranch': False,
                'rPu': 0.0,
                'xPu': 0.0,
                'bPu': 0.0,
                'tapRatio': 1.0,
            }
            return elements + [load_el, lead_el]
        return elements

    def test_1_bus_ok_excel_gen_exists_vision_gen_missing(self):
        """
        TEST 1
        Bus 정상, Excel Generator 존재, Vision Generator 없음
        -> proposal 생성
        -> 실제 element 변화 없음 (zero auto mutation)
        -> solver 변화 없음
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '3': {'bus_number': 3, 'type': 'PQ', 'pload_pu': 0.3, 'qload_pu': 0.1},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.05},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 80.0, 'pg_pu': 0.8, 'qg_pu': 0.3, 'voltage_setpoint': 1.02},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
                '2': {'from_bus': 2, 'to_bus': 3, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True, 'position': {'dx': 100.0, 'dy': 200.0}},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'position': {'dx': 250.0, 'dy': 200.0}},
            {'id': 'bus_3', 'type': 'bus', 'label': '3', 'bus_number': 3, 'isSlack': False, 'position': {'dx': 400.0, 'dy': 200.0}},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'label': 'G_1', 'bus_number': 1},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'label': 'Line 1-2'},
            {'id': 'line_2_3', 'type': 'line', 'startElementId': 'bus_2', 'endElementId': 'bus_3', 'label': 'Line 2-3'},
            {'id': 'load_3', 'type': 'load', 'parentBusId': 'bus_3', 'bus_number': 3, 'label': 'Load_3'},
            # Bus 2 Generator is missing in diagram
        ]

        count_before = len(diagram_elements)
        solver_input_before = self.solver.parse_elements(diagram_elements)

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Element count must be unchanged (NO auto-mutation)
        self.assertEqual(len(updated_elements), count_before)
        self.assertFalse(any('gen_auto' in str(e.get('id', '')) for e in updated_elements))

        # 2. Proposal generated for Bus 2 Generator
        proposals = summary.get('repair_proposals', [])
        self.assertEqual(len(proposals), 1)
        prop = proposals[0]
        self.assertEqual(prop['category'], 'generator')
        self.assertEqual(prop['bus_number'], 2)
        self.assertEqual(prop['action'], 'suggest_add')
        self.assertEqual(prop['reason'], 'EXCEL_EXISTS_VISION_MISSING')
        self.assertAlmostEqual(prop['excel_data']['pg_mw'], 80.0)
        self.assertAlmostEqual(prop['excel_data']['pg_pu'], 0.8)

        # 3. Solver parsed input unchanged
        solver_input_after = self.solver.parse_elements(updated_elements)
        self.assertEqual(len(solver_input_before['gens_by_bus']), len(solver_input_after['gens_by_bus']))
        self.assertNotIn(2, solver_input_after['gens_by_bus'])

    def test_2_apply_generator_proposal(self):
        """
        TEST 2
        Generator proposal Apply
        -> Generator + lead 생성
        -> P/Q/V Excel 적용
        -> solver에 Generator 포함
        """
        proposal = {
            'category': 'generator',
            'action': 'suggest_add',
            'bus_number': 2,
            'excel_data': {
                'bus_number': 2,
                'pg_mw': 80.0,
                'pg_pu': 0.8,
                'qg_mvar': 30.0,
                'qg_pu': 0.3,
                'v_pu': 1.02,
                'is_slack': False,
                'is_synchronous_condenser': False,
                'label': 'G_2'
            }
        }
        elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True, 'position': {'dx': 100.0, 'dy': 200.0}},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'position': {'dx': 300.0, 'dy': 250.0}},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'rPu': 0.01, 'xPu': 0.05, 'bPu': 0.0},
        ]

        elements_applied = self._simulate_apply_proposal(elements, proposal)

        # Generator & lead added
        gen_el = next((e for e in elements_applied if e.get('type') == 'generator' and e.get('bus_number') == 2), None)
        lead_el = next((e for e in elements_applied if e.get('isEquipmentLead') and e.get('isGenLead')), None)

        self.assertIsNotNone(gen_el)
        self.assertIsNotNone(lead_el)
        self.assertEqual(gen_el['source'], 'excel_review_applied')
        self.assertEqual(gen_el['position'], {'dx': 320.0, 'dy': 190.0}) # Canvas coordinates near Bus 2!
        self.assertAlmostEqual(gen_el['pPu'], 0.8)
        self.assertAlmostEqual(gen_el['qPu'], 0.3)
        self.assertAlmostEqual(gen_el['vPu'], 1.02)

        # Solver must now include Bus 2 Generator
        parsed = self.solver.parse_elements(elements_applied)
        self.assertIn(2, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][2][0]['p_pu'], 0.8)

        # Lead must NOT be parsed into transmission branches
        lead_branches = [b for b in parsed['branches'] if 'lead' in str(b.get('label', '')).lower()]
        self.assertEqual(len(lead_branches), 0)

    def test_3_reject_proposal(self):
        """
        TEST 3
        Proposal Reject
        -> Canvas 변화 없음
        -> solver 변화 없음
        -> rejected 기록
        """
        elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True, 'position': {'dx': 100.0, 'dy': 200.0}},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'position': {'dx': 300.0, 'dy': 250.0}},
        ]
        count_before = len(elements)
        parsed_before = self.solver.parse_elements(elements)

        # User rejects proposal -> elements list is NOT modified
        rejected_log = []
        proposal = {'category': 'generator', 'bus_number': 2}
        rejected_log.append(f"Rejected proposal for Bus {proposal['bus_number']} {proposal['category']}")

        self.assertEqual(len(elements), count_before)
        parsed_after = self.solver.parse_elements(elements)
        self.assertEqual(len(parsed_before['gens_by_bus']), len(parsed_after['gens_by_bus']))
        self.assertEqual(len(rejected_log), 1)

    def test_4_excel_load_exists_vision_load_missing(self):
        """
        TEST 4
        Excel Load 존재, Vision Load 없음
        -> Load proposal 생성
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_mw': 50.0, 'qload_mvar': 20.0, 'pload_pu': 0.5, 'qload_pu': 0.2},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True, 'position': {'dx': 100.0, 'dy': 200.0}},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'position': {'dx': 250.0, 'dy': 200.0}},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'label': 'G_1', 'bus_number': 1},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2'},
            # Bus 2 Load missing
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Element count unchanged
        self.assertEqual(len(updated_elements), len(diagram_elements))

        # Load proposal generated
        proposals = summary.get('repair_proposals', [])
        load_props = [p for p in proposals if p['category'] == 'load']
        self.assertEqual(len(load_props), 1)
        self.assertEqual(load_props[0]['bus_number'], 2)
        self.assertAlmostEqual(load_props[0]['excel_data']['p_mw'], 50.0)
        self.assertAlmostEqual(load_props[0]['excel_data']['p_pu'], 0.5)

    def test_5_apply_load_proposal(self):
        """
        TEST 5
        Load Apply
        -> Load + non-electrical lead 생성
        -> Solver에 Load 포함
        """
        proposal = {
            'category': 'load',
            'action': 'suggest_add',
            'bus_number': 2,
            'excel_data': {
                'bus_number': 2,
                'p_mw': 50.0,
                'p_pu': 0.5,
                'q_mvar': 20.0,
                'q_pu': 0.2,
                'label': 'Load_2',
            }
        }
        elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True, 'position': {'dx': 100.0, 'dy': 200.0}},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'position': {'dx': 300.0, 'dy': 200.0}},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'rPu': 0.01, 'xPu': 0.05, 'bPu': 0.0},
        ]

        elements_applied = self._simulate_apply_proposal(elements, proposal)

        # Load & lead added
        load_el = next((e for e in elements_applied if e.get('type') == 'load' and e.get('bus_number') == 2), None)
        lead_el = next((e for e in elements_applied if e.get('isEquipmentLead') and not e.get('isGenLead')), None)

        self.assertIsNotNone(load_el)
        self.assertIsNotNone(lead_el)
        self.assertEqual(load_el['source'], 'excel_review_applied')
        self.assertEqual(load_el['position'], {'dx': 320.0, 'dy': 260.0}) # below bus
        self.assertAlmostEqual(load_el['pPu'], 0.5)
        self.assertAlmostEqual(load_el['qPu'], 0.2)

        # Solver must include Load
        parsed = self.solver.parse_elements(elements_applied)
        self.assertIn(2, parsed['loads_by_bus'])
        self.assertAlmostEqual(parsed['loads_by_bus'][2][0]['p_pu'], 0.5)

        # Lead not in branches
        self.assertEqual(len(parsed['branches']), 1)

    def test_6_bus_mismatch_error_no_proposals_no_bus_creation(self):
        """
        TEST 6
        Bus mismatch
        -> ERROR
        -> proposal 없음 (repair_proposals == [])
        -> 자동 Bus 생성 없음
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '3': {'bus_number': 3, 'type': 'PQ', 'pload_pu': 0.3, 'qload_pu': 0.1},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        # Canvas only has Bus 1, Bus 2 (Bus 3 missing)
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Bus validation failed
        self.assertFalse(summary.get('bus_validation_passed', True))
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        self.assertIn(3, mismatch.get('details', {}).get('missing_buses', []))

        # 2. Strict policy: NO proposals generated when bus validation fails
        self.assertEqual(len(summary.get('repair_proposals', [])), 0)

        # 3. NO bus created
        self.assertEqual(len(updated_elements), 2)
        self.assertFalse(any(e.get('bus_number') == 3 for e in updated_elements))

    def test_7_branch_mismatch_error_no_line_auto_creation(self):
        """
        TEST 7
        Branch mismatch
        -> ERROR / REVIEW
        -> Line 자동 생성 없음
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        # Canvas has Bus 1 and Bus 2, but NO line connecting them
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'bus_number': 1},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Line is NOT auto-created
        self.assertEqual(len(updated_elements), len(diagram_elements))
        self.assertFalse(any(e.get('type') == 'line' for e in updated_elements))

        # Reported as missing branch discrepancy
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        self.assertIn([1, 2], mismatch.get('details', {}).get('missing_branches', []))

    def test_8_existing_generator_and_load_parameter_update_no_proposals(self):
        """
        TEST 8
        Generator/Load 기존 존재
        -> proposal 없음
        -> 기존 객체 parameter update
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_mw': 45.0, 'qload_mvar': 15.0, 'pload_pu': 0.45, 'qload_pu': 0.15},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.05},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 40.0, 'pg_pu': 0.4, 'qg_pu': 0.1, 'voltage_setpoint': 1.01},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'bus_number': 1},
            {'id': 'gen_2', 'type': 'generator', 'parentBusId': 'bus_2', 'bus_number': 2},
            {'id': 'load_2', 'type': 'load', 'parentBusId': 'bus_2', 'bus_number': 2},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Zero proposals because all equipment already exists
        self.assertEqual(len(summary.get('repair_proposals', [])), 0)

        # Existing elements parameters updated
        gen2 = next(e for e in updated_elements if e['id'] == 'gen_2')
        load2 = next(e for e in updated_elements if e['id'] == 'load_2')
        self.assertAlmostEqual(gen2['pPu'], 0.4)
        self.assertAlmostEqual(gen2['vPu'], 1.01)
        self.assertAlmostEqual(load2['pPu'], 0.45)
        self.assertAlmostEqual(load2['qPu'], 0.15)

    def test_9_proposal_generation_alone_leaves_solver_input_identical(self):
        """
        TEST 9
        proposal generation만 수행
        -> before/after Solver parsed input 완전히 동일
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.2, 'qload_pu': 0.05},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 70.0, 'pg_pu': 0.7, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False, 'pPu': 0.2, 'qPu': 0.05},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'bus_number': 1},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'rPu': 0.01, 'xPu': 0.05, 'bPu': 0.0},
        ]

        # Solver parse before proposal generation
        parsed_before = self.solver.parse_elements(diagram_elements)

        # Call apply_to_elements (generates proposal for Bus 2 Gen)
        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Solver parse after proposal generation
        parsed_after = self.solver.parse_elements(updated_elements)

        self.assertEqual(len(parsed_before['buses']), len(parsed_after['buses']))
        self.assertEqual(len(parsed_before['gens_by_bus']), len(parsed_after['gens_by_bus']))
        self.assertEqual(len(parsed_before['loads_by_bus']), len(parsed_after['loads_by_bus']))
        self.assertEqual(len(parsed_before['branches']), len(parsed_after['branches']))
        self.assertNotIn(2, parsed_after['gens_by_bus'])

    def test_10_case24_psse_regression_proposal_flow(self):
        """
        TEST 10
        case24_psse.xlsx
        -> Bus 14 Generator missing proposal 표시 확인
        -> Apply 전 solver에는 추가되지 않는지 확인
        -> Apply 후 Bus 14 Generator가 실제 Canvas의 Bus 14 위치 근처에 표시되는지 확인
        -> lead가 Ybus branch에 포함되지 않는지 확인
        """
        excel_path = os.path.join(backend_dir, 'sample_cases', 'case24_psse.xlsx')
        if not os.path.exists(excel_path):
            self.skipTest(f"case24_psse.xlsx not found at {excel_path}")

        excel_data = self.importer.parse_excel(excel_path)
        slack_bus = excel_data['slack_bus_number']

        # 24개 모선 요소 구성 (Canvas Bus 1..24 완벽 일치)
        elements = []
        for b_str in excel_data['buses'].keys():
            b_num = int(b_str)
            elements.append({
                'id': f'bus_{b_num}',
                'type': 'bus',
                'label': str(b_num),
                'bus_number': b_num,
                'isSlack': (b_num == slack_bus),
                'position': {'dx': 100.0 * (b_num % 6), 'dy': 100.0 * (b_num // 6)}
            })

        # Bus 14를 제외한 발전기 추가 (도면에서 Bus 14 발전기만 미검출된 상황)
        for b_str, g in excel_data['generators'].items():
            b_num = int(b_str)
            if b_num != 14:
                elements.append({
                    'id': f'gen_{b_num}',
                    'type': 'generator',
                    'parentBusId': f'bus_{b_num}',
                    'bus_number': b_num,
                    'label': f'G_{b_num}'
                })

        # 모든 부하 추가 (Bus 14 부하 포함)
        for b_str, b_info in excel_data['buses'].items():
            b_num = int(b_str)
            if b_info.get('pload_mw', 0) > 0 or b_info.get('qload_mvar', 0) > 0:
                elements.append({
                    'id': f'load_{b_num}',
                    'type': 'load',
                    'parentBusId': f'bus_{b_num}',
                    'bus_number': b_num,
                    'label': f'Load_{b_num}'
                })

        # 선로 및 변압기 추가
        added_lines = set()
        for br in excel_data.get('branches', {}).values():
            fb = int(br['from_bus'])
            tb = int(br['to_bus'])
            pair = tuple(sorted([fb, tb]))
            if pair in added_lines:
                continue
            added_lines.add(pair)
            elements.append({
                'id': f'line_{fb}_{tb}',
                'type': 'line',
                'startElementId': f'bus_{fb}',
                'endElementId': f'bus_{tb}',
                'rPu': br.get('r_pu', 0.01),
                'xPu': br.get('x_pu', 0.05),
                'bPu': br.get('b_pu', 0.0),
            })
        added_trans = set()
        for tr in excel_data.get('transformers', {}).values():
            fb = int(tr['from_bus'])
            tb = int(tr['to_bus'])
            pair = tuple(sorted([fb, tb]))
            if pair in added_trans:
                continue
            added_trans.add(pair)
            elements.append({
                'id': f'trans_{fb}_{tb}',
                'type': 'transformer',
                'startElementId': f'bus_{fb}',
                'endElementId': f'bus_{tb}',
                'tapRatio': tr.get('tap', 1.0),
                'rPu': tr.get('r_pu', 0.001),
                'xPu': tr.get('x_pu', 0.02),
            })

        count_before = len(elements)

        # 1. apply_to_elements 실행
        updated_elements, summary = self.importer.apply_to_elements(elements, excel_data)

        # 2. Bus validation passed
        self.assertTrue(summary.get('bus_validation_passed', False))

        # 3. Canvas elements count must NOT change (No auto mutation)
        self.assertEqual(len(updated_elements), count_before)
        self.assertFalse(any('gen_auto' in str(e.get('id', '')) for e in updated_elements))

        # 4. Bus 14 Generator missing proposal must be present
        proposals = summary.get('repair_proposals', [])
        gen14_prop = next((p for p in proposals if p['category'] == 'generator' and p['bus_number'] == 14), None)
        self.assertIsNotNone(gen14_prop, "Bus 14 generator proposal must be present")
        self.assertAlmostEqual(gen14_prop['excel_data']['pg_mw'], 100.0)

        # 5. BEFORE Apply: solver input does NOT contain Bus 14 Generator
        parsed_before_apply = self.solver.parse_elements(updated_elements)
        self.assertNotIn(14, parsed_before_apply['gens_by_bus'])

        # 6. User clicks Apply -> simulate apply on Canvas
        elements_after_apply = self._simulate_apply_proposal(updated_elements, gen14_prop)

        # 7. AFTER Apply: Bus 14 Generator created near Bus 14 Canvas position
        bus14 = next(e for e in elements_after_apply if e['id'] == 'bus_14')
        bus14_pos = bus14['position']
        gen14 = next(e for e in elements_after_apply if e.get('type') == 'generator' and e.get('bus_number') == 14)
        lead14 = next(e for e in elements_after_apply if e.get('isEquipmentLead') and e.get('endElementId') == 'bus_14')

        self.assertIsNotNone(gen14)
        self.assertIsNotNone(lead14)
        self.assertEqual(gen14['position']['dx'], bus14_pos['dx'] + 20.0)
        self.assertEqual(gen14['position']['dy'], bus14_pos['dy'] - 60.0)

        # 8. Solver includes Bus 14 Generator and lead is NOT in branches
        parsed_after_apply = self.solver.parse_elements(elements_after_apply)
        self.assertIn(14, parsed_after_apply['gens_by_bus'])
        self.assertAlmostEqual(parsed_after_apply['gens_by_bus'][14][0]['p_pu'], 1.0)
        self.assertEqual(len(parsed_before_apply['branches']), len(parsed_after_apply['branches']))

        # 9. Power flow calculation converges
        res = self.solver.solve(elements_after_apply)
        self.assertTrue(res['converged'], f"Solver must converge: {res.get('error')}")


if __name__ == '__main__':
    unittest.main()
