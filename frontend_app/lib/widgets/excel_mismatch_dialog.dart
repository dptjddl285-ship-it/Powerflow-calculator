import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ==========================================
// EXCEL MISMATCH ALERT & INTERACTIVE REVIEW DIALOG
// ==========================================
class ExcelMismatchDialog extends StatefulWidget {
  final Map<String, dynamic> mismatchReport;
  final Map<String, dynamic> excelData;
  final List<dynamic> elements;
  final List<Map<String, dynamic>> repairProposals;
  final Function(Map<String, dynamic> proposal)? onApplyProposal;
  final Function(Map<String, dynamic> proposal)? onRejectProposal;
  final VoidCallback? onResetToStart;
  final VoidCallback? onCancel;
  final VoidCallback? onAutoRecover;

  const ExcelMismatchDialog({
    super.key,
    required this.mismatchReport,
    required this.excelData,
    required this.elements,
    this.repairProposals = const [],
    this.onApplyProposal,
    this.onRejectProposal,
    this.onResetToStart,
    this.onCancel,
    this.onAutoRecover,
  });

  @override
  State<ExcelMismatchDialog> createState() => _ExcelMismatchDialogState();
}

class _ExcelMismatchDialogState extends State<ExcelMismatchDialog> {
  bool _isLoadingDiagnosis = false;
  Map<String, dynamic>? _agentDiagnosis;
  String? _diagError;

