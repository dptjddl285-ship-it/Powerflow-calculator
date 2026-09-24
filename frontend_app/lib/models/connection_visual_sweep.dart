import 'review_models.dart';

/// Deterministic ordering and navigation for the visual-only Connection sweep.
/// This helper never changes a line's review state or gate evidence.
class ConnectionVisualSweep {
  const ConnectionVisualSweep._();

  static List<ReviewLineItem> orderedLines(Iterable<ReviewLineItem> lines) {
    final ordered = lines
        .where((line) => line.reviewStatus.toUpperCase() != 'REJECTED')
        .toList();
    ordered.sort((a, b) {
      final yCompare = _minCoordinate(
        a,
        axis: 1,
      ).compareTo(_minCoordinate(b, axis: 1));
      if (yCompare != 0) return yCompare;
      final xCompare = _minCoordinate(
        a,
        axis: 0,
      ).compareTo(_minCoordinate(b, axis: 0));
      return xCompare != 0 ? xCompare : a.lineId.compareTo(b.lineId);
    });
    return ordered;
  }

  static ReviewLineItem? adjacentLine({
    required List<ReviewLineItem> orderedLines,
    required String? selectedLineId,
    required int delta,
  }) {
    if (orderedLines.isEmpty || delta == 0) return null;
    final selectedIndex = orderedLines.indexWhere(
      (line) => line.lineId == selectedLineId,
    );
    final nextIndex = selectedIndex < 0
        ? (delta > 0 ? 0 : orderedLines.length - 1)
        : (selectedIndex + delta).clamp(0, orderedLines.length - 1).toInt();
    return orderedLines[nextIndex];
  }

  static int indexOf(List<ReviewLineItem> orderedLines, String? lineId) =>
      orderedLines.indexWhere((line) => line.lineId == lineId);

  static double _minCoordinate(ReviewLineItem line, {required int axis}) {
    final values = line.path
        .where((point) => point.length > axis)
        .map((point) => point[axis]);
    return values.isEmpty ? double.infinity : values.reduce(_min);
  }

  static double _min(double a, double b) => a < b ? a : b;
}
