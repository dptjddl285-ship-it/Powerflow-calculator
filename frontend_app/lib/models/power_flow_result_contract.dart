class PowerFlowResultContract {
  static bool hasActualResult(Map<String, dynamic>? result) {
    if (result == null || result['converged'] is! bool) return false;
    if (result['iterations'] is! num || result['max_mismatch'] is! num) {
      return false;
    }
    if (result['slack_bus'] is! num || result['summary'] is! Map) return false;
    final buses = result['bus_results'];
    final lines = result['line_results'];
    return buses is List &&
        buses.isNotEmpty &&
        lines is List &&
        lines.isNotEmpty;
  }

  static bool isConverged(Map<String, dynamic>? result) =>
      hasActualResult(result) && result!['converged'] == true;

  /// Returns whether signed solver flow follows CAD endpoint order.
  /// Null means the result endpoints do not match this CAD branch.
  static bool? followsCanvasDirection({
    required int canvasFromBus,
    required int canvasToBus,
    required int solverFromBus,
    required int solverToBus,
    required double pFromMw,
  }) {
    if (canvasFromBus == solverFromBus && canvasToBus == solverToBus) {
      return pFromMw >= 0;
    }
    if (canvasFromBus == solverToBus && canvasToBus == solverFromBus) {
      return pFromMw < 0;
    }
    return null;
  }

  static List<T> orientRoute<T>(List<T> routedPoints, bool forward) => forward
      ? List<T>.unmodifiable(routedPoints)
      : List<T>.unmodifiable(routedPoints.reversed);
}
