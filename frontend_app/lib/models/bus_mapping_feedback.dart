enum BusMappingFeedbackKind {
  processing,
  complete,
  partial,
  unavailable,
  failed,
  noEvidence,
}

class BusMappingFeedback {
  const BusMappingFeedback({
    required this.kind,
    required this.message,
    required this.total,
    required this.verified,
    required this.uncertain,
  });

  final BusMappingFeedbackKind kind;
  final String message;
  final int total;
  final int verified;
  final int uncertain;

  bool get isComplete => kind == BusMappingFeedbackKind.complete;

  factory BusMappingFeedback.processing(int total) => BusMappingFeedback(
    kind: BusMappingFeedbackKind.processing,
    message: 'AI 번호 판독 중... ${total}개 모선의 도면 번호를 확인하고 있습니다.',
    total: total,
    verified: 0,
    uncertain: total,
  );

  factory BusMappingFeedback.failed({int total = 0}) => BusMappingFeedback(
    kind: BusMappingFeedbackKind.failed,
    message: '모선 번호 AI 판독 호출에 실패했습니다.',
    total: total,
    verified: 0,
    uncertain: total,
  );

  factory BusMappingFeedback.fromReport({
    required Map<String, dynamic> report,
    required int totalFallback,
    required Iterable<String> uncertainReasons,
  }) {
    final reasons = uncertainReasons.toSet();
    int count(String key, int fallback) {
      final value = report[key];
      return value is num ? value.toInt() : fallback;
    }

    final total = count('total_buses', totalFallback).clamp(0, 100000);
    final verified = count('verified_count', 0).clamp(0, total);
    final uncertain = count(
      'uncertain_count',
      total - verified,
    ).clamp(0, total);

    if (report['warning']?.toString().toLowerCase().contains('no api key') ==
            true ||
        reasons.contains('NO_API_KEY')) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.unavailable,
        message: 'Gemini 연결이 없어 모선 번호 자동 판독을 실행하지 못했습니다.',
        total: total,
        verified: verified,
        uncertain: uncertain,
      );
    }

    if (report['error'] != null || reasons.contains('VISION_AI_CALL_FAILED')) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.failed,
        message: '모선 번호 AI 판독 호출에 실패했습니다.',
        total: total,
        verified: verified,
        uncertain: uncertain,
      );
    }

    if (total == 0 ||
        (verified == 0 &&
            reasons.isNotEmpty &&
            reasons.every((reason) => reason == 'NO_BUS_NUMBER_FOUND'))) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.noEvidence,
        message: '자동으로 확인할 수 있는 모선 번호가 없습니다. 표시된 항목만 확인해주세요.',
        total: total,
        verified: verified,
        uncertain: uncertain,
      );
    }

    if (verified == total && uncertain == 0) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.complete,
        message: 'AI 모선 번호 판독 완료: $verified/$total',
        total: total,
        verified: verified,
        uncertain: uncertain,
      );
    }

    return BusMappingFeedback(
      kind: BusMappingFeedbackKind.partial,
      message: 'AI 모선 번호 판독: $verified/$total 확인, $uncertain개 확인 필요',
      total: total,
      verified: verified,
      uncertain: uncertain,
    );
  }
}
