import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ==========================================
// EXCEL MISMATCH ALERT & AGENT DIAGNOSTIC DIALOG
// ==========================================
class ExcelMismatchDialog extends StatefulWidget {
  final Map<String, dynamic> mismatchReport;
  final Map<String, dynamic> excelData;
  final VoidCallback onAutoRecover;
  final VoidCallback? onResetToStart;
  final VoidCallback? onCancel;

  const ExcelMismatchDialog({
    super.key,
    required this.mismatchReport,
    required this.excelData,
    required this.elements,
    required this.onAutoRecover,
    this.onResetToStart,
    this.onCancel,
  });

  @override
  State<ExcelMismatchDialog> createState() => _ExcelMismatchDialogState();
}

class _ExcelMismatchDialogState extends State<ExcelMismatchDialog> {
  bool _isLoadingDiagnosis = false;
  Map<String, dynamic>? _agentDiagnosis;
  String? _diagError;

  Future<void> _fetchDiagnosis() async {
    setState(() {
      _isLoadingDiagnosis = true;
      _diagError = null;
    });

    try {
      final uri = Uri.parse('http://127.0.0.1:8000/diagnose_excel_mismatch');
      final serializedElements = widget.elements.map((e) {
        if (e is Map) return e;
        try {
          return (e as dynamic).toJson();
        } catch (_) {
          return {};
        }
      }).toList();

      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'elements': serializedElements,
          'excel_data': widget.excelData,
          'mismatch_report': widget.mismatchReport,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'success') {
          setState(() {
            _agentDiagnosis = data['data'] as Map<String, dynamic>?;
          });
        } else {
          setState(() {
            _diagError = data['message'] ?? '진단 실패';
          });
        }
      } else {
        setState(() {
          _diagError = '서버 오류 (${res.statusCode})';
        });
      }
    } catch (e) {
      setState(() {
        _diagError = '네트워크 오류: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDiagnosis = false;
        });
      }
    }
  }

  Widget _buildStatCard(String title, int diagramVal, int excelVal) {
    final bool match = (diagramVal == excelVal);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: match ? Colors.green.withValues(alpha: 0.5) : Colors.redAccent.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                match ? Icons.check_circle_outline : Icons.cancel_outlined,
                size: 15,
                color: match ? Colors.greenAccent : Colors.redAccent,
              ),
              const SizedBox(width: 4),
              Text(
                title,
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "도면 $diagramVal / 엑셀 $excelVal",
            style: TextStyle(
              color: match ? Colors.white : Colors.amberAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = (widget.mismatchReport['stats'] as Map<String, dynamic>?) ?? {};
    final excelStats = (stats['excel'] as Map<String, dynamic>?) ?? {};
    final diagStats = (stats['diagram'] as Map<String, dynamic>?) ?? {};

    final discrepancies = (widget.mismatchReport['discrepancies'] as List?) ?? [];

    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(22.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "⚠️ 도면과 엑셀 데이터가 일치하지 않습니다!",
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 3),
                        Text(
                          "도면 상의 모선/선로/발전기/부하 연결이 엑셀 계통 사양과 다릅니다.",
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Stats Row
              Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      "모선 (Bus)",
                      (diagStats['buses'] as num?)?.toInt() ?? 0,
                      (excelStats['buses'] as num?)?.toInt() ?? 0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildStatCard(
                      "선로 (Line)",
                      (diagStats['branches'] as num?)?.toInt() ?? 0,
                      (excelStats['branches'] as num?)?.toInt() ?? 0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildStatCard(
                      "발전기 (Gen)",
                      (diagStats['generators'] as num?)?.toInt() ?? 0,
                      (excelStats['generators'] as num?)?.toInt() ?? 0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildStatCard(
                      "부하 (Load)",
                      (diagStats['loads'] as num?)?.toInt() ?? 0,
                      (excelStats['loads'] as num?)?.toInt() ?? 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Discrepancy List
              const Text(
                "📋 불일치 상세 내역",
                style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 130),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: discrepancies.isEmpty
                      ? const Center(
                          child: Text("발견된 세부 불일치 항목이 없습니다.", style: TextStyle(color: Colors.white54)),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: discrepancies.length,
                          separatorBuilder: (c, i) => const Divider(color: Colors.white10, height: 6),
                          itemBuilder: (ctx, idx) {
                            final item = discrepancies[idx];
                            final type = item['type']?.toString() ?? '';
                            final msg = item['message']?.toString() ?? '';
                            final bool isMissing = (type == 'missing');

                            return Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isMissing ? Colors.red.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: isMissing ? Colors.redAccent.withValues(alpha: 0.4) : Colors.orangeAccent.withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: Text(
                                    isMissing ? "누락" : "초과",
                                    style: TextStyle(
                                      color: isMissing ? Colors.redAccent : Colors.orangeAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    msg,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 12),

              // AI Agent Section
              if (_agentDiagnosis == null) ...[
                ElevatedButton.icon(
                  onPressed: _isLoadingDiagnosis ? null : _fetchDiagnosis,
                  icon: _isLoadingDiagnosis
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 18),
                  label: Text(
                    _isLoadingDiagnosis ? "AI 에이전트가 불일치 원인을 분석 중입니다..." : "🤖 AI 에이전트 원인 진단 및 해결 가이드 요청",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                if (_diagError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_diagError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
              ] else ...[
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 170),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1B4B).withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF6366F1), width: 1.2),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 15),
                              const SizedBox(width: 5),
                              Text(
                                "AI 에이전트 진단 리포트 (${_agentDiagnosis!['agent_provider'] ?? 'AI'})",
                                style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            _agentDiagnosis!['advice_ko']?.toString() ?? '',
                            style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // Action Buttons
              Row(
                children: [
                  if (widget.onResetToStart != null) ...[
                    OutlinedButton.icon(
                      onPressed: widget.onResetToStart,
                      icon: const Icon(Icons.restart_alt, size: 16, color: Colors.orangeAccent),
                      label: const Text(
                        "다시 검수 처음으로 돌아가기",
                        style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.orangeAccent),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onCancel?.call();
                    },
                    child: const Text("닫기 (도면 직접 수정)", style: TextStyle(color: Colors.white60)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: widget.onAutoRecover,
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text("누락 요소 자동 추가 (동기화)"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
