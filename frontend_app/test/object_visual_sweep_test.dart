import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/object_visual_sweep.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_coach_policy.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/widgets/object_category_review_bar.dart';

ReviewNodeItem _node(
  String id,
  String className, {
  String status = 'DETECTED',
}) => ReviewNodeItem(
  id: id,
  className: className,
  bbox: const [10.0, 10.0, 8.0, 8.0],
  confidence: 0.95,
  source: 'test',
  reviewStatus: status,
);

final _cleanNodes = [
  _node('bus_1', 'bus'),
  _node('load_1', 'load'),
  _node('gen_1', 'generator'),
  _node('trans_1', 'transformer'),
];

Map<ObjectCategory, int> _counts() => {
  for (final category in ObjectCategory.values) category: 1,
};

void main() {
  group('Object category review state', () {
    test('an unresolved suspicious object blocks category review', () {
      final state = ObjectVisualSweepState();
      final nodes = [
        ..._cleanNodes,
        _node('exception', 'load', status: 'SUSPICIOUS'),
      ];

      expect(state.currentException(nodes)?.id, 'exception');
      expect(state.stage(nodes), ObjectReviewFlowStage.exceptionReview);
      expect(state.selectCategory(ObjectCategory.bus, nodes), isFalse);
      expect(state.reviewedCategories, isEmpty);

      nodes.last.reviewStatus = 'CONFIRMED';
      state.markExceptionResolved();
      expect(state.selectCategory(ObjectCategory.bus, nodes), isTrue);
      expect(state.stage(nodes), ObjectReviewFlowStage.categorySweep);
    });

    test('open missing candidates also block category review', () {
      final state = ObjectVisualSweepState();
      expect(
        state.selectCategory(
          ObjectCategory.bus,
          _cleanNodes,
          hasOpenMissingCandidates: true,
        ),
        isFalse,
      );
      expect(
        state.isComplete(_cleanNodes, hasOpenMissingCandidates: true),
        isFalse,
      );
    });

    test(
      'right navigation reviews Bus, Load, Generator, Transformer in order',
      () {
        final state = ObjectVisualSweepState();
        expect(state.reviewedCategories, isEmpty);

        for (final category in ObjectCategory.values) {
          expect(state.selectAdjacentCategory(1, _cleanNodes), isTrue);
          expect(state.activeCategory, category);
          expect(state.reviewedCategories, contains(category));
          expect(state.reviewedCategoryCount, state.reviewedCategories.length);
          expect(
            state.isComplete(_cleanNodes),
            state.reviewedCategories.length == ObjectCategory.values.length,
          );
        }

        expect(state.reviewedCategories, ObjectCategory.values.toSet());
        expect(state.stage(_cleanNodes), ObjectReviewFlowStage.categorySweep);
        expect(state.beginFinalCheck(_cleanNodes), isTrue);
        expect(state.stage(_cleanNodes), ObjectReviewFlowStage.finalAgentCheck);
        expect(state.confirmFinalCheck(_cleanNodes), isTrue);
        expect(state.stage(_cleanNodes), ObjectReviewFlowStage.readyToComplete);
      },
    );

    test(
      'left navigation changes active category and preserves reviewed state',
      () {
        final state = ObjectVisualSweepState();
        state.selectAdjacentCategory(1, _cleanNodes);
        state.selectAdjacentCategory(1, _cleanNodes);
        state.selectAdjacentCategory(-1, _cleanNodes);

        expect(state.activeCategory, ObjectCategory.bus);
        expect(state.reviewedCategories, {
          ObjectCategory.bus,
          ObjectCategory.load,
        });
      },
    );

    test('direct category selection uses the same state transition', () {
      final state = ObjectVisualSweepState();
      expect(
        state.selectCategory(ObjectCategory.generator, _cleanNodes),
        isTrue,
      );
      expect(state.activeCategory, ObjectCategory.generator);
      expect(state.reviewedCategories, {ObjectCategory.generator});
    });

    test(
      'a category change invalidates only that category and final check',
      () {
        final state = ObjectVisualSweepState();
        state.reviewedCategories.addAll(ObjectCategory.values);
        state.activeCategory = ObjectCategory.transformer;
        expect(state.beginFinalCheck(_cleanNodes), isTrue);
        expect(state.confirmFinalCheck(_cleanNodes), isTrue);

        state.invalidateCategory(ObjectCategory.load);
        expect(state.reviewedCategories, isNot(contains(ObjectCategory.load)));
        expect(state.reviewedCategories.length, 3);
        expect(state.finalCheckPassed, isFalse);
        expect(state.stage(_cleanNodes), ObjectReviewFlowStage.categorySweep);
      },
    );

    test(
      'failed final validation returns from processing without auto-loop state',
      () {
        final state = ObjectVisualSweepState();
        state.reviewedCategories.addAll(ObjectCategory.values);
        expect(state.beginFinalCheck(_cleanNodes), isTrue);
        state.failFinalCheck();

        expect(state.finalCheckInFlight, isFalse);
        expect(state.finalCheckPassed, isFalse);
        expect(state.stage(_cleanNodes), ObjectReviewFlowStage.categorySweep);
      },
    );
  });

  group('Object category review bar', () {
    testWidgets('starts with five unreviewed indicators and runtime counts', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ObjectCategoryReviewBar(
              totalCount: 12,
              categoryCounts: {
                ObjectCategory.bus: 5,
                ObjectCategory.load: 4,
                ObjectCategory.generator: 2,
                ObjectCategory.transformer: 1,
              },
              reviewedCategories: const {},
              activeCategory: null,
              interactionEnabled: true,
              onPrevious: null,
              onNext: () {},
              onSelectCategory: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('전체 12'), findsOneWidget);
      expect(find.text('Bus 5'), findsOneWidget);
      expect(find.text('Load 4'), findsOneWidget);
      expect(find.text('Generator 2'), findsOneWidget);
      expect(find.text('Transformer 1'), findsOneWidget);
      expect(find.text('미확인'), findsNWidgets(5));
      expect(find.text('확인'), findsNothing);
    });

    testWidgets('hover does not review a category; click does', (tester) async {
      final state = ObjectVisualSweepState();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, rebuild) => ObjectCategoryReviewBar(
                totalCount: 4,
                categoryCounts: _counts(),
                reviewedCategories: state.reviewedCategories,
                activeCategory: state.activeCategory,
                interactionEnabled: true,
                onPrevious: null,
                onNext: null,
                onSelectCategory: (category) => rebuild(() {
                  state.selectCategory(category, _cleanNodes);
                }),
              ),
            ),
          ),
        ),
      );

      final busChip = find.byKey(const ValueKey('object-category-chip-bus'));
      await tester.sendEventToBinding(
        PointerHoverEvent(position: tester.getCenter(busChip)),
      );
      await tester.pump();
      expect(state.reviewedCategories, isEmpty);
      expect(state.activeCategory, isNull);

      await tester.tap(busChip);
      await tester.pump();
      expect(state.reviewedCategories, {ObjectCategory.bus});
      expect(state.activeCategory, ObjectCategory.bus);
      expect(find.text('확인'), findsOneWidget);
      expect(find.text('미확인'), findsNWidgets(4));
    });
  });

  group('Object category coach policy', () {
    test('suspicious exceptions take precedence over the category guide', () {
      final exception = _node('sus_1', 'bus', status: 'SUSPICIOUS');
      final decision = ReviewCoachPolicy.resolve(
        PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          suspiciousObjects: 1,
          workingNodes: [exception.toJson()],
        ),
      );

      expect(decision.coachTarget, 'object_bbox');
      expect(decision.focusNodeId, 'sus_1');
      expect(decision.coachMessage, contains('1개'));
      expect(decision.highlightTarget, isNull);
    });

    test(
      'suspicious exception takes priority when missing candidates also exist',
      () {
        final exception = _node('sus_1', 'bus', status: 'SUSPICIOUS');
        final decision = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'OBJECT_REVIEW',
            suspiciousObjects: 1,
            unresolvedMissingCandidates: 2,
            workingNodes: [exception.toJson()],
          ),
        );

        expect(decision.coachTarget, 'object_bbox');
        expect(decision.focusNodeId, 'sus_1');
      },
    );

    test(
      'clean state guides category review and shows the final-check states',
      () {
        const initial = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          hasDiagram: true,
          totalObjects: 4,
        );
        final initialDecision = ReviewCoachPolicy.resolve(initial);
        expect(initialDecision.highlightTarget, 'object_category_bar');
        expect(initialDecision.coachMessage, contains('Bus부터 시작해서 Load'));

        final checking = ReviewCoachPolicy.resolve(
          initial.copyWith(objectReviewStage: 'FINAL_AGENT_CHECK'),
        );
        expect(checking.coachMode, 'PROCESSING');
        expect(checking.coachMessage, contains('마지막 객체 상태'));
        expect(checking.highlightTarget, isNull);

        final ready = ReviewCoachPolicy.resolve(
          initial.copyWith(
            objectReviewStage: 'READY_TO_COMPLETE',
            objectHumanCompletenessConfirmed: true,
          ),
        );
        expect(ready.coachTarget, 'object_gate');
        expect(ready.highlightTarget, 'object_gate');
        expect(ready.coachMessage, contains('[객체 검수 완료]'));
      },
    );
  });
}
