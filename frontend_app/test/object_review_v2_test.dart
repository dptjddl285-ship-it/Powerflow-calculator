import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/object_inspector_view.dart';
import 'package:circuit_solver/widgets/review_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Minimal 1x1 transparent PNG for widget testing
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

  group('Object Review V2 Real Production-Code Tests', () {
    // -------------------------------------------------------------
    // Gate Evaluator Production Tests (Calling ObjectReviewGateEvaluator directly)
    // -------------------------------------------------------------
    test(
      'Gate Evaluator: Clean DETECTED objects pass gate without human batch approval',
      () {
        final nodes = [
          ReviewNodeItem(
            id: 'bus_1',
            className: 'bus',
            bbox: [100.0, 100.0, 150.0, 20.0],
            confidence: 0.95,
            source: 'yolo_primary',
            reviewStatus: 'DETECTED',
          ),
          ReviewNodeItem(
            id: 'gen_1',
            className: 'generator',
            bbox: [200.0, 200.0, 40.0, 40.0],
            confidence: 0.92,
            source: 'yolo_primary',
            reviewStatus: 'DETECTED',
          ),
        ];
        final candidates = <MissingCandidateItem>[];

        expect(
          ObjectReviewGateEvaluator.canVerifyGate(
            workingNodes: nodes,
            missingCandidates: candidates,
          ),
          isTrue,
        );
        expect(
          ObjectReviewGateEvaluator.getBlockers(
            workingNodes: nodes,
            missingCandidates: candidates,
          ),
          isEmpty,
        );
      },
    );

    test('Gate Evaluator: A single SUSPICIOUS object blocks Object Gate', () {
      final nodes = [
        ReviewNodeItem(
          id: 'gen_1',
          className: 'generator',
          bbox: [200.0, 200.0, 40.0, 40.0],
          confidence: 0.65,
          source: 'yolo_primary',
          reviewStatus: 'SUSPICIOUS',
          reviewReasons: ['심볼 인식 신뢰도가 낮습니다.'],
        ),
      ];
      final candidates = <MissingCandidateItem>[];

      expect(
        ObjectReviewGateEvaluator.canVerifyGate(
          workingNodes: nodes,
          missingCandidates: candidates,
        ),
        isFalse,
      );
      final blockers = ObjectReviewGateEvaluator.getBlockers(
        workingNodes: nodes,
        missingCandidates: candidates,
      );
      expect(blockers.any((b) => b.contains('의심 객체')), isTrue);
    });

    test('Gate Evaluator: An OPEN missing candidate blocks Object Gate', () {
      final nodes = [
        ReviewNodeItem(
          id: 'bus_1',
          className: 'bus',
          bbox: [100.0, 100.0, 150.0, 20.0],
          confidence: 0.95,
          source: 'yolo_primary',
          reviewStatus: 'DETECTED',
        ),
      ];
      final candidates = [
        MissingCandidateItem(
          id: 'cand_1',
          suspectedClass: 'load',
          descriptionKo: '고립된 선로 끝단에 부하 기호 누락 의심',
          status: 'OPEN',
        ),
      ];

      expect(
        ObjectReviewGateEvaluator.canVerifyGate(
          workingNodes: nodes,
          missingCandidates: candidates,
        ),
        isFalse,
      );
      final blockers = ObjectReviewGateEvaluator.getBlockers(
        workingNodes: nodes,
        missingCandidates: candidates,
      );
      expect(blockers.any((b) => b.contains('누락 의심 영역')), isTrue);
    });

    test(
      'Gate Evaluator: Confirming [맞음] marks node CONFIRMED and clears blocker',
      () {
        final suspiciousNode = ReviewNodeItem(
          id: 'node_susp',
          className: 'transformer',
          bbox: [50.0, 50.0, 60.0, 60.0],
          confidence: 0.70,
          source: 'yolo_rescue',
          reviewStatus: 'SUSPICIOUS',
        );
        final nodes = [suspiciousNode];
        final candidates = <MissingCandidateItem>[];

        expect(
          ObjectReviewGateEvaluator.canVerifyGate(
            workingNodes: nodes,
            missingCandidates: candidates,
          ),
          isFalse,
        );

        // Perform human confirmation [맞음]
        suspiciousNode.reviewStatus = 'CONFIRMED';
        suspiciousNode.source = '${suspiciousNode.source}_human_confirmed';

        expect(suspiciousNode.reviewStatus, 'CONFIRMED');
        expect(suspiciousNode.source, 'yolo_rescue_human_confirmed');
        expect(
          ObjectReviewGateEvaluator.canVerifyGate(
            workingNodes: nodes,
            missingCandidates: candidates,
          ),
          isTrue,
        );
      },
    );

    // -------------------------------------------------------------
    // TEST A: determineTargetForContext returns null for suspicious (never object_approve / object_batch_approve)
    // -------------------------------------------------------------
    test(
      'TEST A: PowerLensAIService.determineTargetForContext() returns null when suspicious, never object_approve/object_batch_approve',
      () {
        final service = PowerLensAIService.instance;

        const suspiciousContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          suspiciousObjects: 2,
          unresolvedMissingCandidates: 0,
          workingNodes: [
            {'id': 'T1', 'status': 'SUSPICIOUS'},
            {'id': 'B1', 'status': 'DETECTED'},
          ],
        );

        final target = service.determineTargetForContext(suspiciousContext);
        expect(target, isNull);
        expect(target, isNot('object_approve'));
        expect(target, isNot('object_batch_approve'));

        // If missing candidates exist, target should be missing_candidates
        const candidateContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          suspiciousObjects: 0,
          unresolvedMissingCandidates: 1,
        );
        expect(
          service.determineTargetForContext(candidateContext),
          'missing_candidates',
        );

        // Clean Object Review begins at the persistent category guide.
        const cleanContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          suspiciousObjects: 0,
          unresolvedMissingCandidates: 0,
          workingNodes: [
            {'id': 'B1', 'status': 'DETECTED'},
          ],
        );
        expect(
          service.determineTargetForContext(cleanContext),
          'object_category_bar',
        );
      },
    );

    // -------------------------------------------------------------
    // TEST B: Offline fallback has 0 mentions of legacy approval phrases
    // -------------------------------------------------------------
    test(
      'TEST B: OBJECT_REVIEW offline fallback contains 0 mentions of legacy approval phrases',
      () {
        final service = PowerLensAIService.instance;

        // 1. Clean context
        const cleanCtx = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          suspiciousObjects: 0,
          unresolvedMissingCandidates: 0,
          workingNodes: [
            {'id': 'B1', 'status': 'DETECTED'},
            {'id': 'G1', 'status': 'DETECTED'},
          ],
        );
        final replyClean = service.generateOfflineFallbackReply(
          '다음 뭐해?',
          cleanCtx,
        );
        expect(replyClean.contains('정상 객체 일괄 승인'), isFalse);
        expect(replyClean.contains('정상 객체 전체 승인'), isFalse);
        expect(replyClean.contains('승인하고 다음'), isFalse);

        // 2. Suspicious context
        const suspCtx = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          suspiciousObjects: 1,
          selectedElement: 'T1',
          workingNodes: [
            {'id': 'T1', 'status': 'SUSPICIOUS'},
          ],
        );
        final replySusp = service.generateOfflineFallbackReply(
          '확인 어떻게 해?',
          suspCtx,
        );
        expect(replySusp.contains('정상 객체 일괄 승인'), isFalse);
        expect(replySusp.contains('정상 객체 전체 승인'), isFalse);
        expect(replySusp.contains('승인하고 다음'), isFalse);

        // 3. Missing candidates context
        const candCtx = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
          unresolvedMissingCandidates: 1,
        );
        final replyCand = service.generateOfflineFallbackReply('설명해줘', candCtx);
        expect(replyCand.contains('정상 객체 일괄 승인'), isFalse);
        expect(replyCand.contains('정상 객체 전체 승인'), isFalse);
        expect(replyCand.contains('승인하고 다음'), isFalse);
      },
    );

    // -------------------------------------------------------------
    // TEST C: Batch and sequential actions cannot be dispatched in Object Review
    // -------------------------------------------------------------
    test(
      'TEST C: actual PowerLensAppAction / Object Review handler prevents Object batch/sequential approval dispatch',
      () {
        final service = PowerLensAIService.instance;

        const objReviewContext = PowerLensAssistantContext(
          currentScreen: 'REVIEW_PAGE',
          workflowStage: 'object_review',
        );

        // Batch approval commands in Object Review must resolve to empty list (suppressed)
        expect(
          service.resolveIntentActions('정상 객체 일괄 승인', objReviewContext),
          isEmpty,
        );
        expect(
          service.resolveIntentActions('정상 객체 전체 승인', objReviewContext),
          isEmpty,
        );
        expect(
          service.resolveIntentActions('일괄 승인해줘', objReviewContext),
          isEmpty,
        );

        // Positive review replies in Object Review do NOT resolve to approveCurrentAndNext
        expect(
          service.resolveIntentActions('승인', objReviewContext),
          isNot(contains(PowerLensAppAction.approveCurrentAndNext)),
        );
        expect(
          service.resolveIntentActions('맞아', objReviewContext),
          isNot(contains(PowerLensAppAction.approveCurrentAndNext)),
        );
      },
    );

    // -------------------------------------------------------------
    // TEST D: ReviewOverlayView with SUSPICIOUS node renders Guide Box
    // -------------------------------------------------------------
    testWidgets(
      'TEST D: ReviewOverlayView with SUSPICIOUS node renders ObjectGuideBox',
      (tester) async {
        final suspiciousNode = ReviewNodeItem(
          id: 'trans_suspicious_1',
          className: 'transformer',
          bbox: [100.0, 100.0, 50.0, 50.0],
          confidence: 0.60,
          source: 'yolo',
          reviewStatus: 'SUSPICIOUS',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ReviewOverlayView(
                  imageBytes: testImageBytes,
                  imageUrl: '',
                  originalWidth: 800,
                  originalHeight: 600,
                  nodes: [suspiciousNode],
                  selectedNode: null,
                  onSelectNode: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Guide Box should be rendered with key ObjectGuideBox_trans_suspicious_1
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${suspiciousNode.id}')),
          findsOneWidget,
        );
      },
    );

    // -------------------------------------------------------------
    // TEST E: focusTargetsNotifier triggers ReviewOverlayView rebuild to show guide for focused object
    // -------------------------------------------------------------
    testWidgets(
      'TEST E: focusTargetsNotifier update triggers ReviewOverlayView rebuild and displays guide for focused object',
      (tester) async {
        final cleanNode = ReviewNodeItem(
          id: 'gen_clean_1',
          className: 'generator',
          bbox: [200.0, 150.0, 40.0, 40.0],
          confidence: 0.95,
          source: 'yolo_primary',
          reviewStatus: 'DETECTED',
        );
        final nodes = [cleanNode];

        // Ensure focus targets start empty
        PowerLensAIService.instance.clearFocusTargets();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable:
                      PowerLensAIService.instance.focusTargetsNotifier,
                  builder: (context, focusTargets, _) {
                    final guideIds =
                        ObjectReviewGateEvaluator.computeGuideNodeIds(
                          workingNodes: nodes,
                          focusTargets: focusTargets,
                        );
                    return ReviewOverlayView(
                      imageBytes: testImageBytes,
                      imageUrl: '',
                      originalWidth: 800,
                      originalHeight: 600,
                      nodes: nodes,
                      selectedNode: null,
                      guideNodeIds: guideIds,
                      onSelectNode: (_) {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Initially, clean node has NO guide box
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${cleanNode.id}')),
          findsNothing,
        );

        // Now Lensy agent sets focus_targets to cleanNode
        PowerLensAIService.instance.setFocusTargets([
          {'type': 'OBJECT', 'id': cleanNode.id},
        ]);
        await tester.pump();

        // Guide Box now appears because of reactive rebuild!
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${cleanNode.id}')),
          findsOneWidget,
        );
      },
    );

    // -------------------------------------------------------------
    // TEST F: Fabricated Object focus ID does not display guide box
    // -------------------------------------------------------------
    testWidgets(
      'TEST F: Fabricated focus target does NOT display guide box in ReviewOverlayView',
      (tester) async {
        final realNode = ReviewNodeItem(
          id: 'real_bus_10',
          className: 'bus',
          bbox: [50.0, 50.0, 80.0, 20.0],
          confidence: 0.98,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        );
        final nodes = [realNode];

        PowerLensAIService.instance.clearFocusTargets();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable:
                      PowerLensAIService.instance.focusTargetsNotifier,
                  builder: (context, focusTargets, _) {
                    final guideIds =
                        ObjectReviewGateEvaluator.computeGuideNodeIds(
                          workingNodes: nodes,
                          focusTargets: focusTargets,
                        );
                    return ReviewOverlayView(
                      imageBytes: testImageBytes,
                      imageUrl: '',
                      originalWidth: 800,
                      originalHeight: 600,
                      nodes: nodes,
                      selectedNode: null,
                      guideNodeIds: guideIds,
                      onSelectNode: (_) {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Inject fabricated ID
        PowerLensAIService.instance.setFocusTargets([
          {'type': 'OBJECT', 'id': 'ghost_fabricated_999'},
        ]);
        await tester.pump();

        // No guide box for fabricated ID or real node
        expect(
          find.byKey(const ValueKey('ObjectGuideBox_ghost_fabricated_999')),
          findsNothing,
        );
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${realNode.id}')),
          findsNothing,
        );
      },
    );

    // -------------------------------------------------------------
    // TEST G: Resolving suspicious (SUSPICIOUS -> CONFIRMED) removes warning Guide Box
    // -------------------------------------------------------------
    testWidgets(
      'TEST G: Resolving suspicious node to CONFIRMED removes warning Guide Box',
      (tester) async {
        final testNode = ReviewNodeItem(
          id: 'node_to_confirm',
          className: 'generator',
          bbox: [120.0, 120.0, 40.0, 40.0],
          confidence: 0.65,
          source: 'yolo',
          reviewStatus: 'SUSPICIOUS',
        );
        final nodes = [testNode];

        PowerLensAIService.instance.clearFocusTargets();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  final guideIds =
                      ObjectReviewGateEvaluator.computeGuideNodeIds(
                        workingNodes: nodes,
                        focusTargets: PowerLensAIService
                            .instance
                            .focusTargetsNotifier
                            .value,
                      );
                  return SizedBox(
                    width: 800,
                    height: 600,
                    child: ReviewOverlayView(
                      imageBytes: testImageBytes,
                      imageUrl: '',
                      originalWidth: 800,
                      originalHeight: 600,
                      nodes: nodes,
                      selectedNode: null,
                      guideNodeIds: guideIds,
                      onSelectNode: (n) {
                        setState(() {
                          n.reviewStatus = 'CONFIRMED';
                          PowerLensAIService.instance.clearFocusTargets();
                        });
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        // Guide box is present while SUSPICIOUS
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${testNode.id}')),
          findsOneWidget,
        );

        // Simulate human resolution [맞음]
        await tester.tap(
          find.byKey(ValueKey('ObjectGuideBox_${testNode.id}')),
          warnIfMissed: false,
        );
        testNode.reviewStatus = 'CONFIRMED';
        PowerLensAIService.instance.clearFocusTargets();
        await tester.pump();

        // Warning guide box is removed!
        expect(
          find.byKey(ValueKey('ObjectGuideBox_${testNode.id}')),
          findsNothing,
        );
      },
    );

    // -------------------------------------------------------------
    // TEST H: ObjectInspectorView with normal DETECTED node shows confidence and no approval button
    // -------------------------------------------------------------
    testWidgets(
      'TEST H: ObjectInspectorView with normal DETECTED node shows AI model confidence and no approval button',
      (tester) async {
        final normalNode = ReviewNodeItem(
          id: 'load_normal_1',
          className: 'load',
          bbox: [300.0, 300.0, 30.0, 30.0],
          confidence: 0.94,
          source: 'cv_primary',
          reviewStatus: 'DETECTED',
          evidence: {
            'yolo_support': 0.865,
            'policy_decision': 'ACCEPT',
            'is_suspicious': false,
            'geometry_evidence': {'has_cv_lead': true},
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ObjectInspectorView(
                  node: normalNode,
                  onMatch: () {},
                  onEditToggle: () {},
                ),
              ),
            ),
          ),
        );

        expect(find.text('AI 판단 결과'), findsOneWidget);
        expect(find.text('최종 인식 신뢰도'), findsOneWidget);
        expect(find.text('94%'), findsOneWidget);
        expect(find.text('OpenCV 검출'), findsOneWidget);
        expect(find.text('YOLO 보조 확인'), findsOneWidget);
        expect(find.text('86.5%'), findsOneWidget);
        expect(find.text('교차 검증 결과'), findsOneWidget);
        expect(find.text('추가 확인 필요'), findsOneWidget);
        expect(find.textContaining('추가 검토 사유가 없습니다'), findsOneWidget);
        expect(find.textContaining('node_id'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('ObjectTechnicalDetails')));
        await tester.pumpAndSettle();
        expect(find.textContaining('node_id'), findsOneWidget);
        expect(find.textContaining('cv_primary'), findsOneWidget);
        // Zero approval buttons
        expect(find.text("승인하고 다음"), findsNothing);
        expect(find.text("정상 객체 일괄 승인"), findsNothing);
        expect(find.byKey(const ValueKey('ObjectMatchButton')), findsNothing);
      },
    );

    testWidgets(
      'ObjectInspector hides unsupported evidence instead of inventing values',
      (tester) async {
        final nodeWithoutEvidence = ReviewNodeItem(
          id: 'load_unknown',
          className: 'load',
          bbox: const [10.0, 10.0, 8.0, 8.0],
          confidence: 0,
          source: 'unknown',
          reviewStatus: 'DETECTED',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ObjectInspectorView(
                  node: nodeWithoutEvidence,
                  onMatch: () {},
                  onEditToggle: () {},
                ),
              ),
            ),
          ),
        );

        expect(find.text('인식 객체'), findsOneWidget);
        expect(find.text('최종 인식 신뢰도'), findsNothing);
        expect(find.text('OpenCV 검출'), findsNothing);
        expect(find.text('YOLO 보조 확인'), findsNothing);
        expect(find.text('교차 검증 결과'), findsNothing);
        expect(find.text('%'), findsNothing);
      },
    );

    // -------------------------------------------------------------
    // TEST I: ObjectInspectorView with SUSPICIOUS node shows [맞음] and [수정]
    // -------------------------------------------------------------
    testWidgets(
      'TEST I: ObjectInspectorView with SUSPICIOUS node shows [맞음] and [수정] action buttons',
      (tester) async {
        bool matched = false;
        bool editToggled = false;

        final suspiciousNode = ReviewNodeItem(
          id: 'suspicious_xfmr',
          className: 'transformer',
          bbox: [150.0, 150.0, 50.0, 50.0],
          confidence: 0.58,
          source: 'yolo_secondary',
          reviewStatus: 'SUSPICIOUS',
          reviewReasons: ['심볼 인식 신뢰도가 기준치(70%)보다 낮음'],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ObjectInspectorView(
                  node: suspiciousNode,
                  isEditExpanded: false,
                  onMatch: () {
                    matched = true;
                  },
                  onEditToggle: () {
                    editToggled = true;
                  },
                ),
              ),
            ),
          ),
        );

        // Status label is "확인 필요"
        expect(find.text("확인 필요"), findsOneWidget);
        // Review reason is displayed
        expect(find.textContaining("심볼 인식 신뢰도가 기준치"), findsOneWidget);

        // [맞음] button exists and works
        final matchBtn = find.byKey(const ValueKey('ObjectMatchButton'));
        expect(matchBtn, findsOneWidget);
        expect(find.text("맞음"), findsOneWidget);
        await tester.tap(matchBtn);
        expect(matched, isTrue);

        // [수정] button exists and works
        final editBtn = find.byKey(const ValueKey('ObjectEditButton'));
        expect(editBtn, findsOneWidget);
        expect(find.text("수정"), findsOneWidget);
        await tester.tap(editBtn);
        expect(editToggled, isTrue);
      },
    );

    // -------------------------------------------------------------
    // TEST J: Object review screen has 0 visible widgets for "정상 객체 일괄 승인" and "승인하고 다음"
    // -------------------------------------------------------------
    testWidgets(
      'TEST J: Object Review screen has 0 visible widgets for legacy batch or sequential approval',
      (tester) async {
        final normalNode = ReviewNodeItem(
          id: 'bus_clean_101',
          className: 'bus',
          bbox: [200.0, 200.0, 100.0, 20.0],
          confidence: 0.99,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              bottomNavigationBar: Container(
                padding: const EdgeInsets.all(12),
                child: ElevatedButton(
                  key: const ValueKey('ObjectCompleteButton'),
                  onPressed: () {},
                  child: const Text("객체 검수 완료"),
                ),
              ),
              body: ObjectInspectorView(
                node: normalNode,
                onMatch: () {},
                onEditToggle: () {},
              ),
            ),
          ),
        );

        // 0 legacy approval widgets visible
        expect(find.textContaining("정상 객체 일괄 승인"), findsNothing);
        expect(find.textContaining("정상 객체 전체 승인"), findsNothing);
        expect(find.textContaining("승인하고 다음"), findsNothing);

        // Only the gate completion button is present
        expect(
          find.byKey(const ValueKey('ObjectCompleteButton')),
          findsOneWidget,
        );
        expect(find.text("객체 검수 완료"), findsOneWidget);
      },
    );

    // -------------------------------------------------------------
    // Missing candidate click connection test
    // -------------------------------------------------------------
    testWidgets(
      'Missing candidate region click invokes onSelectCandidate with correct item',
      (tester) async {
        MissingCandidateItem? selectedCandidate;
        final candidate = MissingCandidateItem(
          id: 'candidate_xfmr_1',
          suspectedClass: 'transformer',
          descriptionKo: '변압기 누락 의심 영역',
          approximateRegion: [250.0, 250.0, 60.0, 60.0],
          status: 'OPEN',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ReviewOverlayView(
                  imageBytes: testImageBytes,
                  imageUrl: '',
                  originalWidth: 800,
                  originalHeight: 600,
                  nodes: const [],
                  selectedNode: null,
                  openMissingCandidates: [candidate],
                  onSelectCandidate: (c) {
                    selectedCandidate = c;
                  },
                  onSelectNode: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final candFinder = find.text('누락 의심: TRANSFORMER');
        expect(candFinder, findsOneWidget);
        await tester.tap(candFinder);

        expect(selectedCandidate?.id, 'candidate_xfmr_1');
      },
    );

    // -------------------------------------------------------------
    // TEST K: Object Review Lensy stage guidance / speech bubble has 0 legacy approval phrases and uses V2 [맞음] / [수정]
    // -------------------------------------------------------------
    test(
      'TEST K: Object Review Lensy speech bubble text has 0 legacy phrases and uses V2 [맞음] / [수정]',
      () {
        // 1. Suspicious objects present
        final suspSpeech = ObjectReviewGateEvaluator.getSpeechBubbleText(
          suspiciousCount: 1,
          unresolvedCandidatesCount: 0,
          selectedLabel: '변압기 (TR1)',
        );
        expect(suspSpeech.contains('승인하고 다음'), isFalse);
        expect(suspSpeech.contains('정상 객체 일괄 승인'), isFalse);
        expect(suspSpeech.contains('정상 객체 전체 승인'), isFalse);
        expect(suspSpeech.contains('[맞음]'), isTrue);
        expect(suspSpeech.contains('[수정]'), isTrue);
        expect(suspSpeech.contains('변압기 (TR1)'), isTrue);

        // 2. Unresolved candidates present
        final candSpeech = ObjectReviewGateEvaluator.getSpeechBubbleText(
          suspiciousCount: 0,
          unresolvedCandidatesCount: 2,
        );
        expect(candSpeech.contains('승인하고 다음'), isFalse);
        expect(candSpeech.contains('정상 객체 일괄 승인'), isFalse);
        expect(candSpeech.contains('정상 객체 전체 승인'), isFalse);
        expect(candSpeech.contains('[객체 검수 완료]'), isTrue);

        // 3. Clean state
        final cleanSpeech = ObjectReviewGateEvaluator.getSpeechBubbleText(
          suspiciousCount: 0,
          unresolvedCandidatesCount: 0,
        );
        expect(cleanSpeech.contains('승인하고 다음'), isFalse);
        expect(cleanSpeech.contains('정상 객체 일괄 승인'), isFalse);
        expect(cleanSpeech.contains('정상 객체 전체 승인'), isFalse);
        expect(cleanSpeech.contains('[객체 검수 완료]'), isTrue);
      },
    );
  });
}
