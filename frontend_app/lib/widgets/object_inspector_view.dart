import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/review_models.dart';

/// Object Review V2 Dedicated Inspector View
/// Displays AI model confidence, evidence reasons, and actions (Confirm/Edit for Suspicious; Info for Normal)
class ObjectInspectorView extends StatelessWidget {
  final ReviewNodeItem node;
  final bool isEditExpanded;
  final VoidCallback onMatch;
  final VoidCallback onEditToggle;
  final ValueChanged<String>? onClassChanged;
  final VoidCallback? onReject;
  final VoidCallback? onEditDisplayLabel;

  const ObjectInspectorView({
    super.key,
    required this.node,
    this.isEditExpanded = false,
    required this.onMatch,
    required this.onEditToggle,
    this.onClassChanged,
    this.onReject,
    this.onEditDisplayLabel,
  });

  static Color getClassColor(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return const Color(0xFF00E676);
    if (cls.contains('load')) return const Color(0xFFFF9100);
    if (cls.contains('trans')) return const Color(0xFFD500F9);
    return const Color(0xFF2979FF); // bus
  }

  static IconData getClassIcon(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return Icons.bolt;
    if (cls.contains('load')) return Icons.arrow_downward;
    if (cls.contains('trans')) return Icons.sync_alt;
    return Icons.horizontal_rule; // bus
  }

  static String classNameKo(String className) {
    switch (className.toLowerCase()) {
      case 'bus':
        return '모선 (Bus)';
      case 'generator':
        return '발전기 (Generator)';
      case 'load':
        return '부하 (Load)';
      case 'transformer':
        return '변압기 (Transformer)';
      default:
        return className;
    }
  }

  String _humanObjectTitle() {
    final label = node.displayLabel?.trim();
    if (label != null && label.isNotEmpty) {
      final match = RegExp(
        r'^(bus|load|gen(?:erator)?|transformer)[_-](\d+)$',
        caseSensitive: false,
      ).firstMatch(label);
      if (match != null) {
        final prefix = switch (match.group(1)!.toLowerCase()) {
          'bus' => 'Bus',
          'load' => '부하',
          'gen' || 'generator' => '발전기',
          _ => '변압기',
        };
        return '$prefix ${match.group(2)}';
      }
      return label.replaceAll('_', ' ');
    }
    if (node.busNumber != null) {
      return '${classNameKo(node.className)} ${node.busNumber}';
    }
    if (node.displayNumber != null) {
      return '${classNameKo(node.className)} ${node.displayNumber}';
    }
    return classNameKo(node.className);
  }

  static String recommendedActionKo(String? action) {
    if (action == null) return '';
    switch (action.toLowerCase()) {
      case 'confirm':
        return '현재 인식 확정';
      case 'change_class':
        return '종류 변경 권장';
      case 'reject':
        return '객체 제외 권장';
      case 'ask_user':
        return '사람 확인 필요';
      default:
        return '추가 검토 권장';
    }
  }

  Object? _evidenceValue(Iterable<String> keys) {
    for (final key in keys) {
      if (node.evidence.containsKey(key)) return node.evidence[key];
      if (node.metadata.containsKey(key)) return node.metadata[key];
    }
    return null;
  }

  String? _humanSourceLabel() {
    final source = node.source.toLowerCase();
    if (source == 'cv_primary') return 'OpenCV 기반 1차 검출';
    if (source.startsWith('cv')) return 'OpenCV 보조 검출';
    if (source.contains('yolo')) return 'YOLO 기반 검출';
    if (source.contains('human')) return '사용자 확인 또는 수정';
    if (source == 'unknown' || source.isEmpty) return null;
    return null;
  }

  String _formatPercent(num raw, {bool wholeNumber = false}) {
    final value = raw.abs() <= 1 ? raw * 100 : raw;
    if (wholeNumber) return '${value.floor()}%';
    final formatted = value.toStringAsFixed(1);
    return '${formatted.endsWith('.0') ? formatted.substring(0, formatted.length - 2) : formatted}%';
  }

