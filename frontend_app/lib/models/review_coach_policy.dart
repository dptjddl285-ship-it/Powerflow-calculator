import 'connection_visual_sweep.dart';
import 'powerlens_assistant_context.dart';
import 'review_models.dart';

/// One deterministic source for the review coach's target, message, and mode.
class ReviewCoachDecision {
  final String? coachTarget;
  final String coachMessage;
  final String coachMode;
  final String? highlightTarget;
  final String? focusNodeId;
  final String? focusLineId;

  const ReviewCoachDecision({
    required this.coachTarget,
    required this.coachMessage,
    required this.coachMode,
    required this.highlightTarget,
    this.focusNodeId,
    this.focusLineId,
  });
}

class ReviewCoachPolicy {
  const ReviewCoachPolicy._();

  static ReviewCoachDecision resolve(PowerLensAssistantContext context) {
    switch (context.workflowStage.toUpperCase()) {
      case 'OBJECT_REVIEW':
        return _objectDecision(context);
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        return _busDecision(context);
      case 'CONNECTION_REVIEW':
        return _connectionDecision(context);
      case 'FINAL':
      case 'FINAL_CAD':
      case 'VERIFIED_FINAL':
        return _finalDecision(context);
      default:
        return const ReviewCoachDecision(
          coachTarget: null,
          coachMessage: '',
          coachMode: 'NONE',
          highlightTarget: null,
        );
    }
  }

  static ReviewCoachDecision _objectDecision(
    PowerLensAssistantContext context,
  ) {
    if (context.unresolvedMissingCandidates > 0) {
      return const ReviewCoachDecision(
        coachTarget: 'missing_candidates',
        coachMessage: '도면에서 누락 후보를 확인하고 실제 설비인지 검토해주세요.',
        coachMode: 'GUIDE',
        highlightTarget: 'missing_candidates',
      );
    }
    final suspicious = context.workingNodes
        .where(
          (node) =>
              (node['review_status'] ?? node['status'])
                  ?.toString()
                  .toUpperCase() ==
              'SUSPICIOUS',
        )
        .toList();
    if (suspicious.isNotEmpty || context.suspiciousObjects > 0) {
      final selectedId = context.selectedNode?['id']?.toString();
      final focus = suspicious.firstWhere(
        (node) => node['id']?.toString() == selectedId,
        orElse: () => suspicious.isNotEmpty ? suspicious.first : const {},
      );
      final id = focus['id']?.toString();
      return ReviewCoachDecision(
        coachTarget: 'object_bbox',
        coachMessage: '한 번 더 확인할 객체를 도면에 표시했어요. 표시된 객체와 인식 근거를 살펴봐주세요.',
        coachMode: 'GUIDE',
        highlightTarget: null,
        focusNodeId: id,
      );
    }
    if (!context.hasDiagram &&
        context.totalObjects == 0 &&
        context.workingNodes.isEmpty) {
      return const ReviewCoachDecision(
        coachTarget: 'home_upload',
        coachMessage: '단선도 이미지를 불러오면 객체와 결선을 검수할 수 있어요.',
        coachMode: 'GUIDE',
        highlightTarget: 'home_upload',
      );
    }
    return const ReviewCoachDecision(
      coachTarget: 'object_gate',
      coachMessage: '의심 객체는 없어요. 전체 도면을 확인한 뒤 [객체 검수 완료]를 눌러주세요.',
      coachMode: 'GATE',
      highlightTarget: 'object_gate',
    );
  }

