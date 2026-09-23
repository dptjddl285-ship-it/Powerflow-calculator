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

    def test_1_vision_generator_exists_and_excel_exists(self):
        """
        TEST 1 — Vision Generator 존재 + Excel Generator 존재
        결과: 기존 Generator update, 신규 element 생성 없음
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
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.02},
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

        # 신규 요소가 생성되지 않고 기존 요소 개수 유지
        self.assertEqual(len(updated_elements), init_len)
        gen2 = next(e for e in updated_elements if e['id'] == 'gen_2')
        self.assertAlmostEqual(gen2['pPu'], 0.5)
        self.assertAlmostEqual(gen2['qPu'], 0.2)
        self.assertAlmostEqual(gen2['vPu'], 1.02)
        # gen_auto_2 가 별도로 생성되지 않음
        self.assertFalse(any(e['id'] == 'gen_auto_2' for e in updated_elements))

    def test_2_vision_generator_missing_and_excel_exists(self):
        """
        TEST 2 — Vision Generator 미검출 + Excel Generator 존재 (Bus 정상 존재)
        결과: Generator 1개 자동 생성, Excel P/Q/Vset 적용, source=excel_auto, Solver까지 전달
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.05},
                '2': {'bus_number': 2, 'is_slack': False, 'pg_mw': 80.0, 'pg_pu': 0.8, 'qg_pu': 0.3, 'voltage_setpoint': 1.03},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'label': 'G_1', 'bus_number': 1},
            # bus_2의 generator 심볼이 도면에서 미검출됨
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # gen_auto_2가 자동 생성되어야 함
        auto_gen = next((e for e in updated_elements if e['id'] == 'gen_auto_2'), None)
        self.assertIsNotNone(auto_gen, "gen_auto_2가 생성되어야 함")
        self.assertEqual(auto_gen['type'], 'generator')
        self.assertEqual(auto_gen['parentBusId'], 'bus_2')
        self.assertEqual(auto_gen['bus_number'], 2)
        self.assertEqual(auto_gen['source'], 'excel_auto')
        self.assertAlmostEqual(auto_gen['pPu'], 0.8)
        self.assertAlmostEqual(auto_gen['qPu'], 0.3)
        self.assertAlmostEqual(auto_gen['vPu'], 1.03)

        # Solver parse_elements에도 전달되는지 확인
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(2, parsed['gens_by_bus'])
        self.assertEqual(len(parsed['gens_by_bus'][2]), 1)
        self.assertAlmostEqual(parsed['gens_by_bus'][2][0]['p_pu'], 0.8)
        self.assertAlmostEqual(parsed['gens_by_bus'][2][0]['q_pu'], 0.3)

    def test_3_load_and_generator_coexistence(self):
        """
        TEST 3 — Load와 Generator 동시 존재 (Vision에서는 Load만 검출)
        결과: Load 유지, Generator 자동 추가, 둘 다 Solver 입력에 반영
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '5': {'bus_number': 5, 'type': 'PV', 'pload_pu': 0.45, 'qload_pu': 0.15},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '5': {'bus_number': 5, 'is_slack': False, 'pg_mw': 100.0, 'pg_pu': 1.0, 'qg_pu': 0.4, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_5', 'type': 'bus', 'label': '5', 'bus_number': 5, 'isSlack': False},
            {'id': 'load_5', 'type': 'load', 'parentBusId': 'bus_5', 'label': 'Load_5'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Load_5 보존 확인
        load5 = next((e for e in updated_elements if e['id'] == 'load_5'), None)
        self.assertIsNotNone(load5, "Load_5가 보존되어야 함")
        self.assertAlmostEqual(load5['pPu'], 0.45)
        self.assertAlmostEqual(load5['qPu'], 0.15)
        self.assertFalse(load5.get('isSynchronousCondenser', False), "Load는 SC로 변환되면 안 됨")
        self.assertNotIn("동기조상기", load5.get('label', ''))

        # 2. gen_auto_5 자동 추가 확인
        auto_gen = next((e for e in updated_elements if e['id'] == 'gen_auto_5'), None)
        self.assertIsNotNone(auto_gen, "gen_auto_5가 추가되어야 함")
        self.assertAlmostEqual(auto_gen['pPu'], 1.0)
        self.assertEqual(auto_gen['source'], 'excel_auto')

        # 3. Solver 입력에 둘 다 존재하는지 확인
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(5, parsed['loads_by_bus'])
        self.assertAlmostEqual(parsed['loads_by_bus'][5][0]['p_pu'], 0.45)
        self.assertIn(5, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][5][0]['p_pu'], 1.0)

    def test_4_bus_missing(self):
        """
        TEST 4 — Bus 없음 (Excel에 Bus 99 Gen 있으나 Canvas에 Bus 99 없음)
        결과: Generator를 임의 위치에 자동 생성하지 않음, validation/mismatch 처리
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '99': {'bus_number': 99, 'type': 'PV', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 0.0, 'pg_pu': 0.0, 'qg_pu': 0.0, 'voltage_setpoint': 1.0},
                '99': {'bus_number': 99, 'is_slack': False, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {}
        }
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            # bus_99 자체가 도면에 없음
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # gen_auto_99가 생성되지 않아야 함
        self.assertFalse(any('99' in str(e.get('id', '')) for e in updated_elements))
        # mismatch_report에 누락이 보고되어야 함
        mismatch = summary.get('mismatch_report', {})
        self.assertFalse(mismatch.get('is_matched', True))
        disc_targets = [d.get('target') for d in mismatch.get('discrepancies', [])]
        self.assertTrue('Bus 99' in disc_targets or 'G_99' in disc_targets)

    def test_5_duplicate_prevention(self):
        """
        TEST 5 — 중복 방지: Excel 적용을 두 번 실행해도 gen_auto_N이 두 개 생기지 않음
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
        self.assertEqual(len(gens_pass1), 1)

        # 2차 적용 (1차 결과를 다시 인입)
        second_pass_elements, _ = self.importer.apply_to_elements(first_pass_elements, excel_data)
        gens_pass2 = [e for e in second_pass_elements if e.get('type') == 'generator' and (e.get('bus_number') == 3 or '3' in str(e.get('id', '')))]
        self.assertEqual(len(gens_pass2), 1, "중복 생성 없이 1개만 유지되어야 함")

    def test_6_arbitrary_bus_number_not_relying_on_bus14(self):
        """
        TEST 6 — Bus 14 같은 특정 번호에 의존하지 않음 (임의의 Bus 37 자동보완)
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
        auto_gen = next((e for e in updated_elements if e['id'] == 'gen_auto_37'), None)
        self.assertIsNotNone(auto_gen, "Bus 37에 대해 gen_auto_37이 정상 생성되어야 함")
        self.assertAlmostEqual(auto_gen['pPu'], 1.2)
        self.assertAlmostEqual(auto_gen['qPu'], 0.45)
        self.assertAlmostEqual(auto_gen['vPu'], 1.01)
        self.assertEqual(auto_gen['source'], 'excel_auto')

        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(37, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][37][0]['p_pu'], 1.2)

    def test_7_synchronous_condenser_misclassification_prevention(self):
        """
        TEST 7 — Synchronous Condenser 오분류 방지
        Bus 번호가 14라는 이유만으로 SC가 되지 않아야 함.
        Load가 존재한다는 이유로 Generator가 사라지지 않아야 함.
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
            {'id': 'bus_14', 'type': 'bus', 'label': '14', 'bus_number': 14, 'isSlack': False},
            {'id': 'load_14', 'type': 'load', 'parentBusId': 'bus_14', 'label': 'Load_14'},
        ]

        updated_elements, _ = self.importer.apply_to_elements(diagram_elements, excel_data)

        # 1. Load_14는 SC가 아니어야 함
        load14 = next(e for e in updated_elements if e['id'] == 'load_14')
        self.assertFalse(load14.get('isSynchronousCondenser', False))
        self.assertEqual(load14['label'], 'Load_14')

        # 2. gen_auto_14가 생성되어야 함 (Load가 있다고 생략되면 안 됨)
        gen14 = next((e for e in updated_elements if e['id'] == 'gen_auto_14'), None)
        self.assertIsNotNone(gen14, "gen_auto_14가 생성되어야 함")
        self.assertFalse(gen14.get('isSynchronousCondenser', False), "명시적 SC 표기 없으므로 일반 발전기여야 함")
        self.assertAlmostEqual(gen14['pPu'], 1.0)

    def test_8_case24_psse_regression(self):
        """
        TEST 8 — case24_psse.xlsx 회귀 검증
        실제 샘플 파일 case24_psse.xlsx를 로드하여:
        - Bus 14 Load 유지
        - Bus 14 Excel Generator 존재
        - Generator가 Solver input에 전달
        - 중복 Generator 없음
        - 전력 수지 검증 (Slack 결과 특정 숫자 하드코딩 없이 검증)
        """
        excel_path = os.path.join(backend_dir, 'sample_cases', 'case24_psse.xlsx')
        if not os.path.exists(excel_path):
            self.skipTest(f"case24_psse.xlsx not found at {excel_path}")

        excel_data = self.importer.parse_excel(excel_path)
        slack_bus = excel_data['slack_bus_number']

        # 24개 모선 요소 구성
        elements = []
        for b_str in excel_data['buses'].keys():
            b_num = int(b_str)
            elements.append({
                'id': f'bus_{b_num}',
                'type': 'bus',
                'label': str(b_num),
                'bus_number': b_num,
                'isSlack': (b_num == slack_bus)
            })

        # Bus 14를 제외한 발전기 추가 (도면에서 Bus 14 발전기 심볼만 미검출된 상황 모사)
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

        # 선로 및 변압기 추가 (단방향만 추가)
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

        # apply_to_elements 실행
        updated_elements, summary = self.importer.apply_to_elements(elements, excel_data)

        # 1. Bus 14 Load 유지 확인
        load14 = next((e for e in updated_elements if e['id'] == 'load_14'), None)
        self.assertIsNotNone(load14)
        self.assertAlmostEqual(load14['pPu'], 0.78)
        self.assertAlmostEqual(load14['qPu'], 0.20)

        # 2. Bus 14 Generator 자동 보완 확인
        auto_gen_14 = next((e for e in updated_elements if e['id'] == 'gen_auto_14'), None)
        self.assertIsNotNone(auto_gen_14, "Bus 14 generator must be auto-supplemented")
        self.assertAlmostEqual(auto_gen_14['pPu'], 1.0) # 100 MW / 100 MVA
        self.assertEqual(auto_gen_14['source'], 'excel_auto')

        # 3. 중복 없음 확인
        bus14_gens = [e for e in updated_elements if e.get('type') == 'generator' and e.get('bus_number') == 14]
        self.assertEqual(len(bus14_gens), 1)

        # 4. Solver 파싱 확인
        parsed = self.solver.parse_elements(updated_elements)
        self.assertIn(14, parsed['gens_by_bus'])
        self.assertAlmostEqual(parsed['gens_by_bus'][14][0]['p_pu'], 1.0)
        self.assertIn(14, parsed['loads_by_bus'])
        self.assertAlmostEqual(parsed['loads_by_bus'][14][0]['p_pu'], 0.78)

        # 5. Solver 조류계산 수렴 및 전력 수지 검증
        result = self.solver.solve(updated_elements)
        self.assertTrue(result['converged'], f"Solver must converge: {result.get('error')}")

        # Power balance check: Gen = Load + Losses
        tot_gen = result['summary']['total_gen_p_mw']
        tot_load = result['summary']['total_load_p_mw']
        tot_loss = result['summary']['total_loss_p_mw']
        self.assertAlmostEqual(tot_gen, tot_load + tot_loss, delta=0.5)

        # 6. Slack 발전기 정상 작동 및 전체 계통 전력 수지 일치 확인 (특정 숫자 하드코딩 없이 검증)
        bus1_res = next(b for b in result['bus_results'] if b['bus'] == slack_bus)
        bus1_pgen = bus1_res.get('pgen', bus1_res.get('pgen_pu', 0.0) * 100.0)
        self.assertGreater(bus1_pgen, 0.0, "Slack 발전기는 양의 발전량을 출력해야 함")
        self.assertAlmostEqual(tot_gen, tot_load + tot_loss, places=2)


if __name__ == '__main__':
    unittest.main()
