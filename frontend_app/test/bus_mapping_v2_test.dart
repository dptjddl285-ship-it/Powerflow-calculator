import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/bus_inspector_view.dart';
import 'package:circuit_solver/widgets/review_overlay.dart';

ReviewNodeItem makeBus({
  required String id,
  int? busNumber,
  String busNumberStatus = 'VERIFIED',
  List<String> busNumberReasons = const [],
  String reviewStatus = 'CONFIRMED',
  int? suggestedBusNumber,
  List<double> bbox = const [0.1, 0.1, 0.2, 0.3],
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
    suggestedBusNumber: suggestedBusNumber,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PowerLens Bus Mapping V2 Production Tests', () {
    late ReviewNodeItem bus1;
    late ReviewNodeItem bus2;
    late ReviewNodeItem bus3;

    setUp(() {
      bus1 = makeBus(
        id: 'bus_1',
        bbox: [0.1, 0.1, 0.2, 0.3],
        busNumber: 1,
        busNumberStatus: 'VERIFIED',
        reviewStatus: 'CONFIRMED',
      );

      bus2 = makeBus(
        id: 'bus_2',
        bbox: [0.4, 0.4, 0.5, 0.6],
        busNumber: 2,
        busNumberStatus: 'VERIFIED',
        reviewStatus: 'CONFIRMED',
      );

      bus3 = makeBus(
        id: 'bus_3',
        bbox: [0.7, 0.7, 0.8, 0.9],
        busNumber: 3,
        busNumberStatus: 'VERIFIED',
        reviewStatus: 'CONFIRMED',
      );
    });

    // TEST A: VERIFIED Bus만 존재 -> individual approval 없이 Bus Gate PASS 가능.
    test(
      'TEST A: All VERIFIED buses pass Bus Gate without individual approval',
      () {
        final nodes = [bus1, bus2, bus3];
        final canPass = BusReviewGateEvaluator.canVerifyGate(
          workingNodes: nodes,
        );
        final blockers = BusReviewGateEvaluator.getBlockers(
          workingNodes: nodes,
        );

        expect(canPass, isTrue);
        expect(blockers, isEmpty);
        expect(
          BusReviewGateEvaluator.computeGuideBusIds(workingNodes: nodes),
          isEmpty,
        );
      },
    );

    // TEST B: busNumber == null -> Gate FAIL.
    test('TEST B: Bus with null busNumber fails Bus Gate', () {
      final nullBus = makeBus(
        id: 'bus_null',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
        reviewStatus: 'DETECTED',
      );
      final nodes = [bus1, nullBus];

      final canPass = BusReviewGateEvaluator.canVerifyGate(workingNodes: nodes);
      final blockers = BusReviewGateEvaluator.getBlockers(workingNodes: nodes);

      expect(canPass, isFalse);
      expect(blockers.any((b) => b.contains('미지정')), isTrue);
      expect(
        BusReviewGateEvaluator.computeGuideBusIds(workingNodes: nodes),
        contains('bus_null'),
      );
    });

    // TEST C: status UNCERTAIN + number exists -> Gate FAIL -> blocker text 존재.
    test(
      'TEST C: Bus with UNCERTAIN status and existing number fails Gate with blocker text',
      () {
        final uncertainBus = makeBus(
          id: 'bus_unc',
          busNumber: 14,
          busNumberStatus: 'UNCERTAIN',
          reviewStatus: 'DETECTED',
        );
        final nodes = [bus1, uncertainBus];

        final canPass = BusReviewGateEvaluator.canVerifyGate(
          workingNodes: nodes,
        );
        final blockers = BusReviewGateEvaluator.getBlockers(
          workingNodes: nodes,
        );

        expect(canPass, isFalse);
        expect(blockers, isNotEmpty);
        expect(
          blockers.any((b) => b.contains('불확실') || b.contains('UNCERTAIN')),
          isTrue,
        );
        expect(
          BusReviewGateEvaluator.computeGuideBusIds(workingNodes: nodes),
          contains('bus_unc'),
        );
      },
    );

    // TEST C2: the payload sent to the backend preserves Bus verification evidence.
    test('TEST C2: Bus payload preserves status and reasons', () {
      final uncertainBus = makeBus(
        id: 'bus_payload',
        busNumber: 14,
        busNumberStatus: 'UNCERTAIN',
        busNumberReasons: ['NO_BUS_NUMBER_FOUND'],
      );

      final payload = uncertainBus.toJson();

      expect(payload['bus_number_status'], 'UNCERTAIN');
      expect(payload['bus_number_reasons'], ['NO_BUS_NUMBER_FOUND']);
    });

    // TEST D: duplicate number -> Gate FAIL -> duplicate buses guide.
    test(
      'TEST D: Duplicate bus numbers block Gate and are both included in guide',
      () {
        final dupBus1 = makeBus(
          id: 'bus_dup_1',
          bbox: [0.1, 0.1, 0.2, 0.2],
          busNumber: 5,
          busNumberStatus: 'UNCERTAIN',
        );
        final dupBus2 = makeBus(
          id: 'bus_dup_2',
          bbox: [0.3, 0.3, 0.4, 0.4],
          busNumber: 5,
          busNumberStatus: 'UNCERTAIN',
        );
        final List<ReviewNodeItem> nodes = [dupBus1, dupBus2];

        final canPass = BusReviewGateEvaluator.canVerifyGate(
          workingNodes: nodes,
        );
        final blockers = BusReviewGateEvaluator.getBlockers(
          workingNodes: nodes,
        );
        final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
          workingNodes: nodes,
        );

        expect(canPass, isFalse);
        expect(blockers.any((b) => b.contains('중복')), isTrue);
        expect(guideIds, contains('bus_dup_1'));
        expect(guideIds, contains('bus_dup_2'));
      },
    );

    // TEST E: normal VERIFIED Bus -> Inspector 표시 -> 승인 버튼 없음.
    testWidgets(
      'TEST E: Normal VERIFIED Bus in BusInspectorView has NO approval button',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusInspectorView(
                node: bus1,
                allBuses: [bus1, bus2],
                onApplyNumber: (_) {},
              ),
            ),
          ),
        );

        // Must display AI confirmed status
        expect(find.text('AI 확인'), findsOneWidget);
        expect(find.text('Bus #1'), findsOneWidget);

        // Must NOT display any "승인" button
        expect(find.text('승인'), findsNothing);
        expect(find.text('승인하고 다음'), findsNothing);
        expect(find.text('승인하고 다음 모선으로'), findsNothing);
        expect(find.text('확인'), findsNothing);
      },
    );

    // TEST F: UNCERTAIN Bus -> Inspector -> 수정 가능.
    testWidgets(
      'TEST F: UNCERTAIN Bus in BusInspectorView shows edit field and [적용] button',
      (tester) async {
        final unBus = makeBus(
          id: 'bus_u',
          busNumber: null,
          busNumberStatus: 'UNCERTAIN',
          suggestedBusNumber: 12,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusInspectorView(
                node: unBus,
                allBuses: [unBus],
                onApplyNumber: (_) {},
              ),
            ),
          ),
        );

        expect(find.text('확인 필요'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('BusNumberInputField')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('BusApplyButton')), findsOneWidget);
        expect(find.text('적용'), findsOneWidget);
      },
    );

    // TEST G: Human [적용]으로 unique positive 번호 입력 -> callback triggered.
    testWidgets(
      'TEST G: Applying valid unique bus number invokes onApplyNumber',
      (tester) async {
        int? appliedNum;
        final unBus = makeBus(
          id: 'bus_u',
          busNumber: null,
          busNumberStatus: 'UNCERTAIN',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusInspectorView(
                node: unBus,
                allBuses: [unBus],
                onApplyNumber: (num) {
                  appliedNum = num;
                },
              ),
            ),
          ),
        );

        await tester.enterText(
          find.byKey(const ValueKey('BusNumberInputField')),
          '7',
        );
        await tester.tap(find.byKey(const ValueKey('BusApplyButton')));
        await tester.pump();

        expect(appliedNum, equals(7));
      },
    );

    // TEST H: Duplicate bus numbers in Inspector are reflected as duplicate state
    testWidgets('TEST H: Duplicate bus numbers render duplicate warning', (
      tester,
    ) async {
      final bA = makeBus(id: 'bA', busNumber: 3, bbox: [0, 0, 1, 1]);
      final bB = makeBus(id: 'bB', busNumber: 3, bbox: [0, 0, 1, 1]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BusInspectorView(
              node: bA,
              allBuses: [bA, bB],
              onApplyNumber: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('중복 번호'), findsOneWidget);
      expect(find.textContaining('다른 모선과 중복됩니다'), findsOneWidget);
    });

    // TEST I: internal ID = bus_17, number null -> 자동으로 17을 할당하지 않음.
    test('TEST I: Internal ID digits are never auto-assigned as busNumber', () {
      final bus17 = makeBus(
        id: 'bus_17',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
      );

      expect(bus17.busNumber, isNull);
      final blockers = BusReviewGateEvaluator.getBlockers(
        workingNodes: [bus17],
      );
      expect(blockers.any((b) => b.contains('미지정')), isTrue);
    });

    // TEST J: issue Bus bbox -> Guide Box (BusGuideBox_${node.id}).
    testWidgets(
      'TEST J: Issue bus renders BusGuideBox key in ReviewOverlayView',
      (tester) async {
        final Uint8List testImageBytes = Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x0D,
          0x49,
          0x48,
          0x44,
          0x52,
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
          0x08,
          0x06,
          0x00,
          0x00,
          0x00,
          0x1F,
          0x15,
          0xC4,
          0x89,
          0x00,
          0x00,
          0x00,
          0x0A,
          0x49,
          0x44,
          0x41,
          0x54,
          0x78,
          0x9C,
          0x63,
          0x00,
          0x01,
          0x00,
          0x00,
          0x05,
          0x00,
          0x01,
          0x0D,
          0x0A,
          0x2D,
          0xB4,
          0x00,
          0x00,
          0x00,
          0x00,
          0x49,
          0x45,
          0x4E,
          0x44,
          0xAE,
          0x42,
          0x60,
          0x82,
        ]);

        final issueBus = makeBus(
          id: 'bus_issue_1',
          bbox: [100.0, 100.0, 50.0, 50.0],
          busNumber: null,
          busNumberStatus: 'UNCERTAIN',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 500,
                height: 500,
                child: ReviewOverlayView(
                  imageBytes: testImageBytes,
                  imageUrl: '',
                  originalWidth: 500,
                  originalHeight: 500,
                  nodes: [issueBus],
                  lines: const [],
                  guideNodeIds: {'bus_issue_1'},
                  selectedNode: null,
                  selectedLine: null,
                  onSelectNode: (_) {},
                  onSelectLine: (_) {},
                  busFocusOnly: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('BusGuideBox_bus_issue_1')),
          findsOneWidget,
        );
        expect(find.text('번호 확인 필요'), findsOneWidget);
      },
    );

    // A backend focus target is never enough to retain a resolved Bus guide.
    test(
      'TEST K: Stale focus target for a clean Bus does not keep a guide',
      () {
        final focusTargets = [
          {'type': 'OBJECT', 'id': 'bus_1', 'label': '모선 1'},
        ];
        final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
          workingNodes: [bus1, bus2],
          focusTargets: focusTargets,
        );

        expect(guideIds, isEmpty);

        final unresolved = makeBus(
          id: 'bus_unresolved',
          busNumber: null,
          busNumberStatus: 'UNCERTAIN',
        );
        final activeIssueGuide = BusReviewGateEvaluator.computeGuideBusIds(
          workingNodes: [unresolved],
          focusTargets: const [
            {'type': 'OBJECT', 'id': 'bus_unresolved'},
          ],
        );
        expect(activeIssueGuide, {'bus_unresolved'});
      },
    );

    // TEST L: fabricated Bus ID -> Guide 없음.
    test(
      'TEST L: Fabricated bus ID in focus target does not produce guide',
      () {
        final focusTargets = [
          {'type': 'OBJECT', 'id': 'ghost_bus_999'},
        ];
        final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
          workingNodes: [bus1, bus2],
          focusTargets: focusTargets,
        );

        expect(guideIds, isNot(contains('ghost_bus_999')));
        expect(guideIds, isEmpty);
      },
    );

    // TEST M: focus type BUS -> 사용하지 않음.
    test('TEST M: Legacy focus target type BUS is ignored', () {
      final focusTargets = [
        {'type': 'BUS', 'id': 'bus_1'},
      ];
      final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
        workingNodes: [bus1, bus2],
        focusTargets: focusTargets,
      );

      expect(guideIds, isNot(contains('bus_1')));
      expect(guideIds, isEmpty);
    });

    // TEST N & O: a clean Bus state advances after its deterministic gate;
    // entering Bus Mapping remains behind the Object Gate.
    test('TEST N & O: clean Bus completion advances without a second CTA', () {
      final cleanState = BusReviewUiState.fromNodes([bus1, bus2]);
      expect(cleanState.nextActionText, contains('결선 검수'));
      expect(cleanState.nextActionText, isNot(contains('[모선 검수 완료]')));
      expect(
        BusReviewUiPolicy.canEnterBusMapping(objectGateVerified: false),
        isFalse,
      );
      expect(
        BusReviewUiPolicy.canEnterBusMapping(objectGateVerified: true),
        isTrue,
      );
    });

    // TEST P: COMPLETE_CURRENT_STAGE -> resolveIntentActions returns goToNextStage
    test(
      'TEST P: Bus completion utterances map to PowerLensAppAction.goToNextStage',
      () {
        final service = PowerLensAIService.instance;
        const busCtx = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'bus_mapping',
        );

        expect(service.resolveIntentActions('모선 검수 완료', busCtx), [
          PowerLensAppAction.goToNextStage,
        ]);
        expect(service.resolveIntentActions('모선 다 봤어', busCtx), [
          PowerLensAppAction.goToNextStage,
        ]);
        expect(service.resolveIntentActions('모선 확인 끝', busCtx), [
          PowerLensAppAction.goToNextStage,
        ]);
        expect(service.resolveIntentActions('버스 번호 확인 끝', busCtx), [
          PowerLensAppAction.goToNextStage,
        ]);
      },
    );

    // TEST Q: Bus stage does NOT contain "승인하고 다음 모선으로"
    test(
      'TEST Q: Speech and greetings contain 0 occurrences of approve and next',
      () {
        final cleanBubble = BusReviewGateEvaluator.getSpeechBubbleText(
          workingNodes: [bus1, bus2],
        );
        expect(cleanBubble.contains('승인하고 다음'), isFalse);
        expect(cleanBubble.contains('전체 승인'), isFalse);
        expect(cleanBubble.contains('하나씩 넘겨'), isFalse);

        final issueBubble = BusReviewGateEvaluator.getSpeechBubbleText(
          workingNodes: [
            bus1,
            makeBus(id: 'b_u', bbox: [0, 0, 1, 1], busNumber: null),
          ],
        );
        expect(issueBubble.contains('승인하고 다음'), isFalse);
        expect(issueBubble.contains('전체 승인'), isFalse);
        expect(issueBubble.contains('하나씩 넘겨'), isFalse);
      },
    );

    // TEST R: Bus stage does not support batch approve
    test(
      'TEST R: Bus mapping suppresses batch approve in resolveIntentActions',
      () {
        final service = PowerLensAIService.instance;
        const busCtx = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'bus_mapping',
        );

        expect(service.resolveIntentActions('전체 승인', busCtx), isEmpty);
        expect(service.resolveIntentActions('일괄 승인', busCtx), isEmpty);
        expect(service.resolveIntentActions('승인', busCtx), isEmpty);
        expect(service.resolveIntentActions('맞아', busCtx), isEmpty);
      },
    );

    // TEST S: filters: 전체, 확인 필요, 확인됨 exist and work as view filters
    test('TEST S: Bus filter keys and evaluator logic', () {
      final nodes = [
        bus1,
        makeBus(id: 'b_issue', bbox: [0, 0, 1, 1], busNumber: null),
      ];

      final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
        workingNodes: nodes,
      );
      expect(guideIds, contains('b_issue'));
      expect(guideIds, isNot(contains('bus_1')));

      // Production ReviewPage filtering
      final uncertainBuses = BusReviewUiState.filter(
        nodes,
        status: 'UNCERTAIN',
      );
      final verifiedBuses = BusReviewUiState.filter(nodes, status: 'VERIFIED');

      expect(uncertainBuses.length, equals(1));
      expect(verifiedBuses.length, equals(1));
      expect(uncertainBuses.first.id, equals('b_issue'));
      expect(verifiedBuses.first.id, equals('bus_1'));
    });

    // TEST T: Lensy Bus speech 0 mentions of legacy phrases
    test(
      'TEST T: Zero occurrences of legacy speech phrases in evaluator and AI service',
      () {
        final nodes = [bus1, bus2];
        final speechClean = BusReviewGateEvaluator.getSpeechBubbleText(
          workingNodes: nodes,
        );
        expect(speechClean.contains('전체 승인'), isFalse);
        expect(speechClean.contains('하나씩 넘겨'), isFalse);
        expect(speechClean.contains('승인하고 다음 모선'), isFalse);

        final nodesWithIssue = [
          bus1,
          makeBus(
            id: 'b_dup',
            bbox: [0, 0, 1, 1],
            busNumber: 1,
            busNumberStatus: 'UNCERTAIN',
          ),
        ];
        final speechIssue = BusReviewGateEvaluator.getSpeechBubbleText(
          workingNodes: nodesWithIssue,
        );
        expect(speechIssue.contains('전체 승인'), isFalse);
        expect(speechIssue.contains('하나씩 넘겨'), isFalse);
        expect(speechIssue.contains('승인하고 다음 모선'), isFalse);
      },
    );

    // TEST U: Hardcoded 99% Bus confidence is NOT displayed in UI
    testWidgets(
      'TEST U: Hardcoded 99% bus confidence is never rendered in Inspector',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusInspectorView(
                node: bus1,
                allBuses: [bus1],
                onApplyNumber: (_) {},
              ),
            ),
          ),
        );

        expect(find.textContaining('99%'), findsNothing);
        expect(find.textContaining('0.99'), findsNothing);
      },
    );

    // TEST V: Bus banner state is based on Bus issues, not line issues.
    test('TEST V: Bus UI state uses Bus issue metrics only', () {
      final issueNodes = [
        bus1,
        makeBus(
          id: 'bus_issue_1',
          busNumber: null,
          busNumberStatus: 'UNCERTAIN',
        ),
        makeBus(id: 'bus_issue_2', busNumber: 0, busNumberStatus: 'UNCERTAIN'),
      ];
      final state = BusReviewUiState.fromNodes(issueNodes);

      expect(state.subtitle, '모선 번호 검수');
      expect(state.totalBuses, 3);
      expect(state.verifiedBuses, 1);
      expect(state.issueBuses, 2);
      expect(state.nextActionText, '번호 확인이 필요한 모선 2개를 확인하세요.');
      expect(state.nextActionText, isNot(contains('결선 및 전기 검수')));
      expect(state.nextActionText, isNot(contains('전기 오류')));
      expect(state.nextActionText, isNot(contains('최종 검증')));
    });

    // TEST W: clean Bus state advances to Connection after the Bus Gate.
    test('TEST W: clean Bus next action advances without a completion CTA', () {
      final state = BusReviewUiState.fromNodes([bus1, bus2, bus3]);
      expect(state.issueBuses, 0);
      expect(state.nextActionText, '모선 번호 확인이 완료되었습니다. 결선 검수로 자동 이동합니다.');
      expect(state.nextActionText, isNot(contains('최종 검증')));
      expect(state.nextActionText, isNot(contains('[모선 검수 완료]')));
    });

    // TEST X: rejected buses do not enter active totals or focus IDs.
    test('TEST X: rejected Bus is excluded from active UI state', () {
      final rejected = makeBus(
        id: 'bus_rejected',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
        reviewStatus: 'REJECTED',
      );
      final state = BusReviewUiState.fromNodes([bus1, rejected]);

      expect(state.totalBuses, 1);
      expect(state.issueBuses, 0);
      expect(
        BusReviewGateEvaluator.computeGuideBusIds(
          workingNodes: [bus1, rejected],
        ),
        isEmpty,
      );
    });

    // TEST Y: an active duplicate reason blocks even a unique number.
    test('TEST Y: active duplicate reason remains a Bus issue', () {
      final staleReasonBus = makeBus(
        id: 'bus_reason',
        busNumber: 5,
        busNumberStatus: 'VERIFIED',
        busNumberReasons: ['DUPLICATE_BUS_NUMBER_5'],
      );
      final nodes = [bus1, staleReasonBus];

      expect(
        BusReviewGateEvaluator.canVerifyGate(workingNodes: nodes),
        isFalse,
      );
      expect(
        BusReviewGateEvaluator.computeGuideBusIds(workingNodes: nodes),
        contains('bus_reason'),
      );
      expect(BusReviewUiState.fromNodes(nodes).issueBuses, 1);
    });

    // TEST Z: offline "전체 승인해줘" has no legacy batch-approval guidance.
    test('TEST Z: offline Bus batch request gives the single CTA guidance', () {
      final service = PowerLensAIService.instance;
      const busCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        totalBuses: 1,
        unresolvedBusNumbers: 1,
      );
      final reply = service.generateOfflineFallbackReply('전체 승인해줘', busCtx);

      expect(reply, contains('[모선 검수 완료]'));
      expect(reply, contains('정상 모선은 개별 또는 일괄 승인할 필요가 없습니다'));
      expect(reply, isNot(contains('일괄 승인 버튼')));
      expect(reply, isNot(contains('승인하고 다음 모선')));
      expect(reply, isNot(contains('하나씩 넘겨')));
    });

    // Production phase/keyboard/filter contracts used by ReviewPage.
    test('Phase navigation blocks Object bypass and Bus arrows/Enter', () {
      expect(
        BusReviewUiPolicy.canEnterBusMapping(objectGateVerified: false),
        isFalse,
      );
      expect(
        BusReviewUiPolicy.canEnterBusMapping(objectGateVerified: true),
        isTrue,
      );
      for (final key in const [
        'Arrow Left',
        'Arrow Right',
        'Arrow Up',
        'Arrow Down',
        'Enter',
      ]) {
        expect(
          BusReviewUiPolicy.shouldIgnoreGlobalKeyForBus(
            isBusPhase: true,
            isTyping: false,
            keyLabel: key,
          ),
          isTrue,
          reason: key,
        );
      }
      expect(
        BusReviewUiPolicy.shouldIgnoreGlobalKeyForBus(
          isBusPhase: true,
          isTyping: true,
          keyLabel: 'Enter',
        ),
        isFalse,
      );
    });

    test('Production Bus filters return ALL, UNCERTAIN, and VERIFIED sets', () {
      final issue = makeBus(
        id: 'bus_filter_issue',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
      );
      final rejected = makeBus(
        id: 'bus_filter_rejected',
        busNumber: null,
        busNumberStatus: 'UNCERTAIN',
        reviewStatus: 'REJECTED',
      );
      final nodes = [bus1, issue, rejected];

      expect(
        BusReviewUiState.filter(nodes).map((node) => node.id),
        containsAll(<String>['bus_1', 'bus_filter_issue']),
      );
      expect(
        BusReviewUiState.filter(
          nodes,
          status: 'UNCERTAIN',
        ).map((node) => node.id),
        ['bus_filter_issue'],
      );
      expect(
        BusReviewUiState.filter(
          nodes,
          status: 'VERIFIED',
        ).map((node) => node.id),
        ['bus_1'],
      );
    });

    test('TEST AA: zero active Bus is a UI blocker, never clean', () {
      final state = BusReviewUiState.fromNodes(const []);

      expect(state.totalBuses, 0);
      expect(state.issueBuses, 0);
      expect(state.isBlocked, isTrue);
      expect(state.nextActionText, BusReviewUiState.noActiveBusMessage);
      expect(state.nextActionText, isNot(contains('모선 번호 확인이 완료')));
    });

    test('TEST AB: zero active Bus offline Lensy guidance is a blocker', () {
      final service = PowerLensAIService.instance;
      const zeroBusContext = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        workingNodes: [],
      );
      final reply = service.generateOfflineFallbackReply(
        '다음에 뭐 해?',
        zeroBusContext,
      );

      expect(reply, contains(BusReviewUiState.noActiveBusMessage));
      expect(reply, isNot(contains('모선 번호 확인이 완료')));
      expect(reply, isNot(contains('확인 필요: **0개**')));
    });

    test('TEST AC: zero active Bus keeps the production Gate blocked', () {
      expect(BusReviewGateEvaluator.canVerifyGate(workingNodes: []), isFalse);
      expect(
        BusReviewGateEvaluator.getSpeechBubbleText(workingNodes: []),
        contains('유효한 모선'),
      );
    });

    test('TEST AD: VERIFIED number 0 remains an issue row', () {
      final invalid = makeBus(
        id: 'bus_invalid_verified',
        busNumber: 0,
        busNumberStatus: 'VERIFIED',
      );

      expect(
        BusReviewUiState.rowBadgeText(node: invalid, workingNodes: [invalid]),
        '검토필요',
      );
      expect(BusReviewUiState.fromNodes([invalid]).issueBuses, 1);
    });

    test(
      'TEST AE: unique number with active duplicate reason is an issue row',
      () {
        final reasonBus = makeBus(
          id: 'bus_row_duplicate_reason',
          busNumber: 5,
          busNumberStatus: 'VERIFIED',
          busNumberReasons: ['DUPLICATE_BUS_NUMBER_5'],
        );

        expect(
          BusReviewUiState.rowBadgeText(
            node: reasonBus,
            workingNodes: [reasonBus],
          ),
          '중복 번호',
        );
        expect(BusReviewUiState.fromNodes([reasonBus]).issueBuses, 1);
      },
    );

    test(
      'TEST AF: BUS_MAPPING_REVIEW uses the same review-issues Bus branch',
      () {
        final service = PowerLensAIService.instance;
        const baseContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING',
          totalBuses: 1,
          unresolvedBusNumbers: 1,
        );
        const aliasContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'BUS_MAPPING_REVIEW',
          totalBuses: 1,
          unresolvedBusNumbers: 1,
        );

        final baseReply = service.generateOfflineFallbackReply(
          '검토 필요한 항목 보여줘',
          baseContext,
        );
        final aliasReply = service.generateOfflineFallbackReply(
          '검토 필요한 항목 보여줘',
          aliasContext,
        );

        expect(aliasReply, baseReply);
        expect(aliasReply, contains('확인이 필요한 모선'));
        expect(aliasReply, isNot(contains('모선 번호 확인이 완료')));
      },
    );
  });
}
