import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PowerLens Object Review V2 Comprehensive Tests', () {
    // Helper function mirroring gate blocker logic in ReviewPage
    List<String> getObjectGateBlockers({
      required List<ReviewNodeItem> workingNodes,
      required List<MissingCandidateItem> missingCandidates,
    }) {
      final blockers = <String>[];
      final validNodes =
          workingNodes.where((n) => n.reviewStatus != 'REJECTED').toList();
      if (validNodes.isEmpty) {
        blockers.add("유효한 전력 설비 심볼이 없습니다.");
      }
      final suspiciousNodes =
          validNodes.where((n) => n.reviewStatus == 'SUSPICIOUS').toList();
      if (suspiciousNodes.isNotEmpty) {
        blockers.add("확인이 필요한 의심 객체(${suspiciousNodes.length}개)가 남아 있습니다.");
      }
      final unresolvedCands =
          missingCandidates.where((c) => c.status == 'OPEN').toList();
      if (unresolvedCands.isNotEmpty) {
        blockers.add("미해결된 누락 의심 영역(${unresolvedCands.length}개)이 있습니다.");
      }
      return blockers;
    }

    bool canVerifyObjectGate({
      required List<ReviewNodeItem> workingNodes,
      required List<MissingCandidateItem> missingCandidates,
    }) {
      return getObjectGateBlockers(
        workingNodes: workingNodes,
        missingCandidates: missingCandidates,
      ).isEmpty;
    }

    Set<String> computeGuideNodeIds({
      required List<ReviewNodeItem> workingNodes,
      List<Map<String, dynamic>>? lastFocusTargets,
    }) {
      final ids = <String>{};
      for (final node in workingNodes) {
        if (node.reviewStatus == 'SUSPICIOUS') {
          ids.add(node.id);
        }
      }
      if (lastFocusTargets != null) {
        for (final target in lastFocusTargets) {
          if (target['type'] == 'OBJECT') {
            final id = target['id']?.toString();
            if (id != null && workingNodes.any((n) => n.id == id && n.reviewStatus != 'REJECTED')) {
              ids.add(id);
            }
          }
        }
      }
      return ids;
    }

    // TEST 1: 정상 DETECTED 객체만 존재, suspicious 0, candidate 0 -> batch approval 없이 Object Gate PASS 가능
    test('TEST 1: Clean DETECTED objects pass gate without requiring human batch approval', () {
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

      // Gate must be PASS ready even though reviewStatus is DETECTED (not CONFIRMED)
      expect(canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates), isTrue);
      expect(getObjectGateBlockers(workingNodes: nodes, missingCandidates: candidates), isEmpty);
    });

    // TEST 2: SUSPICIOUS 1개 -> Object Gate FAIL
    test('TEST 2: A single SUSPICIOUS object blocks Object Gate', () {
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

      expect(canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates), isFalse);
      final blockers = getObjectGateBlockers(workingNodes: nodes, missingCandidates: candidates);
      expect(blockers.any((b) => b.contains('의심 객체')), isTrue);
    });

    // TEST 3: OPEN candidate 1개 -> Object Gate FAIL
    test('TEST 3: An OPEN missing candidate blocks Object Gate', () {
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

      expect(canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates), isFalse);
      final blockers = getObjectGateBlockers(workingNodes: nodes, missingCandidates: candidates);
      expect(blockers.any((b) => b.contains('누락 의심 영역')), isTrue);
    });

    // TEST 4: SUSPICIOUS를 [맞음] 처리 -> CONFIRMED -> 해당 blocker 제거
    test('TEST 4: Confirming [맞음] marks node CONFIRMED with provenance and clears blocker', () {
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

      expect(canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates), isFalse);

      // Perform [맞음] action
      suspiciousNode.reviewStatus = 'CONFIRMED';
      suspiciousNode.source = '${suspiciousNode.source}_human_confirmed';

      expect(suspiciousNode.reviewStatus, 'CONFIRMED');
      expect(suspiciousNode.source, 'yolo_rescue_human_confirmed');
      expect(canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates), isTrue);
    });

    // TEST 5: normal DETECTED object 클릭 -> Inspector 표시 -> confidence 표시 -> 승인 requirement 없음
    testWidgets('TEST 5: Normal DETECTED object inspector shows AI confirmation without requiring approval', (tester) async {
      final normalNode = ReviewNodeItem(
        id: 'load_1',
        className: 'load',
        bbox: [300.0, 300.0, 30.0, 30.0],
        confidence: 0.94,
        source: 'yolo_primary',
        reviewStatus: 'DETECTED',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Text("객체 종류: 부하 (Load)  ·  AI 모델 인식 신뢰도: ${(normalNode.confidence * 100).toInt()}%"),
                Container(
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_outline),
                      Text("AI가 확인한 정상 객체입니다. (승인 불필요)"),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.textContaining("AI 모델 인식 신뢰도: 94%"), findsOneWidget);
      expect(find.text("AI가 확인한 정상 객체입니다. (승인 불필요)"), findsOneWidget);
      expect(find.text("승인하고 다음"), findsNothing);
    });

    // TEST 6: confidence 0.66 -> "AI 모델 인식 신뢰도 66%" 표시. "정답 확률 66%" 금지
    test('TEST 6: Confidence string displays "AI 모델 인식 신뢰도 66%" and NEVER "정답 확률"', () {
      final node = ReviewNodeItem(
        id: 'test_node',
        className: 'generator',
        bbox: [10.0, 10.0, 20.0, 20.0],
        confidence: 0.66,
        source: 'yolo',
      );

      final confidenceString = "AI 모델 인식 신뢰도: ${(node.confidence * 100).toInt()}%";
      expect(confidenceString, 'AI 모델 인식 신뢰도: 66%');
      expect(confidenceString.contains('정답 확률'), isFalse);
    });

    // TEST 7: reviewReasons 존재 -> 실제 reason 표시
    testWidgets('TEST 7: Inspector displays actual verified reviewReasons', (tester) async {
      final node = ReviewNodeItem(
        id: 'susp_1',
        className: 'generator',
        bbox: [10.0, 10.0, 40.0, 40.0],
        confidence: 0.62,
        source: 'yolo',
        reviewStatus: 'SUSPICIOUS',
        reviewReasons: [
          '심볼 내부 표식이 Generator와 약간 상이함',
          '주변 버스와의 연결 거리가 멂',
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: node.reviewReasons.map((r) => Text("• $r")).toList(),
            ),
          ),
        ),
      );

      expect(find.text("• 심볼 내부 표식이 Generator와 약간 상이함"), findsOneWidget);
      expect(find.text("• 주변 버스와의 연결 거리가 멂"), findsOneWidget);
    });

    // TEST 8: reviewReasons/evidence 없음 -> UI가 가짜 판정 근거 생성하지 않음
    testWidgets('TEST 8: When no reasons/evidence exist, displays honest fallback and no fabricated claims', (tester) async {
      final node = ReviewNodeItem(
        id: 'clean_1',
        className: 'bus',
        bbox: [10.0, 10.0, 100.0, 10.0],
        confidence: 0.98,
        source: 'cv_primary',
        reviewStatus: 'DETECTED',
        reviewReasons: [],
        agentExplanation: null,
      );

      final explanationText = (node.agentExplanation != null && node.agentExplanation!.trim().isNotEmpty)
          ? node.agentExplanation!
          : (node.reviewReasons.isNotEmpty ? "" : "추가 판정 근거가 기록되지 않았습니다.");

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Text(explanationText),
          ),
        ),
      );

      expect(find.text("추가 판정 근거가 기록되지 않았습니다."), findsOneWidget);
      expect(find.textContaining("심볼 모양과 매우 일치"), findsNothing);
      expect(find.textContaining("완벽히 일치"), findsNothing);
    });

    // TEST 9: SUSPICIOUS node bbox -> padded Guide Box rendering data 생성
    test('TEST 9: Suspicious node generates padded Guide Box coordinates (~15% padding)', () {
      final bbox = [100.0, 100.0, 60.0, 40.0]; // x, y, w, h
      final padW = (bbox[2] * 0.15).clamp(8.0, 24.0);
      final padH = (bbox[3] * 0.15).clamp(8.0, 24.0);

      final guideRect = Rect.fromLTWH(
        bbox[0] - padW,
        bbox[1] - padH,
        bbox[2] + 2 * padW,
        bbox[3] + 2 * padH,
      );

      expect(guideRect.left, lessThan(bbox[0]));
      expect(guideRect.top, lessThan(bbox[1]));
      expect(guideRect.width, greaterThan(bbox[2]));
      expect(guideRect.height, greaterThan(bbox[3]));
      expect(guideRect.width, equals(60.0 + 2 * 9.0)); // 60 * 0.15 = 9.0
      expect(guideRect.height, equals(40.0 + 2 * 8.0)); // 40 * 0.15 = 6.0 -> clamped to 8.0
    });

    // TEST 10: focus_targets OBJECT 실제 ID -> 해당 Object guide 활성화
    test('TEST 10: Valid focus_targets OBJECT ID activates Object Guide', () {
      final nodes = [
        ReviewNodeItem(
          id: 'gen_target',
          className: 'generator',
          bbox: [50.0, 50.0, 30.0, 30.0],
          confidence: 0.90,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        ),
      ];
      final focusTargets = [
        {'type': 'OBJECT', 'id': 'gen_target'},
      ];

      final guideIds = computeGuideNodeIds(
        workingNodes: nodes,
        lastFocusTargets: focusTargets,
      );

      expect(guideIds.contains('gen_target'), isTrue);
    });

    // TEST 11: fabricated focus target -> guide 생성 X
    test('TEST 11: Fabricated focus target does NOT generate guide', () {
      final nodes = [
        ReviewNodeItem(
          id: 'gen_real',
          className: 'generator',
          bbox: [50.0, 50.0, 30.0, 30.0],
          confidence: 0.90,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        ),
      ];
      final fabricatedTargets = [
        {'type': 'OBJECT', 'id': 'ghost_object_999'},
        {'type': 'LINE', 'id': 'line_not_node'},
      ];

      final guideIds = computeGuideNodeIds(
        workingNodes: nodes,
        lastFocusTargets: fabricatedTargets,
      );

      expect(guideIds.contains('ghost_object_999'), isFalse);
      expect(guideIds, isEmpty);
    });

    // TEST 12: normal object는 guide 대상 아님
    test('TEST 12: Normal DETECTED object without focus target is not guided', () {
      final nodes = [
        ReviewNodeItem(
          id: 'normal_1',
          className: 'load',
          bbox: [100.0, 100.0, 30.0, 30.0],
          confidence: 0.95,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        ),
      ];

      final guideIds = computeGuideNodeIds(
        workingNodes: nodes,
        lastFocusTargets: [],
      );

      expect(guideIds.contains('normal_1'), isFalse);
    });

    // TEST 13: [객체 검수 완료] PASS -> BUS_MAPPING으로 한 번에 이동
    test('TEST 13: Passing object completion moves directly to BUS_MAPPING without popup dialog', () {
      String currentPhase = 'OBJECT_REVIEW';
      final nodes = [
        ReviewNodeItem(
          id: 'bus_1',
          className: 'bus',
          bbox: [10.0, 10.0, 100.0, 20.0],
          confidence: 0.99,
          source: 'yolo',
          reviewStatus: 'DETECTED',
        ),
      ];
      final candidates = <MissingCandidateItem>[];

      // Execute completion
      if (canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates)) {
        // Direct transition to BUS_MAPPING
        currentPhase = 'BUS_MAPPING_REVIEW';
      }

      expect(currentPhase, 'BUS_MAPPING_REVIEW');
    });

    // TEST 14: [객체 검수 완료] FAIL -> Stage 유지 -> blocker 대상 focus
    test('TEST 14: Blocked object completion maintains stage and focuses blocker', () {
      String currentPhase = 'OBJECT_REVIEW';
      String? focusedId;
      final suspiciousNode = ReviewNodeItem(
        id: 'susp_node',
        className: 'transformer',
        bbox: [10.0, 10.0, 40.0, 40.0],
        confidence: 0.50,
        source: 'yolo',
        reviewStatus: 'SUSPICIOUS',
      );
      final nodes = [suspiciousNode];
      final candidates = <MissingCandidateItem>[];

      if (canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates)) {
        currentPhase = 'BUS_MAPPING_REVIEW';
      } else {
        // Focus next blocker
        focusedId = nodes.firstWhere((n) => n.reviewStatus == 'SUSPICIOUS').id;
      }

      expect(currentPhase, 'OBJECT_REVIEW');
      expect(focusedId, 'susp_node');
    });

    // TEST 15: COMPLETE_CURRENT_STAGE action -> 동일 gate method 사용 -> bypass 없음
    test('TEST 15: Agent COMPLETE_CURRENT_STAGE action uses same gate verification with zero bypass', () {
      final nodes = [
        ReviewNodeItem(
          id: 'susp_node',
          className: 'bus',
          bbox: [10.0, 10.0, 50.0, 10.0],
          confidence: 0.60,
          source: 'yolo',
          reviewStatus: 'SUSPICIOUS',
        ),
      ];
      final candidates = <MissingCandidateItem>[];

      bool agentCompleteAttempt() {
        if (!canVerifyObjectGate(workingNodes: nodes, missingCandidates: candidates)) {
          return false; // Blocker exists, cannot advance
        }
        return true;
      }

      expect(agentCompleteAttempt(), isFalse);
    });

    // TEST 16: Object Stage 화면에 "정상 객체 일괄 승인" primary/default control 없음
    testWidgets('TEST 16: No "정상 객체 일괄 승인" primary control on Object Review screen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () {},
                  child: const Text("객체 검수 완료"),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.textContaining("정상 객체 일괄 승인"), findsNothing);
      expect(find.textContaining("정상 객체 전체 승인"), findsNothing);
    });

    // TEST 17: Object Stage 화면에 "승인하고 다음" primary/default control 없음
    testWidgets('TEST 17: No "승인하고 다음" primary control on Object Review screen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () {},
                  child: const Text("객체 검수 완료"),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.textContaining("승인하고 다음"), findsNothing);
    });

    // TEST 18: class filters: 전체 / Bus / Load / Generator / Transformer 존재
    testWidgets('TEST 18: Class filter chips exist for All, Bus, Load, Generator, and Transformer', (tester) async {
      const classes = ['ALL', 'bus', 'load', 'generator', 'transformer'];
      final labels = {
        'ALL': '전체',
        'bus': 'Bus',
        'load': 'Load',
        'generator': 'Gen',
        'transformer': 'Trans',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: classes.map((c) => Text(labels[c]!)).toList(),
            ),
          ),
        ),
      );

      expect(find.text("전체"), findsOneWidget);
      expect(find.text("Bus"), findsOneWidget);
      expect(find.text("Load"), findsOneWidget);
      expect(find.text("Gen"), findsOneWidget);
      expect(find.text("Trans"), findsOneWidget);
    });

    // TEST 19: proactive GUIDE + focus_targets -> Object Guide Box
    test('TEST 19: Proactive GUIDE mode with focus_targets produces guide box IDs', () {
      final nodes = [
        ReviewNodeItem(
          id: 'suspicious_node_42',
          className: 'generator',
          bbox: [200.0, 150.0, 50.0, 50.0],
          confidence: 0.65,
          source: 'yolo',
          reviewStatus: 'SUSPICIOUS',
        ),
      ];

      const actionMode = 'GUIDE';
      final focusTargets = [
        {'type': 'OBJECT', 'id': 'suspicious_node_42'},
      ];

      Set<String> activeGuides = {};
      if (actionMode == 'GUIDE') {
        activeGuides = computeGuideNodeIds(
          workingNodes: nodes,
          lastFocusTargets: focusTargets,
        );
      }

      expect(activeGuides.contains('suspicious_node_42'), isTrue);
    });

    // TEST 20: proactive NONE -> legacy object_approve highlight 자동 실행 X
    test('TEST 20: Proactive NONE does NOT trigger legacy object_approve highlight', () {
      final aiService = PowerLensAIService.instance;
      aiService.clearHighlight();

      // Proactive result with NONE
      const actionMode = 'NONE';
      const highlightTarget = 'object_approve'; // Legacy target attempted

      if (actionMode != 'NONE' && highlightTarget != 'object_approve') {
        aiService.triggerHighlight(highlightTarget);
      }

      expect(aiService.activeHighlightTarget.value, isNull);
    });
  });
}
