import unittest
import os
import sys

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.excel_case_importer import ExcelCaseImporter
from core.power_flow_solver import PowerFlowSolver


class TestExcelGeneratorAutoSupplement(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.solver = PowerFlowSolver()

    def test_1_bus123_excel_bus2_gen_missed(self):
        """
        TEST 1
        Canvas Bus: 1, 2, 3
        Excel Bus: 1, 2, 3
        Excel Bus 2 Generator exists, Vision Generator missed
        결과:
        - Bus 2 유지
        - Generator 자동 생성 (gen_auto_2)
        - Generator-Bus 2 lead 자동 생성 (lead_gen_auto_2)
        - Excel P/Q/V 적용
        - Solver에 Generator 포함
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
            # Bus 2 Generator missed by Vision
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Bus 2 유지 확인
        bus2 = next((e for e in updated_elements if e['id'] == 'bus_2'), None)
        self.assertIsNotNone(bus2)
        self.assertEqual(bus2.get('bus_number'), 2)

        # 2. Generator 자동 생성 (gen_auto_2)
        auto_gen = next((e for e in updated_elements if e['id'] == 'gen_auto_2'), None)
        self.assertIsNotNone(auto_gen, "gen_auto_2 must be auto-created")
        self.assertEqual(auto_gen['type'], 'generator')
        self.assertEqual(auto_gen['parentBusId'], 'bus_2')
        self.assertEqual(auto_gen['bus_number'], 2)
        self.assertEqual(auto_gen['source'], 'excel_auto')
        self.assertAlmostEqual(auto_gen['pPu'], 0.8)
        self.assertAlmostEqual(auto_gen['qPu'], 0.3)
        self.assertAlmostEqual(auto_gen['vPu'], 1.02)

        # 3. Generator lead 자동 생성 (lead_gen_auto_2)
        auto_lead = next((e for e in updated_elements if e['id'] == 'lead_gen_auto_2'), None)
        self.assertIsNotNone(auto_lead, "lead_gen_auto_2 must be auto-created")
        self.assertEqual(auto_lead['type'], 'line')
        self.assertEqual(auto_lead['startElementId'], 'gen_auto_2')
        self.assertEqual(auto_lead['endElementId'], 'bus_2')
        self.assertTrue(auto_lead.get('isEquipmentLead'))
        self.assertTrue(auto_lead.get('isGenLead'))
        self.assertFalse(auto_lead.get('electricalBranch'))
        self.assertEqual(auto_lead['source'], 'excel_auto')

        # 4. Solver에 Generator 정상 포함
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(2, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][2][0]['p_pu'], 0.8)

    def test_2_bus_mismatch_canvas_12_excel_123_error(self):
        """
        TEST 2
        Canvas Bus: 1, 2
        Excel Bus: 1, 2, 3
        결과:
        - ERROR (bus_validation_passed == False, mismatch report is_matched == False)
        - Bus 3 자동 생성 금지
        - Generator 자동 생성도 실행하지 않음
        - Solver 실행 차단
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '3': {'bus_number': 3, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '3': {'bus_number': 3, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Bus validation FAILED
        self.assertFalse(summary.get('bus_validation_passed', True))
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        self.assertIn(3, mismatch.get('details', {}).get('missing_buses', []))

        # Bus 3 자동 생성 금지
        self.assertFalse(any('bus_3' in str(e.get('id', '')) or e.get('bus_number') == 3 for e in updated_elements))

        # Generator 자동 생성 금지
        self.assertFalse(any(e.get('id') == 'gen_auto_3' for e in updated_elements))
        self.assertEqual(len(summary.get('added_auto_generators', [])), 0)

        # Solver 실행 시 누락된 모선에 대한 검증 오류로 실행 차단
        parsed = self.solver.parse_elements(updated_elements)
        self.assertNotIn(3, parsed['buses'])

    def test_3_bus_mismatch_canvas_1234_excel_123_error(self):
        """
        TEST 3
        Canvas: Bus 1, Bus 2, Bus 3, Bus 4
        Excel: Bus 1, Bus 2, Bus 3
        결과:
        - ERROR (bus_validation_passed == False)
        - Bus 4 삭제/수정 금지 (Canvas 요소 보존)
        - Excel Bus 4 생성 금지
        - 자동보완 금지
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.1, 'qload_pu': 0.05},
                '3': {'bus_number': 3, 'type': 'PQ', 'pload_pu': 0.2, 'qload_pu': 0.1},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'bus_3', 'type': 'bus', 'label': '3', 'bus_number': 3, 'isSlack': False},
            {'id': 'bus_4', 'type': 'bus', 'label': '4', 'bus_number': 4, 'isSlack': False},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Bus validation FAILED
        self.assertFalse(summary.get('bus_validation_passed', True))
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        self.assertIn(4, mismatch.get('details', {}).get('surplus_buses', []))

        # Bus 4 삭제/수정 금지
        bus4 = next((e for e in updated_elements if e['id'] == 'bus_4'), None)
        self.assertIsNotNone(bus4, "Bus 4 must not be deleted or modified")
        self.assertEqual(bus4.get('bus_number'), 4)

        # 자동보완 금지
        self.assertEqual(len(summary.get('added_auto_generators', [])), 0)

    def test_4_bus_mismatch_canvas_123_excel_124_error(self):
        """
        TEST 4
        Canvas Bus 수와 Excel Bus 수는 같지만 (3개씩)
        Canvas: 1, 2, 3
        Excel: 1, 2, 4
        결과:
        - ERROR
        - Bus 3 -> Bus 4 자동 rename 금지
        - Bus 4 자동 생성 금지
        - 자동보완 금지
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '4': {'bus_number': 4, 'type': 'PQ', 'pload_pu': 0.2, 'qload_pu': 0.1},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'bus_3', 'type': 'bus', 'label': '3', 'bus_number': 3, 'isSlack': False},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Bus validation FAILED
        self.assertFalse(summary.get('bus_validation_passed', True))
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        self.assertIn(4, mismatch.get('details', {}).get('missing_buses', []))
        self.assertIn(3, mismatch.get('details', {}).get('surplus_buses', []))

        # Bus 3 -> 4 자동 rename 금지
        bus3 = next((e for e in updated_elements if e['id'] == 'bus_3'), None)
        self.assertIsNotNone(bus3)
        self.assertEqual(bus3.get('bus_number'), 3)
        self.assertEqual(bus3.get('label'), '1' if bus3.get('id') == 'bus_1' else ('3' if bus3.get('id') == 'bus_3' else ''))

        # Bus 4 자동 생성 금지
        self.assertFalse(any(e.get('bus_number') == 4 or 'bus_4' in str(e.get('id', '')) for e in updated_elements))

    def test_5_bus14_load_exists_gen_missed(self):
        """
        TEST 5
        Bus 14에 Load 존재
        Generator Vision 미검출
        Excel Generator 존재
        결과:
        - Load 유지 (SC 오분류 금지)
        - Generator 자동 추가
        - Generator lead 추가
        - 둘 다 같은 Bus에 존재
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '14': {'bus_number': 14, 'type': 'PV', 'pload_pu': 0.78, 'qload_pu': 0.2},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '14': {'bus_number': 14, 'is_slack': False, 'pg_mw': 100.0, 'pg_pu': 1.0, 'qg_pu': 0.46, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_14', 'type': 'bus', 'label': '14', 'bus_number': 14, 'isSlack': False, 'position': {'dx': 300.0, 'dy': 200.0}},
            {'id': 'load_14', 'type': 'load', 'parentBusId': 'bus_14', 'label': 'Load_14', 'bus_number': 14},
        ]

        updated_elements, _ = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Load_14 유지 확인
        load14 = next(e for e in updated_elements if e['id'] == 'load_14')
        self.assertFalse(load14.get('isSynchronousCondenser', False))
        self.assertEqual(load14['label'], 'Load_14')
        self.assertAlmostEqual(load14['pPu'], 0.78)

        # 2. Generator 자동 추가 확인
        gen14 = next((e for e in updated_elements if e['id'] == 'gen_auto_14'), None)
        self.assertIsNotNone(gen14, "gen_auto_14 must be created")
        self.assertEqual(gen14['bus_number'], 14)
        self.assertEqual(gen14['parentBusId'], 'bus_14')
        self.assertAlmostEqual(gen14['pPu'], 1.0)
        self.assertEqual(gen14['source'], 'excel_auto')

        # 3. Generator lead 추가 확인
        lead14 = next((e for e in updated_elements if e['id'] == 'lead_gen_auto_14'), None)
        self.assertIsNotNone(lead14, "lead_gen_auto_14 must be created")
        self.assertEqual(lead14['startElementId'], 'gen_auto_14')
        self.assertEqual(lead14['endElementId'], 'bus_14')

        # 4. 둘 다 같은 Bus 14에 공존
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(14, parsed['loads_by_bus'])
        self.assertIn(14, parsed['gens_by_bus'])

    def test_6_gen_already_detected_in_vision(self):
        """
        TEST 6
        Generator 이미 Vision에서 검출됨
        Excel에도 존재
        결과:
        - 기존 Generator에 Excel data 적용
        - gen_auto 생성 금지
        - lead 중복 생성 금지
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.2, 'qload_pu': 0.1},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.05},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 60.0, 'pg_pu': 0.6, 'qg_pu': 0.25, 'voltage_setpoint': 1.02},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'label': 'G_1', 'bus_number': 1},
            {'id': 'gen_2', 'type': 'generator', 'parentBusId': 'bus_2', 'label': 'G_2', 'bus_number': 2},
        ]
        init_len = len(diagram_elements)

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 기존 발전기 update
        gen2 = next(e for e in updated_elements if e['id'] == 'gen_2')
        self.assertAlmostEqual(gen2['pPu'], 0.6)
        self.assertAlmostEqual(gen2['qPu'], 0.25)
        self.assertAlmostEqual(gen2['vPu'], 1.02)

        # gen_auto 및 lead 생성 금지
        self.assertFalse(any(e['id'] == 'gen_auto_2' for e in updated_elements))
        self.assertFalse(any(e['id'] == 'lead_gen_auto_2' for e in updated_elements))
        self.assertEqual(len(updated_elements), init_len)

    def test_7_excel_apply_twice_no_duplicates(self):
        """
        TEST 7
        Excel apply 두 번 실행
        결과:
        - Generator 중복 없음
        - lead 중복 없음
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '3': {'bus_number': 3, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '3': {'bus_number': 3, 'is_slack': False, 'pg_mw': 60.0, 'pg_pu': 0.6, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_3', 'type': 'bus', 'label': '3', 'bus_number': 3, 'isSlack': False},
        ]

        # 1차 적용
        first_pass_elements, _ = self.importer.apply_to_elements(diagram_elements, excel_data)
        gens_pass1 = [e for e in first_pass_elements if e.get('type') == 'generator' and (e.get('bus_number') == 3 or '3' in str(e.get('id', '')))]
        leads_pass1 = [e for e in first_pass_elements if e.get('type') == 'line' and '3' in str(e.get('id', ''))]
        self.assertEqual(len(gens_pass1), 1)
        self.assertEqual(len(leads_pass1), 1)

        # 2차 적용 (1차 결과 재입력)
        second_pass_elements, _ = self.importer.apply_to_elements(first_pass_elements, excel_data)
        gens_pass2 = [e for e in second_pass_elements if e.get('type') == 'generator' and (e.get('bus_number') == 3 or '3' in str(e.get('id', '')))]
        leads_pass2 = [e for e in second_pass_elements if e.get('type') == 'line' and '3' in str(e.get('id', ''))]
        self.assertEqual(len(gens_pass2), 1, "Generator 중복 없음")
        self.assertEqual(len(leads_pass2), 1, "Lead 중복 없음")

    def test_8_arbitrary_bus37_auto_supplement(self):
        """
        TEST 8
        임의 Bus 37
        Vision Generator 미검출
        Excel Generator 존재
        Bus validation 정상
        결과:
        - 동일하게 Generator + lead 자동보완 (Bus 14 하드코딩 없음)
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '37': {'bus_number': 37, 'type': 'PV', 'pload_pu': 0.1, 'qload_pu': 0.05},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '37': {'bus_number': 37, 'is_slack': False, 'pg_mw': 120.0, 'pg_pu': 1.2, 'qg_pu': 0.45, 'voltage_setpoint': 1.01},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_37', 'type': 'bus', 'label': '37', 'bus_number': 37, 'isSlack': False},
        ]

        updated_elements, _ = self.importer.apply_to_elements(diagram_elements, excel_data)

        # gen_auto_37 생성 확인
        auto_gen = next((e for e in updated_elements if e['id'] == 'gen_auto_37'), None)
        self.assertIsNotNone(auto_gen, "Bus 37 generator must be auto-supplemented")
        self.assertAlmostEqual(auto_gen['pPu'], 1.2)
        self.assertEqual(auto_gen['source'], 'excel_auto')

        # lead_gen_auto_37 생성 확인
        auto_lead = next((e for e in updated_elements if e['id'] == 'lead_gen_auto_37'), None)
        self.assertIsNotNone(auto_lead, "Bus 37 lead must be auto-supplemented")
        self.assertEqual(auto_lead['startElementId'], 'gen_auto_37')
        self.assertEqual(auto_lead['endElementId'], 'bus_37')

        # Solver 전달 확인
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(37, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][37][0]['p_pu'], 1.2)

    def test_9_lead_not_in_ybus_or_branches(self):
        """
        TEST 9
        자동생성 lead가 PowerFlow branch/Ybus에 들어가지 않는지 검증.
        lead 생성 전후로 electrical branch count가 변하지 않아야 한다.
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {
                '1': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.02, 'x_pu': 0.08, 'b_pu': 0.0},
            },
            'transformers': {}
        }
        diagram_elements_before = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'label': 'Line 1-2', 'rPu': 0.02, 'xPu': 0.08},
        ]

        # Lead 생성 전 브랜치 파싱
        parsed_before = self.solver.parse_elements(diagram_elements_before)
        branch_count_before = len(parsed_before['branches'])
        self.assertEqual(branch_count_before, 1)

        # apply_to_elements 실행 (Bus 2 generator 및 lead_gen_auto_2 생성됨)
        updated_elements, _ = self.importer.apply_to_elements(diagram_elements_before, excel_data)

        # lead_gen_auto_2 가 추가되었는지 확인
        lead_el = next((e for e in updated_elements if e['id'] == 'lead_gen_auto_2'), None)
        self.assertIsNotNone(lead_el)

        # Lead 생성 후 브랜치 파싱
        parsed_after = self.solver.parse_elements(updated_elements)
        branch_count_after = len(parsed_after['branches'])

        # 선로 수 불변성 검증: electrical branch count가 변하지 않아야 함
        self.assertEqual(branch_count_before, branch_count_after, "인입선 추가 전후 전기적 브랜치 개수는 동일해야 함")

    def test_10_case24_psse_regression(self):
        """
        TEST 10
        case24_psse.xlsx regression.
        (단, Slack 값을 529로 하드코딩하지 않음)
        검증 항목:
        - Bus 수/번호 validation 통과 여부
        - Bus 14가 실제 Canvas Bus로 존재하는지
        - Excel Generator record가 Bus 14에 매칭되는지
        - Generator 미검출 시 Generator 자동보완
        - Generator lead 자동 생성
        - Load가 삭제되지 않음
        - Generator P/Q가 Solver까지 전달
        - lead는 Ybus/branches에 미포함
        - 전력 수지 일치 및 조류계산 수렴
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

        # 1. apply_to_elements 실행
        updated_elements, summary = self.importer.apply_to_elements(elements, excel_data)

        # 2. Bus 수/번호 validation 통과 여부 검증
        self.assertTrue(summary.get('bus_validation_passed', False), "Bus validation must pass")

        # 3. Bus 14가 실제 Canvas Bus로 존재하는지 확인
        bus14 = next((e for e in updated_elements if e['id'] == 'bus_14'), None)
        self.assertIsNotNone(bus14)
        self.assertEqual(bus14.get('bus_number'), 14)

        # 4. Bus 14 Load 유지 확인
        load14 = next((e for e in updated_elements if e['id'] == 'load_14'), None)
        self.assertIsNotNone(load14)
        self.assertAlmostEqual(load14['pPu'], 0.78)
        self.assertAlmostEqual(load14['qPu'], 0.20)

        # 5. Bus 14 Generator 자동 보완 확인
        auto_gen_14 = next((e for e in updated_elements if e['id'] == 'gen_auto_14'), None)
        self.assertIsNotNone(auto_gen_14, "Bus 14 generator must be auto-supplemented")
        self.assertAlmostEqual(auto_gen_14['pPu'], 1.0)
        self.assertEqual(auto_gen_14['source'], 'excel_auto')

        # 6. Generator lead 자동 생성 확인
        auto_lead_14 = next((e for e in updated_elements if e['id'] == 'lead_gen_auto_14'), None)
        self.assertIsNotNone(auto_lead_14, "Bus 14 lead must be auto-created")
        self.assertEqual(auto_lead_14['startElementId'], 'gen_auto_14')
        self.assertEqual(auto_lead_14['endElementId'], 'bus_14')

        # 7. Solver 파싱 확인 (Gen P/Q 전달, lead는 Ybus/branch 미포함)
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(14, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][14][0]['p_pu'], 1.0)
        self.assertIn(14, parsed['loads_by_bus'])

        # lead가 electrical branches에 포함되지 않음을 확인
        lead_branches = [b for b in parsed['branches'] if 'lead' in str(b.get('line_id', '')).lower()]
        self.assertEqual(len(lead_branches), 0, "Lead line must not be parsed into electrical branches")

        # 8. 조류계산 수렴 및 전력 수지 검증
        result = self.solver.solve(updated_elements)
        self.assertTrue(result['converged'], f"Solver must converge: {result.get('error')}")

        tot_gen = result['summary']['total_gen_p_mw']
        tot_load = result['summary']['total_load_p_mw']
        tot_loss = result['summary']['total_loss_p_mw']
        self.assertAlmostEqual(tot_gen, tot_load + tot_loss, delta=0.5)

        # Slack 모선 발전량 유효성 확인 (특정 숫자 하드코딩 없이 물리 법칙 검증)
        bus1_res = next(b for b in result['bus_results'] if b['bus'] == slack_bus)
        bus1_pgen = bus1_res.get('pgen', bus1_res.get('pgen_pu', 0.0) * 100.0)
        self.assertGreater(bus1_pgen, 0.0, "Slack generator must output positive active power")


if __name__ == '__main__':
    unittest.main()
