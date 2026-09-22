import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/models/review_models.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';
import 'package:circuit_solver/widgets/powerlens_ai/glowing_target_wrapper.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_ai_panel.dart';

void main() {
  final service = PowerLensAIService.instance;

  group('PowerLens Glowing Highlight & Intent Tests', () {
    tearDown(() {
      service.clearHighlight();
    });

    test('natural language queries asking what to do resolve to explainCurrentStage', () {
      expect(service.parseIntent('다음에 뭐 해?'), PowerLensAppAction.explainCurrentStage);
      expect(service.parseIntent('지금 뭐 해야 돼?'), PowerLensAppAction.explainCurrentStage);
      expect(service.parseIntent('어디 눌러야 돼?'), PowerLensAppAction.explainCurrentStage);
      expect(service.parseIntent('어디 해야 돼?'), PowerLensAppAction.explainCurrentStage);
      expect(service.parseIntent('어디 눌러?'), PowerLensAppAction.explainCurrentStage);
    });

    test('determineTargetForContext resolves appropriate target per workflow stage', () {
      // Object Review with unreviewed nodes
      const objCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'object_review',
        workingNodes: [
          {'id': 'B1', 'status': 'SUSPICIOUS'},
          {'id': 'G1', 'status': 'PENDING'},
        ],
      );
      expect(service.determineTargetForContext(objCtx), 'object_approve');

      // Object Review with all confirmed
      const objDoneCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'object_review',
        workingNodes: [
          {'id': 'B1', 'status': 'CONFIRMED'},
        ],
      );
      expect(service.determineTargetForContext(objDoneCtx), 'object_gate');

      // Bus Mapping with unapproved bus
      const busCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'bus_mapping',
        workingNodes: [
          {'id': 'B1', 'className': 'bus', 'status': 'PENDING'},
        ],
      );
      expect(service.determineTargetForContext(busCtx), 'bus_input');

      // Connection Review with unapproved line
      const connCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'connection_review',
        workingLines: [
          {'id': 'L1', 'status': 'PENDING'},
        ],
      );
      expect(service.determineTargetForContext(connCtx), 'connection_priority');

      // Verified Final without Excel
      const finalNoExcelCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'verified_final',
        excelLoaded: false,
      );
      expect(service.determineTargetForContext(finalNoExcelCtx), 'final_excel_upload');

      // Verified Final with Excel
      const finalWithExcelCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'verified_final',
        excelLoaded: true,
      );
      expect(service.determineTargetForContext(finalWithExcelCtx), 'final_canvas_handoff');

      // CAD canvas empty
      const cadEmptyCtx = PowerLensAssistantContext(
        currentScreen: 'MAIN_CANVAS',
        hasDiagram: false,
        totalObjects: 0,
      );
      expect(service.determineTargetForContext(cadEmptyCtx), 'home_upload');

      // Uppercase workflowStage verification (as passed by review_page.dart)
      const objUpperCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        workingNodes: [
          {'id': 'B1', 'status': 'CONFIRMED'},
        ],
      );
      expect(service.determineTargetForContext(objUpperCtx), 'object_gate');

      const busUpperCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'BUS_MAPPING',
        workingNodes: [
          {'id': 'B1', 'className': 'bus', 'status': 'PENDING'},
        ],
      );
      expect(service.determineTargetForContext(busUpperCtx), 'bus_input');

      const connUpperCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
        workingLines: [
          {'id': 'L1', 'status': 'PENDING'},
        ],
      );
      expect(service.determineTargetForContext(connUpperCtx), 'connection_priority');

      const finalUpperCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'FINAL',
        excelLoaded: false,
      );
      expect(service.determineTargetForContext(finalUpperCtx), 'final_excel_upload');

      // Clean objects (0 suspicious, unreviewed nodes exist) guides user to batch approve
      const cleanObjCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'object_review',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 0,
        workingNodes: [
          {'id': 'B1', 'status': 'DETECTED'},
          {'id': 'G1', 'status': 'DETECTED'},
        ],
      );
      expect(service.determineTargetForContext(cleanObjCtx), 'object_batch_approve');
    });

    test('resolveIntentActions handles approveAllClean command vs how-to question', () {
      const objCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'object_review',
      );
      // Explicit commands trigger execution
      expect(service.resolveIntentActions('일괄 승인해줘', objCtx), [PowerLensAppAction.approveAllClean]);
      expect(service.resolveIntentActions('정상 객체 전체 승인', objCtx), [PowerLensAppAction.approveAllClean]);
      expect(service.resolveIntentActions('한 번에 다 승인', objCtx), [PowerLensAppAction.approveAllClean]);

      // How-to / Where questions resolve to explainCurrentStage (guidance + glowing highlight, NO auto execution)
      expect(service.resolveIntentActions('전체 승인할려면 뭐눌러야해??', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('일괄 승인은 어디 눌러?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('전체 승인 어떻게 해?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('조류계산 어디서 해?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('엑셀 파일 어디서 올려?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('다 잘됐을경우 뭐 눌러?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('모두 정상이면 어디 눌러?', objCtx), [PowerLensAppAction.explainCurrentStage]);
      expect(service.resolveIntentActions('일괄승인 버튼 그거 어디 있어?', objCtx), [PowerLensAppAction.explainCurrentStage]);
    });

    test('triggerHighlight updates activeHighlightTarget and clearHighlight resets it', () {
      service.clearHighlight();
      expect(service.activeHighlightTarget.value, isNull);

      service.triggerHighlight('object_approve');
      expect(service.activeHighlightTarget.value, 'object_approve');

      service.clearHighlight();
      expect(service.activeHighlightTarget.value, isNull);
    });

    testWidgets('GlowingTargetWrapper renders child and shows sparkle badge when active', (tester) async {
      service.clearHighlight();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlowingTargetWrapper(
              targetId: 'test_button',
              guideLabel: '✨ 여기를 확인하세요!',
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('테스트 버튼'),
              ),
            ),
          ),
        ),
      );

      // Inactive: child text is visible, sparkle badge is not shown
      expect(find.text('테스트 버튼'), findsOneWidget);
      expect(find.text('✨ 여기를 확인하세요!'), findsNothing);

      // Trigger highlight
      service.triggerHighlight('test_button');
      await tester.pump();

      // Active: sparkle badge appears
      expect(find.text('✨ 여기를 확인하세요!'), findsOneWidget);

      // Deactivate
      service.clearHighlight();
      await tester.pump();

      expect(find.text('✨ 여기를 확인하세요!'), findsNothing);
    });

    test('PowerLensAIService panelOffset persists and can be reset', () {
      expect(service.panelOffset, Offset.zero);
      service.panelOffset = const Offset(120, -80);
      expect(service.panelOffset, const Offset(120, -80));
      service.resetPanelOffset();
      expect(service.panelOffset, Offset.zero);
    });

    testWidgets('PowerLensAIPanel displays drag handle and updates position on drag', (tester) async {
      service.resetPanelOffset();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  right: 20,
                  bottom: 70,
                  child: PowerLensAIPanel(
                    assistantContext: const PowerLensAssistantContext(
                      currentScreen: 'HOME',
                      workflowStage: 'home',
                    ),
                    onClose: () {},
                    isMobile: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Drag indicator is rendered
      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
      expect(find.text('Lensy AI'), findsOneWidget);

      // Initially, no reset button is shown because offset is zero
      expect(find.byIcon(Icons.restart_alt), findsNothing);

      // Drag the header
      final headerFinder = find.text('Lensy AI');
      await tester.drag(headerFinder, const Offset(-100, -50));
      await tester.pumpAndSettle();

      // Service offset is updated and reset button appears
      expect(service.panelOffset.dx, lessThan(-50.0));
      expect(service.panelOffset.dy, lessThan(-20.0));
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);

      // Tap reset button
      await tester.tap(find.byIcon(Icons.restart_alt));
      await tester.pumpAndSettle();

      expect(service.panelOffset, Offset.zero);
      expect(find.byIcon(Icons.restart_alt), findsNothing);

      // Drag again and test double-tap to reset
      await tester.drag(headerFinder, const Offset(-60, -40));
      await tester.pumpAndSettle();
      expect(service.panelOffset.dx, lessThan(0.0));

      // Double tap on header area
      await tester.tap(headerFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(headerFinder);
      await tester.pumpAndSettle();

      expect(service.panelOffset, Offset.zero);
    });

    test('Negative issue queries resolve to explainCurrentStage in review stage', () {
      const objCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'object_review',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 0,
      );

      expect(
        service.resolveIntentActions('검토 필요한 항목 없는데도 이러잖아', objCtx),
        contains(PowerLensAppAction.explainCurrentStage),
      );
      expect(
        service.resolveIntentActions('검토 필요한 항목 없는데?', objCtx),
        contains(PowerLensAppAction.explainCurrentStage),
      );
      expect(
        service.resolveIntentActions('문제 없어', objCtx),
        contains(PowerLensAppAction.explainCurrentStage),
      );
    });

    testWidgets('PowerLensAIPanel shows dynamic action chip based on issue counts', (tester) async {
      // 1. When 0 issues exist in object review: chip says '객체 검수 완료하기'
      const zeroIssueCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(
              assistantContext: zeroIssueCtx,
              onClose: () {},
              isMobile: false,
            ),
          ),
        ),
      );

      expect(find.text('객체 검수 완료하기'), findsAtLeastNWidgets(1));
      expect(find.textContaining('검토 필요 항목'), findsNothing);

      // 2. When issues exist in object review: chip says '검토 필요 항목'
      const hasIssueCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        suspiciousObjects: 2,
        unresolvedMissingCandidates: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PowerLensAIPanel(
              assistantContext: hasIssueCtx,
              onClose: () {},
              isMobile: false,
            ),
          ),
        ),
      );

      expect(find.textContaining('검토 필요 항목'), findsAtLeastNWidgets(1));
    });

    test('ReviewLineItem and ReviewNodeItem value equality and indexOf work by ID', () {
      final lineA = ReviewLineItem(
        lineId: 'L17',
        connectedTo: ['bus_24', 'trans_1'],
        path: [[0, 0], [10, 10]],
        reviewStatus: 'CONFIRMED',
      );
      final lineB = ReviewLineItem(
        lineId: 'L17',
        connectedTo: ['bus_24', 'trans_1'],
        path: [[0, 0], [10, 10]],
        reviewStatus: 'AMBIGUOUS',
      );
      final lineC = ReviewLineItem(
        lineId: 'L18',
        connectedTo: ['bus_24', 'bus_3'],
        path: [[0, 0], [20, 20]],
        reviewStatus: 'DETECTED',
      );

      // Value equality by lineId
      expect(lineA == lineB, isTrue);
      expect(lineA.hashCode == lineB.hashCode, isTrue);
      expect(lineA == lineC, isFalse);

      final lineList = [lineA, lineC];
      expect(lineList.indexOf(lineB), 0);
      expect(lineList.contains(lineB), isTrue);

      final nodeA = ReviewNodeItem(
        id: 'bus_24',
        className: 'bus',
        bbox: [0, 0, 10, 10],
        confidence: 0.95,
        source: 'yolo',
      );
      final nodeB = ReviewNodeItem(
        id: 'bus_24',
        className: 'bus',
        bbox: [1, 1, 10, 10],
        confidence: 0.99,
        source: 'human',
      );
      expect(nodeA == nodeB, isTrue);
      expect(nodeA.hashCode == nodeB.hashCode, isTrue);
    });

    test('Connection review sequential navigation safely handles filter exhaustion and fallbacks', () {
      final line1 = ReviewLineItem(
        lineId: 'L1',
        connectedTo: ['bus_1', 'bus_2'],
        path: [],
        reviewStatus: 'AMBIGUOUS',
      );
      final line2 = ReviewLineItem(
        lineId: 'L2',
        connectedTo: ['bus_2', 'bus_3'],
        path: [],
        reviewStatus: 'CONFIRMED',
      );
      final line3 = ReviewLineItem(
        lineId: 'L3',
        connectedTo: ['bus_3', 'bus_4'],
        path: [],
        reviewStatus: 'CONFIRMED',
      );

      final workingLines = [line1, line2, line3];
      String connFilterStatus = 'AMBIGUOUS';

      List<ReviewLineItem> getFilteredLines() {
        if (connFilterStatus == 'AMBIGUOUS') {
          return workingLines.where((l) => l.reviewStatus == 'AMBIGUOUS').toList();
        }
        return workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
      }

      ReviewLineItem? selectedLine = line1;

      // 1. Initially, line1 is AMBIGUOUS, so filtered lines has 1 item
      var currentFiltered = getFilteredLines();
      expect(currentFiltered.length, 1);
      expect(currentFiltered.first.lineId, 'L1');

      // 2. User confirms line1 -> status becomes CONFIRMED
      line1.reviewStatus = 'CONFIRMED';
      if (connFilterStatus == 'AMBIGUOUS' && !workingLines.any((l) => l.reviewStatus == 'AMBIGUOUS')) {
        connFilterStatus = 'ALL';
      }

      // 3. Fallback logic: filtered lines auto-switches to ALL, avoiding 0-length freeze
      currentFiltered = getFilteredLines();
      expect(connFilterStatus, 'ALL');
      expect(currentFiltered.length, 3);

      // 4. Moving next from L1 safely advances to L2
      int currentIdx = selectedLine != null
          ? currentFiltered.indexWhere((l) => l.lineId == selectedLine!.lineId)
          : -1;
      expect(currentIdx, 0);
      int nextIdx = (currentIdx + 1) % currentFiltered.length;
      selectedLine = currentFiltered[nextIdx];
      expect(selectedLine.lineId, 'L2');

      // 5. Moving next from L2 safely advances to L3
      currentIdx = currentFiltered.indexWhere((l) => l.lineId == selectedLine!.lineId);
      nextIdx = (currentIdx + 1) % currentFiltered.length;
      selectedLine = currentFiltered[nextIdx];
      expect(selectedLine.lineId, 'L3');

      // 6. Moving previous from L3 goes back to L2
      currentIdx = currentFiltered.indexWhere((l) => l.lineId == selectedLine!.lineId);
      int prevIdx = (currentIdx - 1 + currentFiltered.length) % currentFiltered.length;
      selectedLine = currentFiltered[prevIdx];
      expect(selectedLine.lineId, 'L2');

      // 7. Moving previous from L1 wraps around to L3
      selectedLine = line1;
      currentIdx = currentFiltered.indexWhere((l) => l.lineId == selectedLine!.lineId);
      prevIdx = (currentIdx - 1 + currentFiltered.length) % currentFiltered.length;
      selectedLine = currentFiltered[prevIdx];
      expect(selectedLine.lineId, 'L3');
    });

    test('Missing candidate queries and unresolved states correctly prioritize missing_candidates highlight target', () {
      const missingCandidateCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 1,
        workingNodes: [
          {'id': 'B1', 'status': 'CONFIRMED'},
          {'id': 'G1', 'status': 'CONFIRMED'},
        ],
      );

      // When unresolved candidates exist in object review, default target must be missing_candidates
      expect(service.determineTargetForContext(missingCandidateCtx), 'missing_candidates');

      // Stage progression queries with unresolved candidates must direct user to missing_candidates
      expect(service.determineTargetForContext(missingCandidateCtx, query: '다음 단계로 가고 싶어'), 'missing_candidates');
      expect(service.determineTargetForContext(missingCandidateCtx, query: '왜 다음으로 못 넘어가?'), 'missing_candidates');

      // User questions specifically about missing candidates, transformers, or dismiss
      expect(service.determineTargetForContext(missingCandidateCtx, query: '누락후보를 볼려니깐 안눌러져서 확인을할수없어'), 'missing_candidates');
      expect(service.determineTargetForContext(missingCandidateCtx, query: '변압기 가없어서 누락후보라 되는거같은데'), 'missing_candidates');
      expect(service.determineTargetForContext(missingCandidateCtx, query: '문제없음 어떻게 해?'), 'missing_candidates');
    });

    test('MissingCandidateItem dismissal marks candidate as DISMISSED_BY_HUMAN', () {
      final cand = MissingCandidateItem(
        id: 'cand_tr_1',
        suspectedClass: 'transformer',
        descriptionKo: '모선 사이에 연결된 변압기가 감지되지 않았습니다.',
        status: 'OPEN',
      );

      expect(cand.status, 'OPEN');
      cand.status = 'DISMISSED_BY_HUMAN';
      expect(cand.status, 'DISMISSED_BY_HUMAN');

      // When all candidates are dismissed, unresolved count becomes 0
      final candidateList = [cand];
      final openCount = candidateList.where((c) => c.status == 'OPEN').length;
      expect(openCount, 0);

      const resolvedCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 0,
        workingNodes: [
          {'id': 'B1', 'status': 'CONFIRMED'},
        ],
      );
      expect(service.determineTargetForContext(resolvedCtx), 'object_gate');
    });

    test('Expanded glowing target catalog covers 25+ diverse user interaction points via triggerHighlight', () {
      final targets = [
        'phase_step_1',
        'phase_step_2',
        'phase_step_3',
        'phase_step_4',
        'reset_to_beginning',
        'node_reject',
        'node_prev',
        'node_next',
        'node_class_tile',
        'line_reject',
        'line_skip',
        'line_prev',
        'line_next',
        'default_excel_btn',
        'excel_mismatch_btn',
        'palette_bus',
        'palette_line',
        'palette_generator',
        'palette_load',
        'palette_transformer',
        'guide_dialog',
        'canvas_clear',
        'undo_btn',
        'line_straighten',
        'cad_reopen_review',
        'cad_excel_import',
      ];
      for (final t in targets) {
        service.triggerHighlight(t);
        expect(service.activeHighlightTarget.value, t);
      }
      service.clearHighlight();
      expect(service.activeHighlightTarget.value, isNull);
    });

    test('AI companion provides explicit batch approve guidance when objects are clean', () async {
      const cleanCtx = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'OBJECT_REVIEW',
        suspiciousObjects: 0,
        unresolvedMissingCandidates: 0,
        workingNodes: [
          {'id': 'B1', 'status': 'DETECTED'},
          {'id': 'G1', 'status': 'DETECTED'},
        ],
      );

      await service.sendMessage('다 잘됐을경우 뭐 눌러?', cleanCtx);
      final lastMsg = service.messages.last.text;
      expect(lastMsg, contains('정상 객체 일괄 승인'));
      expect(lastMsg, contains('누르면 됩니다'));

      // Also verify quick actions suggest batch approval when nodes are unconfirmed
      final quickActions = service.messages.last.suggestedActions;
      expect(quickActions, contains('정상 객체 일괄 승인'));
    });
  });
}