  final Set<String> _appliedProposalKeys = {};
  final Set<String> _rejectedProposalKeys = {};

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
    final details = (widget.mismatchReport['details'] as Map<String, dynamic>?) ?? {};
    final missingBuses = (details['missing_buses'] as List?) ?? [];
    final surplusBuses = (details['surplus_buses'] as List?) ?? [];
    final bool hasBusMismatch = missingBuses.isNotEmpty || surplusBuses.isNotEmpty;

    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 820),
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
                      color: hasBusMismatch
                          ? Colors.redAccent.withValues(alpha: 0.2)
                          : Colors.amberAccent.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasBusMismatch ? Icons.error_outline : Icons.warning_amber_rounded,
                      color: hasBusMismatch ? Colors.redAccent : Colors.amberAccent,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasBusMismatch
                              ? "🔴 모선 불일치 오류 (Bus Mismatch Error)"
                              : "⚠️ 도면과 엑셀 데이터 불일치 검수",
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          hasBusMismatch
                              ? "모선 번호/개수가 일치하지 않아 설비 자동 제안 및 생성이 전면 차단되었습니다."
                              : "도면과 엑셀 간 차이를 확인하고 Generator/Load 수정 제안을 승인할 수 있습니다.",
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

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
              const SizedBox(height: 12),

              // Scrollable Body
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Bus Mismatch Safety Warning Banner
                      if (hasBusMismatch) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.shade900.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.redAccent, width: 1.5),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.dangerous_outlined, color: Colors.redAccent, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    "모선 검증 실패 - 설비 자동 제안 및 생성 차단",
                                    style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "누락 모선: ${missingBuses.isEmpty ? '없음' : missingBuses.join(', ')}  |  초과 모선: ${surplusBuses.isEmpty ? '없음' : surplusBuses.join(', ')}\n"
                                "안전 정책: 모선 개수나 번호가 일치하지 않는 경우, Bus/Line/Generator/Load의 임의 자동 생성이 엄격히 금지됩니다. 도면의 모선을 먼저 수동으로 수정해 주십시오.",
                                style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.35),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Generator / Load Proposals Section
                      if (!hasBusMismatch && widget.repairProposals.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6), width: 1.2),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.auto_fix_high, color: Colors.amberAccent, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    "🟡 Excel 교차검증 설비 제안 (${widget.repairProposals.length}건)",
                                    style: const TextStyle(color: Colors.amberAccent, fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                "Excel에는 존재하지만 도면에서 미검출된 Generator/Load입니다. 승인(적용) 시 실제 Bus 위치에 설비와 인입선을 생성합니다.",
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                              const SizedBox(height: 10),
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: widget.repairProposals.length,
                                separatorBuilder: (c, i) => const Divider(color: Colors.white12, height: 12),
                                itemBuilder: (ctx, idx) {
                                  final prop = widget.repairProposals[idx];
                                  final cat = prop['category']?.toString() ?? 'equipment';
                                  final bNum = prop['bus_number'] ?? 0;
                                  final key = "${cat}_$bNum";
                                  final isApplied = _appliedProposalKeys.contains(key);
                                  final isRejected = _rejectedProposalKeys.contains(key);
                                  final isGen = cat == 'generator';
                                  final exData = (prop['excel_data'] as Map<String, dynamic>?) ?? {};

                                  String specText;
                                  if (isGen) {
                                    final mw = (exData['pg_mw'] as num?)?.toDouble() ?? 0.0;
                                    final mvar = (exData['qg_mvar'] as num?)?.toDouble() ?? 0.0;
                                    final v = (exData['v_pu'] as num?)?.toDouble() ?? 1.0;
                                    final isSC = exData['is_synchronous_condenser'] == true;
                                    specText = isSC
                                        ? "동기조상기 (P=0 MW, Q=${mvar.toStringAsFixed(1)} Mvar, V=${v.toStringAsFixed(2)} pu)"
                                        : "P=${mw.toStringAsFixed(1)} MW, Q=${mvar.toStringAsFixed(1)} Mvar, V=${v.toStringAsFixed(2)} pu";
                                  } else {
                                    final mw = (exData['p_mw'] as num?)?.toDouble() ?? 0.0;
                                    final mvar = (exData['q_mvar'] as num?)?.toDouble() ?? 0.0;
                                    specText = "P=${mw.toStringAsFixed(1)} MW, Q=${mvar.toStringAsFixed(1)} Mvar";
                                  }

                                  return Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isApplied
                                            ? Colors.greenAccent.withValues(alpha: 0.6)
                                            : isRejected
                                                ? Colors.orangeAccent.withValues(alpha: 0.4)
                                                : Colors.white24,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Icon(
                                          isGen ? Icons.bolt : Icons.arrow_downward_rounded,
                                          color: isGen ? Colors.cyanAccent : Colors.orangeAccent,
                                          size: 22,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    "Bus $bNum ${isGen ? '발전기' : '부하'}",
                                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                                    decoration: BoxDecoration(
                                                      color: Colors.red.withValues(alpha: 0.2),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: const Text("도면: 미검출", style: TextStyle(color: Colors.redAccent, fontSize: 10)),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                "Excel 기준값: $specText",
                                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        if (isApplied) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.green.withValues(alpha: 0.2),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: Colors.greenAccent),
                                            ),
                                            child: const Row(
                                              children: [
                                                Icon(Icons.check, color: Colors.greenAccent, size: 14),
                                                SizedBox(width: 4),
                                                Text("적용 완료", style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                        ] else if (isRejected) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.withValues(alpha: 0.2),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: Colors.orangeAccent),
                                            ),
                                            child: const Row(
                                              children: [
                                                Icon(Icons.close, color: Colors.orangeAccent, size: 14),
                                                SizedBox(width: 4),
                                                Text("거부됨", style: TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                        ] else ...[
                                          OutlinedButton(
                                            onPressed: () {
                                              setState(() {
                                                _rejectedProposalKeys.add(key);
                                              });
                                              widget.onRejectProposal?.call(prop);
                                            },
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.white70,
                                              side: const BorderSide(color: Colors.white30),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            ),
                                            child: const Text("거부", style: TextStyle(fontSize: 12)),
                                          ),
                                          const SizedBox(width: 6),
                                          ElevatedButton(
                                            onPressed: () {
                                              setState(() {
                                                _appliedProposalKeys.add(key);
                                              });
                                              widget.onApplyProposal?.call(prop);
                                            },
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.teal.shade700,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                            ),
                                            child: const Text("적용", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Discrepancy List
                      const Text(
                        "📋 불일치 상세 내역 (Discrepancies)",
                        style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 140),
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
                                  final cat = item['category']?.toString() ?? '';
                                  final type = item['type']?.toString() ?? '';
                                  final msg = item['message']?.toString() ?? '';
                                  final bool isMissing = (type == 'missing');
                                  final bool isCritical = (cat == 'bus' || cat == 'branch' || cat == 'transformer');

                                  return Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isCritical
                                              ? Colors.red.withValues(alpha: 0.2)
                                              : (isMissing ? Colors.amber.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2)),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(
                                            color: isCritical
                                                ? Colors.redAccent.withValues(alpha: 0.5)
                                                : (isMissing ? Colors.amberAccent.withValues(alpha: 0.5) : Colors.orangeAccent.withValues(alpha: 0.5)),
                                          ),
                                        ),
                                        child: Text(
                                          isCritical ? "ERROR" : (isMissing ? "제안가능" : "초과"),
                                          style: TextStyle(
                                            color: isCritical
                                                ? Colors.redAccent
                                                : (isMissing ? Colors.amberAccent : Colors.orangeAccent),
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
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1B4B).withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF6366F1), width: 1.2),
                          ),
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
                      ],
                    ],
                  ),
                ),
              ),
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
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onCancel?.call();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF334155),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text("닫기 (도면 직접 수정)"),
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
