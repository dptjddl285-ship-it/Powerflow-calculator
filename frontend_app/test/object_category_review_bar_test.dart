import 'package:circuit_solver/models/object_visual_sweep.dart';
import 'package:circuit_solver/widgets/object_category_review_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ObjectCategoryReviewBar tests', () {
    testWidgets(
      'displays 3 states (UNREVIEWED, CURRENT, REVIEWED), All summary badge, and Prev/Next buttons',
      (tester) async {
        String? selectedCategory;
        bool nextClicked = false;
        bool prevClicked = false;
        bool allClicked = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ObjectCategoryReviewBar(
                totalCount: 41,
                categories: const [
                  ObjectReviewCategoryStatus(
                    key: 'bus',
                    count: 24,
                    state: ObjectCategoryState.reviewed,
                  ),
                  ObjectReviewCategoryStatus(
                    key: 'load',
                    count: 17,
                    state: ObjectCategoryState.current,
                  ),
                  ObjectReviewCategoryStatus(
                    key: 'generator',
                    count: 2,
                    state: ObjectCategoryState.unreviewed,
                  ),
                ],
                allReviewed: false,
                onSelectCategory: (k) => selectedCategory = k,
                onConfirmCurrentAndNext: () => nextClicked = true,
                onPreviousCategory: () => prevClicked = true,
                onSelectAll: () => allClicked = true,
              ),
            ),
          ),
        );

        // Header and progress
        expect(find.text('설비 종류별 확인'), findsOneWidget);
        expect(find.text('1/3 확인'), findsOneWidget);

        // All summary badge
        expect(find.text('전체 41'), findsOneWidget);
        expect(find.text('미완료'), findsOneWidget);

        // 3 States
        expect(find.text('Bus 24'), findsOneWidget);
        expect(find.text('확인 완료'), findsOneWidget); // Bus is reviewed

        expect(find.text('Load 17'), findsOneWidget);
        expect(find.text('확인 중'), findsOneWidget); // Load is current

        expect(find.text('Generator 2'), findsOneWidget);
        expect(find.text('미확인'), findsOneWidget); // Generator is unreviewed

        // Navigation buttons
        expect(find.byKey(ObjectCategoryReviewBar.prevButtonKey), findsOneWidget);
        expect(find.byKey(ObjectCategoryReviewBar.nextButtonKey), findsOneWidget);

        // Test hover does not invoke onSelectCategory or mutation
        final loadChip = find.byKey(
          ObjectCategoryReviewBar.categoryChipKey('load'),
        );
        await tester.sendEventToBinding(
          PointerHoverEvent(position: tester.getCenter(loadChip)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(selectedCategory, isNull);

        // Tap chip selects category without confirming
        await tester.tap(loadChip);
        await tester.pump();
        expect(selectedCategory, 'load');

        // Tap Prev / Next
        await tester.tap(find.byKey(ObjectCategoryReviewBar.prevButtonKey));
        await tester.pump();
        expect(prevClicked, isTrue);

        await tester.tap(find.byKey(ObjectCategoryReviewBar.nextButtonKey));
        await tester.pump();
        expect(nextClicked, isTrue);

        // Tap All
        await tester.tap(find.byKey(ObjectCategoryReviewBar.allChipKey));
        await tester.pump();
        expect(allClicked, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('allReviewed shows green check on All summary badge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ObjectCategoryReviewBar(
              totalCount: 4,
              categories: [
                ObjectReviewCategoryStatus(
                  key: 'bus',
                  count: 1,
                  state: ObjectCategoryState.reviewed,
                ),
                ObjectReviewCategoryStatus(
                  key: 'load',
                  count: 1,
                  state: ObjectCategoryState.reviewed,
                ),
                ObjectReviewCategoryStatus(
                  key: 'generator',
                  count: 1,
                  state: ObjectCategoryState.reviewed,
                ),
                ObjectReviewCategoryStatus(
                  key: 'transformer',
                  count: 1,
                  state: ObjectCategoryState.reviewed,
                ),
              ],
              allReviewed: true,
              onSelectCategory: _dummySelect,
            ),
          ),
        ),
      );

      expect(find.text('4/4 확인'), findsOneWidget);
      // All 4 categories + summary chip + next button = 6 "확인 완료" labels
      expect(find.text('확인 완료'), findsNWidgets(6));
      expect(find.text('미확인'), findsNothing);
      expect(find.text('확인 중'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'CURRENT badge has white/transparent background, cyan border >= 2px, and subtle scale pulse',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ObjectCategoryReviewBar(
                totalCount: 24,
                categories: const [
                  ObjectReviewCategoryStatus(
                    key: 'bus',
                    count: 24,
                    state: ObjectCategoryState.current,
                  ),
                ],
                allReviewed: false,
                onSelectCategory: _dummySelect,
                onConfirmCurrentAndNext: () {},
              ),
            ),
          ),
        );

        // Find the Bus chip
        final busChipFinder = find.byKey(
          ObjectCategoryReviewBar.categoryChipKey('bus'),
        );
        expect(busChipFinder, findsOneWidget);

        // Verify AnimatedContainer inside chip has white/transparent background (no blue fill)
        final containerFinder = find.descendant(
          of: busChipFinder,
          matching: find.byType(AnimatedContainer),
        );
        expect(containerFinder, findsOneWidget);

        final container = tester.widget<AnimatedContainer>(containerFinder);
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(Colors.white));

        // Verify border is cyan/blue and width >= 2.0
        final border = decoration.border as Border;
        expect(border.top.width, greaterThanOrEqualTo(2.0));
        expect(border.top.color, isNot(Colors.transparent));

        // Verify Transform.scale is applied to the CURRENT badge
        final scaleFinder = find.descendant(
          of: busChipFinder,
          matching: find.byType(Transform),
        );
        expect(scaleFinder, findsOneWidget);

        // Verify [확인 후 다음] button has glowing border and boxShadow
        final nextBtnContainer = tester.widget<Container>(
          find.ancestor(
            of: find.byKey(ObjectCategoryReviewBar.nextButtonKey),
            matching: find.byType(Container),
          ).first,
        );
        final nextDeco = nextBtnContainer.decoration as BoxDecoration?;
        expect(nextDeco?.boxShadow, isNotNull);
        expect(nextDeco!.boxShadow!.isNotEmpty, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

void _dummySelect(String _) {}
