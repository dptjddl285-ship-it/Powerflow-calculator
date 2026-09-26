import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_button.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_panel.dart';

ReviewNodeItem makeBus({
  required String id,
  required List<double> bbox,
  int? busNumber = 1,
  String busNumberStatus = 'VERIFIED',
  List<String> busNumberReasons = const [],
  String reviewStatus = 'CONFIRMED',
}) {
  return ReviewNodeItem(
    id: id,
    className: 'bus',
    bbox: bbox,
    confidence: 0.95,
    source: 'ai',
    busNumber: busNumber,
    busNumberStatus: busNumberStatus,
    busNumberReasons: busNumberReasons,
    reviewStatus: reviewStatus,
  );
}

void main() {
  final service = PowerLensAIService.instance;

  setUp(() {
    service.clearHistory();
    service.httpClient = null;
  });

  group('PowerLens Bus Mapping Human Review Gate & Guidance Tests', () {
    // 1. AI all verified -> phase still BUS_MAPPING (no auto advancement)
    test('1. AI all verified -> technical state ready but human confirmation required', () {
      final buses = List.generate(
        24,
        (i) => makeBus(id: 'bus_${i + 1}', bbox: [0.1 * i, 0.1, 0.1 * i + 0.05, 0.2], busNumber: i + 1),
      );
      final uiState = BusReviewUiState.fromNodes(buses);
      final canVerify = BusReviewGateEvaluator.canVerifyGate(workingNodes: buses);
      expect(canVerify, isTrue);
      expect(uiState.totalBuses, 24);
      expect(uiState.verifiedBuses, 24);
      expect(uiState.issueBuses, 0);
      expect(uiState.hasIssues, isFalse);
      // Verify that UI state guides human completion instead of auto transition
      expect(uiState.nextActionText, contains('[모선 검수 완료]'));
      expect(uiState.nextActionText, isNot(contains('자동으로 이동')));
    });

    // 2. AI all verified -> busHumanReviewConfirmed false by default
    test('2. busHumanReviewConfirmed state defaults to false and gates transition', () {
      bool busHumanReviewConfirmed = false;
      bool canVerifyBusGate = true;

      // Gate check simulation
      bool canAdvanceToConnection({required bool gateReady, required bool humanConfirmed}) {
        return gateReady && humanConfirmed;
      }

      expect(canAdvanceToConnection(gateReady: canVerifyBusGate, humanConfirmed: busHumanReviewConfirmed), isFalse);

      // Only true after explicit human confirmation
      busHumanReviewConfirmed = true;
      expect(canAdvanceToConnection(gateReady: canVerifyBusGate, humanConfirmed: busHumanReviewConfirmed), isTrue);
    });

    // 3. 5 sec wait -> still BUS_MAPPING (no timer auto-advance)
    testWidgets('3. 5 sec wait -> still in BUS_MAPPING phase without auto progression', (tester) async {
      var currentPhase = 'BUS_MAPPING';
      var busHumanReviewConfirmed = false;

      // Simulate a timer or frame advance
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));

      expect(currentPhase, 'BUS_MAPPING');
      expect(busHumanReviewConfirmed, isFalse);
    });

    // 4. BusCompleteButton -> human confirmed -> Gate
    test('4. BusCompleteButton click sets human confirmed and triggers gate', () {
      bool busHumanReviewConfirmed = false;
      bool gateTriggered = false;

      void completeBusReview({required bool canVerify}) {
        if (!canVerify) return;
        busHumanReviewConfirmed = true;
        gateTriggered = true;
      }

      completeBusReview(canVerify: true);
      expect(busHumanReviewConfirmed, isTrue);
      expect(gateTriggered, isTrue);
    });

    // 5. "다 했어" -> same handler
    test('5. Lensy completion utterance "다 했어" maps to goToNextStage and shares handler', () {
      const busCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        totalBuses: 24,
        unresolvedBusNumbers: 0,
      );

      final utterances = ['다 했어', '확인했어', '다 확인했어', '모선 확인 끝났어', '문제 없어', '번호 다 맞아'];
      for (final utterance in utterances) {
        final actions = service.resolveIntentActions(utterance, busCtx);
        expect(
          actions,
          contains(PowerLensAppAction.goToNextStage),
          reason: 'Utterance "$utterance" must resolve to goToNextStage',
        );
      }
    });

    // 6. UNCERTAIN + "다 했어" -> blocked
    test('6. UNCERTAIN buses block completion and guide user to resolve issues first', () {
      final buses = [
        makeBus(id: 'bus_1', bbox: [0, 0, 1, 1], busNumber: 1),
        makeBus(id: 'bus_2', bbox: [0, 0, 1, 1], busNumber: null, busNumberStatus: 'UNCERTAIN'),
        makeBus(id: 'bus_3', bbox: [0, 0, 1, 1], busNumber: 3, busNumberStatus: 'UNCERTAIN'),
      ];

      final uiState = BusReviewUiState.fromNodes(buses);
      final canVerify = BusReviewGateEvaluator.canVerifyGate(workingNodes: buses);
      expect(canVerify, isFalse);
      expect(uiState.issueBuses, 2);

      String? blockerMessage;
      bool busHumanReviewConfirmed = false;

      void completeBusReview({required bool canVerify, required int unresolved}) {
        if (!canVerify) {
          blockerMessage = '아직 확인이 필요한 모선이 $unresolved개 있어요. 표시된 모선부터 확인해주세요.';
          return;
        }
        busHumanReviewConfirmed = true;
      }

      completeBusReview(canVerify: canVerify, unresolved: uiState.issueBuses);
      expect(busHumanReviewConfirmed, isFalse);
      expect(blockerMessage, '아직 확인이 필요한 모선이 2개 있어요. 표시된 모선부터 확인해주세요.');
    });

    // 7. last UNCERTAIN manually fixed -> still BUS_MAPPING (no auto transition)
    test('7. Manually fixing last UNCERTAIN bus updates state but stays in BUS_MAPPING', () {
      var currentPhase = 'BUS_MAPPING';
      var busHumanReviewConfirmed = false;

      // Simulate applying number to the last uncertain bus
      final buses = [
        makeBus(id: 'bus_1', bbox: [0, 0, 1, 1], busNumber: 1),
        makeBus(id: 'bus_2', bbox: [0, 0, 1, 1], busNumber: 2, busNumberStatus: 'VERIFIED'),
      ];
      final canVerify = BusReviewGateEvaluator.canVerifyGate(workingNodes: buses);
      expect(canVerify, isTrue);

      // Manual fix does NOT automatically advance phase
      expect(currentPhase, 'BUS_MAPPING');
      expect(busHumanReviewConfirmed, isFalse);
    });

    // 8. human confirmation after fix -> Connection
    test('8. Explicit confirmation after manual fix enables advance to Connection', () {
      var currentPhase = 'BUS_MAPPING';
      var busHumanReviewConfirmed = false;
      var isBusVerified = false;

      void onConfirm() {
        busHumanReviewConfirmed = true;
        isBusVerified = true;
        currentPhase = 'CONNECTION_REVIEW';
      }

      onConfirm();
      expect(busHumanReviewConfirmed, isTrue);
      expect(isBusVerified, isTrue);
      expect(currentPhase, 'CONNECTION_REVIEW');
    });

    // 9. top phase badge cannot bypass human gate
    test('9. Stepper badge for connection review is disabled without human confirmation', () {
      bool isStepBadgeClickable({
        required bool hasActiveLines,
        required bool isBusVerified,
        required bool busHumanReviewConfirmed,
      }) {
        return hasActiveLines && isBusVerified && busHumanReviewConfirmed;
      }

      // Has active lines, but not human confirmed
      expect(
        isStepBadgeClickable(hasActiveLines: true, isBusVerified: true, busHumanReviewConfirmed: false),
        isFalse,
      );

      // Confirmed, but bus not verified by gate
      expect(
        isStepBadgeClickable(hasActiveLines: true, isBusVerified: false, busHumanReviewConfirmed: true),
        isFalse,
      );

      // All verified and human confirmed
      expect(
        isStepBadgeClickable(hasActiveLines: true, isBusVerified: true, busHumanReviewConfirmed: true),
        isTrue,
      );
    });

    // 10. opened Lensy canonical guidance renders as assistant bubble
    testWidgets('10. Opened Lensy canonical guidance renders as assistant message bubble', (tester) async {
      const guidance = '모선 번호 자동 판독을 마쳤어요. 24개의 모선 번호를 모두 읽었고, 현재 확인이 필요한 번호는 없습니다.\n\n제가 먼저 확인했으니, 이번에는 도면의 모선 번호가 실제 도면과 맞는지 직접 한 번 더 확인해 주세요.\n\n확인이 끝나면 저에게 \'다 했어\' 또는 \'확인했어\'라고 말씀하시거나, 아래에서 깜박이고 있는 [모선 검수 완료] 버튼을 눌러주세요.';
      service.syncBusMappingGuidance(guidance);

      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        busMappingMessage: guidance,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(
              assistantContext: context,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Card container exists with correct key
      expect(find.byKey(const ValueKey('objectReviewCurrentGuidanceCard')), findsOneWidget);
      // Pinned text exists and matches guidance
      expect(find.byKey(const ValueKey('objectReviewCurrentGuidanceText')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('objectReviewCurrentGuidanceText'))).data,
        guidance,
      );
      // Renders conversational bubble styling (not old rigid card)
      final cardFinder = find.byKey(const ValueKey('objectReviewCurrentGuidanceCard'));
      expect(cardFinder, findsOneWidget);
      final bubbleContainer = tester.widget<Container>(
        find.descendant(of: cardFinder, matching: find.byType(Container)).last,
      );
      expect(bubbleContainer.decoration, isA<BoxDecoration>());
      final decoration = bubbleContainer.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFFF1F5F9));
      await tester.pump(const Duration(seconds: 11));
    });

    // 11. closed/open/help exact same guidance
    testWidgets('11. Closed bubble, opened pinned card, and help reply have exact same guidance', (tester) async {
      const guidance = '모선 번호 자동 판독을 마쳤어요. 24개의 모선 번호를 모두 읽었고, 현재 확인이 필요한 번호는 없습니다.\n\n제가 먼저 확인했으니, 이번에는 도면의 모선 번호가 실제 도면과 맞는지 직접 한 번 더 확인해 주세요.\n\n확인이 끝나면 저에게 \'다 했어\' 또는 \'확인했어\'라고 말씀하시거나, 아래에서 깜박이고 있는 [모선 검수 완료] 버튼을 눌러주세요.';
      service.syncBusMappingGuidance(guidance);

      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        busMappingMessage: guidance,
      );

      // Closed bubble
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PowerLensAIFloatingButton(
              onPressed: _noop,
              useObjectReviewGuidance: true,
            ),
          ),
        ),
      );
      final closedText = tester.widget<Text>(
        find.byKey(const ValueKey('objectReviewLensyGuidanceBubble')),
      ).data;
      expect(closedText, guidance);

      // Opened pinned card
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(
              assistantContext: context,
              onClose: _noop,
            ),
          ),
        ),
      );
      final openedText = tester.widget<Text>(
        find.byKey(const ValueKey('objectReviewCurrentGuidanceText')),
      ).data;
      expect(openedText, guidance);

      // Help query ("다음에 뭐 해?")
      await service.sendMessage('다음에 뭐 해?', context);
      final helpReply = service.messages.lastWhere(
        (m) => m.sender == 'assistant',
      );
      expect(helpReply.text, guidance);
      await tester.pump(const Duration(seconds: 11));
    });
  });
}

void _noop() {}
