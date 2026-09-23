import 'dart:typed_data';

class ReviewNodeItem {
  String id;
  String className;
  List<double> bbox; // [cx, cy, w, h] in original pixel coordinates
  double confidence;
  String source;
  String reviewStatus; // 'DETECTED', 'SUSPICIOUS', 'CONFIRMED', 'REJECTED'
  List<String> reviewReasons;
  String? agentExplanation;
  String? recommendedAction;
  List<String> suggestedClasses;
  Map<String, dynamic> evidence;
  Map<String, dynamic> metadata;

  // Display and Labeling enhancements
  String? displayLabel; // e.g. "BUS 4", "LOAD 2", "GEN 1"
  int? displayNumber; // e.g. 4, 2, 1
  int? suggestedBusNumber; // e.g. 4
  int? busNumber; // Verified or candidate bus number
  String? busNumberStatus; // 'VERIFIED', 'UNCERTAIN'
  List<String> busNumberReasons;
  int? connectedBusNumber;
  String? connectedBusId;
  String? numberSource; // 'detected_text' or 'sequence_fallback'
  double labelOffsetDx; // Draggable label offset x
  double labelOffsetDy; // Draggable label offset y

  ReviewNodeItem({
    required this.id,
    required this.className,
    required this.bbox,
    required this.confidence,
    required this.source,
    this.reviewStatus = 'DETECTED',
    this.reviewReasons = const [],
    this.agentExplanation,
    this.recommendedAction,
    this.suggestedClasses = const [],
    this.evidence = const {},
    this.metadata = const {},
    this.displayLabel,
    this.displayNumber,
    this.suggestedBusNumber,
    this.busNumber,
    this.busNumberStatus,
    this.busNumberReasons = const [],
    this.connectedBusNumber,
    this.connectedBusId,
    this.numberSource,
    this.labelOffsetDx = 0.0,
    this.labelOffsetDy = 0.0,
  });

  String get effectiveDisplayLabel {
    final cls = className.toLowerCase();
    if (cls == 'bus') {
      if (busNumber != null) return "Bus $busNumber";
      if (displayNumber != null) return "Bus $displayNumber";
      if (displayLabel != null && displayLabel!.isNotEmpty)
        return displayLabel!;
      return id.toUpperCase();
    } else if (cls.contains('gen')) {
      if (busNumber != null) return "G_$busNumber";
      if (displayLabel != null && displayLabel!.isNotEmpty)
        return displayLabel!;
      return id.toUpperCase();
    } else if (cls.contains('load')) {
      if (busNumber != null) return "Load_$busNumber";
      if (displayLabel != null && displayLabel!.isNotEmpty)
        return displayLabel!;
      return id.toUpperCase();
    }
    if (displayLabel != null && displayLabel!.isNotEmpty) {
      return displayLabel!;
    }
    return id.toUpperCase();
  }

