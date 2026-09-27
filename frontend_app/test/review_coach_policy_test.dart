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
      final visited = <String>{};
      ConnectionVisualSweep.updateVisitedLineIds(
        visited,
        currentLineId: 'line_top_left',
        nextLineId: 'line_top_right',
        delta: 1,
      );
      expect(visited, {'line_top_left'});
      ConnectionVisualSweep.updateVisitedLineIds(
        visited,
        currentLineId: 'line_top_right',
        nextLineId: 'line_top_left',
        delta: -1,
      );
      expect(visited, isEmpty);
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
      expect(
        ReviewCoachPolicy.resolveMascotState(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'CONNECTION_REVIEW',
            workingLines: lines.map((line) => line.toJson()).toList(),
          ),
          completionCtaReady: false,
        ),
        'idle',
      );
    });

    test('Object missing candidates take priority over suspicious objects', () {
      final suspicious = ReviewNodeItem(
        id: 'object_1',
        className: 'load',
        bbox: const [10, 10, 5, 5],
        confidence: 0.55,
        source: 'test',
        reviewStatus: 'SUSPICIOUS',
      );
      final decision = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          suspiciousObjects: 1,
          unresolvedMissingCandidates: 1,
          workingNodes: [suspicious.toJson()],
          selectedNode: suspicious.toJson(),
        ),
      );

      expect(decision.coachMessage, contains('[수동 추가]'));
      expect(decision.coachMessage, contains('[문제 없음]'));
      expect(decision.highlightTarget, 'missing_candidates');
      expect(decision.coachTarget, 'missing_candidates');

      final suspiciousOnly = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          suspiciousObjects: 1,
          unresolvedMissingCandidates: 0,
          workingNodes: [suspicious.toJson()],
          selectedNode: suspicious.toJson(),
        ),
      );
      expect(suspiciousOnly.coachMessage, contains('[맞음]'));
      expect(suspiciousOnly.coachMessage, contains('[수정]'));
      expect(suspiciousOnly.coachMessage, contains('이제 강조된 객체 검토 카드'));
      expect(suspiciousOnly.highlightTarget, 'object_review_card');
      expect(suspiciousOnly.focusNodeId, 'object_1');
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

        final lastLineSelected = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'CONNECTION_REVIEW',
            workingLines: lines.map((line) => line.toJson()).toList(),
            selectedLine: ordered.last.toJson(),
            connectionVisualSweepStarted: true,
          ),
        );
        expect(lastLineSelected.coachTarget, 'connection_line_focus');

        final completeContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          workingLines: lines.map((line) => line.toJson()).toList(),
          selectedLine: ordered.last.toJson(),
          connectionVisualSweepStarted: true,
          connectionVisualSweepComplete: true,
        );
        final complete = ReviewCoachPolicy.resolve(completeContext);
        expect(complete.coachTarget, 'connection_gate');
        expect(complete.highlightTarget, 'connection_gate');
        expect(complete.coachMode, 'GATE');
        expect(
          complete.coachMessage,
          '결선 검수를 모두 확인했어요.\n'
          '현재 확인이 필요한 결선은 없습니다.\n\n'
          '전체 네트워크를 마지막으로 한 번 확인해 주세요.\n\n'
          '문제가 없다면 아래에서 깜박이고 있는\n'
          '[결선 검수 완료] 버튼을 눌러\n'
          '다음 단계로 이동해 주세요.',
        );
        expect(
          ReviewCoachPolicy.resolveMascotState(
            completeContext,
            completionCtaReady: true,
          ),
          'success',
        );
      },
    );

    test('Object completion CTA readiness controls Lensy success', () {
      final bus = makeBus('bus_object_review', number: 1);
      final readyContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        hasDiagram: true,
        totalObjects: 1,
        workingNodes: [bus.toJson()],
        objectReviewStage: 'READY_TO_COMPLETE',
        objectHumanCompletenessConfirmed: true,
      );

      expect(
        ReviewCoachPolicy.resolveMascotState(
          readyContext,
          completionCtaReady: true,
        ),
        'success',
      );
      expect(
        ReviewCoachPolicy.resolve(readyContext).coachMessage,
        '객체 검수를 모두 확인했어요.\n'
        '마지막으로 전체 도면을 한 번 확인해 주세요.\n\n'
        '문제가 없다면 아래에서 깜박이고 있는\n'
        '[객체 검수 완료] 버튼을 눌러주세요.',
      );

      final blockedContext = readyContext.copyWith(
        suspiciousObjects: 1,
        currentBlockers: const ['의심 객체가 남아 있습니다.'],
      );
      expect(
        ReviewCoachPolicy.resolveMascotState(
          blockedContext,
          completionCtaReady: false,
        ),
        'warning',
      );
    });

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
        expect(cleanDecision.coachMode, 'HUMAN_REVIEW');
        expect(cleanDecision.coachMessage, contains('[모선 검수 완료]'));
        expect(
          ReviewCoachPolicy.resolveMascotState(
            PowerLensAssistantContext(
              currentScreen: 'REVIEW_PAGE',
              workflowStage: 'BUS_MAPPING',
              workingNodes: [makeBus('bus_clean', number: 1).toJson()],
            ),
            completionCtaReady: true,
          ),
          'success',
        );
      },
    );

    test('Bus reading and unresolved buses cannot show Lensy success', () {
      final buses = [makeBus('bus_clean', number: 1)];
      final reading = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        workingNodes: buses.map((bus) => bus.toJson()).toList(),
        busMappingAiReading: true,
      );
      expect(
        ReviewCoachPolicy.resolveMascotState(
          reading,
          completionCtaReady: false,
        ),
        'thinking',
      );

      final unresolved = ReviewNodeItem(
        id: 'bus_unresolved',
        className: 'bus',
        bbox: const [20, 20, 10, 10],
        confidence: 0.9,
        source: 'test',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
        reviewStatus: 'CONFIRMED',
      );
      final unresolvedContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        workingNodes: [unresolved.toJson()],
        unresolvedBusNumbers: 1,
        currentBlockers: const ['모선 번호 확인이 필요합니다.'],
      );
      expect(
        ReviewCoachPolicy.resolveMascotState(
          unresolvedContext,
          completionCtaReady: false,
        ),
        'warning',
      );
    });

    test('Bus coach treats HTTP 200 as successful human review guidance', () {
      final buses = [
        makeBus('bus_clean_1', number: 1),
        makeBus('bus_clean_2', number: 2),
      ];
      final decision = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
          workingNodes: buses.map((bus) => bus.toJson()).toList(),
          busFailureCode: '200',
        ),
      );

      expect(decision.coachTarget, 'bus_gate');
      expect(decision.coachMode, 'HUMAN_REVIEW');
      expect(decision.highlightTarget, 'bus_gate');
      expect(
        decision.coachMessage,
        '모선 번호 자동 판독을 마쳤어요.\n'
        '2개의 모선 번호를 모두 확인했습니다.\n\n'
        '제가 먼저 확인했으니,\n'
        '이번에는 도면의 모선 번호가 실제 번호와 맞는지\n'
        '직접 한 번 더 눈으로 확인해 주세요.\n\n'
        '모두 맞다면 저에게\n'
        '\'다 했어\' 또는 \'확인했어\'라고 말씀하시거나,\n'
        '아래에서 깜박이고 있는\n'
        '[모선 검수 완료] 버튼을 눌러주세요.',
      );
    });

    test('Bus coach reports HTTP and explicit failure states only', () {
      final buses = [makeBus('bus_clean', number: 1)];
      for (final failureCode in ['500', 'TIMEOUT', 'UNAVAILABLE']) {
        final decision = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
            workingNodes: buses.map((bus) => bus.toJson()).toList(),
            busFailureCode: failureCode,
          ),
        );

        expect(decision.coachTarget, 'bus_bbox', reason: failureCode);
        expect(decision.coachMode, 'GUIDE', reason: failureCode);
        expect(decision.coachMessage, contains('AI 자동 판독을 완료하지 못했어요.'));
      }
    });

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
  });
}
