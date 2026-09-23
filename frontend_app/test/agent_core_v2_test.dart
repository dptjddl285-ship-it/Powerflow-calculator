import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = PowerLensAIService.instance;

  group('Agent Core V2 Action Mapping Tests', () {
    test('Action ID Mapping correctly maps canonical backend action IDs', () {
      expect(service.mapBackendActionId('RUN_POWER_FLOW'), PowerLensAppAction.runPowerFlow);
      expect(service.mapBackendActionId('SHOW_POWER_FLOW_RESULTS'), PowerLensAppAction.showPowerFlowResults);
      expect(service.mapBackendActionId('GO_HOME'), PowerLensAppAction.goHome);
      expect(service.mapBackendActionId('COMPLETE_CURRENT_STAGE'), PowerLensAppAction.goToNextStage);
      expect(service.mapBackendActionId('OPEN_EXCEL_PICKER'), PowerLensAppAction.triggerExcelUpload);
      expect(service.mapBackendActionId('OPEN_DIAGRAM_PICKER'), PowerLensAppAction.triggerPhotoUpload);
      expect(service.mapBackendActionId('LOAD_SAMPLE_DIAGRAM'), PowerLensAppAction.loadSampleDiagram);
      expect(service.mapBackendActionId('SHOW_REVIEW_ISSUES'), PowerLensAppAction.showReviewIssues);
      expect(service.mapBackendActionId('HANDOFF_TO_CANVAS'), PowerLensAppAction.handoffToCanvas);
      expect(service.mapBackendActionId('SHOW_FLOW_DIRECTION'), PowerLensAppAction.showFlowDirection);
      expect(service.mapBackendActionId('HIDE_FLOW_DIRECTION'), PowerLensAppAction.hideFlowDirection);
      expect(service.mapBackendActionId('SHOW_VALUE_LABELS'), PowerLensAppAction.showValueLabels);
      expect(service.mapBackendActionId('HIDE_VALUE_LABELS'), PowerLensAppAction.hideValueLabels);
    });

    test('Maps NO_ACTION, null, empty and unknown strings to null', () {
      expect(service.mapBackendActionId('NO_ACTION'), isNull);
      expect(service.mapBackendActionId(null), isNull);
      expect(service.mapBackendActionId(''), isNull);
      expect(service.mapBackendActionId('UNKNOWN_CUSTOM_ACTION'), isNull);
      expect(service.mapBackendActionId('DROP_TABLE'), isNull);
    });
  });

  group('Agent Core V2 Action Execution Policy Tests', () {
    PowerLensAppAction? lastDispatchedAction;
    Map<String, dynamic>? lastDispatchedParams;

    Future<bool> mockHandler(PowerLensAppAction action, Map<String, dynamic>? params) async {
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

    test('GUIDE mode illuminates highlight target but NEVER dispatches action', () async {
      final success = await service.executeBackendAction(
        actionMode: 'GUIDE',
        actionId: 'RUN_POWER_FLOW',
        highlightTarget: 'final_powerflow',
      );

      expect(success, isFalse);
      expect(lastDispatchedAction, isNull);
      expect(service.activeHighlightTarget.value, 'final_powerflow');
    });

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
  });

  group('Agent Core V2 Proactive Deduplication Tests', () {
    setUp(() {
      service.clearProactiveKeys();
    });

    test('Deduplicates proactive requests per (document_id, stage)', () {
      expect(service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'), isTrue);
      expect(service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'), isFalse);
      expect(service.shouldRequestProactive('doc_123', 'BUS_MAPPING'), isTrue);
      expect(service.shouldRequestProactive('doc_456', 'OBJECT_REVIEW'), isTrue);

      service.clearProactiveKeys();
      expect(service.shouldRequestProactive('doc_123', 'OBJECT_REVIEW'), isTrue);
    });
  });
}
