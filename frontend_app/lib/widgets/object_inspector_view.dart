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

  static String recommendedActionKo(String? action) {
    if (action == null) return '';
    switch (action.toLowerCase()) {
      case 'confirm':
        return '현재 인식 확정';
      case 'change_class':
        return '종류 변경 권장';
      case 'reject':
        return '객체 제외 권장';
      default:
        return action;
    }
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
    final List<String> reasons = node.reviewReasons
        .where((r) => r.trim().isNotEmpty)
        .toList();
    final String? explanation =
        (node.agentExplanation != null &&
            node.agentExplanation!.trim().isNotEmpty)
        ? node.agentExplanation
        : null;
    final technicalEvidence = <String, dynamic>{
      ...node.evidence,
      ...node.metadata,
    };
    final rawYoloSupport = technicalEvidence['yolo_support'];
    final yoloSupport = rawYoloSupport is num
        ? rawYoloSupport.toDouble()
        : double.tryParse(rawYoloSupport?.toString() ?? '');
    final yoloSupportPercent =
        yoloSupport != null &&
            yoloSupport.isFinite &&
            yoloSupport >= 0 &&
            yoloSupport <= 1
        ? (yoloSupport * 100).round()
        : null;
    final normalizedSource = node.source.toLowerCase();
    final sourceLabel = normalizedSource.contains('cv')
        ? 'OpenCV 1차 검출'
        : normalizedSource.contains('yolo')
        ? 'YOLO 검출'
        : normalizedSource.contains('human')
        ? '사용자 확인'
        : null;
    final humanEvidenceRows = <String>[
      if (sourceLabel != null) '검출 출처: $sourceLabel',
      if (yoloSupportPercent != null && yoloSupportPercent > 0)
        'YOLO 보조 확인: $yoloSupportPercent%',
      if (normalizedSource.contains('cv') &&
          yoloSupportPercent != null &&
          yoloSupportPercent > 0)
        '교차 검증: OpenCV 검출을 YOLO가 보조 확인했습니다.',
      '추가 확인 필요: ${isSuspicious ? '있음' : '없음'}',
    ];
    final technicalRows = <String, dynamic>{
      'node_id': node.id,
      'class': node.className,
      'bbox': node.bbox,
      'confidence': node.confidence,
      'source': node.source,
      ...technicalEvidence,
    };
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
                      node.effectiveDisplayLabel,
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
        Text(
          "객체 종류: ${classNameKo(node.className)}  ·  최종 인식 신뢰도: ${(node.confidence * 100).toInt()}%",
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
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
                    "AI 판단 근거",
                    style: TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (explanation != null)
                Text(
                  explanation,
                  style: const TextStyle(
                    color: Color(0xFF1E293B),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              if (humanEvidenceRows.isNotEmpty)
                ...humanEvidenceRows.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      entry,
                      style: const TextStyle(
                        color: Color(0xFF334155),
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              if (explanation == null && humanEvidenceRows.isEmpty)
                const Text(
                  "확인 근거 정보가 없습니다.",
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                    height: 1.4,
                    fontStyle: FontStyle.italic,
                  ),
                ),
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
              const SizedBox(height: 4),
              ExpansionTile(
                key: const ValueKey('ObjectTechnicalDetails'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text(
                  "기술 상세 정보",
                  style: TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: technicalRows.entries
                    .map(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            '${entry.key}: ${entry.value}',
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 10,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
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
          // Clean normal object: Information only, no approval required
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
                    "AI가 확인한 정상 객체입니다. (승인 불필요)",
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
