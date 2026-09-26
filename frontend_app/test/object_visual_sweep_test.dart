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

    test('clean objects are reviewed once per detected category', () {
      final state = ObjectVisualSweepState();
      final nodes = [
        _node('bus_a', 10, 10),
        _node('bus_b', 20, 10),
        ReviewNodeItem(
          id: 'load_a',
          className: 'load',
          bbox: [30, 10, 10, 10],
          confidence: 0.95,
          source: 'test',
          reviewStatus: 'DETECTED',
        ),
      ];

      expect(state.reviewCategoryKeys(nodes), ['bus', 'load']);
      expect(state.stage(nodes), ObjectReviewFlowStage.categoryReview);
      expect(state.currentTarget(nodes)?.id, 'bus_a');
      expect(state.markCategoryReviewed('bus', nodes), isTrue);
      expect(state.markCategoryReviewed('bus', nodes), isFalse);
      expect(state.reviewedCategoryCount(nodes), 1);
      expect(state.currentTarget(nodes)?.id, 'load_a');
      expect(state.isComplete(nodes), isFalse);
      expect(state.markCategoryReviewed('load', nodes), isTrue);
      expect(state.isComplete(nodes), isTrue);
    });

    test('resolved exceptions transition into category review', () {
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

      suspicious.reviewStatus = 'CONFIRMED';
      state.markExceptionResolved(suspicious.id);
      expect(state.currentTarget(nodes)?.id, 'exception_next');
      expect(state.visitedCount(nodes), 1);
      nextSuspicious.reviewStatus = 'CONFIRMED';
      state.markExceptionResolved(nextSuspicious.id);
      expect(state.visitedCount(nodes), 2);
      expect(state.stage(nodes), ObjectReviewFlowStage.categoryReview);
      expect(state.markCategoryReviewed('bus', nodes), isTrue);
      expect(state.isComplete(nodes), isTrue);
    });

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

    test('all categories wait for explicit human confirmation', () {
      final state = ObjectVisualSweepState();
      final nodes = [_node('only', 10, 10)];

      expect(state.markCategoryReviewed('bus', nodes), isTrue);
      expect(state.isComplete(nodes), isTrue);
      expect(state.stage(nodes), ObjectReviewFlowStage.waitingHumanComplete);
      expect(state.humanCompleteConfirmed, isFalse);
      expect(state.confirmHumanComplete(nodes), isTrue);
      expect(state.stage(nodes), ObjectReviewFlowStage.readyToComplete);
    });

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
        state.markCategoryReviewed('bus', nodes);
        expect(state.confirmHumanComplete(nodes), isTrue);

        nodes.add(_node('new_bus', 15, 10));
        expect(state.isCategoryReviewed('bus', nodes), isFalse);
        expect(state.isComplete(nodes), isFalse);
        expect(state.markCategoryReviewed('bus', nodes), isTrue);

        nodes.add(
          ReviewNodeItem(
            id: 'new',
            className: 'load',
            bbox: [20, 10, 10, 10],
            confidence: 0.95,
            source: 'test',
            reviewStatus: 'DETECTED',
          ),
        );
        expect(state.isComplete(nodes), isFalse);
        expect(state.stage(nodes), ObjectReviewFlowStage.categoryReview);
        expect(state.markCategoryReviewed('load', nodes), isTrue);
        expect(state.humanCompleteConfirmed, isFalse);
      },
    );

    test('3-state category sweep flow: Bus -> Load -> Gen -> Back -> Trans -> 4/4 Complete', () {
      final state = ObjectVisualSweepState();
      final nodes = [
        _node('bus_1', 10, 10),
        ReviewNodeItem(id: 'load_1', className: 'load', bbox: [20, 10, 10, 10], confidence: 0.95, source: 'test', reviewStatus: 'DETECTED'),
        ReviewNodeItem(id: 'gen_1', className: 'generator', bbox: [30, 10, 10, 10], confidence: 0.95, source: 'test', reviewStatus: 'DETECTED'),
        ReviewNodeItem(id: 'trans_1', className: 'transformer', bbox: [40, 10, 10, 10], confidence: 0.95, source: 'test', reviewStatus: 'DETECTED'),
      ];

      // 1. Initial State: Bus is CURRENT, all others UNREVIEWED
      expect(state.currentCategoryKey, 'bus');
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.current);
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.unreviewed);
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.unreviewed);
      expect(state.getCategoryState('transformer', nodes), ObjectCategoryState.unreviewed);
      expect(state.isAllCategoriesReviewed(nodes), isFalse);
      expect(state.canGoPrevious(nodes), isFalse);

      // 2. Direct click on badge only views, NEVER marks reviewed
      state.selectCategory('load', nodes);
      expect(state.currentCategoryKey, 'load');
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.current);
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.unreviewed);
      expect(state.reviewedCategoryKeys, isEmpty);

      // Reset back to bus
      state.selectCategory('bus', nodes);
      expect(state.currentCategoryKey, 'bus');

      // 3. Right Arrow: Bus -> REVIEWED, advances to Load (CURRENT)
      final advancedToLoad = state.confirmCurrentAndGoNext(nodes);
      expect(advancedToLoad, isTrue);
      expect(state.currentCategoryKey, 'load');
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.current);
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.unreviewed);
      expect(state.getCategoryState('transformer', nodes), ObjectCategoryState.unreviewed);
      expect(state.canGoPrevious(nodes), isTrue);

      // 4. Right Arrow: Load -> REVIEWED, advances to Generator (CURRENT)
      final advancedToGen = state.confirmCurrentAndGoNext(nodes);
      expect(advancedToGen, isTrue);
      expect(state.currentCategoryKey, 'generator');
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.current);
      expect(state.getCategoryState('transformer', nodes), ObjectCategoryState.unreviewed);

      // 5. Left Arrow: returns to Load without deleting reviewed history
      final wentBack = state.goPreviousCategory(nodes);
      expect(wentBack, isTrue);
      expect(state.currentCategoryKey, 'load');
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.current);
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.reviewed);
      expect(state.isCategoryReviewed('load', nodes), isTrue); // History preserved!
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.unreviewed);

      // 6. Right Arrow from Load: advances back to Generator without double count
      final reAdvance = state.confirmCurrentAndGoNext(nodes);
      expect(reAdvance, isTrue);
      expect(state.currentCategoryKey, 'generator');
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.current);

      // 7. Right Arrow: Generator -> REVIEWED, advances to Transformer (CURRENT)
      final advancedToTrans = state.confirmCurrentAndGoNext(nodes);
      expect(advancedToTrans, isTrue);
      expect(state.currentCategoryKey, 'transformer');
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('transformer', nodes), ObjectCategoryState.current);
      expect(state.isAllCategoriesReviewed(nodes), isFalse);

      // 8. Final Right Arrow on Transformer: marks Transformer REVIEWED
      final lastAdvanced = state.confirmCurrentAndGoNext(nodes);
      expect(lastAdvanced, isFalse); // Last category reached
      expect(state.isAllCategoriesReviewed(nodes), isTrue); // 4/4 Complete!
      expect(state.getCategoryState('bus', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('load', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('generator', nodes), ObjectCategoryState.reviewed);
      expect(state.getCategoryState('transformer', nodes), ObjectCategoryState.reviewed);
      expect(state.isComplete(nodes), isTrue);
    });
  });
}
