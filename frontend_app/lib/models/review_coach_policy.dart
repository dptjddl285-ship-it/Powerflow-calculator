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
        coachMessage:
            'AI가 확인이 필요한 객체 ${suspicious.length > 0 ? suspicious.length : context.suspiciousObjects}개를 찾았습니다. 먼저 반짝이는 객체부터 확인해 주세요.',
        coachMode: 'GUIDE',
        highlightTarget: null,
        focusNodeId: context.objectVisualSweepCurrentId ?? id,
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
    final legacySummaryContext =
        context.totalObjects == 0 &&
        context.selectedNode == null &&
        context.workingNodes.isNotEmpty;
    if (context.objectHumanCompletenessConfirmed &&
        context.currentBlockers.isNotEmpty) {
      return ReviewCoachDecision(
        coachTarget: 'object_gate',
        coachMessage:
            '전체 객체 확인을 기록했어요. 객체 검수에 남은 항목을 먼저 해결해 주세요: ${context.currentBlockers.first}',
        coachMode: 'BLOCKED',
        highlightTarget: null,
      );
    }
    if (context.objectReviewStage == 'CATEGORY_REVIEW') {
      if (context.objectWorkflowMessage != null &&
          context.objectWorkflowMessage!.isNotEmpty) {
        return ReviewCoachDecision(
          coachTarget: 'object_category_review',
          coachMessage: context.objectWorkflowMessage!,
          coachMode: 'GUIDE',
          highlightTarget: 'object_category_bar',
          focusNodeId: context.selectedNode?['id']?.toString(),
        );
      }
      final busCount = context.workingNodes
          .where(
            (node) =>
                node['class_name']?.toString().toLowerCase() == 'bus' &&
                node['review_status']?.toString().toUpperCase() != 'REJECTED',
          )
          .length;
      final count = busCount;
      return ReviewCoachDecision(
        coachTarget: 'object_category_review',
        coachMessage: ObjectReviewGuidanceMessages.initialBus(count),
        coachMode: 'GUIDE',
        highlightTarget: 'object_category_bar',
        focusNodeId: context.selectedNode?['id']?.toString(),
      );
    }
    if (context.objectHumanCompletenessConfirmed || legacySummaryContext) {
      return const ReviewCoachDecision(
        coachTarget: 'object_gate',
        coachMessage: ObjectReviewGuidanceMessages.allReviewedCompletePass,
        coachMode: 'GATE',
        highlightTarget: 'object_gate',
      );
    }
    if (context.objectReviewStage == 'WAITING_HUMAN_COMPLETE') {
      return const ReviewCoachDecision(
        coachTarget: 'object_human_confirmation',
        coachMessage: '설비 종류별 확인을 마쳤어요. 문제가 없다면 “확인했어”라고 말씀해 주세요.',
        coachMode: 'GUIDE',
        highlightTarget: null,
      );
    }
    final selectedId =
        context.objectVisualSweepCurrentId ??
        context.selectedNode?['id']?.toString();
    final progress = context.objectVisualSweepTotal > 0
        ? ' (${context.objectVisualSweepVisited + 1}/${context.objectVisualSweepTotal})'
        : '';
    return ReviewCoachDecision(
      coachTarget: 'object_bbox',
      coachMessage:
          'AI 1차 검수에서는 의심 객체가 없습니다. 마지막으로 검출된 객체를 하나씩 빠르게 확인해 주세요.$progress',
      coachMode: 'GUIDE',
      highlightTarget: null,
      focusNodeId: selectedId,
    );
  }

  static ReviewCoachDecision _busDecision(PowerLensAssistantContext context) {
    if (context.busMappingAiReading) {
      return const ReviewCoachDecision(
        coachTarget: 'bus_ai_reading',
        coachMessage: '지금 Lensy가 도면의 모선 번호를 확인하고 있어요. 잠시만 기다려 주세요.',
        coachMode: 'PROCESSING',
        highlightTarget: 'bus_ai_reading',
      );
    }
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
    if (context.busFailureCode != null && context.busFailureCode!.isNotEmpty) {
      return ReviewCoachDecision(
        coachTarget: 'bus_bbox',
        coachMessage:
            'AI 자동 판독을 완료하지 못했어요. 모선 번호를 직접 확인해 적용하면 다음 미확정 모선으로 이동합니다.',
        coachMode: 'GUIDE',
        highlightTarget: null,
        focusNodeId: context.selectedNode?['id']?.toString(),
      );
    }
    return const ReviewCoachDecision(
      coachTarget: null,
      coachMessage:
          '모선 번호 오류가 없어 자동 검증 중이에요. 별도 완료 버튼 없이 검증에 통과하면 결선 검수로 이동합니다.',
      coachMode: 'PROCESSING',
      highlightTarget: null,
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

class ObjectReviewGuidanceMessages {
  static String initialBus(int count) {
    return '오른쪽 위의 설비 종류를 하나씩 확인해 주세요.\n'
        'Bus → Load → Generator → Transformer 순서로 진행합니다.\n'
        '지금은 Bus ${count}개를 확인할 차례예요.\n'
        '도면에서 Bus가 빠지거나 잘못 인식된 곳이 없는지 살펴봐 주세요.\n'
        '확인이 끝나면 오른쪽 위에서 깜박이는 [확인 후 다음 >] 버튼을 눌러주세요.\n'
        '버튼을 누르면 다음 종류인 Load로 넘어갑니다.';
  }

  static String load(int count) {
    return 'Bus 확인을 마쳤어요.\n'
        '이번에는 Load ${count}개를 확인할 차례예요.\n'
        '도면에서 Load가 빠지거나 잘못 인식된 곳이 없는지 살펴봐 주세요.\n'
        '확인이 끝나면 오른쪽 위에서 깜박이는 [확인 후 다음 >] 버튼을 눌러주세요.\n'
        '버튼을 누르면 다음 종류인 Generator로 넘어갑니다.';
  }

  static String generator(int count) {
    return 'Load 확인을 마쳤어요.\n'
        '이번에는 Generator ${count}개를 확인할 차례예요.\n'
        '도면에서 Generator가 빠지거나 잘못 인식된 곳이 없는지 살펴봐 주세요.\n'
        '확인이 끝나면 오른쪽 위에서 깜박이는 [확인 후 다음 >] 버튼을 눌러주세요.\n'
        '버튼을 누르면 다음 종류인 Transformer로 넘어갑니다.';
  }

  static String transformer(int count) {
    return 'Generator 확인을 마쳤어요.\n'
        '마지막으로 Transformer ${count}개를 확인할 차례예요.\n'
        '도면에서 Transformer가 빠지거나 잘못 인식된 곳이 없는지 살펴봐 주세요.\n'
        '확인이 끝나면 오른쪽 위에서 깜박이는 [확인 후 다음 >] 버튼을 눌러주세요.\n'
        '버튼을 누르면 전체 회로 보기로 전환합니다.';
  }

  static String revisit(String categoryLabel) =>
      '$categoryLabel 객체를 다시 보여드릴게요.\n'
      '필요한 부분을 다시 확인해주세요.\n'
      '확인이 끝나면 [확인 후 다음 >]을 눌러 계속 진행할 수 있어요.';

  static const String allReviewedBeforeCheck =
      'Bus, Load, Generator, Transformer를 모두 확인했어요.\n'
      '전체 회로를 표시했어요. 도면 전체를 한 번 더 살펴봐 주세요.\n'
      '이제 Lensy가 객체 상태와 남은 검수 항목을 다시 확인할게요.';

  static const String allReviewedCompletePass =
      '전체 객체 검수가 완료됐습니다. 현재 전체 회로를 확인하고 있습니다.\n'
      '문제가 없다면 아래에서 깜박이고 있는 [객체 검수 완료] 버튼을 눌러주세요.';
}
