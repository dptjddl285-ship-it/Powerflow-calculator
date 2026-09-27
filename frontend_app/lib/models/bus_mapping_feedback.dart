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
    this.modelUsed,
    this.primaryModel,
    this.fallbackModel,
    this.fallbackUsed = false,
    this.httpCode,
  });

  final BusMappingFeedbackKind kind;
  final String message;
  final int total;
  final int verified;
  final int uncertain;
  final String? modelUsed;
  final String? primaryModel;
  final String? fallbackModel;
  final bool fallbackUsed;
  final int? httpCode;

  bool get isComplete => kind == BusMappingFeedbackKind.complete;

  bool shouldAutoVerifyBusGate({required bool gateReady}) =>
      isComplete &&
      total > 0 &&
      verified == total &&
      uncertain == 0 &&
      gateReady;

  factory BusMappingFeedback.processing(int total) => BusMappingFeedback(
    kind: BusMappingFeedbackKind.processing,
    message: 'AI 번호 판독 중... 지금 Lensy가 도면의 모선 번호를 확인하고 있어요. 잠시만 기다려 주세요.',
    total: total,
    verified: 0,
    uncertain: total,
  );

  factory BusMappingFeedback.failed({int total = 0, int? httpCode}) =>
      BusMappingFeedback(
        kind: BusMappingFeedbackKind.failed,
        message: _failureMessage(httpCode),
        total: total,
        verified: 0,
        uncertain: total,
        httpCode: httpCode,
      );

  static String _failureMessage(int? httpCode) {
    switch (httpCode) {
      case 429:
        return 'AI 사용량 제한으로 자동 판독을 완료하지 못했습니다. 수동 확인으로 계속 진행할 수 있습니다.';
      case 503:
        return 'AI 서비스가 일시적으로 응답하지 않습니다. 수동 확인으로 계속 진행할 수 있습니다.';
      case 404:
        return '현재 Gemini 모델을 찾을 수 없어 자동 판독을 완료하지 못했습니다. 수동 확인으로 계속 진행할 수 있습니다.';
      default:
        return 'AI 자동 판독 호출에 실패했습니다. 수동 확인으로 진행합니다.';
    }
  }

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
    final rawCode = report['http_code'] ?? report['status_code'];
    final httpCode = rawCode is num
        ? rawCode.toInt()
        : int.tryParse(rawCode?.toString() ?? '') ??
              (() {
                final match = RegExp(
                  r'\b(404|429|503)\b',
                ).firstMatch(report['error']?.toString() ?? '');
                return match == null ? null : int.tryParse(match.group(1)!);
              })();
    final modelUsed = report['model_used']?.toString();
    final primaryModel = report['primary_model']?.toString();
    final fallbackModel = report['fallback_model']?.toString();
    final fallbackUsed = report['fallback_used'] == true;

    if (report['warning']?.toString().toLowerCase().contains('no api key') ==
            true ||
        reasons.contains('NO_API_KEY')) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.unavailable,
        message: 'Gemini 연결이 없어 모선 번호 자동 판독을 실행하지 못했습니다.',
        total: total,
        verified: verified,
        uncertain: uncertain,
        modelUsed: modelUsed,
        primaryModel: primaryModel,
        fallbackModel: fallbackModel,
        fallbackUsed: fallbackUsed,
        httpCode: httpCode,
      );
    }

    if (report['error'] != null || reasons.contains('VISION_AI_CALL_FAILED')) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.failed,
        message: _failureMessage(httpCode),
        total: total,
        verified: verified,
        uncertain: uncertain,
        modelUsed: modelUsed,
        primaryModel: primaryModel,
        fallbackModel: fallbackModel,
        fallbackUsed: fallbackUsed,
        httpCode: httpCode,
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
        modelUsed: modelUsed,
        primaryModel: primaryModel,
        fallbackModel: fallbackModel,
        fallbackUsed: fallbackUsed,
        httpCode: httpCode,
      );
    }

    if (verified == total && uncertain == 0) {
      return BusMappingFeedback(
        kind: BusMappingFeedbackKind.complete,
        message: 'AI 모선 번호 판독 완료: $verified/$total. 번호 검증 후 결선 검수로 이동합니다.',
        total: total,
        verified: verified,
        uncertain: uncertain,
        modelUsed: modelUsed,
        primaryModel: primaryModel,
        fallbackModel: fallbackModel,
        fallbackUsed: fallbackUsed,
        httpCode: httpCode,
      );
    }

    return BusMappingFeedback(
      kind: BusMappingFeedbackKind.partial,
      message:
          'AI 모선 번호 판독: $verified/$total 확인, $uncertain개 확인 필요. 반짝이는 모선부터 같이 확인해 주세요.',
      total: total,
      verified: verified,
      uncertain: uncertain,
      modelUsed: modelUsed,
      primaryModel: primaryModel,
      fallbackModel: fallbackModel,
      fallbackUsed: fallbackUsed,
      httpCode: httpCode,
    );
  }
}