  static ReviewCoachDecision _busDecision(PowerLensAssistantContext context) {
    final nodes = context.workingNodes.map(ReviewNodeItem.fromJson).toList();
    final issueIds = BusReviewGateEvaluator.computeGuideBusIds(
      workingNodes: nodes,
    );
    if (nodes
        .where(
          (n) =>
              n.className.toLowerCase() == 'bus' &&
              n.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .isEmpty) {
      return const ReviewCoachDecision(
        coachTarget: null,
        coachMessage: BusReviewUiState.noActiveBusMessage,
        coachMode: 'BLOCKED',
        highlightTarget: null,
      );
    }
    if (issueIds.isNotEmpty) {
      final selectedId = context.selectedNode?['id']?.toString();
      final id = issueIds.contains(selectedId)
          ? selectedId
          : _firstBusIssue(nodes, issueIds);
      return ReviewCoachDecision(
        coachTarget: 'bus_bbox',
        coachMessage: '번호 확인이 필요한 모선을 보라색으로 표시했어요. 하나씩 번호와 위치를 대조해주세요.',
        coachMode: 'GUIDE',
        highlightTarget: null,
        focusNodeId: id,
      );
    }
    return const ReviewCoachDecision(
      coachTarget: 'bus_gate',
      coachMessage: '다시 확인할 모선 번호는 없어요. 전체 번호를 살펴본 뒤 [모선 검수 완료]를 눌러주세요.',
      coachMode: 'GATE',
      highlightTarget: 'bus_gate',
    );
  }

  static String? _firstBusIssue(
    List<ReviewNodeItem> nodes,
    Set<String> issueIds,
  ) {
    final issues = nodes.where((node) => issueIds.contains(node.id)).toList();
    issues.sort((a, b) {
      double top(ReviewNodeItem node) => node.bbox.length >= 4
          ? node.bbox[1] - node.bbox[3] / 2
          : double.infinity;
      double left(ReviewNodeItem node) => node.bbox.length >= 4
          ? node.bbox[0] - node.bbox[2] / 2
          : double.infinity;
      final y = top(a).compareTo(top(b));
      if (y != 0) return y;
      final x = left(a).compareTo(left(b));
      return x != 0 ? x : a.id.compareTo(b.id);
    });
    return issues.isEmpty ? null : issues.first.id;
  }

  static ReviewCoachDecision _connectionDecision(
    PowerLensAssistantContext context,
  ) {
    final lines = context.workingLines.map(ReviewLineItem.fromJson).toList();
    final blockers = ConnectionReviewGateEvaluator.getBlockers(
      workingLines: lines,
      topologyIssues: context.topologyIssues,
    );
    if (ConnectionReviewGateEvaluator.activeLines(lines).isEmpty) {
      return const ReviewCoachDecision(
        coachTarget: null,
        coachMessage: ConnectionReviewGateEvaluator.noActiveLineMessage,
        coachMode: 'BLOCKED',
        highlightTarget: null,
      );
    }
    if (blockers.isNotEmpty) {
      final guideIds = ConnectionReviewGateEvaluator.computeGuideLineIds(
        workingLines: lines,
        topologyIssues: context.topologyIssues,
      );
      final orderedIssues = ConnectionVisualSweep.orderedLines(
        lines.where((line) => guideIds.contains(line.lineId)),
      );
      final selectedId =
          context.selectedLine?['line_id']?.toString() ??
          context.selectedLine?['id']?.toString();
      final focusId = guideIds.contains(selectedId)
          ? selectedId
          : (orderedIssues.isEmpty ? null : orderedIssues.first.lineId);
      return ReviewCoachDecision(
        coachTarget: 'connection_exception',
        coachMessage: '확인이 필요한 실제 결선 예외만 표시했어요. 해당 선로의 끝점·경로·전기 근거를 확인해주세요.',
        coachMode: 'GUIDE',
        highlightTarget: null,
        focusLineId: focusId,
      );
    }

    final ordered = ConnectionVisualSweep.orderedLines(lines);
    if (!context.connectionVisualSweepStarted) {
      return const ReviewCoachDecision(
        coachTarget: 'connection_focus_toggle',
        coachMessage:
            'AI가 결선 구조를 확인했어요. [선로만 집중 모드]를 누르거나 → 키로 전체 선로를 순서대로 육안 확인하세요.',
        coachMode: 'GUIDE',
        highlightTarget: 'connection_focus_toggle',
      );
    }

    final selectedId =
        context.selectedLine?['line_id']?.toString() ??
        context.selectedLine?['id']?.toString();
    final selectedIndex = ConnectionVisualSweep.indexOf(ordered, selectedId);
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    final complete =
        context.connectionVisualSweepComplete ||
        (ordered.isNotEmpty && index == ordered.length - 1);
    final current = ordered.isEmpty ? null : ordered[index];
    if (complete) {
      return ReviewCoachDecision(
        coachTarget: 'connection_gate',
        coachMessage:
            '최종 육안 확인 ${ordered.length} / ${ordered.length} 완료예요. 선로 상태는 변경되지 않았어요. 하단 [결선 검수 완료]를 눌러주세요.',
        coachMode: 'GATE',
        highlightTarget: 'connection_gate',
        focusLineId: current?.lineId,
      );
    }
    final progress = index + 1;
    return ReviewCoachDecision(
      coachTarget: 'connection_line_focus',
      coachMessage:
          '최종 육안 확인 $progress / ${ordered.length}. 선택된 실제 경로와 양 끝점을 확인한 뒤 → 키를 누르세요.',
      coachMode: 'FOCUS',
      highlightTarget: current == null
          ? null
          : 'connection_line:${current.lineId}',
      focusLineId: current?.lineId,
    );
  }

  static ReviewCoachDecision _finalDecision(PowerLensAssistantContext context) {
    if (!context.excelLoaded) {
      return const ReviewCoachDecision(
        coachTarget: 'final_excel_upload',
        coachMessage: '검증된 단선도예요. 실제 조류계산을 위해 계통 제원 Excel 파일을 연결해주세요.',
        coachMode: 'GUIDE',
        highlightTarget: 'final_excel_upload',
      );
    }
    if (context.finalVerified &&
        context.excelMappingStatus.toUpperCase() == 'MATCHED') {
      return const ReviewCoachDecision(
        coachTarget: 'final_canvas_handoff',
        coachMessage: 'Excel 대조가 일치했어요. [캔버스 편집 화면으로 이동]을 눌러 다음 단계로 가세요.',
        coachMode: 'GATE',
        highlightTarget: 'final_canvas_handoff',
      );
    }
    if (context.excelMappingStatus.toUpperCase() == 'MISMATCH') {
      return const ReviewCoachDecision(
        coachTarget: 'excel_mismatch_btn',
        coachMessage:
            'Excel 대조에서 불일치가 있어 CAD로 이동할 수 없어요. 표시된 항목을 확인하고 해결한 뒤 다시 대조해주세요.',
        coachMode: 'GUIDE',
        highlightTarget: 'excel_mismatch_btn',
      );
    }
    return const ReviewCoachDecision(
      coachTarget: 'final_excel_upload',
      coachMessage: 'Excel 파일은 연결됐지만 대조 결과가 없어요. Excel 대조 상태를 확인해주세요.',
      coachMode: 'GUIDE',
      highlightTarget: 'final_excel_upload',
    );
  }
}