  factory ReviewNodeItem.fromJson(Map<String, dynamic> json) {
    var rawBbox = json['bbox'];
    List<double> parsedBbox = [0, 0, 10, 10];
    if (rawBbox is List) {
      parsedBbox = rawBbox.map((e) => (e as num).toDouble()).toList();
    }

    var reasons = <String>[];
    if (json['review_reasons'] is List) {
      reasons = (json['review_reasons'] as List)
          .map((e) => e.toString())
          .toList();
    }

    var bReasons = <String>[];
    if (json['bus_number_reasons'] is List) {
      bReasons = (json['bus_number_reasons'] as List)
          .map((e) => e.toString())
          .toList();
    }

    int? bNum =
        (json['bus_number'] as num?)?.toInt() ??
        (json['display_bus_no'] as num?)?.toInt() ??
        (json['parameters'] is Map
            ? (json['parameters']['bus_number'] as num?)?.toInt()
            : null);

    return ReviewNodeItem(
      id: json['id']?.toString() ?? '',
      className: json['class']?.toString() ?? 'bus',
      bbox: parsedBbox,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      source: json['source']?.toString() ?? 'unknown',
      reviewStatus:
          (json['review_status'] ?? json['status'])?.toString().toUpperCase() ??
          'DETECTED',
      reviewReasons: reasons,
      agentExplanation: json['agent_explanation']?.toString(),
      recommendedAction: json['recommended_action']?.toString(),
      evidence: json['evidence'] is Map<String, dynamic>
          ? json['evidence']
          : {},
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata']
          : {},
      displayLabel:
          json['display_name']?.toString() ?? json['display_label']?.toString(),
      displayNumber: (json['display_number'] as num?)?.toInt(),
      suggestedBusNumber: (json['suggested_bus_number'] as num?)?.toInt(),
      busNumber: bNum,
      busNumberStatus:
          json['bus_number_status']?.toString() ??
          (json['parameters'] is Map
              ? json['parameters']['bus_number_status']?.toString()
              : null),
      busNumberReasons: bReasons,
      connectedBusNumber: (json['connected_bus_number'] as num?)?.toInt(),
      connectedBusId: json['connected_bus_id']?.toString(),
      numberSource: json['number_source']?.toString(),
      labelOffsetDx: (json['label_offset_dx'] as num?)?.toDouble() ?? 0.0,
      labelOffsetDy: (json['label_offset_dy'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'class': className,
      'bbox': bbox,
      'confidence': confidence,
      'source': source,
      'review_status': reviewStatus,
      'review_reasons': reviewReasons,
      if (agentExplanation != null) 'agent_explanation': agentExplanation,
      if (recommendedAction != null) 'recommended_action': recommendedAction,
      'suggested_classes': suggestedClasses,
      'evidence': evidence,
      'metadata': metadata,
      'display_label': effectiveDisplayLabel,
      'display_number': displayNumber,
      'suggested_bus_number': suggestedBusNumber,
      'number_source': numberSource,
      'label_offset_dx': labelOffsetDx,
      'label_offset_dy': labelOffsetDy,
      'bus_number': busNumber,
      'bus_number_status': busNumberStatus,
      'bus_number_reasons': busNumberReasons,
      'connected_bus_number': connectedBusNumber,
      'connected_bus_id': connectedBusId,
    };
  }

  ReviewNodeItem copyWith({
    String? id,
    String? className,
    List<double>? bbox,
    double? confidence,
    String? source,
    String? reviewStatus,
    List<String>? reviewReasons,
    String? agentExplanation,
    String? recommendedAction,
    List<String>? suggestedClasses,
    Map<String, dynamic>? evidence,
    Map<String, dynamic>? metadata,
    String? displayLabel,
    int? displayNumber,
    int? suggestedBusNumber,
    String? numberSource,
    double? labelOffsetDx,
    double? labelOffsetDy,
  }) {
    return ReviewNodeItem(
      id: id ?? this.id,
      className: className ?? this.className,
      bbox: bbox ?? List.from(this.bbox),
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reviewReasons: reviewReasons ?? List.from(this.reviewReasons),
      agentExplanation: agentExplanation ?? this.agentExplanation,
      recommendedAction: recommendedAction ?? this.recommendedAction,
      suggestedClasses: suggestedClasses ?? List.from(this.suggestedClasses),
      evidence: evidence ?? this.evidence,
      metadata: metadata ?? this.metadata,
      displayLabel: displayLabel ?? this.displayLabel,
      displayNumber: displayNumber ?? this.displayNumber,
      suggestedBusNumber: suggestedBusNumber ?? this.suggestedBusNumber,
      numberSource: numberSource ?? this.numberSource,
      labelOffsetDx: labelOffsetDx ?? this.labelOffsetDx,
      labelOffsetDy: labelOffsetDy ?? this.labelOffsetDy,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReviewNodeItem &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class MissingCandidateItem {
  final String id;
  final String suspectedClass;
  final String descriptionKo;
  final List<double>? approximateRegion;
  String status; // 'OPEN', 'RESOLVED_BY_MANUAL_ADD', 'DISMISSED_BY_HUMAN'
  final String source;

  MissingCandidateItem({
    required this.id,
    required this.suspectedClass,
    required this.descriptionKo,
    this.approximateRegion,
    this.status = 'OPEN',
    this.source = 'agent_completeness',
  });

  factory MissingCandidateItem.fromJson(Map<String, dynamic> json) {
    List<double>? region;
    if (json['approximate_region'] is List) {
      region = (json['approximate_region'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
    }
    return MissingCandidateItem(
      id: json['id']?.toString() ?? '',
      suspectedClass: json['suspected_class']?.toString() ?? 'transformer',
      descriptionKo: json['description_ko']?.toString() ?? '미검출 설비 후보',
      approximateRegion: region,
      status: json['status']?.toString().toUpperCase() ?? 'OPEN',
      source: json['source']?.toString() ?? 'agent_completeness',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'suspected_class': suspectedClass,
      'description_ko': descriptionKo,
      'approximate_region': approximateRegion,
      'status': status,
      'source': source,
    };
  }

  MissingCandidateItem copyWith({String? status}) {
    return MissingCandidateItem(
      id: id,
      suspectedClass: suspectedClass,
      descriptionKo: descriptionKo,
      approximateRegion: approximateRegion,
      status: status ?? this.status,
      source: source,
    );
  }
}

class ObjectReviewGateEvaluator {
  static List<String> getBlockers({
    required List<ReviewNodeItem> workingNodes,
    required List<MissingCandidateItem> missingCandidates,
  }) {
    final blockers = <String>[];
    final validNodes = workingNodes
        .where((n) => n.reviewStatus != 'REJECTED')
        .toList();
    if (validNodes.isEmpty) {
      blockers.add("유효한 전력 설비 심볼이 없습니다.");
    }
    final suspiciousNodes = validNodes
        .where((n) => n.reviewStatus == 'SUSPICIOUS')
        .toList();
    if (suspiciousNodes.isNotEmpty) {
      blockers.add("확인이 필요한 의심 객체(${suspiciousNodes.length}개)가 남아 있습니다.");
    }
    final unresolvedCands = missingCandidates
        .where((c) => c.status == 'OPEN')
        .toList();
    if (unresolvedCands.isNotEmpty) {
      blockers.add("미해결된 누락 의심 영역(${unresolvedCands.length}개)이 있습니다.");
    }
    return blockers;
  }

  static bool canVerifyGate({
    required List<ReviewNodeItem> workingNodes,
    required List<MissingCandidateItem> missingCandidates,
  }) {
    return getBlockers(
      workingNodes: workingNodes,
      missingCandidates: missingCandidates,
    ).isEmpty;
  }

  static Set<String> computeGuideNodeIds({
    required List<ReviewNodeItem> workingNodes,
    List<Map<String, dynamic>>? focusTargets,
  }) {
    final ids = <String>{};
    for (final node in workingNodes) {
      if (node.reviewStatus == 'SUSPICIOUS') {
        ids.add(node.id);
      }
    }
    if (focusTargets != null) {
      final nodeMap = {for (final n in workingNodes) n.id: n};
      for (final target in focusTargets) {
        final type = target['type']?.toString().toUpperCase();
        final id = target['id']?.toString();
        if (type == 'OBJECT' && id != null) {
          final node = nodeMap[id];
          // Fabricated ID protection: node must actually exist in workingNodes
          // Resolved protection: if node is already CONFIRMED or REJECTED, do not retain review warning guide
          if (node != null &&
              node.reviewStatus != 'REJECTED' &&
              node.reviewStatus != 'CONFIRMED') {
            ids.add(id);
          }
        }
      }
    }
    return ids;
  }

  static String getSpeechBubbleText({
    required int suspiciousCount,
    required int unresolvedCandidatesCount,
    String? selectedLabel,
  }) {
    if (suspiciousCount > 0) {
      final label = selectedLabel ?? '첫 번째 검토 항목';
      return "객체를 확인해봤어요. 대부분 괜찮고, 제가 다시 봤으면 하는 것부터 보여드릴게요.\n"
          "도면에 표시된 $label의 AI 판단 근거를 확인한 뒤 [맞음] 또는 [수정]을 선택해주세요.";
    }
    if (unresolvedCandidatesCount > 0) {
      return "의심 객체는 모두 확인되었으나, 누락 후보 $unresolvedCandidatesCount건이 남아 있어요.\n"
          "목록에서 복구하거나 문제없음 처리 후 [객체 검수 완료]를 눌러주세요.";
    }
    return "도면 내 모든 객체 인식이 정상적으로 완료되었어요!\n"
        "검토가 필요한 항목이 없으니 아래의 [객체 검수 완료]를 눌러 다음 단계로 가면 돼요.";
  }
}

class BusReviewGateEvaluator {
  static List<String> getBlockers({
    required List<ReviewNodeItem> workingNodes,
  }) {
    final blockers = <String>[];
    final busNodes = workingNodes
        .where(
          (n) =>
              n.className.toLowerCase() == 'bus' &&
              n.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .toList();

    if (busNodes.isEmpty) {
      blockers.add("도면 내 유효한 모선(Bus) 객체가 없습니다.");
      return blockers;
    }

    final counts = <int, int>{};
    for (final b in busNodes) {
      if (b.busNumber != null && b.busNumber! > 0) {
        counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
      }
    }
    final duplicates = counts.entries
        .where((e) => e.value > 1)
        .map((e) => e.key)
        .toList();

    final missingNumberBuses = <String>[];
    final invalidNumberBuses = <String>[];
    final duplicateBuses = <String>[];
    final uncertainStatusBuses = <String>[];

    for (final b in busNodes) {
      final num = b.busNumber;
      final status = (b.busNumberStatus ?? '').toUpperCase();
      final reasons = b.busNumberReasons;
      final hasActiveDupReason = reasons.any(
        (r) => r.toUpperCase().startsWith('DUPLICATE_BUS_NUMBER_'),
      );

      if (num == null) {
        missingNumberBuses.add(b.id);
      } else if (num <= 0) {
        invalidNumberBuses.add(b.id);
      } else if (duplicates.contains(num) || hasActiveDupReason) {
        duplicateBuses.add(b.id);
      } else if (status == 'UNCERTAIN') {
        uncertainStatusBuses.add(b.id);
      }
    }

    if (duplicates.isNotEmpty || duplicateBuses.isNotEmpty) {
      final dupStr = duplicates.isNotEmpty
          ? duplicates.map((n) => "#$n").join(", ")
          : "확인 필요";
      blockers.add("중복된 모선 번호($dupStr)가 존재합니다. 각각 고유한 번호로 수정해 주세요.");
    }
    if (missingNumberBuses.isNotEmpty) {
      blockers.add("번호가 미지정된 모선(${missingNumberBuses.length}개)이 있습니다.");
    }
    if (invalidNumberBuses.isNotEmpty) {
      blockers.add(
        "유효하지 않은 번호(0 이하)를 가진 모선(${invalidNumberBuses.length}개)이 있습니다.",
      );
    }
    if (uncertainStatusBuses.isNotEmpty) {
      blockers.add(
        "판독 상태가 불확실(UNCERTAIN)한 모선(${uncertainStatusBuses.length}개)이 있습니다.",
      );
    }

    return blockers;
  }

  static bool canVerifyGate({required List<ReviewNodeItem> workingNodes}) {
    return getBlockers(workingNodes: workingNodes).isEmpty;
  }

  static Set<String> computeGuideBusIds({
    required List<ReviewNodeItem> workingNodes,
    List<Map<String, dynamic>>? focusTargets,
  }) {
    final ids = <String>{};
    final busNodes = workingNodes
        .where(
          (n) =>
              n.className.toLowerCase() == 'bus' &&
              n.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .toList();

    final counts = <int, int>{};
    for (final b in busNodes) {
      if (b.busNumber != null && b.busNumber! > 0) {
        counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
      }
    }
    final duplicates = counts.entries
        .where((e) => e.value > 1)
        .map((e) => e.key)
        .toSet();

    for (final b in busNodes) {
      final num = b.busNumber;
      final status = (b.busNumberStatus ?? '').toUpperCase();
      final reasons = b.busNumberReasons;
      final hasActiveDupReason = reasons.any(
        (r) => r.toUpperCase().startsWith('DUPLICATE_BUS_NUMBER_'),
      );

      if (num == null ||
          num <= 0 ||
          duplicates.contains(num) ||
          status == 'UNCERTAIN' ||
          hasActiveDupReason) {
        ids.add(b.id);
      }
    }

    if (focusTargets != null) {
      final nodeMap = {for (final n in workingNodes) n.id: n};
      for (final target in focusTargets) {
        final type = target['type']?.toString().toUpperCase();
        final id = target['id']?.toString();
        // Canonical focus target type is 'OBJECT'. Legacy 'BUS' is disallowed.
        if (type == 'OBJECT' && id != null) {
          final node = nodeMap[id];
          if (node != null &&
              node.className.toLowerCase() == 'bus' &&
              node.reviewStatus != 'REJECTED') {
            ids.add(id);
          }
        }
      }
    }

    return ids;
  }

  static String getSpeechBubbleText({
    required List<ReviewNodeItem> workingNodes,
    String? selectedLabel,
  }) {
    final activeBuses = workingNodes
        .where(
          (node) =>
              node.className.toLowerCase() == 'bus' &&
              node.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .toList();
    if (activeBuses.isEmpty) {
      return "유효한 모선(Bus) 객체가 없습니다.\n"
          "객체 검수에서 모선 인식을 확인해주세요.";
    }

    final issueIds = computeGuideBusIds(workingNodes: activeBuses);
    final issueCount = issueIds.length;

    if (issueCount > 0) {
      return "모선 번호를 전체 확인했어요.\n"
          "다시 확인하면 좋은 모선이 ${issueCount}개 있어요.\n"
          "도면에 표시해둘게요.";
    }

    return "제가 다시 확인할 모선은 이제 없어요.\n"
        "전체 번호를 한번 확인한 뒤\n"
        "[모선 검수 완료]를 눌러주세요.";
  }
}

class BusReviewUiState {
  static const noActiveBusMessage = '유효한 모선(Bus) 객체가 없습니다. 객체 검수를 확인해주세요.';

  final int totalBuses;
  final int verifiedBuses;
  final int issueBuses;

  const BusReviewUiState({
    required this.totalBuses,
    required this.verifiedBuses,
    required this.issueBuses,
  });

  bool get hasIssues => issueBuses > 0;

  bool get isBlocked => totalBuses == 0 || hasIssues;

  String get subtitle => '모선 번호 검수';

  String get nextActionText {
    if (totalBuses == 0) return noActiveBusMessage;
    if (hasIssues) return '번호 확인이 필요한 모선 $issueBuses개를 확인하세요.';
    return '모선 번호 확인이 완료되었습니다. [모선 검수 완료]를 눌러주세요.';
  }

  static List<ReviewNodeItem> activeBusNodes(Iterable<ReviewNodeItem> nodes) {
    return nodes
        .where(
          (node) =>
              node.className.toLowerCase() == 'bus' &&
              node.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .toList();
  }

  factory BusReviewUiState.fromNodes(Iterable<ReviewNodeItem> nodes) {
    final active = activeBusNodes(nodes);
    final issueIds = BusReviewGateEvaluator.computeGuideBusIds(
      workingNodes: active,
    );
    return BusReviewUiState(
      totalBuses: active.length,
      verifiedBuses: active.length - issueIds.length,
      issueBuses: issueIds.length,
    );
  }

  static String rowBadgeText({
    required ReviewNodeItem node,
    required List<ReviewNodeItem> workingNodes,
  }) {
    final issueIds = BusReviewGateEvaluator.computeGuideBusIds(
      workingNodes: activeBusNodes(workingNodes),
    );
    if (!issueIds.contains(node.id)) return '확인됨';

    final active = activeBusNodes(workingNodes);
    final counts = <int, int>{};
    for (final bus in active) {
      if (bus.busNumber != null && bus.busNumber! > 0) {
        counts[bus.busNumber!] = (counts[bus.busNumber!] ?? 0) + 1;
      }
    }
    final hasDuplicateReason = node.busNumberReasons.any(
      (reason) => reason.toUpperCase().startsWith('DUPLICATE_BUS_NUMBER_'),
    );
    final hasDuplicateNumber =
        node.busNumber != null && (counts[node.busNumber!] ?? 0) > 1;
    return hasDuplicateNumber || hasDuplicateReason ? '중복 번호' : '검토필요';
  }

  static List<ReviewNodeItem> filter(
    Iterable<ReviewNodeItem> nodes, {
    String status = 'ALL',
  }) {
    final active = activeBusNodes(nodes);
    final issueIds = BusReviewGateEvaluator.computeGuideBusIds(
      workingNodes: active,
    );
    if (status == 'UNCERTAIN') {
      return active.where((node) => issueIds.contains(node.id)).toList();
    }
    if (status == 'VERIFIED') {
      return active.where((node) => !issueIds.contains(node.id)).toList();
    }
    return active;
  }
}

class BusReviewUiPolicy {
  static bool canEnterBusMapping({required bool objectGateVerified}) {
    return objectGateVerified;
  }

  static bool shouldIgnoreGlobalKeyForBus({
    required bool isBusPhase,
    required bool isTyping,
    required String keyLabel,
  }) {
    if (!isBusPhase || isTyping) return false;
    return const {
      'Arrow Right',
      'Arrow Left',
      'Arrow Up',
      'Arrow Down',
      'Enter',
      'Numpad Enter',
    }.contains(keyLabel);
  }
}

/// Deterministic, exception-first policy for the Connection Review V2 gate.
///
/// This helper is deliberately independent of widgets so the final CTA,
/// Lensy focus targets, and tests all use the same rules. A clean DETECTED
/// line is usable without an individual approval action. Only actual
/// exceptions or authoritative topology errors are returned as blockers.
class ConnectionReviewGateEvaluator {
  static const noActiveLineMessage =
      '유효한 결선 선로가 없습니다. 결선 검출을 확인해주세요.';
  static const primaryActionLabel = '결선 검수 완료';
  static const filterAll = 'ALL';
  static const filterNeedsReview = 'NEEDS_REVIEW';
  static const filterCrossing = 'CROSSING';

  static List<ReviewLineItem> activeLines(
    Iterable<ReviewLineItem> lines,
  ) {
    return lines
        .where((line) => line.reviewStatus.toUpperCase() != 'REJECTED')
        .toList();
  }

  /// Production filter contract shared by the Connection V2 widget and tests.
  /// Empty filtered results stay empty; callers must not fall back to ALL.
  static List<ReviewLineItem> filter(
    Iterable<ReviewLineItem> lines, {
    String status = filterAll,
  }) {
    final normalized = status.toUpperCase();
    if (normalized == 'REJECTED') {
      return lines
          .where((line) => line.reviewStatus.toUpperCase() == 'REJECTED')
          .toList();
    }

    final active = activeLines(lines);
    switch (normalized) {
      case filterNeedsReview:
      case 'AMBIGUOUS':
        return active.where(isExceptionLine).toList();
      case filterCrossing:
        return active.where(isUnresolvedCrossing).toList();
      case 'ERROR_ONLY':
        return active.where(lineHasCriticalIssue).toList();
      case 'DETECTED':
        return active
            .where((line) => line.reviewStatus.toUpperCase() == 'DETECTED')
            .toList();
      case 'AUTO_CONFIRMED':
        return active
            .where(
              (line) =>
                  line.reviewStatus.toUpperCase() == 'CONFIRMED' &&
                  !line.source.contains('human'),
            )
            .toList();
      case 'HUMAN_CONFIRMED':
        return active
            .where(
              (line) =>
                  line.reviewStatus.toUpperCase() == 'CONFIRMED' &&
                  line.source.contains('human'),
            )
            .toList();
      case filterAll:
      default:
        return active;
    }
  }

  static ReviewLineItem? selectedLineForFilter({
    required Iterable<ReviewLineItem> workingLines,
    required String status,
    ReviewLineItem? selectedLine,
  }) {
    if (selectedLine == null) return null;
    final visible = filter(workingLines, status: status);
    return visible.any((line) => line.lineId == selectedLine.lineId)
        ? selectedLine
        : null;
  }

  static bool isCriticalIssue(Map<String, dynamic> issue) {
    return issue['severity']?.toString().toLowerCase() == 'error';
  }

  static List<Map<String, dynamic>> _lineIssues(ReviewLineItem line) {
    final issues = <Map<String, dynamic>>[...line.validationIssues];
    final nested = line.evidence['validation_issues'];
    if (nested is List) {
      for (final issue in nested) {
        if (issue is Map<String, dynamic>) issues.add(issue);
      }
    }
    return issues;
  }

  static bool lineHasCriticalIssue(ReviewLineItem line) {
    return _lineIssues(line).any(isCriticalIssue);
  }

  static String _criticalIssueIdentity(
    Map<String, dynamic> issue, {
    String fallback = '',
  }) {
    final code = issue['code']?.toString().trim() ?? '';
    final message = issue['message']?.toString().trim() ?? '';
    if (code.isNotEmpty || message.isNotEmpty) {
      return 'evidence:$code:$message';
    }
    final id = issue['issue_id'] ?? issue['id'];
    if (id != null && id.toString().trim().isNotEmpty) {
      return 'id:${id.toString()}';
    }
    final lineId = issue['line_id'] ?? issue['lineId'];
    if (lineId != null && lineId.toString().trim().isNotEmpty) {
      return 'line:${lineId.toString()}';
    }
    return 'fallback:$fallback:${issue.toString()}';
  }

  static int criticalErrorCount({
    required List<ReviewLineItem> workingLines,
    List<Map<String, dynamic>> topologyIssues = const [],
  }) {
    final identities = <String>{};
    for (final line in activeLines(workingLines)) {
      for (final issue in _lineIssues(line).where(isCriticalIssue)) {
        identities.add(
          _criticalIssueIdentity(issue, fallback: line.lineId),
        );
      }
    }
    for (final issue in topologyIssues.where(isCriticalIssue)) {
      identities.add(_criticalIssueIdentity(issue));
    }
    return identities.length;
  }

  static bool _containsCrossingKey(String key) {
    final normalized = key.toLowerCase();
    return normalized.contains('cross') ||
        normalized.contains('overlap') ||
        normalized.contains('intersection') ||
        normalized.contains('교차');
  }

  static bool _evidenceValueExists(Object? value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized.isNotEmpty &&
          normalized != 'false' &&
          normalized != 'none' &&
          normalized != 'null';
    }
    if (value is Iterable || value is Map) return (value as dynamic).isNotEmpty;
    return true;
  }

  /// Returns true only when the payload contains explicit crossing/overlap
  /// evidence. A path alone is never treated as crossing evidence.
  static bool hasCrossingEvidence(ReviewLineItem line) {
    bool inspectMap(Map<String, dynamic> map) {
      for (final entry in map.entries) {
        if (_containsCrossingKey(entry.key) &&
            _evidenceValueExists(entry.value)) {
          return true;
        }
        if (entry.value is Map<String, dynamic> &&
            inspectMap(entry.value as Map<String, dynamic>)) {
          return true;
        }
      }
      return false;
    }

    if (inspectMap(line.evidence)) return true;
    return _lineIssues(line).any(
      (issue) => inspectMap(issue) ||
          (_containsCrossingKey(issue['code']?.toString() ?? '') &&
              _evidenceValueExists(issue['message'])),
    );
  }

  static bool isCrossingResolved(ReviewLineItem line) {
    final resolution = line.connectionReviewResolution?.toUpperCase();
    return resolution == 'CONNECTED' || resolution == 'CROSSING_ONLY';
  }

  static bool isUnresolvedCrossing(ReviewLineItem line) {
    return hasCrossingEvidence(line) && !isCrossingResolved(line);
  }

  static bool isExceptionLine(ReviewLineItem line) {
    return line.reviewStatus.toUpperCase() == 'AMBIGUOUS' ||
        lineHasCriticalIssue(line) ||
        isUnresolvedCrossing(line);
  }

  static List<String> getBlockers({
    required List<ReviewLineItem> workingLines,
    List<Map<String, dynamic>> topologyIssues = const [],
  }) {
    final blockers = <String>[];
    final active = activeLines(workingLines);
    if (active.isEmpty) {
      blockers.add(noActiveLineMessage);
      return blockers;
    }

    final ambiguousCount = active
        .where((line) => line.reviewStatus.toUpperCase() == 'AMBIGUOUS')
        .length;
    if (ambiguousCount > 0) {
      blockers.add('확인이 필요한 결선 $ambiguousCount건이 남아 있습니다.');
    }

    final crossingCount =
        active.where(isUnresolvedCrossing).length;
    if (crossingCount > 0) {
      blockers.add('교차 여부 확인이 필요한 결선 $crossingCount건이 남아 있습니다.');
    }

    final criticalErrorCountValue = criticalErrorCount(
      workingLines: workingLines,
      topologyIssues: topologyIssues,
    );
    if (criticalErrorCountValue > 0) {
      blockers.add(
        '전기적 연결 오류 $criticalErrorCountValue건을 해결해야 합니다.',
      );
    }
    return blockers;
  }

  static bool canVerifyGate({
    required List<ReviewLineItem> workingLines,
    List<Map<String, dynamic>> topologyIssues = const [],
  }) {
    return getBlockers(
      workingLines: workingLines,
      topologyIssues: topologyIssues,
    ).isEmpty;
  }

  static String? _issueId(Map<String, dynamic> issue) {
    final raw = issue['issue_id'] ?? issue['id'];
    return raw?.toString();
  }

  static Set<String> _issueComponentIds(Map<String, dynamic> issue) {
    final ids = <String>{};
    final raw = issue['component_ids'] ?? issue['related_ids'];
    if (raw is List) ids.addAll(raw.map((value) => value.toString()));
    final lineId = issue['line_id'] ?? issue['lineId'];
    if (lineId != null) ids.add(lineId.toString());
    return ids;
  }

  static Set<String> computeGuideLineIds({
    required List<ReviewLineItem> workingLines,
    List<Map<String, dynamic>> topologyIssues = const [],
    List<Map<String, dynamic>>? focusTargets,
  }) {
    final active = activeLines(workingLines);
    final ids = <String>{
      for (final line in active)
        if (isExceptionLine(line)) line.lineId,
    };
    final criticalIssues = topologyIssues.where(isCriticalIssue).toList();
    for (final issue in criticalIssues) {
      final components = _issueComponentIds(issue);
      for (final line in active) {
        if (components.contains(line.lineId) ||
            line.connectedTo.any(components.contains)) {
          ids.add(line.lineId);
        }
      }
    }
    if (focusTargets != null) {
      for (final target in focusTargets) {
        final type = target['type']?.toString().toUpperCase();
        final id = target['id']?.toString();
        final matching = active.where((item) => item.lineId == id);
        final line = matching.isEmpty ? null : matching.first;
        if (type == 'LINE' && line != null && isExceptionLine(line)) {
          ids.add(line.lineId);
        }
      }
    }
    return ids;
  }

  static Set<String> computeGuideIssueIds({
    List<Map<String, dynamic>> topologyIssues = const [],
    List<ReviewLineItem> workingLines = const [],
    List<Map<String, dynamic>>? focusTargets,
  }) {
    final ids = <String>{
      for (final issue in topologyIssues.where(isCriticalIssue))
        if (_issueId(issue) != null) _issueId(issue)!,
    };
    for (final line in activeLines(workingLines)) {
      for (final issue in _lineIssues(line).where(isCriticalIssue)) {
        if (_issueId(issue) != null) ids.add(_issueId(issue)!);
      }
    }
    if (focusTargets != null) {
      final validIds = <String>{
        for (final issue in topologyIssues)
          if (_issueId(issue) != null) _issueId(issue)!,
      }.whereType<String>().toSet();
      ids.addAll(
        focusTargets
            .where((target) => target['type']?.toString().toUpperCase() == 'ISSUE')
            .map((target) => target['id']?.toString())
            .whereType<String>()
            .where(validIds.contains),
      );
    }
    return ids;
  }

  static String lineStatusLabel(ReviewLineItem line) {
    final status = line.reviewStatus.toUpperCase();
    if (status == 'REJECTED') return '제외';
    if (lineHasCriticalIssue(line)) return '전기 오류';
    if (isUnresolvedCrossing(line)) return '교차 검토';
    if (status == 'AMBIGUOUS') return '확인 필요';
    return 'AI 확인 · 정상 연결';
  }

  static ReviewLineItem reassignTarget(
    ReviewLineItem line,
    String targetId,
  ) {
    final endpoints = List<String>.from(line.connectedTo);
    if (endpoints.isEmpty) return line;
    if (endpoints.length == 1) {
      endpoints.add(targetId);
    } else {
      endpoints[1] = targetId;
    }
    final reassigned = line.copyWith(
      connectedTo: endpoints,
      reviewStatus: 'CONFIRMED',
      source: 'human_reconnected',
    );
    reassigned.connectionReviewResolution = null;
    return reassigned;
  }
}

class CompletenessReviewResult {
  final String assessment;
  final String messageKo;
  final List<MissingCandidateItem> candidates;
  final Map<String, int> classCounts;
  final String agentStatus;

  CompletenessReviewResult({
    required this.assessment,
    required this.messageKo,
    required this.candidates,
    this.classCounts = const {},
    this.agentStatus = 'DETERMINISTIC',
  });

  factory CompletenessReviewResult.fromJson(Map<String, dynamic> json) {
    var rawList = json['candidates'] as List? ?? [];
    var parsed = rawList
        .map((c) => MissingCandidateItem.fromJson(c as Map<String, dynamic>))
        .toList();

    var rawCounts = json['class_counts'] as Map<String, dynamic>? ?? {};
    Map<String, int> counts = {};
    rawCounts.forEach((k, v) {
      if (v is num) counts[k] = v.toInt();
    });

    return CompletenessReviewResult(
      assessment: json['assessment']?.toString() ?? 'ALL_EXPECTED_PRESENT',
      messageKo: json['message_ko']?.toString() ?? '',
      candidates: parsed,
      classCounts: counts,
      agentStatus: json['agent_status']?.toString() ?? 'DETERMINISTIC',
    );
  }
}

class ReviewLineItem {
  String lineId;
  List<String> connectedTo; // [sourceNodeId, targetNodeId]
  List<List<double>> path; // [[x1,y1], [x2,y2], ...] original coordinates
  String sourcePort;
  String targetPort;
  String traceMethod;
  String reviewStatus; // 'DETECTED', 'AMBIGUOUS', 'CONFIRMED', 'REJECTED'
  String source;
  List<Map<String, dynamic>> validationIssues;
  Map<String, dynamic> evidence;
  String? connectionReviewResolution;
  String? agentExplanation;
  String? recommendedAction;
  List<String> candidateTargets;

  // Display and Labeling enhancements
  String? displayLabel; // e.g. "L1", "L2"
  String? displayName; // e.g. "L1 (BUS 4 ↔ LOAD 2)"
  String? endpointsDisplay; // e.g. "BUS 4 ↔ LOAD 2"
  double labelOffsetDx;
  double labelOffsetDy;

  ReviewLineItem({
    required this.lineId,
    required this.connectedTo,
    required this.path,
    this.sourcePort = 'auto',
    this.targetPort = 'auto',
    this.traceMethod = 'electrical_graph',
    this.reviewStatus = 'DETECTED',
    this.source = 'ai_detected',
    this.validationIssues = const [],
    this.evidence = const {},
    this.connectionReviewResolution,
    this.agentExplanation,
    this.recommendedAction,
    this.candidateTargets = const [],
    this.displayLabel,
    this.displayName,
    this.endpointsDisplay,
    this.labelOffsetDx = 0.0,
    this.labelOffsetDy = 0.0,
  });

  String get effectiveDisplayLabel {
    if (displayLabel != null && displayLabel!.isNotEmpty) {
      return displayLabel!;
    }
    return lineId.toUpperCase();
  }

  factory ReviewLineItem.fromJson(Map<String, dynamic> json) {
    var rawConnected = json['connected_to'];
    List<String> parsedConnected = [];
    if (rawConnected is List) {
      parsedConnected = rawConnected.map((e) => e.toString()).toList();
    }

    var rawPath = json['path'];
    List<List<double>> parsedPath = [];
    if (rawPath is List) {
      for (var pt in rawPath) {
        if (pt is List && pt.length >= 2) {
          parsedPath.add([
            (pt[0] as num).toDouble(),
            (pt[1] as num).toDouble(),
          ]);
        }
      }
    }

    var rawIssues = json['validation_issues'];
    List<Map<String, dynamic>> parsedIssues = [];
    if (rawIssues is List) {
      parsedIssues = rawIssues
          .map((i) => i is Map<String, dynamic> ? i : <String, dynamic>{})
          .toList();
    }

    var rawCandidates =
        json['candidate_connections'] ?? json['candidate_targets'];
    List<String> parsedCandidates = [];
    if (rawCandidates is List) {
      parsedCandidates = rawCandidates.map((e) => e.toString()).toList();
    }

    final rawEvidence = json['evidence'];
    final parsedEvidence = rawEvidence is Map<String, dynamic>
        ? rawEvidence
        : <String, dynamic>{};

    return ReviewLineItem(
      lineId: json['line_id']?.toString() ?? json['id']?.toString() ?? '',
      connectedTo: parsedConnected,
      path: parsedPath,
      sourcePort: json['source_port']?.toString() ?? 'auto',
      targetPort: json['target_port']?.toString() ?? 'auto',
      traceMethod: json['trace_method']?.toString() ?? 'electrical_graph',
      reviewStatus:
          (json['review_status'] ?? json['status'])?.toString().toUpperCase() ??
          'DETECTED',
      source: json['source']?.toString() ?? 'ai_detected',
      validationIssues: parsedIssues,
      evidence: parsedEvidence,
      connectionReviewResolution:
          (json['connection_review_resolution'] ??
                  json['crossing_resolution'] ??
                  json['crossingResolution'])
              ?.toString(),
      agentExplanation: json['agent_explanation']?.toString(),
      recommendedAction: json['recommended_action']?.toString(),
      candidateTargets: parsedCandidates,
      displayLabel: json['display_label']?.toString(),
      displayName: json['display_name']?.toString(),
      endpointsDisplay: json['endpoints_display']?.toString(),
      labelOffsetDx: (json['label_offset_dx'] as num?)?.toDouble() ?? 0.0,
      labelOffsetDy: (json['label_offset_dy'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'line_id': lineId,
      'connected_to': connectedTo,
      'path': path,
      'source_port': sourcePort,
      'target_port': targetPort,
      'trace_method': traceMethod,
      'review_status': reviewStatus,
      'source': source,
      'validation_issues': validationIssues,
      'evidence': evidence,
      if (connectionReviewResolution != null)
        'connection_review_resolution': connectionReviewResolution,
      if (agentExplanation != null) 'agent_explanation': agentExplanation,
      if (recommendedAction != null) 'recommended_action': recommendedAction,
      'candidate_targets': candidateTargets,
      'display_label': effectiveDisplayLabel,
      'display_name': displayName,
      'endpoints_display': endpointsDisplay,
      'label_offset_dx': labelOffsetDx,
      'label_offset_dy': labelOffsetDy,
    };
  }

  ReviewLineItem copyWith({
    String? lineId,
    List<String>? connectedTo,
    List<List<double>>? path,
    String? sourcePort,
    String? targetPort,
    String? traceMethod,
    String? reviewStatus,
    String? source,
    List<Map<String, dynamic>>? validationIssues,
    Map<String, dynamic>? evidence,
    String? connectionReviewResolution,
    String? agentExplanation,
    String? recommendedAction,
    List<String>? candidateTargets,
    String? displayLabel,
    String? displayName,
    String? endpointsDisplay,
    double? labelOffsetDx,
    double? labelOffsetDy,
  }) {
    return ReviewLineItem(
      lineId: lineId ?? this.lineId,
      connectedTo: connectedTo ?? List.from(this.connectedTo),
      path: path ?? List.from(this.path),
      sourcePort: sourcePort ?? this.sourcePort,
      targetPort: targetPort ?? this.targetPort,
      traceMethod: traceMethod ?? this.traceMethod,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      source: source ?? this.source,
      validationIssues: validationIssues ?? List.from(this.validationIssues),
      evidence: evidence ?? Map<String, dynamic>.from(this.evidence),
      connectionReviewResolution:
          connectionReviewResolution ?? this.connectionReviewResolution,
      agentExplanation: agentExplanation ?? this.agentExplanation,
      recommendedAction: recommendedAction ?? this.recommendedAction,
      candidateTargets: candidateTargets ?? List.from(this.candidateTargets),
      displayLabel: displayLabel ?? this.displayLabel,
      displayName: displayName ?? this.displayName,
      endpointsDisplay: endpointsDisplay ?? this.endpointsDisplay,
      labelOffsetDx: labelOffsetDx ?? this.labelOffsetDx,
      labelOffsetDy: labelOffsetDy ?? this.labelOffsetDy,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReviewLineItem &&
          runtimeType == other.runtimeType &&
          lineId == other.lineId;

  @override
  int get hashCode => lineId.hashCode;
}

class ReviewImageMeta {
  final int width;
  final int height;
  final String url;

  ReviewImageMeta({
    required this.width,
    required this.height,
    required this.url,
  });

  factory ReviewImageMeta.fromJson(Map<String, dynamic> json) {
    return ReviewImageMeta(
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      url: json['url']?.toString() ?? '',
    );
  }
}

class PriorityReviewItem {
  final String id;
  final String displayLabel;
  final String
  targetType; // 'NODE', 'LINE', 'MISSING_CANDIDATE', 'TOPOLOGY_ISSUE'
  final String reason;
  final String severity; // 'ALERT', 'WARNING', 'ERROR'

  PriorityReviewItem({
    required this.id,
    required this.displayLabel,
    required this.targetType,
    required this.reason,
    this.severity = 'WARNING',
  });

  factory PriorityReviewItem.fromJson(Map<String, dynamic> json) {
    return PriorityReviewItem(
      id: json['id']?.toString() ?? '',
      displayLabel: json['display_label']?.toString() ?? '',
      targetType: json['target_type']?.toString() ?? 'NODE',
      reason: json['reason']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'WARNING',
    );
  }
}

class ProactiveSummaryItem {
  final String summaryText;
  final int totalCount;
  final int cleanCount;
  final int suspiciousCount;
  final int missingCount;
  final List<PriorityReviewItem> priorityItems;
  final String providerMode;
  final String displayMode;

  ProactiveSummaryItem({
    required this.summaryText,
    required this.totalCount,
    required this.cleanCount,
    required this.suspiciousCount,
    required this.missingCount,
    this.priorityItems = const [],
    this.providerMode = 'local',
    this.displayMode = '로컬 분석 모드',
  });

  factory ProactiveSummaryItem.fromJson(Map<String, dynamic> json) {
    var rawItems = json['priority_items'] as List? ?? [];
    var parsedItems = rawItems
        .map((p) => PriorityReviewItem.fromJson(p as Map<String, dynamic>))
        .toList();

    return ProactiveSummaryItem(
      summaryText: json['summary_text']?.toString() ?? '',
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      cleanCount: (json['clean_count'] as num?)?.toInt() ?? 0,
      suspiciousCount: (json['suspicious_count'] as num?)?.toInt() ?? 0,
      missingCount: (json['missing_count'] as num?)?.toInt() ?? 0,
      priorityItems: parsedItems,
      providerMode: json['provider_mode']?.toString() ?? 'local',
      displayMode: json['display_mode']?.toString() ?? '로컬 분석 모드',
    );
  }
}

class ReviewDocument {
  final String documentId;
  final String reviewStage;
  final ReviewImageMeta image;
  final List<ReviewNodeItem> nodes;
  final List<ReviewLineItem> lines;
  final Map<String, dynamic> pipeline;
  final ProactiveSummaryItem? proactiveSummary;
  final Uint8List? rawBytes;

  ReviewDocument({
    required this.documentId,
    required this.reviewStage,
    required this.image,
    required this.nodes,
    this.lines = const [],
    this.pipeline = const {},
    this.proactiveSummary,
    this.rawBytes,
  });

  factory ReviewDocument.fromJson(
    Map<String, dynamic> json, {
    Uint8List? rawBytes,
  }) {
    var rawNodes = json['nodes'] as List? ?? [];
    var parsedNodes = rawNodes
        .map((n) => ReviewNodeItem.fromJson(n as Map<String, dynamic>))
        .toList();

    var rawLines = json['lines'] as List? ?? [];
    var parsedLines = rawLines
        .map((l) => ReviewLineItem.fromJson(l as Map<String, dynamic>))
        .toList();

    ProactiveSummaryItem? summary;
    if (json['proactive_summary'] is Map<String, dynamic>) {
      summary = ProactiveSummaryItem.fromJson(json['proactive_summary']);
    }

    return ReviewDocument(
      documentId: json['document_id']?.toString() ?? '',
      reviewStage: json['review_stage']?.toString() ?? 'OBJECT_REVIEW',
      image: ReviewImageMeta.fromJson(
        json['image'] as Map<String, dynamic>? ?? {},
      ),
      nodes: parsedNodes,
      lines: parsedLines,
      pipeline: json['pipeline'] as Map<String, dynamic>? ?? {},
      proactiveSummary: summary,
      rawBytes: rawBytes,
    );
  }
}

class VerifiedSLD {
  final String schemaVersion;
  final String documentId;
  final String status;
  final ReviewImageMeta image;
  final List<ReviewNodeItem> nodes;
  final List<ReviewLineItem> lines;
  final Map<String, dynamic> verification;

  VerifiedSLD({
    this.schemaVersion = "1.0",
    required this.documentId,
    this.status = "VERIFIED",
    required this.image,
    required this.nodes,
    required this.lines,
    this.verification = const {},
  });

  factory VerifiedSLD.fromJson(Map<String, dynamic> json) {
    var rawNodes = json['nodes'] as List? ?? [];
    var parsedNodes = rawNodes
        .map((n) => ReviewNodeItem.fromJson(n as Map<String, dynamic>))
        .toList();

    var rawLines = json['lines'] as List? ?? [];
    var parsedLines = rawLines
        .map((l) => ReviewLineItem.fromJson(l as Map<String, dynamic>))
        .toList();

    return VerifiedSLD(
      schemaVersion: json['schema_version']?.toString() ?? "1.0",
      documentId: json['document_id']?.toString() ?? '',
      status: json['status']?.toString() ?? "VERIFIED",
      image: ReviewImageMeta.fromJson(
        json['image'] as Map<String, dynamic>? ?? {},
      ),
      nodes: parsedNodes,
      lines: parsedLines,
      verification: json['verification'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'document_id': documentId,
      'status': status,
      'image': {'width': image.width, 'height': image.height},
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'lines': lines.map((l) => l.toJson()).toList(),
      'verification': verification,
    };
  }
}

class ChatMessageItem {
  final String role; // "user", "assistant"
  final String text;
  final DateTime timestamp;
  final String? agentStatus;
  final String? providerMode;

  ChatMessageItem({
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.agentStatus,
    this.providerMode,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, String> toPayload() {
    return {'role': role, 'content': text};
  }
}
