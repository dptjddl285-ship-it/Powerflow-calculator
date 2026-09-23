import 'package:flutter_test/flutter_test.dart';

import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

ReviewLineItem makeConnectionLine({
  String id = 'line_1',
  String status = 'DETECTED',
  List<Map<String, dynamic>> issues = const [],
  Map<String, dynamic> evidence = const {},
  String? resolution,
  List<String> candidates = const [],
}) {
  return ReviewLineItem(
    lineId: id,
    connectedTo: const ['bus_1', 'load_1'],
    path: const [
      [10, 10],
      [20, 20],
      [30, 30],
    ],
    reviewStatus: status,
    validationIssues: issues,
    evidence: evidence,
    connectionReviewResolution: resolution,
    candidateTargets: candidates,
  );
}

void main() {
  group('Connection Review V2 production evaluator', () {
    test('AA-AE: production filters preserve empty results and clear stale selection', () {
      final normalA = makeConnectionLine(id: 'normal_a');
      final normalB = makeConnectionLine(id: 'normal_b');
      final normalC = makeConnectionLine(id: 'normal_c');
      final ambiguous = makeConnectionLine(
        id: 'exception_1',
        status: 'AMBIGUOUS',
      );
      final lines = [normalA, normalB, normalC, ambiguous];

      expect(
        ConnectionReviewGateEvaluator.filter(
          lines,
          status: ConnectionReviewGateEvaluator.filterAll,
        ),
        hasLength(4),
      );
      expect(
        ConnectionReviewGateEvaluator.filter(
          [normalA, normalB, normalC],
          status: ConnectionReviewGateEvaluator.filterNeedsReview,
        ),
        isEmpty,
      );
      expect(
        ConnectionReviewGateEvaluator.filter(
          [normalA, normalB, normalC],
          status: ConnectionReviewGateEvaluator.filterCrossing,
        ),
        isEmpty,
      );
      expect(
        ConnectionReviewGateEvaluator.filter(
          lines,
          status: ConnectionReviewGateEvaluator.filterNeedsReview,
        ),
        [ambiguous],
      );
      expect(
        ConnectionReviewGateEvaluator.selectedLineForFilter(
          workingLines: lines,
          status: ConnectionReviewGateEvaluator.filterNeedsReview,
          selectedLine: normalA,
        ),
        isNull,
      );
      expect(
        ConnectionReviewGateEvaluator.selectedLineForFilter(
          workingLines: lines,
          status: ConnectionReviewGateEvaluator.filterNeedsReview,
          selectedLine: ambiguous,
        ),
        same(ambiguous),
      );
    });

    test('COUNT: duplicate line/topology critical evidence counts once', () {
      const Map<String, dynamic> shared = {
        'id': 'shared_error',
        'code': 'EXPLICIT_LINE_ERROR',
        'severity': 'error',
        'message': '동일한 결선 오류',
      };
      final line = makeConnectionLine(
        id: 'line_shared',
        issues: [shared],
      );

      expect(
        ConnectionReviewGateEvaluator.criticalErrorCount(
          workingLines: [line],
          topologyIssues: [shared],
        ),
        1,
      );
    });

    test('A/F/O: clean DETECTED line is usable without approval', () {
      final lines = [makeConnectionLine()];
      expect(
        ConnectionReviewGateEvaluator.getBlockers(workingLines: lines),
        isEmpty,
      );
      expect(
        ConnectionReviewGateEvaluator.canVerifyGate(workingLines: lines),
        isTrue,
      );
      expect(
        ConnectionReviewGateEvaluator.lineStatusLabel(lines.single),
        'AI 확인 · 정상 연결',
      );
    });

    test('B/N: AMBIGUOUS is the real LINE exception and blocks', () {
      final line = makeConnectionLine(id: 'line_amb', status: 'AMBIGUOUS');
      expect(
        ConnectionReviewGateEvaluator.getBlockers(workingLines: [line]),
        isNotEmpty,
      );
      expect(
        ConnectionReviewGateEvaluator.computeGuideLineIds(
          workingLines: [line],
        ),
        contains('line_amb'),
      );
      expect(
        ConnectionReviewGateEvaluator.lineStatusLabel(line),
        '확인 필요',
      );
    });

    test('C/X: severity error blocks; warning/info do not', () {
      final errorLine = makeConnectionLine(
        id: 'line_error',
        issues: const [
          {'id': 'issue_error', 'severity': 'error', 'message': '끝점 오류'},
        ],
      );
      expect(
        ConnectionReviewGateEvaluator.canVerifyGate(
          workingLines: [errorLine],
        ),
        isFalse,
      );
      expect(
        ConnectionReviewGateEvaluator.lineStatusLabel(errorLine),
        '전기 오류',
      );

      final cleanLine = makeConnectionLine(id: 'line_warning');
      expect(
        ConnectionReviewGateEvaluator.canVerifyGate(
          workingLines: [cleanLine],
          topologyIssues: const [
            {'id': 'warn', 'severity': 'warning'},
            {'id': 'info', 'severity': 'info'},
          ],
        ),
        isTrue,
      );
    });

    test('E: zero active lines is a deterministic blocker', () {
      final rejected = makeConnectionLine(id: 'line_rejected', status: 'REJECTED');
      final blockers = ConnectionReviewGateEvaluator.getBlockers(
        workingLines: [rejected],
      );
      expect(blockers, [ConnectionReviewGateEvaluator.noActiveLineMessage]);
      expect(
        ConnectionReviewGateEvaluator.computeGuideLineIds(
          workingLines: [rejected],
        ),
        isEmpty,
      );
    });

    test('G/H/I/P: guides preserve actual IDs and discard fabricated focus', () {
      final line = makeConnectionLine(id: 'line_real', status: 'AMBIGUOUS');
      final guides = ConnectionReviewGateEvaluator.computeGuideLineIds(
        workingLines: [line],
        focusTargets: const [
          {'type': 'LINE', 'id': 'line_fake'},
          {'type': 'LINE', 'id': 'line_real'},
        ],
      );
      expect(guides, {'line_real'});

      final topologyGuides =
          ConnectionReviewGateEvaluator.computeGuideLineIds(
        workingLines: [line],
        topologyIssues: const [
          {
            'id': 'issue_real',
            'severity': 'error',
            'component_ids': ['bus_1', 'load_1'],
          },
        ],
      );
      expect(topologyGuides, contains('line_real'));
    });

    test('Y/Z: crossing actions are available only with explicit evidence', () {
      final noEvidence = makeConnectionLine(id: 'line_plain');
      expect(
        ConnectionReviewGateEvaluator.hasCrossingEvidence(noEvidence),
        isFalse,
      );

      final crossing = makeConnectionLine(
        id: 'line_cross',
        evidence: const {
          'crossing_candidate': true,
          'path': [
            [10, 10],
            [20, 20],
          ],
        },
      );
      expect(
        ConnectionReviewGateEvaluator.hasCrossingEvidence(crossing),
        isTrue,
      );
      expect(
        ConnectionReviewGateEvaluator.getBlockers(workingLines: [crossing]),
        isNotEmpty,
      );
      final resolved = makeConnectionLine(
        id: 'line_cross',
        evidence: const {'crossing_candidate': true},
        resolution: 'CONNECTED',
      );
      expect(
        ConnectionReviewGateEvaluator.canVerifyGate(workingLines: [resolved]),
        isTrue,
      );
    });

    test('U: explicit candidate selection changes the endpoint and confirms the line', () {
      final line = makeConnectionLine(
        id: 'line_candidate',
        status: 'AMBIGUOUS',
        candidates: const ['bus_2'],
      );
      final updated = ConnectionReviewGateEvaluator.reassignTarget(line, 'bus_2');
      expect(updated.connectedTo, ['bus_1', 'bus_2']);
      expect(updated.reviewStatus, 'CONFIRMED');
      expect(updated.source, 'human_reconnected');
    });

    test('J/K/S/T: legacy sequential intents are not emitted', () {
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
        workingLines: [
          {'line_id': 'line_1', 'review_status': 'AMBIGUOUS'},
        ],
      );
      final service = PowerLensAIService.instance;
      expect(service.resolveIntentActions('다음 선 보여줘', context), isEmpty);
      expect(service.resolveIntentActions('선로만 집중해줘', context), isEmpty);
      expect(service.resolveIntentActions('이거 괜찮아', context), isEmpty);
      expect(
        service.resolveIntentActions('검토 완료하고 다음 단계로 가자', context),
        [PowerLensAppAction.goToNextStage],
      );
    });

    test('L/M/Q/R: clean and exception speech use the single final CTA', () {
      final service = PowerLensAIService.instance;
      const cleanContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
        workingLines: [
          {'line_id': 'line_clean', 'review_status': 'DETECTED'},
        ],
      );
      expect(
        service.generateOfflineFallbackReply('다음에 뭐 해?', cleanContext),
        contains('결선 검수 완료'),
      );
      expect(
        service.generateOfflineFallbackReply('다음에 뭐 해?', cleanContext),
        isNot(contains('선로 승인하고 다음')),
      );

      const issueContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
        workingLines: [
          {'line_id': 'line_issue', 'review_status': 'AMBIGUOUS'},
        ],
      );
      expect(
        service.generateOfflineFallbackReply('검토 필요', issueContext),
        contains('예외'),
      );
    });
  });
}
