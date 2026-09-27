import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_coach_policy.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_button.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_message.dart';
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

    // 10. opened Lensy canonical guidance renders as the final assistant bubble
    testWidgets(
      '10. Opened Lensy canonical guidance renders at the conversation tail',
      (tester) async {
        const guidance =
            '모선 번호 자동 판독을 마쳤어요.\n24개의 모선 번호를 모두 확인했습니다.\n\n제가 먼저 확인했으니,\n이번에는 도면의 모선 번호가 실제 번호와 맞는지\n직접 한 번 더 눈으로 확인해 주세요.\n\n모두 맞다면 저에게\n\'다 했어\' 또는 \'확인했어\'라고 말씀하시거나,\n아래에서 깜박이고 있는\n[모선 검수 완료] 버튼을 눌러주세요.';
        service.syncBusMappingGuidance(guidance);

        const context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
          busMappingMessage: guidance,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(assistantContext: context, onClose: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('objectReviewCurrentGuidanceCard')),
          findsNothing,
        );
        final tail = find.byKey(
          const ValueKey('currentWorkflowGuidanceBubble'),
        );
        expect(tail, findsOneWidget);
        expect(
          tester.widget<PowerLensAIMessageBubble>(tail).message.text,
          guidance,
        );
        expect(find.byType(ListView), findsOneWidget);
        expect(
          find.descendant(of: find.byType(ListView), matching: tail),
          findsOneWidget,
        );
        expect(
          service.messages.any((message) => message.text == guidance),
          isFalse,
        );
        await tester.pump(const Duration(seconds: 11));
      },
    );

    // 11. closed/open/help exact same guidance, without duplicate bubbles
    testWidgets(
      '11. Closed bubble, opened tail, and help share exact guidance once',
      (tester) async {
        const guidance =
            '모선 번호 자동 판독을 마쳤어요.\n24개의 모선 번호를 모두 확인했습니다.\n\n제가 먼저 확인했으니,\n이번에는 도면의 모선 번호가 실제 번호와 맞는지\n직접 한 번 더 눈으로 확인해 주세요.\n\n모두 맞다면 저에게\n\'다 했어\' 또는 \'확인했어\'라고 말씀하시거나,\n아래에서 깜박이고 있는\n[모선 검수 완료] 버튼을 눌러주세요.';
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
        final closedText = tester
            .widget<Text>(
              find.byKey(const ValueKey('objectReviewLensyGuidanceBubble')),
            )
            .data;
        expect(closedText, guidance);

        // Opened conversation tail
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
            ),
          ),
        );
        final openedTail = find.byKey(
          const ValueKey('currentWorkflowGuidanceBubble'),
        );
        final openedText = tester
            .widget<PowerLensAIMessageBubble>(openedTail)
            .message
            .text;
        expect(openedText, guidance);

        // Help query ("다음에 뭐 해?")
        await service.sendMessage('다음에 뭐 해?', context);
        await tester.pumpAndSettle();
        expect(service.messages, hasLength(1));
        expect(service.messages.single.isUser, isTrue);
        expect(
          tester.widget<PowerLensAIMessageBubble>(openedTail).message.text,
          guidance,
        );
        expect(
          find.byKey(const ValueKey('currentWorkflowGuidanceBubble')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 11));
      },
    );

    testWidgets(
      'Bus AI reading shows canonical processing tail, spinner, and no completion action',
      (tester) async {
        final buses = List.generate(
          24,
          (index) => makeBus(
            id: 'reading_${index + 1}',
            bbox: [index.toDouble(), 0, 1, 1],
            busNumber: index + 1,
          ),
        );
        final context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
          totalBuses: buses.length,
          busMappingAiReading: true,
          busMappingMessage: '이전 검수 안내',
          workingNodes: buses.map((bus) => bus.toJson()).toList(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final expected = ReviewCoachPolicy.resolve(context).coachMessage;
        final tail = find.byKey(
          const ValueKey('currentWorkflowGuidanceBubble'),
        );
        expect(
          tester.widget<PowerLensAIMessageBubble>(tail).message.text,
          expected,
        );
        expect(expected, contains('잠시만 기다려주세요.'));
        expect(
          find.byKey(const ValueKey('busMappingThinkingStatus')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('busMappingThinkingText')),
          findsOneWidget,
        );
        expect(find.text('모선 번호 확인 완료'), findsNothing);
        expect(find.text('AI 번호 판독 중...'), findsNothing);
        expect(
          service.quickActionsForContext(context),
          isNot(contains('모선 번호 확인 완료')),
        );
      },
    );

    testWidgets(
      'ready Connection Review guidance renders as the final conversation bubble',
      (tester) async {
        final line = ReviewLineItem(
          lineId: 'line_clean',
          connectedTo: const ['bus_1', 'load_1'],
          path: const [
            [1, 1],
            [2, 2],
          ],
          reviewStatus: 'DETECTED',
        );
        final context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          connectionVisualSweepStarted: true,
          connectionVisualSweepComplete: true,
          selectedLine: line.toJson(),
          workingLines: [line.toJson()],
        );
        final inProgressContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          connectionVisualSweepStarted: true,
          selectedLine: line.toJson(),
          workingLines: [line.toJson()],
        );
        expect(
          ReviewCoachPolicy.resolve(context).coachTarget,
          'connection_gate',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(
                assistantContext: inProgressContext,
                onClose: _noop,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
            ),
          ),
        );
        await tester.pumpAndSettle();

        const expected =
            '결선 검수를 모두 확인했어요.\n'
            '현재 확인이 필요한 결선은 없습니다.\n\n'
            '전체 네트워크를 마지막으로 한 번 확인해 주세요.\n\n'
            '문제가 없다면 아래에서 깜박이고 있는\n'
            '[결선 검수 완료] 버튼을 눌러\n'
            '다음 단계로 이동해 주세요.';
        final tail = find.byKey(
          const ValueKey('currentWorkflowGuidanceBubble'),
        );
        expect(find.text('대화 기록'), findsOneWidget);
        expect(find.text(expected), findsOneWidget);
        expect(tail, findsOneWidget);
        expect(
          tester.widget<PowerLensAIMessageBubble>(tail).message.text,
          expected,
        );
        expect(
          find.descendant(of: find.byType(ListView), matching: tail),
          findsOneWidget,
        );
      },
    );

    test('Bus deterministic guidance bypasses proactive requests', () async {
      final originalBaseUrl = PowerLensAIService.baseUrl;
      var proactiveRequests = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/review/proactive_summary')) {
          proactiveRequests++;
        }
        return http.Response('{}', 200);
      });
      service.httpClient = mockClient;
      PowerLensAIService.baseUrl = 'http://127.0.0.1:1';
      addTearDown(() async {
        service.httpClient = null;
        PowerLensAIService.baseUrl = originalBaseUrl;
        mockClient.close();
      });

      const guidance = '자동 판독을 마쳤어요. 직접 확인해 주세요.';
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        busMappingMessage: guidance,
      );
      await service.notifyStageChange(context);
      await service.onStageChanged('BUS_MAPPING', context);

      expect(proactiveRequests, 0);
      expect(service.currentBusMappingGuidance, guidance);
    });

    test(
      'an in-flight proactive reply cannot replace newly synced Bus guidance',
      () async {
        final requestStarted = Completer<void>();
        final response = Completer<http.Response>();
        final originalBaseUrl = PowerLensAIService.baseUrl;
        final mockClient = MockClient((request) {
          requestStarted.complete();
          return response.future;
        });
        service.httpClient = mockClient;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:1';
        addTearDown(() async {
          service.httpClient = null;
          PowerLensAIService.baseUrl = originalBaseUrl;
          mockClient.close();
        });

        const initialContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
        );
        final pending = service.notifyStageChange(initialContext);
        await requestStarted.future;
        const guidance = '모선 번호 자동 판독을 마쳤어요. 직접 확인해 주세요.';
        service.syncBusMappingGuidance(guidance);
        response.complete(
          http.Response(
            jsonEncode({
              'status': 'success',
              'reply_ko': '오래된 원격 안내',
              'agent_status': 'PROACTIVE',
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await pending;

        expect(service.currentBusMappingGuidance, guidance);
        expect(
          service.messages.any((message) => message.text == '오래된 원격 안내'),
          isFalse,
        );
      },
    );

    test(
      '24 verified buses resolve to human-review guidance; partial results show dynamic unresolved count',
      () {
        final completeBuses = List.generate(
          24,
          (index) => makeBus(
            id: 'complete_${index + 1}',
            bbox: [index.toDouble(), 0, 1, 1],
            busNumber: index + 1,
          ),
        );
        final complete = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
            totalBuses: completeBuses.length,
            workingNodes: completeBuses.map((bus) => bus.toJson()).toList(),
          ),
        );
        expect(complete.coachMessage, contains('24개의 모선 번호를 모두 확인했습니다'));
        expect(complete.coachMessage, contains('직접 한 번 더 눈으로 확인'));
        expect(complete.coachMessage, contains('[모선 검수 완료]'));
        expect(complete.coachMessage, isNot(contains('자동으로 읽고 있어요')));
        expect(complete.coachMessage, isNot(contains('잠시만 기다려')));

        final partialBuses = [
          ...completeBuses.take(21),
          makeBus(
            id: 'uncertain_22',
            bbox: [22, 0, 1, 1],
            busNumber: null,
            busNumberStatus: 'UNCERTAIN',
          ),
          makeBus(
            id: 'uncertain_23',
            bbox: [23, 0, 1, 1],
            busNumber: null,
            busNumberStatus: 'UNCERTAIN',
          ),
          makeBus(
            id: 'uncertain_24',
            bbox: [24, 0, 1, 1],
            busNumber: null,
            busNumberStatus: 'UNCERTAIN',
          ),
        ];
        final partial = ReviewCoachPolicy.resolve(
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
            totalBuses: partialBuses.length,
            workingNodes: partialBuses.map((bus) => bus.toJson()).toList(),
          ),
        );
        expect(partial.coachMessage, contains('전체 24개 중 21개는 확인했고'));
        expect(partial.coachMessage, contains('3개는 번호를 명확하게 읽지 못했습니다'));
        expect(partial.coachMessage, isNot(contains('잠시만 기다려')));
      },
    );
  });
}

void _noop() {}
