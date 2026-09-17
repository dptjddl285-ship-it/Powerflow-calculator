"""Excel vs Diagram Discrepancy Diagnostic Agent.

Provides AI-driven analysis and actionable recovery guidance when diagram elements
do not match parsed Excel grid data.
"""
from __future__ import annotations

import json
import os
import urllib.request
from typing import Any, Dict, List, Optional

from agent.providers import get_assistant_provider


class ExcelDiscrepancyAgent:
    """Agent analyzing divergence between Single Line Diagrams and Excel case data."""

    def __init__(self):
        pass

    def diagnose(
        self,
        elements: List[Dict[str, Any]],
        excel_data: Dict[str, Any],
        mismatch_report: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Diagnose discrepancies and generate actionable advice."""
        if mismatch_report.get("is_matched", False):
            return {
                "status": "matched",
                "headline": "✅ 도면과 엑셀 데이터가 완벽하게 일치합니다.",
                "advice_ko": "모든 모선, 선로, 발전기, 부하 데이터가 엑셀 사양과 정확히 일치하여 즉시 조류계산을 수행할 수 있습니다.",
                "suggested_actions": ["조류계산 실행"],
            }

        details = mismatch_report.get("details", {})
        missing_buses = details.get("missing_buses", [])
        surplus_buses = details.get("surplus_buses", [])
        missing_branches = details.get("missing_branches", [])
        surplus_branches = details.get("surplus_branches", [])
        missing_gens = details.get("missing_generators", [])
        missing_loads = details.get("missing_loads", [])
        stats = mismatch_report.get("stats", {})

        # 1. Try Gemini LLM if configured
        gemini_advice = self._call_gemini_diagnose(mismatch_report, stats)
        if gemini_advice:
            return gemini_advice

        # 2. Local Fallback deterministic diagnosis
        return self._local_rule_diagnose(mismatch_report, stats, missing_buses, surplus_buses, missing_branches, surplus_branches, missing_gens, missing_loads)

    def _call_gemini_diagnose(
        self,
        mismatch_report: Dict[str, Any],
        stats: Dict[str, Any],
    ) -> Optional[Dict[str, Any]]:
        api_key = os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip()
        if not api_key:
            return None

        model_name = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash-lite")
        system_instruction = (
            "당신은 전력 계통(Power System) 도면 및 단선도(SLD) 검증 전문가 AI 에이전트입니다.\n"
            "사용자가 도면을 캔버스에 구성한 후 엑셀 계통 데이터를 적용했으나 불일치가 발생했습니다.\n"
            "불일치 내역을 분석하여 사용자에게 다음 형식의 친절하고 명확한 한국어 가이드를 작성하세요:\n\n"
            "【불일치 핵심 요약】\n"
            "- 모선/선로/발전기/부하 차이점 요약\n\n"
            "【원인 추정】\n"
            "- 도면 이미지 인식(OCR 미인식, 선로 끊김, 번호 오인식) 또는 엑셀 케이스 불일치 원인\n\n"
            "【해결 가이드】\n"
            "1. 캔버스에서 어떻게 수정해야 하는지 단계별 안내\n"
            "2. '누락 요소 자동 추가' 버튼을 눌러 엑셀 사양대로 자동 보정할 수 있음을 안내\n"
        )

        user_content = (
            f"도면과 엑셀 데이터 비교 결과:\n"
            f"- 엑셀 통계: 모선 {stats.get('excel', {}).get('buses')}개, 선로 {stats.get('excel', {}).get('branches')}개, 발전기 {stats.get('excel', {}).get('generators')}개, 부하 {stats.get('excel', {}).get('loads')}개\n"
            f"- 도면 통계: 모선 {stats.get('diagram', {}).get('buses')}개, 선로 {stats.get('diagram', {}).get('branches')}개, 발전기 {stats.get('diagram', {}).get('generators')}개, 부하 {stats.get('diagram', {}).get('loads')}개\n"
            f"- 상세 불일치: {json.dumps(mismatch_report.get('details', {}), ensure_ascii=False)}\n"
        )

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model_name}:generateContent?key={api_key}"
        payload = {
            "system_instruction": {"parts": [{"text": system_instruction}]},
            "contents": [{"role": "user", "parts": [{"text": user_content}]}],
            "generationConfig": {"temperature": 0.2, "maxOutputTokens": 800},
        }

        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=8.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                candidates = data.get("candidates", [])
                if candidates:
                    reply = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
                    if reply.strip():
                        return {
                            "status": "mismatch",
                            "agent_provider": "GEMINI_LLM",
                            "headline": "⚠️ 도면과 엑셀 데이터가 일치하지 않습니다!",
                            "advice_ko": reply.strip(),
                            "suggested_actions": [
                                "캔버스에서 누락된 모선/선로 번호 점검",
                                "우측 하단 '누락 요소 자동 보정'으로 자동 완성",
                                "도면에 맞는 올바른 엑셀 케이스 파일 재업로드",
                            ],
                        }
        except Exception as e:
            print(f"[ExcelDiscrepancyAgent Gemini Call Failed]: {e}")

        return None

    def _local_rule_diagnose(
        self,
        mismatch_report: Dict[str, Any],
        stats: Dict[str, Any],
        missing_buses: List[int],
        surplus_buses: List[int],
        missing_branches: List[List[int]],
        surplus_branches: List[List[int]],
        missing_gens: List[int],
        missing_loads: List[int],
    ) -> Dict[str, Any]:
        """Rule-based local fallback diagnosis."""
        sections = []

        # 1. Summary
        ex_s = stats.get("excel", {})
        dg_s = stats.get("diagram", {})
        sections.append(
            f"【불일치 핵심 요약】\n"
            f"• 엑셀 사양: 모선 {ex_s.get('buses', 0)}개, 선로 {ex_s.get('branches', 0)}개, 발전기 {ex_s.get('generators', 0)}개, 부하 {ex_s.get('loads', 0)}개\n"
            f"• 현재 도면: 모선 {dg_s.get('buses', 0)}개, 선로 {dg_s.get('branches', 0)}개, 발전기 {dg_s.get('generators', 0)}개, 부하 {dg_s.get('loads', 0)}개\n"
        )

        diff_notes = []
        if missing_buses:
            diff_notes.append(f"누락된 모선: {', '.join(f'Bus {b}' for b in missing_buses[:10])}{' 외' if len(missing_buses) > 10 else ''}")
        if surplus_buses:
            diff_notes.append(f"초과된 모선: {', '.join(f'Bus {b}' for b in surplus_buses[:10])}")
        if missing_branches:
            diff_notes.append(f"연결되지 않은 선로: {len(missing_branches)}개 (예: {', '.join(f'Line {fb}-{tb}' for fb, tb in missing_branches[:5])})")
        if missing_gens:
            diff_notes.append(f"누락된 발전기: {', '.join(f'G_{b}' for b in missing_gens[:8])}")

        if diff_notes:
            sections.append("• 주요 차이점:\n  - " + "\n  - ".join(diff_notes))

        # 2. Root Cause
        causes = []
        if missing_buses:
            causes.append("도면 인식(OCR) 과정에서 일부 모선 번호 텍스트가 흐릿하거나 선로와 겹쳐 숫자가 누락되었을 수 있습니다.")
        if missing_branches and not missing_buses:
            causes.append("모선은 모두 인식되었으나, 선로 결선 중 일부 선로가 끊어지거나 코너 굴절부에서 연결점으로 인정되지 않았습니다.")
        if len(missing_buses) > 5 and len(missing_branches) > 10:
            causes.append("업로드하신 엑셀 파일이 현재 도면과 다른 규격(예: 14모선 도면에 24모선 엑셀 업로드)일 가능성이 높습니다.")
        if not causes:
            causes.append("도면의 객체 라벨 번호와 엑셀의 모선 ID 간의 불일치로 매핑되지 않았습니다.")

        sections.append("\n【원인 추정】\n- " + "\n- ".join(causes))

        # 3. Action Guide
        actions = []
        actions.append("1. 캔버스에서 모선 번호 라벨(예: 1, 2, 14 등)이 정확한지 확인하고 수정하세요.")
        if missing_branches:
            actions.append("2. 누락된 선로의 경우, 캔버스 선로 그리기 툴로 양쪽 모선 사이에 선을 다시 그어주세요.")
        actions.append("3. 하단의 [누락 요소 자동 추가] 버튼을 클릭하시면 엑셀 데이터를 바탕으로 누락된 요소를 자동 복구할 수 있습니다.")
        actions.append("4. 현재 도면과 일치하는 올바른 엑셀 파일(예: IEEE 24-bus)이 맞는지 확인해 주세요.")

        sections.append("\n【해결 가이드】\n" + "\n".join(actions))

        return {
            "status": "mismatch",
            "agent_provider": "LOCAL_RULE_BASED",
            "headline": "⚠️ 도면과 엑셀 데이터가 일치하지 않습니다!",
            "advice_ko": "\n".join(sections),
            "suggested_actions": [
                "모선 번호 및 선로 결선 수동 점검",
                "누락 요소 자동 추가 실행",
                "계통 엑셀 파일 재확인",
            ],
        }


excel_discrepancy_agent = ExcelDiscrepancyAgent()
