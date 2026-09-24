import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/bus_mapping_feedback.dart';

void main() {
  group('BusMappingFeedback', () {
    test('only reports completion when every bus is verified', () {
      final feedback = BusMappingFeedback.fromReport(
        report: const {
          'total_buses': 24,
          'verified_count': 24,
          'uncertain_count': 0,
        },
        totalFallback: 24,
        uncertainReasons: const [],
      );

      expect(feedback.kind, BusMappingFeedbackKind.complete);
      expect(feedback.message, contains('24/24'));
    });

    test('reports partial recognition and remaining review count', () {
      final feedback = BusMappingFeedback.fromReport(
        report: const {
          'total_buses': 24,
          'verified_count': 18,
          'uncertain_count': 6,
        },
        totalFallback: 24,
        uncertainReasons: const ['LOW_CONFIDENCE'],
      );

      expect(feedback.kind, BusMappingFeedbackKind.partial);
      expect(feedback.message, contains('18/24'));
      expect(feedback.uncertain, 6);
    });

    test(
      'distinguishes missing provider configuration from request failures',
      () {
        final unavailable = BusMappingFeedback.fromReport(
          report: const {'total_buses': 2, 'warning': 'NO_API_KEY'},
          totalFallback: 2,
          uncertainReasons: const ['NO_API_KEY'],
        );
        final failed = BusMappingFeedback.fromReport(
          report: const {'total_buses': 2, 'error': 'VISION_AI_CALL_FAILED'},
          totalFallback: 2,
          uncertainReasons: const ['VISION_AI_CALL_FAILED'],
        );

        expect(unavailable.kind, BusMappingFeedbackKind.unavailable);
        expect(failed.kind, BusMappingFeedbackKind.failed);
      },
    );

    test('reports missing visual evidence without claiming success', () {
      final feedback = BusMappingFeedback.fromReport(
        report: const {
          'total_buses': 3,
          'verified_count': 0,
          'uncertain_count': 3,
        },
        totalFallback: 3,
        uncertainReasons: const ['NO_BUS_NUMBER_FOUND'],
      );

      expect(feedback.kind, BusMappingFeedbackKind.noEvidence);
      expect(feedback.isComplete, isFalse);
    });
  });
}
