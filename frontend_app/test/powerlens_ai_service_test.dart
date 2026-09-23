import 'package:flutter_test/flutter_test.dart';

import 'package:circuit_solver/models/powerlens_assistant_context.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

void main() {
  final service = PowerLensAIService.instance;

  group('PowerLens natural-language app actions', () {
    test('maps navigation and review phrases to deterministic actions', () {
      expect(service.parseIntent('처음 화면으로 돌아가줘'), PowerLensAppAction.goHome);
      expect(service.parseIntent('처음 화면으로 다시 가볼까?'), PowerLensAppAction.goHome);
      expect(
        service.parseIntent('사진 다시 넣을래'),
        PowerLensAppAction.triggerPhotoUpload,
      );
      expect(
        service.parseIntent('나 파일에서 한번 회로도 가져올래'),
        PowerLensAppAction.triggerPhotoUpload,
      );
      expect(
        service.parseIntent('새 도면 하나 넣고 싶어'),
        PowerLensAppAction.triggerPhotoUpload,
      );
      expect(
        service.parseIntent('엑셀 다시 불러와'),
        PowerLensAppAction.triggerExcelUpload,
      );
      expect(
        service.parseIntent('캔버스로 이동해줘'),
        PowerLensAppAction.handoffToCanvas,
      );
      expect(
        service.parseIntent('샘플 도면 불러줘'),
        PowerLensAppAction.loadSampleDiagram,
      );
      expect(
        service.parseIntent('다음 단계로 가자'),
        PowerLensAppAction.goToNextStage,
      );
      expect(
        service.parseIntent('다음에 뭐 해?'),
        PowerLensAppAction.explainCurrentStage,
      );
      expect(
        service.parseIntent('이 단계에서 뭘 해야 해?'),
        PowerLensAppAction.explainCurrentStage,
      );
      expect(
        service.parseIntent('문제 있는 것만 보여줘'),
        PowerLensAppAction.showReviewIssues,
      );
      expect(
        service.parseIntent('그럼 다음 거 보자'),
        PowerLensAppAction.goToNextStage,
      );
      expect(
        service.parseIntent('이제 계산 한번 해보자'),
        PowerLensAppAction.runPowerFlow,
      );
      expect(
        service.parseIntent('계산 진행'),
        PowerLensAppAction.runPowerFlow,
      );
      expect(
        service.parseIntent('결과 보여줘'),
        PowerLensAppAction.showPowerFlowResults,
      );
    });

    test(
      'uses explicit result-display actions instead of ambiguous toggles',
      () {
        expect(service.parseIntent('조류계산 해줘'), PowerLensAppAction.runPowerFlow);
        expect(
          service.parseIntent('흐름 방향 보여줘'),
          PowerLensAppAction.showFlowDirection,
        );
        expect(
          service.parseIntent('수치 숨겨줘'),
          PowerLensAppAction.hideValueLabels,
        );
        expect(service.resolveIntentActions('숫자는 치우고 흐름만 보여줘'), [
          PowerLensAppAction.hideValueLabels,
          PowerLensAppAction.showFlowDirection,
        ]);
        expect(service.resolveIntentActions('화살표만 보여줘'), [
          PowerLensAppAction.hideValueLabels,
          PowerLensAppAction.showFlowDirection,
        ]);
      },
    );

    test('uses the review stage to resolve an implicit approval', () {
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
      );
      expect(service.resolveIntentActions('이거 괜찮아 보이는데?', context), [
        PowerLensAppAction.approveCurrentAndNext,
      ]);
      expect(service.resolveIntentActions('넌 뭘 할 수 있어?'), [
        PowerLensAppAction.explainCurrentStage,
      ]);
      expect(service.resolveIntentActions('나 이제 뭐 하면 돼?'), [
        PowerLensAppAction.explainCurrentStage,
      ]);
    });

    test('separates connection overview, lines-only, and sequential review', () {
      const context = PowerLensAssistantContext(
        currentScreen: 'REVIEW_PAGE',
        workflowStage: 'CONNECTION_REVIEW',
      );
      expect(service.resolveIntentActions('전체 다 봐줘', context), [
        PowerLensAppAction.connectionFullReview,
      ]);
      expect(service.resolveIntentActions('선로만 집중해줘', context), [
        PowerLensAppAction.connectionLinesOnly,
      ]);
      expect(service.resolveIntentActions('다음 선 보여줘', context), [
        PowerLensAppAction.connectionNextLine,
      ]);
      expect(service.resolveIntentActions('객체 검수 완료해줘', context), [
        PowerLensAppAction.goToNextStage,
      ]);
    });
  });

  test('serializes actual circuit state for the agent request', () {
    const context = PowerLensAssistantContext(
      currentScreen: 'REVIEW_PAGE',
      workflowStage: 'CONNECTION_REVIEW',
      documentId: 'doc-1',
      hasDiagram: true,
      totalObjects: 1,
      totalConnections: 1,
      selectedNode: {'id': 'bus_1', 'class': 'bus'},
      workingNodes: [
        {'id': 'bus_1', 'class': 'bus', 'review_status': 'CONFIRMED'},
      ],
      workingLines: [
        {
          'line_id': 'line_1',
          'connected_to': ['bus_1', 'bus_2'],
        },
      ],
      topologyIssues: [
        {'code': 'isolated_subgraph', 'severity': 'error'},
      ],
      currentBlockers: ['토폴로지 오류 1건'],
    );

    final json = context.toJson();

    expect(json['working_nodes'], hasLength(1));
    expect(json['working_lines'], hasLength(1));
    expect(json['selected_node']['id'], 'bus_1');
    expect(json['topology_issues'], hasLength(1));
    expect(json['current_blockers'], ['토폴로지 오류 1건']);
  });
}
