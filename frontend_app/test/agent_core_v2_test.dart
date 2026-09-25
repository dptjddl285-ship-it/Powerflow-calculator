import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final service = PowerLensAIService.instance;

  group('Agent Core V2 Action Mapping Tests', () {
    test('Action ID Mapping correctly maps canonical backend action IDs', () {
      expect(
        service.mapBackendActionId('RUN_POWER_FLOW'),
        PowerLensAppAction.runPowerFlow,
      );
      expect(
        service.mapBackendActionId('SHOW_POWER_FLOW_RESULTS'),
        PowerLensAppAction.showPowerFlowResults,
      );
      expect(service.mapBackendActionId('GO_HOME'), PowerLensAppAction.goHome);
      expect(
        service.mapBackendActionId('COMPLETE_CURRENT_STAGE'),
        PowerLensAppAction.goToNextStage,
      );
      expect(
        service.mapBackendActionId('OPEN_EXCEL_PICKER'),
        PowerLensAppAction.triggerExcelUpload,
      );
      expect(
        service.mapBackendActionId('OPEN_DIAGRAM_PICKER'),
        PowerLensAppAction.triggerPhotoUpload,
      );
      expect(
        service.mapBackendActionId('LOAD_SAMPLE_DIAGRAM'),
        PowerLensAppAction.loadSampleDiagram,
      );
      expect(
        service.mapBackendActionId('SHOW_REVIEW_ISSUES'),
        PowerLensAppAction.showReviewIssues,
      );
      expect(
        service.mapBackendActionId('HANDOFF_TO_CANVAS'),
        PowerLensAppAction.handoffToCanvas,
      );
      expect(
        service.mapBackendActionId('SHOW_FLOW_DIRECTION'),
        PowerLensAppAction.showFlowDirection,
      );
      expect(
        service.mapBackendActionId('HIDE_FLOW_DIRECTION'),
        PowerLensAppAction.hideFlowDirection,
      );
      expect(
        service.mapBackendActionId('SHOW_VALUE_LABELS'),
        PowerLensAppAction.showValueLabels,
      );
      expect(
        service.mapBackendActionId('HIDE_VALUE_LABELS'),
        PowerLensAppAction.hideValueLabels,
      );
    });

    test('Maps NO_ACTION, null, empty and unknown strings to null', () {
      expect(service.mapBackendActionId('NO_ACTION'), isNull);
      expect(service.mapBackendActionId(null), isNull);
      expect(service.mapBackendActionId(''), isNull);
      expect(service.mapBackendActionId('UNKNOWN_CUSTOM_ACTION'), isNull);
      expect(service.mapBackendActionId('DROP_TABLE'), isNull);
    });

    test(
      'Phase 4 voice phrases resolve to and dispatch the button action',
      () async {
        const home = PowerLensAssistantContext(
          currentScreen: 'HOME',
          workflowStage: 'HOME',
        );
        const objectReview = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
        );
        const busReview = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
        );
        const connectionReview = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'CONNECTION_REVIEW',
        );
        const verifiedFinal = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
        );
        const powerFlow = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'POWERFLOW_READY',
        );
        const results = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'POWERFLOW_CONVERGED',
        );

        final cases = <(String, PowerLensAppAction, PowerLensAssistantContext)>[
          ('도면 불러올래', PowerLensAppAction.triggerPhotoUpload, home),
          ('객체 검수 끝났어', PowerLensAppAction.goToNextStage, objectReview),
          ('다 봤어', PowerLensAppAction.goToNextStage, objectReview),
          ('다음', PowerLensAppAction.goToNextStage, objectReview),
          ('모선 다 봤어', PowerLensAppAction.goToNextStage, busReview),
          ('다음', PowerLensAppAction.goToNextStage, busReview),
          ('엑셀 넣을게', PowerLensAppAction.triggerExcelUpload, verifiedFinal),
          ('제원 가져와', PowerLensAppAction.triggerExcelUpload, verifiedFinal),
          ('CAD로 넘어가', PowerLensAppAction.handoffToCanvas, verifiedFinal),
          ('계산해줘', PowerLensAppAction.runPowerFlow, powerFlow),
          ('조류계산 해줘', PowerLensAppAction.runPowerFlow, powerFlow),
          ('결과 보여줘', PowerLensAppAction.showPowerFlowResults, results),
        ];
        final dispatched = <PowerLensAppAction>[];
        Future<bool> handler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async {
          dispatched.add(action);
          return true;
        }

        service.registerActionHandler(handler);
        try {
          for (final (utterance, expected, context) in cases) {
            final actions = service.resolveIntentActions(utterance, context);
            expect(actions, [expected], reason: utterance);
            expect(
              await service.dispatchAction(actions.single, context: context),
              isTrue,
              reason: utterance,
            );
            expect(dispatched.last, expected, reason: utterance);
          }
          for (final phrase in ['다 봤어', '결선 다 봤어', '결선 끝났어', '다음']) {
            expect(
              service.resolveIntentActions(phrase, connectionReview),
              isEmpty,
              reason: '$phrase must guide to the connection Gate, not run it',
            );
          }
          const explicitGateCommand = '결선 검수 완료 실행해줘';
          final gateActions = service.resolveIntentActions(
            explicitGateCommand,
            connectionReview,
          );
          expect(gateActions, [PowerLensAppAction.goToNextStage]);
          expect(
            await service.dispatchAction(
              gateActions.single,
              context: connectionReview,
            ),
            isTrue,
          );
          expect(dispatched.last, PowerLensAppAction.goToNextStage);
        } finally {
          service.unregisterActionHandler(handler);
        }
      },
    );

    test('generic review completion speech does not become a CAD action', () {
      const cadContext = PowerLensAssistantContext(
        currentScreen: 'CAD_CANVAS',
        workflowStage: 'POWERFLOW_READY',
      );
      expect(service.resolveIntentActions('다음', cadContext), isEmpty);
      expect(service.resolveIntentActions('다 봤어', cadContext), isEmpty);
    });
  });

  group('Agent Core V2 Action Execution Policy Tests', () {
    PowerLensAppAction? lastDispatchedAction;
    Map<String, dynamic>? lastDispatchedParams;

    Future<bool> mockHandler(
      PowerLensAppAction action,
      Map<String, dynamic>? params,
    ) async {
      lastDispatchedAction = action;
      lastDispatchedParams = params;
      return true;
    }

    setUp(() {
      lastDispatchedAction = null;
      lastDispatchedParams = null;
      service.clearHighlight();
      service.registerActionHandler(mockHandler);
    });

    tearDown(() {
      service.unregisterActionHandler(mockHandler);
      service.clearHighlight();
    });

    test('EXECUTE mode dispatches action to registered handler', () async {
      final success = await service.executeBackendAction(
        actionMode: 'EXECUTE',
        actionId: 'RUN_POWER_FLOW',
        actionParams: {'method': 'newton_raphson'},
        highlightTarget: 'final_powerflow',
      );

      expect(success, isTrue);
      expect(lastDispatchedAction, PowerLensAppAction.runPowerFlow);
      expect(lastDispatchedParams, {'method': 'newton_raphson'});
      expect(service.activeHighlightTarget.value, 'final_powerflow');
    });

    test(
      'GUIDE mode illuminates highlight target but NEVER dispatches action',
      () async {
        final success = await service.executeBackendAction(
          actionMode: 'GUIDE',
          actionId: 'RUN_POWER_FLOW',
          highlightTarget: 'final_powerflow',
        );

        expect(success, isFalse);
        expect(lastDispatchedAction, isNull);
        expect(service.activeHighlightTarget.value, 'final_powerflow');
      },
    );

    test('CONFIRM_REQUIRED mode NEVER dispatches action', () async {
      final success = await service.executeBackendAction(
        actionMode: 'CONFIRM_REQUIRED',
        actionId: 'RUN_POWER_FLOW',
      );

      expect(success, isFalse);
      expect(lastDispatchedAction, isNull);
    });

    test('NONE mode NEVER dispatches action', () async {
      final success = await service.executeBackendAction(
        actionMode: 'NONE',
        actionId: 'GO_HOME',
      );

      expect(success, isFalse);
      expect(lastDispatchedAction, isNull);
    });

    test(
      'a ReviewPage Gate rejection never falls through to the hidden canvas',
      () async {
        var canvasCalls = 0;
        Future<bool> canvasHandler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async {
          canvasCalls++;
          return true;
        }

        Future<bool> reviewGateHandler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async => false;

        const reviewContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
        );
        service.registerActionHandler(canvasHandler);
        service.registerActionHandler(reviewGateHandler);
        try {
          final success = await service.executeBackendAction(
            actionMode: 'EXECUTE',
            actionId: 'OPEN_EXCEL_PICKER',
            context: reviewContext,
          );
          expect(success, isFalse);
          expect(canvasCalls, 0);
        } finally {
          service.unregisterActionHandler(reviewGateHandler);
          service.unregisterActionHandler(canvasHandler);
        }
      },
    );

    test(
      'offline circuit edits require confirmation and dispatch no action',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';
        server.listen((HttpRequest request) async {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'error', 'message': 'offline test'}));
          await request.response.close();
        });

        final dispatched = <PowerLensAppAction>[];
        Future<bool> handler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async {
          dispatched.add(action);
          return true;
        }

        service.registerActionHandler(handler);
        try {
          const context = PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'BUS_MAPPING',
          );
          await service.sendMessage('모선 번호를 7로 바꿔', context);
          expect(dispatched, isEmpty);
          expect(service.messages.last.agentStatus, 'LOCAL_CONFIRM_REQUIRED');
          expect(service.messages.last.text, contains('안전'));
          expect(
            service.requiresCircuitMutationConfirmation('모선 번호를 7로 바꿔'),
            isTrue,
          );
        } finally {
          service.unregisterActionHandler(handler);
          PowerLensAIService.baseUrl = originalBaseUrl;
          await server.close(force: true);
        }
      },
    );

    test(
      'a generic acknowledgement is not a shortcut past category review',
      () {
        const context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          hasDiagram: true,
          totalObjects: 54,
          objectReviewStage: 'CATEGORY_SWEEP',
          objectVisualSweepVisited: 0,
          objectVisualSweepTotal: 4,
        );

        expect(service.resolveIntentActions('확인했어', context), isEmpty);
        expect(
          service.determineTargetForContext(context),
          'object_category_bar',
        );
      },
    );
  });

  group('Agent Core V2 Proactive Deduplication Tests', () {
    setUp(() {
      service.clearProactiveKeys();
    });

    test('Deduplicates proactive requests per (document_id, stage)', () {
      expect(
        service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'),
        isTrue,
      );
      expect(
        service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'),
        isFalse,
      );
      expect(service.shouldRequestProactive('doc_123', 'BUS_MAPPING'), isTrue);
      expect(
        service.shouldRequestProactive('doc_456', 'OBJECT_REVIEW'),
        isTrue,
      );

      service.clearProactiveKeys();
      expect(
        service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'),
        isTrue,
      );
    });
  });

  group('Agent Core V2 Highlight Deduplication Tests', () {
    test(
      'Avoids duplicate triggerHighlight when target is already active',
      () async {
        int triggerCount = 0;
        void listener() {
          if (service.activeHighlightTarget.value == 'object_gate') {
            triggerCount++;
          }
        }

        service.activeHighlightTarget.addListener(listener);
        service.triggerHighlight('object_gate');
        expect(service.activeHighlightTarget.value, 'object_gate');
        expect(triggerCount, 1);

        // executeBackendAction with the same highlight target must NOT re-trigger
        await service.executeBackendAction(
          actionMode: 'NONE',
          actionId: null,
          highlightTarget: 'object_gate',
        );
        expect(triggerCount, 1);

        service.activeHighlightTarget.removeListener(listener);
        service.clearHighlight();
      },
    );
  });

  group('Agent Core V2 Error Handling and Fallback Tests', () {
    test('Routes HTTP 200 + status:error to offline fallback', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originalBaseUrl = PowerLensAIService.baseUrl;
      PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((HttpRequest request) async {
        if (request.uri.path == '/review/agent_chat') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'status': 'error',
                'message': 'Simulated internal agent exception',
              }),
            );
          await request.response.close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });

      try {
        const testContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'OBJECT_REVIEW',
          documentId: 'doc_err_test',
        );

        final initialCount = service.messages.length;
        await service.sendMessage('객체 상태 어때?', testContext);

        expect(service.messages.length, greaterThan(initialCount));
        final lastMsg = service.messages.last;
        // The service must route to offline fallback instead of treating it as success
        expect(lastMsg.agentStatus, 'LOCAL_READY');
        expect(lastMsg.sender, 'assistant');
        expect(service.mascotState, 'blocked');
      } finally {
        await server.close(force: true);
        PowerLensAIService.baseUrl = originalBaseUrl;
      }
    });
  });

  group('Agent Core V2 Final Wiring Tests (TEST A - TEST F)', () {
    test(
      'TEST A: /review/proactive_summary success triggers 1 call and 1 message; second notify triggers 0 calls',
      () async {
        int proactiveCallCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest request) async {
          if (request.uri.path == '/review/proactive_summary') {
            proactiveCallCount++;
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'status': 'success',
                  'reply_ko': '의심 객체 2개를 확인해주세요.',
                  'highlight_target': null,
                  'focus_targets': [
                    {
                      'type': 'OBJECT',
                      'id': 'node_1',
                      'reason': 'suspicious',
                      'severity': 'warning',
                    },
                  ],
                  'agent_status': 'GEMINI_PROACTIVE',
                  'provider_mode': 'gemini',
                }),
              );
            await request.response.close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          }
        });

        try {
          service.clearHistory();
          service.clearProactiveKeys();
          service.clearFocusTargets();

          const contextA = PowerLensAssistantContext(
            documentId: 'doc_1',
            workflowStage: 'OBJECT_REVIEW',
            suspiciousObjects: 2,
          );

          // First notify: 1 HTTP call, 1 message added, focus_targets preserved
          await service.notifyStageChange(contextA);
          expect(proactiveCallCount, 1);
          expect(service.messages.length, 1);
          expect(service.messages.first.text, contains('의심 객체 2개를 확인해주세요.'));
          expect(service.lastFocusTargets.length, 1);
          expect(service.lastFocusTargets.first['id'], 'node_1');

          // Second notify in same stage: 0 additional calls, no duplicate message
          await service.notifyStageChange(contextA);
          expect(proactiveCallCount, 1);
          expect(service.messages.length, 1);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'TEST B: Different stage BUS_MAPPING makes +1 proactive HTTP call',
      () async {
        int proactiveCallCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest request) async {
          if (request.uri.path == '/review/proactive_summary') {
            proactiveCallCount++;
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'status': 'success',
                  'reply_ko': '모선 번호를 확인해주세요.',
                  'highlight_target': null,
                  'focus_targets': [],
                  'agent_status': 'GEMINI_PROACTIVE',
                  'provider_mode': 'gemini',
                }),
              );
            await request.response.close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          }
        });

        try {
          service.clearHistory();
          service.clearProactiveKeys();

          const context1 = PowerLensAssistantContext(
            documentId: 'doc_1',
            workflowStage: 'OBJECT_REVIEW',
          );
          await service.notifyStageChange(context1);
          expect(proactiveCallCount, 1);

          const context2 = PowerLensAssistantContext(
            documentId: 'doc_1',
            workflowStage: 'BUS_MAPPING',
          );
          await service.notifyStageChange(context2);
          expect(proactiveCallCount, 2);
          expect(service.messages.length, 2);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'TEST C: Backend proactive failure uses deterministic local proactive fallback without UI lock or duplicates',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest request) async {
          if (request.uri.path == '/review/proactive_summary') {
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..write('Server Error');
            await request.response.close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          }
        });

        try {
          service.clearHistory();
          service.clearProactiveKeys();

          const contextFail = PowerLensAssistantContext(
            documentId: 'doc_fail',
            workflowStage: 'OBJECT_REVIEW',
            suspiciousObjects: 1,
          );

          await service.notifyStageChange(contextFail);
          expect(service.messages.length, 1);
          expect(service.messages.first.agentStatus, 'LOCAL_READY');
          expect(service.isLoading, isFalse);

          // Dedup prevents duplicate fallback message for same doc and stage
          await service.notifyStageChange(contextFail);
          expect(service.messages.length, 1);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'TEST D: normal /agent_chat with action_mode: NONE and highlight_target: null leaves activeHighlightTarget unchanged',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest request) async {
          if (request.uri.path == '/review/agent_chat') {
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'status': 'success',
                  'result': {
                    'reply_ko': '설명을 안내해 드립니다.',
                    'action_mode': 'NONE',
                    'highlight_target': null,
                    'agent_status': 'GEMINI',
                  },
                }),
              );
            await request.response.close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          }
        });

        try {
          service.clearHistory();
          service.clearHighlight();

          const context = PowerLensAssistantContext(
            documentId: 'doc_1',
            workflowStage: 'HOME',
          );

          expect(service.activeHighlightTarget.value, isNull);
          await service.sendMessage('계통이 뭐야?', context);
          expect(service.activeHighlightTarget.value, isNull);
          expect(service.messages.last.text.contains('반짝'), isFalse);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test('TEST E: GUIDE + final_powerflow triggers highlight', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originalBaseUrl = PowerLensAIService.baseUrl;
      PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((HttpRequest request) async {
        if (request.uri.path == '/review/agent_chat') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'status': 'success',
                'result': {
                  'reply_ko': '조류계산을 실행할 수 있는 버튼을 확인하세요.',
                  'action_mode': 'GUIDE',
                  'highlight_target': 'final_powerflow',
                  'agent_status': 'GEMINI',
                },
              }),
            );
          await request.response.close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });

      try {
        service.clearHistory();
        service.clearHighlight();

        const context = PowerLensAssistantContext(
          documentId: 'doc_1',
          workflowStage: 'FINAL',
          excelLoaded: true,
        );

        await service.sendMessage('조류계산 어디서 눌러?', context);
        expect(service.activeHighlightTarget.value, 'final_powerflow');
        expect(service.messages.last.text.contains('반짝반짝 빛나고 있어요'), isTrue);
      } finally {
        await server.close(force: true);
        PowerLensAIService.baseUrl = originalBaseUrl;
      }
    });

    test(
      'TEST F: NONE + backend highlight null does NOT automatically turn on the category guide',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest request) async {
          if (request.uri.path == '/review/agent_chat') {
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'status': 'success',
                  'result': {
                    'reply_ko': '모든 객체가 승인된 상태입니다.',
                    'action_mode': 'NONE',
                    'highlight_target': null,
                    'agent_status': 'GEMINI',
                  },
                }),
              );
            await request.response.close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          }
        });

        try {
          service.clearHistory();
          service.clearHighlight();

          // Under this context, the deterministic target is the category guide.
          const context = PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'OBJECT_REVIEW',
            documentId: 'doc_1',
            suspiciousObjects: 0,
            unresolvedMissingCandidates: 0,
            workingNodes: [
              {'id': 'node_1', 'status': 'CONFIRMED'},
            ],
          );
          expect(
            service.determineTargetForContext(context),
            'object_category_bar',
          );

          await service.sendMessage('상태 알려줘', context);

          // Online flow must strictly respect backend contract: highlight_target is null -> NO highlight!
          expect(service.activeHighlightTarget.value, isNull);
          expect(service.messages.last.text.contains('반짝'), isFalse);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );
  });
}
