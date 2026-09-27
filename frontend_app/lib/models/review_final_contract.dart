import 'review_models.dart';

/// Deterministic gates for the Verified SLD → Excel → CAD handoff.
class ReviewFinalContract {
  const ReviewFinalContract._();

  static bool canImportExcel({
    required bool isFinalPhase,
    required VerifiedSLD? verifiedSld,
  }) => isFinalPhase && verifiedSld?.status == 'VERIFIED';

  static bool hasVerifiedExcelMatch(Map<String, dynamic>? mismatchReport) =>
      mismatchReport?['is_matched'] == true;

  static bool canHandoffToCanvas({
    required bool isFinalPhase,
    required VerifiedSLD? verifiedSld,
    required Map<String, dynamic>? excelData,
    required Map<String, dynamic>? mismatchReport,
  }) =>
      canImportExcel(isFinalPhase: isFinalPhase, verifiedSld: verifiedSld) &&
      excelData != null &&
      hasVerifiedExcelMatch(mismatchReport);

  static List<String> mismatchMessages(Map<String, dynamic>? report) {
    if (report == null) return const [];
    final raw = report['discrepancies'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => (item['message'] ?? item['target'] ?? '').toString())
        .where((message) => message.trim().isNotEmpty)
        .toList(growable: false);
  }
}