  List<MapEntry<String, String>> _humanEvidenceRows() {
    final rows = <MapEntry<String, String>>[
      MapEntry('인식 객체', classNameKo(node.className)),
    ];
    if (node.confidence > 0) {
      rows.add(
        MapEntry(
          '최종 인식 신뢰도',
          _formatPercent(node.confidence, wholeNumber: true),
        ),
      );
    }

    final policy = _evidenceValue([
      'policy_decision',
    ])?.toString().toUpperCase();
    final sourceLabel = _humanSourceLabel();
    if (sourceLabel != null) {
      final value =
          node.source.toLowerCase() == 'cv_primary' && policy == 'ACCEPT'
          ? '정상 검출'
          : sourceLabel;
      final label = node.source.toLowerCase().startsWith('cv')
          ? 'OpenCV 검출'
          : '검출 방식';
      rows.add(MapEntry(label, value));
    }

    final yoloSupport = _evidenceValue(['yolo_support']);
    if (yoloSupport is num && yoloSupport > 0) {
      rows.add(MapEntry('YOLO 보조 확인', _formatPercent(yoloSupport)));
    }

    final geometry = _evidenceValue(['geometry_evidence']);
    if (geometry is Map && geometry['has_cv_lead'] == true) {
      rows.add(MapEntry('OpenCV 보조 확인', '검출 근거 있음'));
    }

    final policyLabel = switch (policy) {
      'ACCEPT' => '정상 객체',
      'REVIEW' => '추가 확인 필요',
      'RESCUE' => '보완 검출 후보',
      'REJECT' => '제외 대상',
      _ => null,
    };
    if (policyLabel != null) {
      rows.add(MapEntry('교차 검증 결과', policyLabel));
    }

    final suspicious = _evidenceValue(['is_suspicious']);
    if (suspicious is bool ||
        node.reviewStatus.toUpperCase() == 'SUSPICIOUS' ||
        node.reviewStatus.toUpperCase() == 'DETECTED' ||
        node.reviewStatus.toUpperCase() == 'CONFIRMED') {
      final needsReview = suspicious is bool
          ? suspicious
          : node.reviewStatus.toUpperCase() == 'SUSPICIOUS';
      rows.add(MapEntry('추가 확인 필요', needsReview ? '있음' : '없음'));
    }
    return rows;
  }

