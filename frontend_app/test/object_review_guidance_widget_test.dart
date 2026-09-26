import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_coach_policy.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_button.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_message.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_panel.dart';

void main() {
  final service = PowerLensAIService.instance;
  final initialGuidance = ObjectReviewGuidanceMessages.initialBus(24);
  final nextGuidance = ObjectReviewGuidanceMessages.load(17);

  setUp(() {
    service.clearHistory();
    service.httpClient = null;
  });

  test(
    'superseded guidance is archived and help uses the virtual tail bubble',
    () async {
      final originalBaseUrl = PowerLensAIService.baseUrl;
      var agentChatRequests = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/review/agent_chat')) {
          agentChatRequests++;
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

      final firstContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        objectWorkflowMessage: initialGuidance,
      );
      service.syncObjectReviewGuidance(initialGuidance);
      expect(service.messages, isEmpty);

      await service.sendMessage('여기서 어떻게 진행해?', firstContext);
      expect(service.messages, hasLength(1));
      expect(service.messages.single.isUser, isTrue);
      expect(service.messages.single.text, '여기서 어떻게 진행해?');
      expect(agentChatRequests, 0);

      service.syncObjectReviewGuidance(nextGuidance);
      expect(service.currentObjectWorkflowGuidance, nextGuidance);
      expect(service.messages, hasLength(2));
      expect(service.messages.any((message) => message.isUser), isTrue);
      expect(service.messages.last.text, initialGuidance);
      expect(service.messages.last.isUser, isFalse);

      service.syncObjectReviewGuidance(nextGuidance);
      expect(service.messages, hasLength(2));
      expect(
        service.messages.where((message) => message.text == initialGuidance),
        hasLength(1),
      );
    },
  );

  test(
    'canonical guidance archives once across Object and Bus stages while the new text stays current',
    () async {
      const objectBusGuidance = 'Bus를 확인해 주세요.';
      const loadGuidance = 'Bus 확인을 마쳤어요. Load를 확인해 주세요.';
      const busReadingGuidance = '모선 번호를 자동으로 읽고 있어요.';
      const busCompleteGuidance = '모선 번호 판독을 마쳤어요. 직접 확인해 주세요.';

      service.syncObjectReviewGuidance(objectBusGuidance);
      service.syncObjectReviewGuidance(objectBusGuidance);
      expect(service.messages, isEmpty);

      service.syncObjectReviewGuidance(loadGuidance);
      service.syncObjectReviewGuidance(loadGuidance);
      expect(service.messages.map((message) => message.text), [
        objectBusGuidance,
      ]);

      service.syncBusMappingGuidance(busReadingGuidance);
      expect(service.messages.map((message) => message.text), [
        objectBusGuidance,
        loadGuidance,
      ]);
      expect(service.currentObjectWorkflowGuidance, isNull);
      expect(service.currentBusMappingGuidance, busReadingGuidance);

      service.syncBusMappingGuidance(busCompleteGuidance);
      service.syncBusMappingGuidance(busCompleteGuidance);
      expect(service.messages.map((message) => message.text), [
        objectBusGuidance,
        loadGuidance,
        busReadingGuidance,
      ]);
      expect(service.currentBusMappingGuidance, busCompleteGuidance);

      service.shouldRequestProactive('archive-test', 'CONNECTION_REVIEW');
      await service.onStageChanged(
        'CONNECTION_REVIEW',
        const PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
          documentId: 'archive-test',
        ),
      );
      expect(service.messages.map((message) => message.text), [
        objectBusGuidance,
        loadGuidance,
        busReadingGuidance,
        busCompleteGuidance,
      ]);
      expect(service.currentBusMappingGuidance, isNull);
    },
  );

  test(
    're-entering Object Review clears stage transients but keeps history',
    () {
      const oldBusGuidance = '모선 번호 판독을 마쳤어요. 직접 확인해 주세요.';
      const objectGuidance = '현재 강조된 객체를 확인한 뒤 [맞음] 또는 [수정]을 눌러주세요.';

      service.syncBusMappingGuidance(oldBusGuidance);
      service.setStageHighlightTarget('bus_gate');
      service.setFocusTargets([
        {'type': 'BUS', 'id': 'bus_14'},
      ]);

      service.clearReviewStageTransients();
      service.syncObjectReviewGuidance(objectGuidance);

      expect(service.currentBusMappingGuidance, isNull);
      expect(service.currentObjectWorkflowGuidance, objectGuidance);
      expect(service.currentWorkflowGuidance, objectGuidance);
      expect(service.messages.map((message) => message.text), [oldBusGuidance]);
      expect(service.stageHighlightTarget, isNull);
      expect(service.activeHighlightTarget.value, isNull);
      expect(service.lastFocusTargets, isEmpty);
      expect(service.mascotState, 'idle');
    },
  );

  testWidgets(
    'archived guidance appears in history and latest canonical guidance remains only in the virtual tail',
    (tester) async {
      const previousGuidance = 'Bus 확인을 마쳤어요. Load를 확인해 주세요.';
      const currentGuidance = 'Load 확인을 마쳤어요. Generator를 확인해 주세요.';
      service.syncObjectReviewGuidance(previousGuidance);
      service.syncObjectReviewGuidance(currentGuidance);

      final context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        objectWorkflowMessage: currentGuidance,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(previousGuidance), findsOneWidget);
      expect(find.text(currentGuidance), findsOneWidget);
      expect(
        service.messages.where((message) => message.text == previousGuidance),
        hasLength(1),
      );
      expect(
        service.messages.where((message) => message.text == currentGuidance),
        isEmpty,
      );
      final bubbles = tester.widgetList<PowerLensAIMessageBubble>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(PowerLensAIMessageBubble),
        ),
      );
      expect(bubbles.last.message.text, currentGuidance);
    },
  );

  testWidgets(
    'closed and conversation-tail guidance match through every Object Review stage and help query',
    (tester) async {
      final originalBaseUrl = PowerLensAIService.baseUrl;
      var agentChatRequests = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/review/agent_chat')) {
          agentChatRequests++;
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
      final guidanceByStage = [
        initialGuidance,
        nextGuidance,
        ObjectReviewGuidanceMessages.generator(10),
        ObjectReviewGuidanceMessages.transformer(3),
        ObjectReviewGuidanceMessages.allReviewedBeforeCheck,
        ObjectReviewGuidanceMessages.allReviewedCompletePass,
      ];

      for (final guidance in guidanceByStage) {
        service.syncObjectReviewGuidance(guidance);
        final context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          objectWorkflowMessage: guidance,
        );

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
        final closedGuidance = tester
            .widget<Text>(
              find.byKey(const ValueKey('objectReviewLensyGuidanceBubble')),
            )
            .data;
        expect(closedGuidance, guidance);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('currentWorkflowGuidanceBubble')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<PowerLensAIMessageBubble>(
                find.byKey(const ValueKey('currentWorkflowGuidanceBubble')),
              )
              .message
              .text,
          guidance,
        );
        expect(
          find.byKey(const ValueKey('objectReviewCurrentGuidanceCard')),
          findsNothing,
        );
        expect(find.text('대화 기록'), findsOneWidget);

        await service.sendMessage('여기서 어떻게 진행해?', context);
        await tester.pumpAndSettle();
        expect(service.messages.last.isUser, isTrue);
        expect(
          tester
              .widget<PowerLensAIMessageBubble>(
                find.byKey(const ValueKey('currentWorkflowGuidanceBubble')),
              )
              .message
              .text,
          guidance,
        );
        expect(
          find.byKey(const ValueKey('currentWorkflowGuidanceBubble')),
          findsOneWidget,
        );
        expect(agentChatRequests, 0);
      }
      await tester.pump(const Duration(seconds: 11));
    },
  );

  testWidgets(
    'current guidance is the last assistant bubble after existing chat history',
    (tester) async {
      service.clearHistory();
      // Simulate historical messages from HOME / upload stages
      for (var i = 1; i <= 6; i++) {
        service.addMessageForTest(
          PowerLensAIMessageItem(
            id: 'legacy_msg_$i',
            sender: i.isEven ? 'user' : 'assistant',
            text: '과거 대화 내역 $i: 도면 사진을 업로드하거나 분석을 진행하세요.',
            stage: 'HOME',
          ),
        );
      }

      final canonical = ObjectReviewGuidanceMessages.initialBus(24);
      service.syncObjectReviewGuidance(canonical);

      final context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        objectWorkflowMessage: canonical,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(assistantContext: context, onClose: _noop),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('currentWorkflowGuidanceTail')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('objectReviewCurrentGuidanceCard')),
        findsNothing,
      );
      expect(service.messages, hasLength(6));
      expect(
        find.byKey(const ValueKey('objectReviewChatHistoryHeading')),
        findsOneWidget,
      );

      final listViewFinder = find.byType(ListView);
      expect(listViewFinder, findsOneWidget);
      expect(
        find.descendant(
          of: listViewFinder,
          matching: find.byKey(const ValueKey('currentWorkflowGuidanceTail')),
        ),
        findsOneWidget,
      );
      final visibleBubbles = tester.widgetList<PowerLensAIMessageBubble>(
        find.descendant(
          of: listViewFinder,
          matching: find.byType(PowerLensAIMessageBubble),
        ),
      );
      expect(visibleBubbles.last.message.text, canonical);
    },
  );
}

void _noop() {}
