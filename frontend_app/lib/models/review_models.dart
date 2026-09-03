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
      if (displayLabel != null && displayLabel!.isNotEmpty) return displayLabel!;
      return id.toUpperCase();
    } else if (cls.contains('gen')) {
      if (busNumber != null) return "G_$busNumber";
      if (displayLabel != null && displayLabel!.isNotEmpty) return displayLabel!;
      return id.toUpperCase();
    } else if (cls.contains('load')) {
      if (busNumber != null) return "Load_$busNumber";
      if (displayLabel != null && displayLabel!.isNotEmpty) return displayLabel!;
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

    int? bNum = (json['bus_number'] as num?)?.toInt() ??
        (json['display_bus_no'] as num?)?.toInt() ??
        (json['parameters'] is Map ? (json['parameters']['bus_number'] as num?)?.toInt() : null);

    return ReviewNodeItem(
      id: json['id']?.toString() ?? '',
      className: json['class']?.toString() ?? 'bus',
      bbox: parsedBbox,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      source: json['source']?.toString() ?? 'unknown',
      reviewStatus:
          json['review_status']?.toString().toUpperCase() ?? 'DETECTED',
      reviewReasons: reasons,
      agentExplanation: json['agent_explanation']?.toString(),
      recommendedAction: json['recommended_action']?.toString(),
      evidence: json['evidence'] is Map<String, dynamic>
          ? json['evidence']
          : {},
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata']
          : {},
      displayLabel: json['display_name']?.toString() ?? json['display_label']?.toString(),
      displayNumber: (json['display_number'] as num?)?.toInt(),
      suggestedBusNumber: (json['suggested_bus_number'] as num?)?.toInt(),
      busNumber: bNum,
      busNumberStatus: json['bus_number_status']?.toString() ?? (json['parameters'] is Map ? json['parameters']['bus_number_status']?.toString() : null),
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
      'display_label': displayLabel,
      'display_number': displayNumber,
      'suggested_bus_number': suggestedBusNumber,
      'number_source': numberSource,
      'label_offset_dx': labelOffsetDx,
      'label_offset_dy': labelOffsetDy,
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

    return ReviewLineItem(
      lineId: json['line_id']?.toString() ?? json['id']?.toString() ?? '',
      connectedTo: parsedConnected,
      path: parsedPath,
      sourcePort: json['source_port']?.toString() ?? 'auto',
      targetPort: json['target_port']?.toString() ?? 'auto',
      traceMethod: json['trace_method']?.toString() ?? 'electrical_graph',
      reviewStatus:
          json['review_status']?.toString().toUpperCase() ?? 'DETECTED',
      source: json['source']?.toString() ?? 'ai_detected',
      validationIssues: parsedIssues,
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
      if (agentExplanation != null) 'agent_explanation': agentExplanation,
      if (recommendedAction != null) 'recommended_action': recommendedAction,
      'candidate_targets': candidateTargets,
      'display_label': displayLabel,
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

  ChatMessageItem({
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.agentStatus,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, String> toPayload() {
    return {'role': role, 'content': text};
  }
}
