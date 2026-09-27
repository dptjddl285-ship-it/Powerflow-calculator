import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_final_contract.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

VerifiedSLD verifiedSld({String status = 'VERIFIED'}) => VerifiedSLD.fromJson({
  'document_id': 'verified-doc',
  'status': status,
  'image': {'width': 100, 'height': 100},
  'nodes': [],
  'lines': [],
});

void main() {
  group('Final Excel V2 contract', () {
    final service = PowerLensAIService.instance;

    tearDown(() {
      service.clearHistory();
      service.clearProactiveKeys();
    });

    List<String> greetingActions(PowerLensAssistantContext context) {
      service.clearHistory();
      service.ensureInitialGreeting(context.workflowStage, context);
      return service.messages.single.suggestedActions;
    }

    test('C8: CAD로 넘어가 resolves to the gated canvas handoff action', () {
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'FINAL',
        finalVerified: true,
        excelLoaded: true,
        excelMappingStatus: 'MATCHED',
      );
      expect(
        PowerLensAIService.instance.resolveIntentActions('CAD로 넘어가', context),
        [PowerLensAppAction.handoffToCanvas],
      );
    });

    test(
      'FINAL without Excel offers import, not calculation or flow display',
      () {
        const context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          finalVerified: true,
        );

        expect(greetingActions(context), [
          'Excel 가져오기',
          '다음에 뭐 해?',
          '현재 상태 요약',
        ]);
        expect(
          service.determineTargetForContext(context),
          'final_excel_upload',
        );
      },
    );

    test(
      'FINAL with an Excel mismatch does not offer CAD or power-flow actions',
      () {
        const context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          finalVerified: true,
          excelLoaded: true,
          excelMappingStatus: 'MISMATCH',
        );

        expect(greetingActions(context), [
          'Excel 다시 가져오기',
          '다음에 뭐 해?',
          '현재 상태 요약',
        ]);
        expect(
          service.determineTargetForContext(context),
          'excel_mismatch_btn',
        );
        expect(
          service.generateOfflineFallbackReply('다음에 뭐 해?', context),
          contains('불일치'),
        );
      },
    );

    test('FINAL with matched Excel offers CAD handoff only', () {
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'FINAL',
        finalVerified: true,
        excelLoaded: true,
        excelMappingStatus: 'MATCHED',
      );

      expect(greetingActions(context), ['CAD로 이동', '다음에 뭐 해?', '현재 상태 요약']);
      expect(
        service.determineTargetForContext(context),
        'final_canvas_handoff',
      );
    });

    test(
      'CAD quick actions are gated on readiness and actual solver evidence',
      () {
        const notReady = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'EXCEL',
          excelLoaded: true,
          powerflowReady: false,
        );
        expect(greetingActions(notReady), [
          '현재 상태 요약',
          'Excel 다시 가져오기',
          '다음에 뭐 해?',
        ]);

        const ready = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'FINAL_CAD',
          excelLoaded: true,
          powerflowReady: true,
        );
        expect(greetingActions(ready).first, '조류계산 실행');

        const converged = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'POWERFLOW',
          powerflowConverged: true,
          powerflowEvidence: {'converged': true, 'iterations': 4},
        );
        expect(greetingActions(converged), ['결과 보여줘', '흐름 방향 보여줘', '수치 보여줘']);
      },
    );

    test(
      'final proactive guidance refreshes when the Excel state changes',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';
        server.listen((request) async {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('offline');
          await request.response.close();
        });

        const noExcel = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          documentId: 'final-mismatch',
          finalVerified: true,
        );
        const mismatch = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          documentId: 'final-mismatch',
          finalVerified: true,
          excelLoaded: true,
          excelMappingStatus: 'MISMATCH',
        );

        try {
          await service.notifyStageChange(noExcel);
          expect(service.messages.single.suggestedActions.first, 'Excel 가져오기');

          service.refreshContextGuidance(mismatch);

          expect(service.messages.single.text, contains('불일치'));
          expect(service.messages.single.text, contains('CAD로 이동할 수 없어요'));
          expect(
            service.messages.single.suggestedActions.first,
            'Excel 다시 가져오기',
          );
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'blocked REVIEW and unready CAD power-flow requests are local guides',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requestCount = 0;
        server.listen((request) async {
          requestCount++;
          await request.response.close();
        });
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';
        var actionCount = 0;
        Future<bool> handler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async {
          actionCount++;
          return true;
        }

        service.registerActionHandler(handler);
        const contexts = [
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'FINAL',
            finalVerified: true,
          ),
          PowerLensAssistantContext(
            currentScreen: 'REVIEW_PAGE',
            workflowStage: 'FINAL',
            finalVerified: true,
            excelLoaded: true,
            excelMappingStatus: 'MISMATCH',
          ),
          PowerLensAssistantContext(
            currentScreen: 'CAD_CANVAS',
            workflowStage: 'FINAL_CAD',
            excelLoaded: true,
            powerflowReady: false,
            currentBlockers: ['모선 연결 검토'],
          ),
        ];

        try {
          for (final context in contexts) {
            service.clearHistory();
            await service.sendMessage('계산해줘', context);
            expect(service.messages.last.agentStatus, 'LOCAL_GUIDE');
            expect(service.messages.last.text, isNot(contains('실행했어요')));
            expect(service.messages.last.text, isNot(contains('실행합니다')));
          }
          expect(requestCount, 0);
          expect(actionCount, 0);
        } finally {
          service.unregisterActionHandler(handler);
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'EXECUTE replies follow the actual handler result for review handoff and CAD run',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              '{"status":"success","reply_ko":"조류계산을 실행합니다. 기다려주세요.","action_mode":"EXECUTE","action_id":"RUN_POWER_FLOW","suggested_actions":[]}',
            );
          await request.response.close();
        });
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';
        final handledActions = <PowerLensAppAction>[];
        Future<bool> handler(
          PowerLensAppAction action,
          Map<String, dynamic>? params,
        ) async {
          handledActions.add(action);
          return true;
        }

        service.registerActionHandler(handler);
        const matchedReview = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          finalVerified: true,
          excelLoaded: true,
          excelMappingStatus: 'MATCHED',
        );
        const readyCanvas = PowerLensAssistantContext(
          currentScreen: 'CAD_CANVAS',
          workflowStage: 'FINAL_CAD',
          excelLoaded: true,
          powerflowReady: true,
        );

        try {
          await service.sendMessage('계산해줘', matchedReview);
          expect(service.messages.last.text, contains('캔버스로 이동했어요'));
          expect(service.messages.last.text, isNot(contains('조류계산을 실행합니다')));

          await service.sendMessage('계산해줘', readyCanvas);
          expect(service.messages.last.text, contains('조류계산을 실행했어요'));
          expect(handledActions, [
            PowerLensAppAction.runPowerFlow,
            PowerLensAppAction.runPowerFlow,
          ]);
        } finally {
          service.unregisterActionHandler(handler);
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test(
      'backend-suggested FINAL actions cannot bypass the Excel gate',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originalBaseUrl = PowerLensAIService.baseUrl;
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';
        server.listen((request) async {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              '{"status":"success","reply_ko":"안내","suggested_actions":["조류계산 실행","흐름 방향 보여줘"]}',
            );
          await request.response.close();
        });

        const context = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'FINAL',
          documentId: 'final-no-excel',
          finalVerified: true,
        );

        try {
          await service.notifyStageChange(context);
          expect(service.messages.single.suggestedActions, [
            'Excel 가져오기',
            '다음에 뭐 해?',
            '현재 상태 요약',
          ]);
        } finally {
          await server.close(force: true);
          PowerLensAIService.baseUrl = originalBaseUrl;
        }
      },
    );

    test('F1: Excel import is available only in verified final phase', () {
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: false,
          verifiedSld: verifiedSld(),
        ),
        isFalse,
      );
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: true,
          verifiedSld: verifiedSld(status: 'PENDING'),
        ),
        isFalse,
      );
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
        ),
        isTrue,
      );
    });

    test('F2: an unknown comparison is not a verified match', () {
      expect(ReviewFinalContract.hasVerifiedExcelMatch(null), isFalse);
      expect(ReviewFinalContract.hasVerifiedExcelMatch(const {}), isFalse);
      expect(
        ReviewFinalContract.hasVerifiedExcelMatch({'is_matched': 'true'}),
        isFalse,
      );
    });

    test('F3: an explicit Excel mismatch blocks canvas handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': false},
        ),
        isFalse,
      );
    });

    test('F4: absent Excel data blocks canvas handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: null,
          mismatchReport: const {'is_matched': true},
        ),
        isFalse,
      );
    });

    test('F5: only a strict boolean matched report reveals the handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': true},
        ),
        isTrue,
      );
    });

    test('F6: a non-verified diagram can never hand off', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(status: 'PENDING'),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': true},
        ),
        isFalse,
      );
    });

    test(
      'F7: mismatch repair copy is sourced from actual discrepancy messages',
      () {
        expect(
          ReviewFinalContract.mismatchMessages({
            'summary': '한 개 불일치',
            'discrepancies': [
              {'target': 'Bus 7', 'message': '모선 7번이 엑셀에서 누락되었습니다.'},
              {'target': 'Line 1-2'},
              'malformed row',
            ],
          }),
          ['모선 7번이 엑셀에서 누락되었습니다.', 'Line 1-2'],
        );
      },
    );

    test(
      'F8: a missing comparison report remains a blocker, not a green state',
      () {
        expect(
          ReviewFinalContract.canHandoffToCanvas(
            isFinalPhase: true,
            verifiedSld: verifiedSld(),
            excelData: const {'sbase_mva': 100},
            mismatchReport: null,
          ),
          isFalse,
        );
      },
    );
  });
}
