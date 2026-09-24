import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/object_visual_sweep.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/review_coach_policy.dart';

ReviewNodeItem _node(
  String id,
  double x,
  double y, {
  String status = 'DETECTED',
}) => ReviewNodeItem(
  id: id,
  className: 'bus',
  bbox: [x, y, 10, 10],
  confidence: 0.95,
  source: 'test',
  reviewStatus: status,
);

void main() {
  group('Object visual sweep', () {
    test(
      'orders active targets by drawing position and ignores rejected nodes',
      () {
        final state = ObjectVisualSweepState();
        final nodes = [
          _node('lower', 10, 30),
          _node('right', 30, 10),
          _node('left', 10, 10),
          _node('removed', 5, 5, status: 'REJECTED'),
        ];

        expect(state.orderedTargets(nodes).map((node) => node.id), [
          'left',
          'right',
          'lower',
        ]);
        expect(state.currentTarget(nodes)?.id, 'left');
      },
    );

    test(
      'only the current pulse target advances and visited IDs remain recorded',
      () {
        final state = ObjectVisualSweepState();
        final nodes = [
          _node('a', 10, 10),
          _node('b', 20, 10),
          _node('c', 30, 10),
        ];

        expect(state.visitCurrentTarget('b', nodes), isFalse);
        expect(state.visitedObjectIds, isEmpty);
        expect(state.visitCurrentTarget('a', nodes), isTrue);
        expect(state.currentTarget(nodes)?.id, 'b');
        expect(state.visitCurrentTarget('a', nodes), isFalse);
        expect(state.visitCurrentTarget('b', nodes), isTrue);
        expect(state.currentTarget(nodes)?.id, 'c');
        expect(state.visitedObjectIds, {'a', 'b'});
      },
    );

    test(
      'resolved exceptions count as visited and are not requested twice',
      () {
        final state = ObjectVisualSweepState();
        final suspicious = _node('exception', 10, 10, status: 'SUSPICIOUS');
        final nextSuspicious = _node(
          'exception_next',
          15,
          10,
          status: 'SUSPICIOUS',
        );
        final normal = _node('normal', 20, 10);
        final nodes = [normal, nextSuspicious, suspicious];

        expect(state.stage(nodes), ObjectReviewFlowStage.exceptionReview);
        expect(state.currentTarget(nodes)?.id, 'exception');
        expect(state.visitCurrentTarget('exception', nodes), isFalse);

        suspicious.reviewStatus = 'CONFIRMED';
        state.markExceptionResolved(suspicious.id);
        expect(state.currentTarget(nodes)?.id, 'exception_next');
        expect(state.visitedCount(nodes), 1);
        nextSuspicious.reviewStatus = 'CONFIRMED';
        state.markExceptionResolved(nextSuspicious.id);
        expect(state.currentTarget(nodes)?.id, 'normal');
        expect(state.visitedCount(nodes), 2);
        expect(state.visitCurrentTarget('normal', nodes), isTrue);
        expect(state.isComplete(nodes), isTrue);
      },
    );

    test('missing candidates pause the visual sweep until resolved', () {
      final state = ObjectVisualSweepState();
      final nodes = [_node('a', 10, 10)];

      expect(
        state.currentTarget(nodes, hasOpenMissingCandidates: true),
        isNull,
      );
      expect(state.isComplete(nodes, hasOpenMissingCandidates: true), isFalse);
      expect(state.currentTarget(nodes)?.id, 'a');
    });

    test(
      'last target waits for explicit human confirmation before ready state',
      () {
        final state = ObjectVisualSweepState();
        final nodes = [_node('only', 10, 10)];

        expect(state.visitCurrentTarget('only', nodes), isTrue);
        expect(state.isComplete(nodes), isTrue);
        expect(state.stage(nodes), ObjectReviewFlowStage.waitingHumanComplete);
        expect(state.humanCompleteConfirmed, isFalse);
        expect(state.confirmHumanComplete(nodes), isTrue);
        expect(state.stage(nodes), ObjectReviewFlowStage.readyToComplete);
      },
    );

    test(
      'object gate is highlighted only after explicit human confirmation',
      () {
        final nodes = [_node('a', 10, 10), _node('b', 20, 10)];
        final waitingContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          hasDiagram: true,
          totalObjects: nodes.length,
          workingNodes: nodes.map((node) => node.toJson()).toList(),
          objectReviewStage: 'WAITING_HUMAN_COMPLETE',
          objectVisualSweepVisited: nodes.length,
          objectVisualSweepTotal: nodes.length,
        );

        final waitingDecision = ReviewCoachPolicy.resolve(waitingContext);
        expect(waitingDecision.highlightTarget, isNull);
        expect(waitingDecision.coachTarget, 'object_human_confirmation');
        expect(waitingDecision.coachMessage, contains('확인했어'));

        final readyDecision = ReviewCoachPolicy.resolve(
          waitingContext.copyWith(
            objectHumanCompletenessConfirmed: true,
            objectReviewStage: 'READY_TO_COMPLETE',
          ),
        );
        expect(readyDecision.highlightTarget, 'object_gate');
        expect(readyDecision.coachTarget, 'object_gate');
      },
    );

    test(
      'a newly detected active target invalidates a prior confirmation after review',
      () {
        final state = ObjectVisualSweepState();
        final nodes = [_node('a', 10, 10)];
        state.visitCurrentTarget('a', nodes);
        expect(state.confirmHumanComplete(nodes), isTrue);

        nodes.add(_node('new', 20, 10));
        expect(state.isComplete(nodes), isFalse);
        expect(state.visitCurrentTarget('new', nodes), isTrue);
        expect(state.humanCompleteConfirmed, isFalse);
      },
    );
  });
}