  String _humanReason(String reason) {
    final value = reason.trim();
    if (value.startsWith('Low confidence')) return 'AI 신뢰도가 기준보다 낮습니다.';
    if (value.startsWith('Rescued candidate')) {
      return '보완 검출 규칙으로 추가된 후보입니다.';
    }
    if (value.startsWith('Overlap with')) return '다른 객체와 검출 영역이 겹칩니다.';
    if (RegExp(r'^[a-z0-9_]+$', caseSensitive: false).hasMatch(value)) {
      return '기술 검토 사유가 기록되어 있습니다. 상세 내용은 기술 정보에서 확인할 수 있습니다.';
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final isSuspicious = node.reviewStatus == 'SUSPICIOUS';
    final isHumanModified = node.source.contains('human');
    final classColor = getClassColor(node.className);

    // Determine status badge text and color
    final String statusLabel;
    final Color statusColor;
    if (isSuspicious) {
      statusLabel = "확인 필요";
      statusColor = const Color(0xFFD97706);
    } else if (isHumanModified) {
      statusLabel = "사람 수정됨";
      statusColor = const Color(0xFF059669);
    } else {
      statusLabel = "AI 확인";
      statusColor = const Color(0xFF2563EB);
    }

    // Determine evidence text
    final rawReasons = node.reviewReasons.isNotEmpty
        ? node.reviewReasons
        : (_evidenceValue(['suspicious_reasons', 'policy_reasons']) is List
              ? (_evidenceValue(['suspicious_reasons', 'policy_reasons'])
                        as List)
                    .map((reason) => reason.toString())
                    .toList()
              : const <String>[]);
    final reasons = rawReasons
        .where((reason) => reason.trim().isNotEmpty)
        .map(_humanReason)
        .toList();
    final String? explanation =
        (node.agentExplanation != null &&
            node.agentExplanation!.trim().isNotEmpty)
        ? node.agentExplanation
        : null;
    final evidenceRows = _humanEvidenceRows();
    final rawDetails = const JsonEncoder.withIndent('  ').convert({
      'node_id': node.id,
      'class': node.className,
      'bbox': node.bbox,
      'confidence': node.confidence,
      'source': node.source,
      'review_status': node.reviewStatus,
      'evidence': node.evidence,
      'metadata': node.metadata,
    });
    return Column(
      key: const ValueKey('ObjectInspector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with Display Label, Class Icon, Edit Label Icon, and Status Badge
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Icon(
                    getClassIcon(node.className),
                    color: classColor,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _humanObjectTitle(),
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (onEditDisplayLabel != null)
                    IconButton(
                      icon: const Icon(
                        Icons.edit,
                        size: 14,
                        color: Color(0xFF2563EB),
                      ),
                      tooltip: "표시명 / 번호 수정",
                      onPressed: onEditDisplayLabel,
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const SizedBox(height: 12),

        // Evidence section
        if (reasons.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Color(0xFFD97706),
                      size: 14,
                    ),
                    SizedBox(width: 4),
                    Text(
                      "검토 필요 사유:",
                      style: TextStyle(
                        color: Color(0xFF92400E),
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ...reasons.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      "• $r",
                      style: const TextStyle(
                        color: Color(0xFF78350F),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],

        // AI Agent Explanation or fallback
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    color: Color(0xFF2563EB),
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    "AI 판단 결과",
                    style: TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (evidenceRows.isNotEmpty)
                ...evidenceRows.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 132,
                          child: Text(
                            entry.key,
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entry.value,
                            style: const TextStyle(
                              color: Color(0xFF1E293B),
                              fontSize: 11.5,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Text(
                  "확인할 수 있는 구조화 검증 정보가 없습니다.",
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                    height: 1.4,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              if (explanation != null) ...[
                const SizedBox(height: 6),
                Text(
                  explanation,
                  style: const TextStyle(
                    color: Color(0xFF1E293B),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
              if (node.recommendedAction != null) ...[
                const SizedBox(height: 8),
                Text(
                  "추천 조치: ${recommendedActionKo(node.recommendedAction)}",
                  style: const TextStyle(
                    color: Color(0xFF15803D),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
        ExpansionTile(
          key: const ValueKey('ObjectTechnicalDetails'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text(
            '기술 상세 정보 펼치기',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
          ),
          children: [
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  rawDetails,
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Inspector Actions V2
        if (isSuspicious) ...[
          // Suspicious object: Primary [맞음] and [수정]
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  key: const ValueKey('ObjectMatchButton'),
                  onPressed: onMatch,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text(
                    "맞음",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('ObjectEditButton'),
                  onPressed: onEditToggle,
                  icon: Icon(
                    isEditExpanded ? Icons.close : Icons.tune,
                    size: 16,
                  ),
                  label: Text(
                    isEditExpanded ? "닫기" : "수정",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    side: const BorderSide(
                      color: Color(0xFF3B82F6),
                      width: 1.2,
                    ),
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (isEditExpanded) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "올바른 객체 종류를 선택하세요:",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF334155),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: ['bus', 'generator', 'load', 'transformer'].map((
                      cls,
                    ) {
                      final isCurrent = node.className.toLowerCase() == cls;
                      return ChoiceChip(
                        label: Text(
                          cls.toUpperCase(),
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: isCurrent,
                        onSelected: (selected) {
                          if (selected && onClassChanged != null) {
                            onClassChanged!(cls);
                          }
                        },
                        selectedColor: getClassColor(
                          cls,
                        ).withValues(alpha: 0.25),
                        backgroundColor: Colors.white,
                        side: BorderSide(
                          color: isCurrent
                              ? getClassColor(cls)
                              : const Color(0xFFCBD5E1),
                        ),
                      );
                    }).toList(),
                  ),
                  if (onReject != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onReject,
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 14,
                          color: Color(0xFFDC2626),
                        ),
                        label: const Text(
                          "객체 제외/삭제",
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ] else ...[
          // A selected normal object remains informational; category review
          // still provides the final human visual pass for the whole drawing.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  color: Color(0xFF16A34A),
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "AI 검출에서 추가 검토 사유가 없습니다. 전체 도면은 종류별 검수에서 확인해주세요.",
                    style: TextStyle(
                      color: Color(0xFF15803D),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Optional manual edit expansion tile if user wants to change anyway
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: const Text(
              "고급: 객체 종류 수정 / 제외",
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
            ),
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: ['bus', 'generator', 'load', 'transformer'].map((
                  cls,
                ) {
                  final isCurrent = node.className.toLowerCase() == cls;
                  return ChoiceChip(
                    label: Text(
                      cls.toUpperCase(),
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: isCurrent,
                    onSelected: (selected) {
                      if (selected && onClassChanged != null) {
                        onClassChanged!(cls);
                      }
                    },
                    selectedColor: getClassColor(cls).withValues(alpha: 0.25),
                    backgroundColor: Colors.white,
                    side: BorderSide(
                      color: isCurrent
                          ? getClassColor(cls)
                          : const Color(0xFFCBD5E1),
                    ),
                  );
                }).toList(),
              ),
              if (onReject != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onReject,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 14,
                      color: Color(0xFFDC2626),
                    ),
                    label: const Text(
                      "객체 제외/삭제",
                      style: TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
