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
    'workflow guidance stays canonical outside history and help uses the tail bubble',
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
      expect(service.messages, hasLength(1));
      expect(service.messages.any((message) => message.isUser), isTrue);
      expect(
        service.messages.any((message) => message.text == initialGuidance),
        isFalse,
      );
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
