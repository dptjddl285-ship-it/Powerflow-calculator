import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/connection_visual_sweep.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_coach_policy.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

ReviewLineItem makeLine(
  String id,
  List<List<double>> path, {
  String status = 'DETECTED',
}) => ReviewLineItem(
  lineId: id,
  connectedTo: const ['bus_1', 'load_1'],
  path: path,
  reviewStatus: status,
);

ReviewNodeItem makeBus(String id, {int? number, String status = 'VERIFIED'}) =>
    ReviewNodeItem(
      id: id,
      className: 'bus',
      bbox: const [20, 20, 10, 10],
      confidence: 0.9,
      source: 'test',
      busNumber: number,
      busNumberStatus: status,
      reviewStatus: 'CONFIRMED',
    );

void main() {
  group('review coach policy and visual sweep', () {
    final lines = [
      makeLine('line_bottom', const [
        [10, 40],
        [20, 50],
      ]),
      makeLine('line_top_right', const [
        [20, 10],
        [30, 15],
      ]),
      makeLine('line_top_left', const [
        [5, 10],
        [10, 20],
      ]),
    ];

    test('sweep order uses path minY, then minX, then lineId', () {
      final ordered = ConnectionVisualSweep.orderedLines(lines);
      expect(ordered.map((line) => line.lineId), [
        'line_top_left',
        'line_top_right',
        'line_bottom',
      ]);
      expect(
        ConnectionVisualSweep.adjacentLine(
          orderedLines: ordered,
          selectedLineId: null,
          delta: 1,
        )?.lineId,
        'line_top_left',
      );
      expect(
        ConnectionVisualSweep.adjacentLine(
          orderedLines: ordered,
          selectedLineId: 'line_top_left',
          delta: 1,
        )?.lineId,
        'line_top_right',
      );
      expect(
        ConnectionVisualSweep.adjacentLine(
          orderedLines: ordered,
          selectedLineId: 'line_top_left',
          delta: -1,
        )?.lineId,
        'line_top_left',
      );
      expect(lines.every((line) => line.reviewStatus == 'DETECTED'), isTrue);
    });

    test('clean Connection first guides the focus toggle, not the Gate', () {
      final decision = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          workingLines: lines.map((line) => line.toJson()).toList(),
        ),
      );

      expect(decision.coachTarget, 'connection_focus_toggle');
      expect(decision.highlightTarget, 'connection_focus_toggle');
      expect(decision.coachMode, 'GUIDE');
      expect(decision.coachMessage, contains('→'));
      expect(decision.coachMessage, isNot(contains('[결선 검수 완료]')));
    });

    test(
      'active sweep reports visual progress and only then guides the Gate',
      () {
        final ordered = ConnectionVisualSweep.orderedLines(lines);
        final inProgress = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'CONNECTION_REVIEW',
            workingLines: lines.map((line) => line.toJson()).toList(),
            selectedLine: ordered[1].toJson(),
            connectionVisualSweepStarted: true,
          ),
        );
        expect(inProgress.coachTarget, 'connection_line_focus');
        expect(inProgress.coachMode, 'FOCUS');
        expect(inProgress.focusLineId, 'line_top_right');
        expect(inProgress.coachMessage, contains('최종 육안 확인 2 / 3'));
        expect(inProgress.coachMessage, isNot(contains('승인')));

        final complete = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'CONNECTION_REVIEW',
            workingLines: lines.map((line) => line.toJson()).toList(),
            selectedLine: ordered.last.toJson(),
            connectionVisualSweepStarted: true,
            connectionVisualSweepComplete: true,
          ),
        );
        expect(complete.coachTarget, 'connection_gate');
        expect(complete.highlightTarget, 'connection_gate');
        expect(complete.coachMode, 'GATE');
        expect(complete.coachMessage, contains('최종 육안 확인 3 / 3'));
      },
    );

    test('actual exceptions override the clean visual-sweep guide', () {
      final exceptional = makeLine('line_exception', const [
        [4, 8],
        [12, 18],
      ], status: 'AMBIGUOUS');
      final decision = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          workingLines: [
            ...lines.map((line) => line.toJson()),
            exceptional.toJson(),
          ],
          connectionVisualSweepStarted: true,
        ),
      );

      expect(decision.coachTarget, 'connection_exception');
      expect(decision.coachMode, 'GUIDE');
      expect(decision.focusLineId, 'line_exception');
      expect(decision.highlightTarget, isNull);
    });

    test(
      'Bus coach selects a real unresolved bus and clean state clears it',
      () {
        final issueBus = makeBus('bus_issue', status: 'UNCERTAIN');
        final issueDecision = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
            workingNodes: [issueBus.toJson()],
            unresolvedBusNumbers: 1,
            selectedNode: issueBus.toJson(),
          ),
        );
        expect(issueDecision.coachTarget, 'bus_bbox');
        expect(issueDecision.focusNodeId, 'bus_issue');
        expect(issueDecision.highlightTarget, isNull);
        expect(issueDecision.coachMode, 'GUIDE');

        final cleanDecision = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
            workingNodes: [makeBus('bus_clean', number: 1).toJson()],
          ),
        );
        expect(cleanDecision.coachTarget, 'bus_gate');
        expect(cleanDecision.highlightTarget, 'bus_gate');
        expect(cleanDecision.coachMode, 'GATE');
      },
    );

    test(
      'final state distinguishes Excel upload from matched canvas handoff',
      () {
        final upload = ReviewCoachPolicy.resolve(
          const PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'FINAL',
            finalVerified: true,
          ),
        );
        expect(upload.highlightTarget, 'final_excel_upload');

        final handoff = ReviewCoachPolicy.resolve(
          const PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'FINAL',
            finalVerified: true,
            excelLoaded: true,
            excelMappingStatus: 'MATCHED',
          ),
        );
        expect(handoff.highlightTarget, 'final_canvas_handoff');
        expect(handoff.coachMode, 'GATE');
      },
    );

    test('temporary highlights restore the persistent stage target', () async {
      final service = PowerLensAIService.instance;
      service.clearHighlight();
      service.setStageHighlightTarget('connection_focus_toggle');
      service.triggerHighlight(
        'temporary_response_target',
        duration: const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(service.activeHighlightTarget.value, 'connection_focus_toggle');
      service.clearHighlight();
    });

    test(
      'Object Review guide stays lit until its workflow stage changes',
      () async {
        final service = PowerLensAIService.instance;
        service.clearHighlight();
        service.setStageHighlightTarget(
          'object_category_bar',
          persistent: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(service.activeHighlightTarget.value, 'object_category_bar');
        expect(service.hasPersistentStageHighlight, isTrue);

        service.triggerHighlight(
          'temporary_response_target',
          duration: const Duration(milliseconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(service.activeHighlightTarget.value, 'object_category_bar');

        service.setStageHighlightTarget('object_gate', persistent: true);
        expect(service.activeHighlightTarget.value, 'object_gate');
        service.setStageHighlightTarget(null);
        expect(service.activeHighlightTarget.value, isNull);
        service.clearHighlight();
      },
    );
  });
}
