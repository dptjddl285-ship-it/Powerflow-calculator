import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/powerlens_assistant_context.dart';
import '../models/review_models.dart';
import '../widgets/powerlens_ai/powerlens_ai_message.dart';

enum PowerLensAppAction {
  goHome,
  goToNextStage,
  goToPreviousStage,
  triggerPhotoUpload,
  triggerExcelUpload,
  loadSampleDiagram,
  showReviewIssues,
  approveCurrentAndNext,
  approveAllClean,
  connectionFullReview,
  connectionLinesOnly,
  connectionNextLine,
  handoffToCanvas,
  runPowerFlow,
  showPowerFlowResults,
  toggleFlowDirection,
  showFlowDirection,
  hideFlowDirection,
  toggleValueLabels,
  showValueLabels,
  hideValueLabels,
  explainCurrentStage,
}

typedef PowerLensActionHandler =
    Future<bool> Function(
      PowerLensAppAction action,
      Map<String, dynamic>? params,
    );

class PowerLensAIService extends ChangeNotifier {
  static final PowerLensAIService _instance = PowerLensAIService._internal();
  factory PowerLensAIService() => _instance;
  static PowerLensAIService get instance => _instance;
  PowerLensAIService._internal();

  static String baseUrl = 'http://127.0.0.1:8000';

  final List<PowerLensAIMessageItem> _messages = [];
  List<PowerLensAIMessageItem> get messages => List.unmodifiable(_messages);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String _mascotState = 'idle';
  String get mascotState => _mascotState;

  String? _lastFailedQuery;
  String? get lastFailedQuery => _lastFailedQuery;

  int _requestSerial = 0;

  String? _lastNotifiedStage;
  String? get lastNotifiedStage => _lastNotifiedStage;

  /// Prevent duplicate proactive summaries per (document_id, stage)
  final Set<String> _requestedProactiveKeys = {};

  bool shouldRequestProactive(String? documentId, String stage) {
    final key = '${documentId ?? "no_doc"}_$stage';
    if (_requestedProactiveKeys.contains(key)) return false;
    _requestedProactiveKeys.add(key);
    return true;
  }

  void clearProactiveKeys() {
    _requestedProactiveKeys.clear();
  }

  String _geminiStatus =
      'LOCAL_READY'; // 'CONNECTED' | 'LOCAL_FALLBACK' | 'LOCAL_READY'
  String get geminiStatus => _geminiStatus;

  /// Target UI element currently sparkling/glowing on screen for user guidance
  final ValueNotifier<String?> activeHighlightTarget = ValueNotifier<String?>(
    null,
  );
  Timer? _highlightTimer;

  /// Focus targets received from the latest proactive summary or agent chat
  final ValueNotifier<List<Map<String, dynamic>>> focusTargetsNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  List<Map<String, dynamic>> get lastFocusTargets =>
      List.unmodifiable(focusTargetsNotifier.value);

  void setFocusTargets(List<Map<String, dynamic>> targets) {
    focusTargetsNotifier.value = List.unmodifiable(targets);
  }

  void clearFocusTargets() {
    focusTargetsNotifier.value = const [];
  }

  void removeFocusTarget(String targetId) {
    final nextTargets = focusTargetsNotifier.value
        .where((target) => target['id']?.toString() != targetId)
        .toList(growable: false);
    if (nextTargets.length != focusTargetsNotifier.value.length) {
      focusTargetsNotifier.value = nextTargets;
    }
  }

  /// User-dragged position offset for the AI chat panel (persists while app runs)
  Offset panelOffset = Offset.zero;

  void resetPanelOffset() {
    panelOffset = Offset.zero;
    notifyListeners();
  }

  void triggerHighlight(
    String target, {
    Duration duration = const Duration(seconds: 10),
  }) {
    _highlightTimer?.cancel();
    activeHighlightTarget.value = target;
    _highlightTimer = Timer(duration, () {
      if (activeHighlightTarget.value == target) {
        activeHighlightTarget.value = null;
      }
    });
  }

  void clearHighlight() {
    _highlightTimer?.cancel();
    activeHighlightTarget.value = null;
  }

  String? determineTargetForContext(
    PowerLensAssistantContext context, {
    String? query,
  }) {
    final screen = context.currentScreen.toUpperCase();
    final stage = context.workflowStage.toLowerCase();

    // Pure State-Based Fallback (Zero Keyword Dictionary).
    // All natural-language questions and intent reasoning are handled directly by Gemini LLM.
    if (screen == 'REVIEW_PAGE') {
      switch (stage) {
        case 'object_review':
          if (context.unresolvedMissingCandidates > 0) {
            return 'missing_candidates';
          }
          final hasSuspicious =
              context.suspiciousObjects > 0 ||
              context.workingNodes.any(
                (n) =>
                    n['status'] == 'SUSPICIOUS' ||
                    n['review_status'] == 'SUSPICIOUS',
              );
          if (hasSuspicious) {
            // In V2, suspicious objects are guided by on-canvas Guide Boxes, not a button highlight
            return null;
          }
          return 'object_gate';
        case 'bus_mapping':
        case 'bus_mapping_review':
          final busNodes = context.workingNodes.where(_isActiveBusMap).toList();
          final numbers = <int>[];
          final duplicates = <int>{};
          for (final b in busNodes) {
            final rawNum = b['busNumber'] ?? b['bus_number'];
            final parsedNo = rawNum is num
                ? rawNum.toInt()
                : (rawNum != null ? int.tryParse(rawNum.toString()) : null);
            if (parsedNo != null && parsedNo > 0) {
              if (numbers.contains(parsedNo)) {
                duplicates.add(parsedNo);
              } else {
                numbers.add(parsedNo);
              }
            }
          }
          final hasIssue =
              busNodes.isEmpty ||
              context.unresolvedBusNumbers > 0 ||
              context.duplicateBusNumbers > 0 ||
              busNodes.any((n) {
                final rawNum = n['busNumber'] ?? n['bus_number'];
                final parsedNo = rawNum is num
                    ? rawNum.toInt()
                    : (rawNum != null ? int.tryParse(rawNum.toString()) : null);
                final status =
                    (n['busNumberStatus'] ??
                            n['bus_number_status'] ??
                            n['status'])
                        ?.toString()
                        .toUpperCase();
                if (parsedNo == null ||
                    parsedNo <= 0 ||
                    duplicates.contains(parsedNo)) {
                  return true;
                }
                if (status == 'UNCERTAIN' || status == 'PENDING') {
                  return true;
                }
                return false;
              });
          if (hasIssue) {
            // In V2, bus issues are guided by on-canvas Bus Guide Boxes, not a button highlight
            return null;
          }
          return 'bus_gate';
        case 'connection_review':
          final lines = context.workingLines
              .map((raw) => ReviewLineItem.fromJson(raw))
              .toList();
          final blockers = ConnectionReviewGateEvaluator.getBlockers(
            workingLines: lines,
            topologyIssues: context.topologyIssues,
          );
          // Exception lines are guided by their real LINE/ISSUE focus on the
          // canvas. The only stable UI target for a clean review is the
          // single final CTA.
          return blockers.isEmpty ? 'connection_gate' : null;
        case 'verified_final':
        case 'final':
          if (!context.excelLoaded) {
            return 'final_excel_upload';
          }
          return 'final_canvas_handoff';
        default:
          return null;
      }
    } else {
      if (!context.hasDiagram && context.totalObjects == 0) {
        return 'home_upload';
      } else if (context.powerflowConverged == null) {
        return 'final_powerflow';
      } else {
        return 'result_flow';
      }
    }
  }

  Future<void> refreshProviderStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/review/provider_status'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final providerMode = data is Map
          ? data['provider_mode']?.toString().toLowerCase()
          : null;
      final nextStatus = providerMode == 'gemini' ? 'CONNECTED' : 'LOCAL_READY';
      if (_geminiStatus != nextStatus) {
        _geminiStatus = nextStatus;
        notifyListeners();
      }
    } catch (_) {
      // The companion still works in local mode when the backend is offline.
    }
  }

  void setProviderMode(String? providerMode) {
    final normalized = providerMode?.toLowerCase() ?? '';
    final nextStatus = normalized.startsWith('gemini')
        ? 'CONNECTED'
        : 'LOCAL_READY';
    if (_geminiStatus == nextStatus) return;
    _geminiStatus = nextStatus;
    notifyListeners();
  }

  // Handlers are kept as a stack so the currently visible workflow screen can
  // own the same global AI entry point without coupling the service to a page's
  // private state. The main canvas remains underneath ReviewPage and resumes
  // automatically when the review handler is unregistered.
  final List<PowerLensActionHandler> _actionHandlers = [];

  void registerActionHandler(PowerLensActionHandler handler) {
    _actionHandlers.removeWhere((registered) => registered == handler);
    _actionHandlers.add(handler);
  }

  void unregisterActionHandler(PowerLensActionHandler handler) {
    _actionHandlers.removeWhere((registered) => registered == handler);
  }

  Future<bool> dispatchAction(
    PowerLensAppAction action, [
    Map<String, dynamic>? params,
  ]) async {
    // Iterate from the visible/top-most screen to the root canvas. A handler
    // may return false when an action is not applicable to its current stage.
    for (final handler in List<PowerLensActionHandler>.from(
      _actionHandlers.reversed,
    )) {
      try {
        if (await handler(action, params)) return true;
      } catch (_) {
        // A page being disposed must not prevent another registered screen
        // from handling a global action.
      }
    }
    return false;
  }

  /// Maps backend canonical action_id to Flutter PowerLensAppAction
  PowerLensAppAction? mapBackendActionId(String? actionId) {
    if (actionId == null || actionId.isEmpty) return null;
    switch (actionId.toUpperCase()) {
      case 'GO_HOME':
        return PowerLensAppAction.goHome;
      case 'OPEN_DIAGRAM_PICKER':
        return PowerLensAppAction.triggerPhotoUpload;
      case 'LOAD_SAMPLE_DIAGRAM':
        return PowerLensAppAction.loadSampleDiagram;
      case 'SHOW_REVIEW_ISSUES':
        return PowerLensAppAction.showReviewIssues;
      case 'COMPLETE_CURRENT_STAGE':
        return PowerLensAppAction.goToNextStage;
      case 'OPEN_EXCEL_PICKER':
        return PowerLensAppAction.triggerExcelUpload;
      case 'HANDOFF_TO_CANVAS':
        return PowerLensAppAction.handoffToCanvas;
      case 'RUN_POWER_FLOW':
        return PowerLensAppAction.runPowerFlow;
      case 'SHOW_POWER_FLOW_RESULTS':
        return PowerLensAppAction.showPowerFlowResults;
      case 'SHOW_FLOW_DIRECTION':
        return PowerLensAppAction.showFlowDirection;
      case 'HIDE_FLOW_DIRECTION':
        return PowerLensAppAction.hideFlowDirection;
      case 'SHOW_VALUE_LABELS':
        return PowerLensAppAction.showValueLabels;
      case 'HIDE_VALUE_LABELS':
        return PowerLensAppAction.hideValueLabels;
      case 'NO_ACTION':
      default:
        return null;
    }
  }

  /// Safe Action Executor: Only dispatches when actionMode is 'EXECUTE'.
  /// GUIDE, CONFIRM_REQUIRED, and NONE illuminate or inform without execution.
  Future<bool> executeBackendAction({
    required String? actionMode,
    required String? actionId,
    Map<String, dynamic>? actionParams,
    String? highlightTarget,
  }) async {
    if (highlightTarget != null &&
        highlightTarget.isNotEmpty &&
        highlightTarget.toLowerCase() != 'null' &&
        activeHighlightTarget.value != highlightTarget) {
      triggerHighlight(highlightTarget);
    }

    if (actionMode != 'EXECUTE') {
      return false;
    }

    final appAction = mapBackendActionId(actionId);
    if (appAction == null) return false;

    return await dispatchAction(appAction, actionParams);
  }

  String _normalizeQuery(String text) {
    return text.trim().toLowerCase().replaceAll(
      RegExp(r'[\s\.,!?~…`"“”‘’]+'),
      '',
    );
  }

  bool _containsAny(String query, Iterable<String> terms) {
    return terms.any(query.contains);
  }

  bool _isActiveBusMap(Map<String, dynamic> node) {
    final className =
        (node['className'] ?? node['class_name'] ?? node['class'] ?? '')
            .toString()
            .toLowerCase();
    final reviewStatus =
        (node['reviewStatus'] ?? node['review_status'] ?? node['status'] ?? '')
            .toString()
            .toUpperCase();
    return className == 'bus' && reviewStatus != 'REJECTED';
  }

  int _activeBusCount(PowerLensAssistantContext context) {
    if (context.workingNodes.isNotEmpty) {
      return context.workingNodes.where(_isActiveBusMap).length;
    }
    return context.totalBuses;
  }

  bool _isReviewStage(PowerLensAssistantContext? context) {
    final stage = context?.workflowStage.toUpperCase();
    return stage == 'OBJECT_REVIEW' ||
        stage == 'BUS_MAPPING' ||
        stage == 'BUS_MAPPING_REVIEW' ||
        stage == 'CONNECTION_REVIEW' ||
        stage == 'LINE_REVIEW' ||
        context?.currentScreen.toUpperCase() == 'REVIEW_PAGE';
  }

  bool _isConnectionReviewStage(PowerLensAssistantContext? context) {
    final stage = context?.workflowStage.toUpperCase();
    return stage == 'CONNECTION_REVIEW' || stage == 'LINE_REVIEW';
  }

  /// Resolve a message into one or more safe, deterministic UI actions.
  ///
  /// This is intentionally a small semantic router rather than a full NLP
  /// model. It handles the common ways a person naturally describes an
  /// action, while the backend remains responsible for evidence-based
  /// explanations that do not have a local UI action.
  List<PowerLensAppAction> resolveIntentActions(
    String text, [
    PowerLensAssistantContext? context,
  ]) {
    final q = _normalizeQuery(text);
    if (q.isEmpty) return const [];

    // If the user is asking a question (where to click, how to do, what button to press),
    // provide guidance and trigger glowing highlights instead of silently executing actions!
    final isHowToOrWhereQuestion = _containsAny(q, const [
      '뭐눌러',
      '뭘눌러',
      '무엇을눌러',
      '어디눌러',
      '어디해야',
      '어디를해야',
      '어디야',
      '어디서',
      '어디에',
      '어디',
      '어떻게',
      '할려면',
      '하려면',
      '누르면',
      '누르면돼',
      '누르면되',
      '위치',
      '방법',
      '뭐해야',
      '뭘해야',
      '무엇을해야',
      '다음에뭐',
      '다음할일',
      '어떤버튼',
      '무슨버튼',
      '어느버튼',
      '버튼어디',
      '어느거',
      '어느것',
    ]);
    if (isHowToOrWhereQuestion) {
      return const [PowerLensAppAction.explainCurrentStage];
    }

    final hasContent = _containsAny(q, const [
      '파일',
      '사진',
      '도면',
      '회로도',
      '이미지',
      '그림',
    ]);
    final hasUploadVerb = _containsAny(q, const [
      '넣',
      '올리',
      '가져',
      '불러',
      '업로드',
      '선택',
      '추가',
      '다시',
      '새로',
      '넣고싶',
      '가져오',
    ]);
    final hasExcelWord = _containsAny(q, const [
      '엑셀',
      'xlsx',
      'xls',
      '계통제원',
      '계통데이터',
    ]);
    final wantsHide = _containsAny(q, const [
      '숨',
      '감춰',
      '치워',
      '없애',
      '끄',
      '안보',
      '보이지않',
    ]);
    final wantsShow = _containsAny(q, const ['보여', '표시', '켜', '띄워', '나타내']);
    final hasFlowWord = _containsAny(q, const [
      '흐름',
      '화살표',
      '조류방향',
      '전력흐름',
      '전력방향',
    ]);
    final hasValueWord = _containsAny(q, const [
      '수치',
      '숫자',
      '값',
      '라벨',
      '전압',
      '전력량',
    ]);

    // Explicit sample intent wins over the generic upload words.
    if (_containsAny(q, const ['샘플', 'ieee', '체험'])) {
      return const [PowerLensAppAction.loadSampleDiagram];
    }

    if (_containsAny(q, const [
      '처음',
      '첫화면',
      '시작화면',
      '홈으로',
      '홈화면',
      '메인화면',
      '초기화면',
      '초기화로',
    ])) {
      return const [PowerLensAppAction.goHome];
    }

    // Spreadsheet input is a separate workflow action from photo upload.
    if (hasExcelWord && hasUploadVerb) {
      return const [PowerLensAppAction.triggerExcelUpload];
    }

    if (hasContent && hasUploadVerb) {
      return const [PowerLensAppAction.triggerPhotoUpload];
    }

    final isConnectionReview = _isConnectionReviewStage(context);
    // Connection Review V2 is a whole-network exception review. Legacy
    // view-mode and next-line commands remain in the enum for compatibility,
    // but are intentionally not emitted by the active semantic router.
    final asksForSequentialConnection =
        isConnectionReview &&
        _containsAny(q, const [
          '다음선',
          '다음선로',
          '다음거',
          '하나씩볼',
          '한선씩',
          '이선봐',
        ]);

    if (_containsAny(q, const [
      '캔버스로이동',
      '캔버스이동',
      '캔버스편집',
      '도면편집화면',
      'cad로넘어가',
      'cad로이동',
    ])) {
      return const [PowerLensAppAction.handoffToCanvas];
    }

    if (_containsAny(q, const [
      '조류계산',
      '조류계산해',
      '파워플로우',
      '전력계산',
      '계산실행',
      '계산진행',
      '계산진행해',
      '계산해보',
      '계산한번',
    ])) {
      return const [PowerLensAppAction.runPowerFlow];
    }

    if (_containsAny(q, const ['결과보여', '결과열', '결과표', '수치결과', '수치표'])) {
      return const [PowerLensAppAction.showPowerFlowResults];
    }

    final actions = <PowerLensAppAction>[];
    if (hasValueWord && wantsHide) {
      actions.add(PowerLensAppAction.hideValueLabels);
    }
    if (hasFlowWord && wantsHide) {
      actions.add(PowerLensAppAction.hideFlowDirection);
    } else if (hasFlowWord && wantsShow) {
      actions.add(PowerLensAppAction.showFlowDirection);
    }
    // "화살표만 보여줘" means show the flow and remove distracting numbers.
    if (hasFlowWord &&
        wantsShow &&
        q.contains('만') &&
        !actions.contains(PowerLensAppAction.hideValueLabels)) {
      actions.insert(0, PowerLensAppAction.hideValueLabels);
    }
    if (hasValueWord && wantsShow && !(hasFlowWord && q.contains('만'))) {
      actions.add(PowerLensAppAction.showValueLabels);
    }
    if (actions.isNotEmpty) return actions;

    final asksNoIssues = _containsAny(q, const [
      '검토필요없',
      '검토필요한항목없',
      '검토항목없',
      '검토할거없',
      '문제없',
      '이상없',
      '오류없',
      '다확인',
      '전부확인',
      '모두확인',
    ]);
    if (asksNoIssues && _isReviewStage(context)) {
      return const [PowerLensAppAction.explainCurrentStage];
    }

    if (_containsAny(q, const [
      '문제있는',
      '오류만',
      '이상만',
      '검토필요',
      '확인할항목',
      '문제항목',
      '검토항목',
    ])) {
      return const [PowerLensAppAction.showReviewIssues];
    }

    final isBatchApprove = _containsAny(q, const [
      '일괄승인',
      '전체승인',
      '모두승인',
      '한번에승인',
      '한번에다승인',
      '다승인',
      '정상승인',
      '정상객체승인',
      '정상객체일괄',
      '정상객체전체',
    ]);
    final stageStr = context?.workflowStage.toLowerCase() ?? '';
    final isObjectOrBusReview =
        stageStr == 'object_review' ||
        stageStr == 'bus_mapping' ||
        stageStr == 'bus_mapping_review';
    if (_isReviewStage(context) && isBatchApprove) {
      if (isObjectOrBusReview || isConnectionReview) {
        return const [];
      }
      return const [PowerLensAppAction.approveAllClean];
    }

    final isPositiveReviewReply = _containsAny(q, const [
      '괜찮',
      '맞아',
      '맞는것같',
      '문제없',
      '승인',
      '확인했',
      '좋아보',
      '오케이',
    ]);
    if (_isReviewStage(context) && isPositiveReviewReply) {
      if (isObjectOrBusReview || isConnectionReview) {
        return const [];
      }
      return const [PowerLensAppAction.approveCurrentAndNext];
    }

    if (asksForSequentialConnection) return const [];

    if (_containsAny(q, const [
      '다음에뭐',
      '다음할일',
      '뭐해야',
      '뭘해야',
      '무엇을해야',
      '이제뭐',
      '뭘할수',
      '뭐할수',
      '이단계에서',
      '단계설명',
      '어떻게시작',
      '뭘보면',
      '무엇을보면',
      '어디부터보',
      '어디눌러',
      '어디해야',
      '어디를해야',
      '뭐눌러',
    ])) {
      return const [PowerLensAppAction.explainCurrentStage];
    }

    if (_containsAny(q, const ['이전', '전단계', '뒤로', '돌아가'])) {
      return const [PowerLensAppAction.goToPreviousStage];
    }
    if (_containsAny(q, const [
      '객체검수완료',
      '객체확인완료',
      '검수완료해',
      '모선검수완료',
      '모선확인완료',
      '모선검수끝',
      '모선확인끝',
      '모선다봤',
      '버스번호확인끝',
    ])) {
      return const [PowerLensAppAction.goToNextStage];
    }
    if (_containsAny(q, const ['다음', '넘어가', '계속', '진행하', '다음거', '다음단계'])) {
      return const [PowerLensAppAction.goToNextStage];
    }

    if (_containsAny(q, const ['흐름전환', '흐름토글'])) {
      return const [PowerLensAppAction.toggleFlowDirection];
    }
    if (hasValueWord && _containsAny(q, const ['전환', '토글'])) {
      return const [PowerLensAppAction.toggleValueLabels];
    }
    return const [];
  }

  PowerLensAppAction? parseIntent(String text) {
    final actions = resolveIntentActions(text);
    return actions.isEmpty ? null : actions.first;
  }

  void ensureInitialGreeting(
    String stage, [
    PowerLensAssistantContext? context,
  ]) {
    if (_messages.isNotEmpty) return;

    final greeting = _getStageGreeting(stage, context);
    _messages.add(
      PowerLensAIMessageItem(
        id: 'msg_welcome',
        sender: 'assistant',
        text: greeting,
        stage: stage,
        suggestedActions: _getQuickActions(stage, context),
        agentStatus: _geminiStatus,
      ),
    );
    _lastNotifiedStage = stage;
    notifyListeners();
  }

  Future<void> notifyStageChange(PowerLensAssistantContext context) async {
    await _requestProactiveForContext(context.workflowStage, context);
  }

  Future<void> onStageChanged(
    String stage, [
    PowerLensAssistantContext? context,
  ]) async {
    await _requestProactiveForContext(stage, context);
  }

  Future<void> _requestProactiveForContext(
    String stage, [
    PowerLensAssistantContext? context,
  ]) async {
    if (!shouldRequestProactive(context?.documentId, stage)) return;
    _lastNotifiedStage = stage;

    final uri = Uri.parse('$baseUrl/review/proactive_summary');
    final payload = {
      'document_id': context?.documentId ?? 'default_doc',
      'stage': stage,
      'working_nodes': context?.workingNodes ?? const [],
      'working_lines': context?.workingLines ?? const [],
      'missing_candidates': context?.missingCandidates ?? const [],
      'topology_issues': context?.topologyIssues ?? const [],
      'app_context': context?.toJson() ?? {'workflow_stage': stage},
    };

    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map ||
            decoded['status']?.toString().toLowerCase() != 'success') {
          throw Exception(
            'Proactive summary returned non-success status: ${decoded is Map ? decoded['status'] : 'unknown'}',
          );
        }

        final result = decoded;
        var replyKo = _cleanAssistantReply(
          result['reply_ko']?.toString() ??
              result['summary_text']?.toString() ??
              '단계를 검토하고 있습니다.',
        );

        final actionMode =
            result['action_mode']?.toString().toUpperCase() ?? 'NONE';
        // Online highlight policy: only trigger visual highlight when action_mode is GUIDE
        final backendHighlight = result['highlight_target']?.toString();
        if (actionMode == 'GUIDE' &&
            backendHighlight != null &&
            backendHighlight.isNotEmpty &&
            backendHighlight.toLowerCase() != 'null') {
          triggerHighlight(backendHighlight);
          if (!replyKo.contains('반짝')) {
            replyKo += "\n\n✨ 지금 진행할 위치가 화면에서 반짝반짝 빛나고 있어요!";
          }
        }

        if (result['focus_targets'] is List) {
          setFocusTargets(
            List<Map<String, dynamic>>.from(
              (result['focus_targets'] as List).whereType<Map>().map(
                (e) => Map<String, dynamic>.from(e),
              ),
            ),
          );
        }

        final agentStatus = result['agent_status']?.toString() ?? 'PROACTIVE';
        final providerMode = result['provider_mode']?.toString().toLowerCase();
        _geminiStatus =
            (providerMode == 'gemini' ||
                agentStatus.toUpperCase().contains('GEMINI'))
            ? 'CONNECTED'
            : 'LOCAL_READY';

        final rawActions = result['suggested_actions'];
        final actions = rawActions is List
            ? rawActions.map((e) => e.toString()).take(3).toList()
            : _getQuickActions(stage, context);

        _messages.add(
          PowerLensAIMessageItem(
            id: 'proactive_${DateTime.now().millisecondsSinceEpoch}',
            sender: 'assistant',
            text: replyKo,
            stage: stage,
            suggestedActions: actions,
            agentStatus: agentStatus,
          ),
        );
        notifyListeners();
        return;
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (_) {
      // Local deterministic proactive fallback on error or offline
      _executeLocalProactiveFallback(stage, context);
    }
  }

  void _executeLocalProactiveFallback(
    String stage, [
    PowerLensAssistantContext? context,
  ]) {
    String? proactiveText;
    if (stage == 'EXCEL_LOADED') {
      proactiveText = "제원이 연결되었습니다. 조류계산을 실행할 수 있습니다.";
    } else if (stage == 'POWERFLOW_CONVERGED') {
      proactiveText = "계산이 수렴했습니다. 결과를 같이 살펴볼까요?";
    } else if (context != null) {
      proactiveText = _getStageProactiveText(context);
    } else {
      switch (stage) {
        case 'HOME':
          proactiveText = "단선도를 불러오면 객체와 연결 상태를 함께 확인해드릴게요.";
          break;
        case 'OBJECT_REVIEW':
          proactiveText = "객체 분석이 끝났습니다. 확인이 필요한 항목만 먼저 살펴보세요.";
          break;
        case 'BUS_MAPPING':
        case 'BUS_MAPPING_REVIEW':
          proactiveText = "이제 모선 번호를 확인합니다.";
          break;
        case 'CONNECTION_REVIEW':
          proactiveText = "모선 확인이 끝났습니다. 다음은 선로 연결 상태를 확인합니다.";
          break;
        case 'FINAL':
        case 'FINAL_CAD':
          proactiveText = "단선도 검증이 끝났습니다. 조류계산을 위해 계통 제원을 연결할 수 있습니다.";
          break;
      }
    }

    proactiveText ??= "현재 $stage 단계입니다. 안내가 필요하시면 언제든 질문해주세요.";

    _messages.add(
      PowerLensAIMessageItem(
        id: 'proactive_fallback_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'assistant',
        text: _cleanAssistantReply(proactiveText),
        stage: stage,
        suggestedActions: _getQuickActions(stage, context),
        agentStatus: 'LOCAL_READY',
      ),
    );
    notifyListeners();
  }

  Future<void> sendMessage(
    String text,
    PowerLensAssistantContext context,
  ) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isLoading) return;

    final requestId = ++_requestSerial;

    final userMsg = PowerLensAIMessageItem(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      sender: 'user',
      text: trimmed,
      stage: context.workflowStage,
    );
    _messages.add(userMsg);
    _isLoading = true;
    _mascotState = 'thinking';
    _lastFailedQuery = null;
    notifyListeners();

    var finalMascotState = 'idle';
    try {
      final fallbackHighlightTarget = determineTargetForContext(
        context,
        query: trimmed,
      );

      // 1. Semantic Routing First: Send query to backend Agent /review/agent_chat
      final uri = Uri.parse('$baseUrl/review/agent_chat');
      final payload = {
        'document_id': context.documentId,
        'message': trimmed,
        'stage': context.workflowStage,
        'selected_node': context.selectedNode,
        'selected_line': context.selectedLine,
        'working_nodes': context.workingNodes,
        'working_lines': context.workingLines,
        'missing_candidates': context.missingCandidates,
        'topology_issues': context.topologyIssues,
        'history': _buildHistoryPayload(),
        'app_context': context.toJson(),
      };

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map ||
            decoded['status']?.toString().toLowerCase() != 'success') {
          throw Exception(
            'Backend agent_chat returned error or non-success status: ${decoded is Map ? decoded['status'] : 'unknown'}',
          );
        }

        final data = decoded;
        final rawResult = data['result'];
        final result = rawResult is Map
            ? Map<String, dynamic>.from(rawResult)
            : Map<String, dynamic>.from(data);
        var replyKo = _cleanAssistantReply(
          result['reply_ko']?.toString() ?? '답변을 생성하지 못했습니다.',
        );

        final backendHighlight = result['highlight_target']?.toString();
        final effectiveHighlight =
            (backendHighlight != null &&
                backendHighlight.isNotEmpty &&
                backendHighlight.toLowerCase() != 'null')
            ? backendHighlight
            : null;

        if (effectiveHighlight != null) {
          triggerHighlight(effectiveHighlight);
          if (!replyKo.contains('반짝')) {
            replyKo += "\n\n✨ 지금 진행할 위치가 화면에서 반짝반짝 빛나고 있어요!";
          }
        }

        if (result['focus_targets'] is List) {
          setFocusTargets(
            List<Map<String, dynamic>>.from(
              (result['focus_targets'] as List).whereType<Map>().map(
                (e) => Map<String, dynamic>.from(e),
              ),
            ),
          );
        }

        final actionMode =
            result['action_mode']?.toString().toUpperCase() ?? 'NONE';
        final actionId = result['action_id']?.toString();
        final rawActionParams = result['action_params'];
        final actionParams = rawActionParams is Map
            ? Map<String, dynamic>.from(rawActionParams)
            : null;

        bool actionExecuted = false;
        if (actionMode == 'EXECUTE') {
          actionExecuted = await executeBackendAction(
            actionMode: actionMode,
            actionId: actionId,
            actionParams: actionParams,
            highlightTarget:
                null, // Avoid duplicate trigger; already highlighted above
          );
        }

        final agentStatus =
            result['agent_status']?.toString() ?? 'LOCAL_FALLBACK';
        final providerMode = result['provider_mode']?.toString().toLowerCase();
        _geminiStatus =
            providerMode == 'gemini' ||
                agentStatus.toUpperCase().contains('GEMINI')
            ? 'CONNECTED'
            : 'LOCAL_READY';
        final rawActions = result['suggested_actions'];
        final actions = rawActions is List
            ? rawActions.map((e) => e.toString()).take(3).toList()
            : _getQuickActions(context.workflowStage, context);

        _messages.add(
          PowerLensAIMessageItem(
            id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
            sender: 'assistant',
            text: replyKo,
            stage: context.workflowStage,
            suggestedActions: actions,
            agentStatus: agentStatus,
          ),
        );
        finalMascotState = (actionMode == 'EXECUTE' && actionExecuted)
            ? 'success'
            : 'speaking';
      } else {
        // Backend offline or non-200 -> Fall back to offline local keyword routing
        await _executeOfflineFallback(
          trimmed,
          context,
          requestId,
          fallbackHighlightTarget,
        );
        finalMascotState = 'blocked';
      }
    } on TimeoutException {
      if (requestId != _requestSerial) return;
      final fallbackHighlightTarget = determineTargetForContext(
        context,
        query: trimmed,
      );
      await _executeOfflineFallback(
        trimmed,
        context,
        requestId,
        fallbackHighlightTarget,
        timeout: true,
      );
      finalMascotState = 'blocked';
    } catch (_) {
      if (requestId != _requestSerial) return;
      final fallbackHighlightTarget = determineTargetForContext(
        context,
        query: trimmed,
      );
      await _executeOfflineFallback(
        trimmed,
        context,
        requestId,
        fallbackHighlightTarget,
      );
      finalMascotState = 'blocked';
    } finally {
      // A stale response must never append a late answer or unlock a newer
      // request. The current request always clears its loading state here.
      if (requestId == _requestSerial) {
        _isLoading = false;
        _mascotState = finalMascotState;
        notifyListeners();
        if (finalMascotState == 'success' || finalMascotState == 'speaking') {
          final completedState = finalMascotState;
          Future<void>.delayed(
            Duration(milliseconds: completedState == 'success' ? 1600 : 2600),
            () {
              if (requestId == _requestSerial &&
                  !_isLoading &&
                  _mascotState == completedState) {
                _mascotState = 'idle';
                notifyListeners();
              }
            },
          );
        }
      }
    }
  }

  Future<void> _executeOfflineFallback(
    String trimmed,
    PowerLensAssistantContext context,
    int requestId,
    String? fallbackHighlightTarget, {
    bool timeout = false,
  }) async {
    _geminiStatus = 'LOCAL_FALLBACK';
    _lastFailedQuery = trimmed;

    final intentActions = resolveIntentActions(trimmed, context);
    final uiExecutableActions = intentActions
        .where((a) => a != PowerLensAppAction.explainCurrentStage)
        .toList();

    if (uiExecutableActions.isNotEmpty) {
      final handledActions = <bool>[];
      for (final action in uiExecutableActions) {
        if (requestId != _requestSerial) return;
        if (_isPointingAction(action)) {
          _mascotState = 'speaking';
          notifyListeners();
        }
        handledActions.add(await dispatchAction(action));
      }
      if (requestId != _requestSerial) return;

      final replies = <String>[];
      for (var i = 0; i < uiExecutableActions.length; i++) {
        replies.add(
          _getActionReply(uiExecutableActions[i], handledActions[i], context),
        );
      }
      _messages.add(
        PowerLensAIMessageItem(
          id: 'ai_action_${DateTime.now().millisecondsSinceEpoch}',
          sender: 'assistant',
          text: replies.join(' '),
          stage: context.workflowStage,
          suggestedActions: _getQuickActions(context.workflowStage, context),
          agentStatus: _geminiStatus,
        ),
      );
    } else {
      _addLocalFallbackMessage(
        timeout ? '응답 시간이 길어졌어요. $trimmed' : trimmed,
        context,
        timeout: timeout,
      );
    }
  }

  String _getActionReply(
    PowerLensAppAction action,
    bool handled,
    PowerLensAssistantContext context,
  ) {
    switch (action) {
      case PowerLensAppAction.goHome:
        return handled
            ? '홈으로 돌아왔어요. 도면 파일을 올리거나 샘플로 시작해보세요.'
            : '지금은 홈으로 이동할 수 없어요.';
      case PowerLensAppAction.goToNextStage:
        return handled
            ? '다음 단계로 이동했어요.'
            : _cleanAssistantReply(_getBlockedNextStageReply(context));
      case PowerLensAppAction.goToPreviousStage:
        return handled ? '이전 단계로 돌아갔어요.' : '이전 단계로 이동할 수 없어요.';
      case PowerLensAppAction.triggerPhotoUpload:
        return handled ? '도면 파일을 고를 수 있도록 업로드 창을 열었어요.' : '지금은 업로드 창을 열 수 없어요.';
      case PowerLensAppAction.triggerExcelUpload:
        return handled
            ? '엑셀 파일을 고를 수 있도록 선택 창을 열었어요.'
            : '지금은 엑셀 선택 창을 열 수 없어요.';
      case PowerLensAppAction.loadSampleDiagram:
        return handled
            ? 'IEEE-24 샘플을 불러오고 있어요. 검수가 끝나면 다음 단계도 안내할게요.'
            : '샘플을 불러오지 못했어요.';
      case PowerLensAppAction.showReviewIssues:
        return _getReviewIssuesReply(context, handled);
      case PowerLensAppAction.approveCurrentAndNext:
        return handled
            ? '현재 항목을 확인했어요. 남은 예외가 있으면 도면에서 해당 항목만 확인해주세요.'
            : '지금은 개별 승인할 항목이 없어요.';
      case PowerLensAppAction.approveAllClean:
        return handled
            ? '정상 대기 항목들을 한 번에 확인했어요.'
            : '일괄 처리할 대기 항목이 없거나 이미 처리되었습니다.';
      case PowerLensAppAction.connectionFullReview:
        return handled
            ? '전체 결선 화면에서 확인이 필요한 예외를 표시했어요.'
            : '지금은 결선 검수 화면을 열 수 없어요.';
      case PowerLensAppAction.connectionLinesOnly:
        return handled
            ? '전체 네트워크 화면에서 확인이 필요한 결선을 표시했어요.'
            : '지금은 결선 검수 화면을 열 수 없어요.';
      case PowerLensAppAction.connectionNextLine:
        return handled
            ? '자동 선로 이동은 사용하지 않아요. 확인이 필요한 결선을 도면에서 선택해주세요.'
            : '확인할 결선이 없어요.';
      case PowerLensAppAction.handoffToCanvas:
        return handled
            ? '캔버스로 이동했어요. 여기서 조류계산을 시작할 수 있어요.'
            : '아직 캔버스로 이동할 수 없어요.';
      case PowerLensAppAction.runPowerFlow:
        return handled
            ? (context.currentScreen.toUpperCase() == 'REVIEW_PAGE'
                  ? '캔버스로 이동했어요. 거기서 실제 조류계산을 시작할 수 있어요.'
                  : '조류계산을 실행했어요. 결과가 준비되면 선로 위에 방향 화살표를 보여드릴게요.')
            : '조류계산을 실행하려면 도면과 계통 제원을 먼저 연결해주세요.';
      case PowerLensAppAction.showPowerFlowResults:
        return handled
            ? '계산 결과를 열었어요. 수치와 선로 조류를 확인해보세요.'
            : '먼저 조류계산을 완료하면 결과를 보여드릴 수 있어요.';
      case PowerLensAppAction.toggleFlowDirection:
        return handled ? '전력 흐름 표시를 전환했어요.' : '아직 표시를 전환할 조류계산 결과가 없어요.';
      case PowerLensAppAction.showFlowDirection:
        return handled ? '전력 흐름 방향을 표시했어요.' : '조류계산 결과가 있으면 흐름 방향을 보여드릴 수 있어요.';
      case PowerLensAppAction.hideFlowDirection:
        return handled ? '흐름 화살표를 숨겼어요.' : '숨길 흐름 표시가 없어요.';
      case PowerLensAppAction.toggleValueLabels:
        return handled ? '수치 라벨 표시를 전환했어요.' : '수치 라벨을 전환할 수 없어요.';
      case PowerLensAppAction.showValueLabels:
        return handled
            ? '전압과 전력 수치 라벨을 표시했어요.'
            : '조류계산 결과가 있으면 수치 라벨을 보여드릴 수 있어요.';
      case PowerLensAppAction.hideValueLabels:
        return handled ? '수치 라벨을 숨겼어요.' : '숨길 수치 라벨이 없어요.';
      case PowerLensAppAction.explainCurrentStage:
        return "${_getNextActionAnswer(context)}\n\n✨ 지금 진행할 위치가 화면에서 반짝반짝 빛나고 있어요!";
    }
  }

  String _getReviewIssuesReply(
    PowerLensAssistantContext context,
    bool handled,
  ) {
    if (!handled) {
      return '현재 화면에서는 검토 항목을 표시할 수 없어요.';
    }

    final stage = context.workflowStage.toUpperCase();

    if (stage == 'OBJECT_REVIEW') {
      final susp = context.suspiciousObjects;
      final missing = context.unresolvedMissingCandidates;

      if (susp > 0) {
        return '확인이 필요한 의심 객체 $susp건을 표시했어요. 도면에서 해당 객체를 클릭하여 AI 판단 근거를 확인하고 [맞음] 또는 [수정]을 진행해주세요.';
      } else if (missing > 0) {
        return '누락 후보 $missing건이 남아 있어요. 목록에서 확인 후 복구하거나 문제없음 처리해주세요.';
      } else {
        return '현재 검토가 필요한 항목이 없습니다! 도면을 마지막으로 확인하신 후 아래의 [객체 검수 완료]를 눌러 다음 단계(모선 번호 매핑)로 진행하시면 됩니다.';
      }
    } else if (stage == 'BUS_MAPPING' || stage == 'BUS_MAPPING_REVIEW') {
      final uncertain = context.unresolvedBusNumbers;
      final dups = context.duplicateBusNumbers;
      final totalBuses = _activeBusCount(context);

      if (totalBuses == 0) {
        return BusReviewUiState.noActiveBusMessage;
      } else if (uncertain > 0 || dups > 0) {
        final parts = [
          if (uncertain > 0) '미지정 모선 $uncertain개',
          if (dups > 0) '중복 모선 $dups개',
        ];
        return '확인이 필요한 모선(${parts.join(', ')})을 표시했어요. 도면 위 표시를 클릭해 번호를 수정한 뒤 [모선 검수 완료]를 눌러주세요.';
      } else {
        return '현재 검토가 필요한 모선 번호 오류가 없습니다! 전체 번호를 마지막으로 확인한 뒤 [모선 검수 완료]를 눌러 결선 검수로 넘어가시면 됩니다.';
      }
    } else if (stage == 'CONNECTION_REVIEW') {
      final lines = context.workingLines
          .map((raw) => ReviewLineItem.fromJson(raw))
          .toList();
      final blockers = ConnectionReviewGateEvaluator.getBlockers(
        workingLines: lines,
        topologyIssues: context.topologyIssues,
      );
      if (blockers.isNotEmpty) {
        return '확인이 필요한 결선만 도면에 표시했어요. ${blockers.join(' ')} 실제 선로와 근거를 확인한 뒤 예외를 해결해주세요.';
      }
      return '현재 검토가 필요한 결선 예외가 없습니다. 전체 네트워크를 마지막으로 확인한 뒤 [결선 검수 완료]를 눌러주세요.';
    } else if (stage == 'FINAL' ||
        stage == 'FINAL_CAD' ||
        stage == 'VERIFIED_FINAL') {
      if (!context.excelLoaded) {
        return '도면 검증이 모두 완료되었으며 검토할 이상 항목이 없습니다! [엑셀 파일 선택]을 눌러 계통 제원을 연결해주세요.';
      } else {
        return '모든 도면 및 제원 검토가 완료되었습니다! [캔버스로 이동]을 눌러 실제 조류계산을 시작해보세요.';
      }
    }

    return '현재 단계에서 검토가 필요한 특이사항이 없습니다. 다음 단계로 진행하실 수 있습니다.';
  }

  bool _isPointingAction(PowerLensAppAction action) {
    return false;
  }

  String _cleanAssistantReply(String reply) {
    var cleaned = reply
        .replaceAll(RegExp(r'^\s*#{1,6}\s*', multiLine: true), '')
        .replaceAll(
          RegExp(r'^\s*.*\*\*\[[^\]\r\n]+\]\s*:?\*\*\s*$', multiLine: true),
          '',
        )
        .replaceAll(
          RegExp(r'^\s*\[?(판단|근거\s*요약|추천\s*액션)\]?\s*:?\s*', multiLine: true),
          '',
        )
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.isEmpty ? '지금은 답변을 만들지 못했어요. 잠시 후 다시 시도해주세요.' : cleaned;
  }

  Future<void> retryLastMessage(PowerLensAssistantContext context) async {
    final query = _lastFailedQuery;
    if (query == null || query.trim().isEmpty || _isLoading) return;
    await sendMessage(query, context);
  }

  String _getBlockedNextStageReply(PowerLensAssistantContext ctx) {
    switch (ctx.workflowStage) {
      case 'OBJECT_REVIEW':
        if (ctx.suspiciousObjects > 0) {
          return "⚠️ 검토가 필요한 객체가 **${ctx.suspiciousObjects}개** 남아 있어요. "
              "먼저 해당 항목을 승인하거나 제외하면 모선 번호 확인으로 넘어갈 수 있습니다.";
        }
        if (ctx.unresolvedMissingCandidates > 0) {
          return "⚠️ 누락 의심 설비(누락 후보)가 **${ctx.unresolvedMissingCandidates}개** 감지되어 게이트가 닫혀 있습니다.\n"
              "단선도에 원래 해당 설비(예: 변압기 등)가 없는 계통이라면, 화면 상단의 보라색 [누락 후보] 배지나 좌측 카드의 **[문제 없음]** 버튼을 누르시면 즉시 해결되어 [객체 검수 완료] 버튼이 활성화됩니다!";
        }
        break;
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        if (_activeBusCount(ctx) == 0) {
          return "⚠️ ${BusReviewUiState.noActiveBusMessage}\n"
              "객체 검수에서 모선 인식을 확인한 뒤 다시 시도해주세요.";
        }
        if (ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0) {
          return "⚠️ 아직 확정하지 않은 모선 번호가 **${ctx.unresolvedBusNumbers}개**"
              "${ctx.duplicateBusNumbers > 0 ? '이고 중복 번호도 ${ctx.duplicateBusNumbers}개' : ''} 있어요. "
              "번호를 확인한 뒤 다음 단계로 갈 수 있습니다.";
        }
        break;
      case 'CONNECTION_REVIEW':
        final connectionLines = ctx.workingLines
            .map((raw) => ReviewLineItem.fromJson(raw))
            .toList();
        final connectionBlockers = ConnectionReviewGateEvaluator.getBlockers(
          workingLines: connectionLines,
          topologyIssues: ctx.topologyIssues,
        );
        if (connectionBlockers.isNotEmpty) {
          return "⚠️ ${connectionBlockers.join(' ')} 실제 선로와 근거를 확인한 뒤 최종 검증으로 넘어갈 수 있습니다.";
        }
        break;
      case 'FINAL':
        if (!ctx.finalVerified) {
          return "⚠️ 아직 Verified Circuit이 준비되지 않았어요. "
              "최종 검증을 통과한 뒤 CAD 화면으로 이동할 수 있습니다.";
        }
        break;
    }

    final blockerText = ctx.currentBlockers.isNotEmpty
        ? ctx.currentBlockers.join(', ')
        : '현재 단계의 필수 검토를 먼저 완료해 주세요.';
    return "⚠️ **아직 다음 단계로 진행할 수 없습니다.** $blockerText";
  }

  String generateOfflineFallbackReply(
    String userQuery,
    PowerLensAssistantContext context, {
    bool timeout = false,
  }) {
    String reply;
    final stage = context.workflowStage.toUpperCase();
    final selected = context.selectedElement;
    final normalizedQuery = _normalizeQuery(userQuery);

    if (_containsAny(normalizedQuery, const [
      '일괄승인',
      '전체승인',
      '모두승인',
      '한번에승인',
      '다승인',
      '일괄',
    ])) {
      if (stage == 'BUS_MAPPING' || stage == 'BUS_MAPPING_REVIEW') {
        if (_activeBusCount(context) == 0) {
          reply =
              "✨ **모선 번호 검수 안내:**\n"
              "• ${BusReviewUiState.noActiveBusMessage}\n"
              "• 객체 검수에서 모선 인식을 확인해주세요.";
        } else {
          reply =
              "✨ **모선 번호 검수 안내:**\n"
              "• 정상 모선은 개별 또는 일괄 승인할 필요가 없습니다.\n"
              "• 확인 필요로 표시된 모선만 번호를 확인하거나 수정한 뒤 [모선 검수 완료]를 눌러주세요.";
        }
      } else if (stage == 'OBJECT_REVIEW') {
        reply =
            "✨ **객체 검수 안내:**\n"
            "• 정상 객체는 일괄 승인할 필요가 없습니다. 도면에 확인 필요로 표시된 의심 객체나 누락 후보만 확인하시면 됩니다.\n"
            "• 확인이 끝나면 하단의 [객체 검수 완료] 버튼을 눌러 다음 단계로 진행하세요.";
      } else if (stage == 'CONNECTION_REVIEW') {
        reply =
            "✨ **결선 검수 안내:**\n"
            "• 정상 결선은 개별 승인하지 않습니다.\n"
            "• 확인 필요, 교차 근거, 전기 오류가 표시된 예외만 실제 도면과 대조한 뒤 [결선 검수 완료]를 눌러주세요.";
      } else {
        reply =
            "✨ **정상 항목 일괄 승인 안내:**\n"
            "• 우측 패널의 일괄 승인 버튼을 누르면 현재 단계의 정상 항목들을 한 번에 확정하고 다음 단계로 진행하실 수 있습니다.";
      }
    } else if (_containsAny(normalizedQuery, const [
      '다음에뭐',
      '뭐해야',
      '뭘해야',
      '무엇을해야',
      '이제뭐',
      '뭘할수',
      '뭐할수',
      '할수있',
      '이단계에서',
      '다음단계',
      '뭐눌러',
      '어디눌러',
      '어디해야',
      '어디야',
      '어떻게',
      '할려면',
      '하려면',
      '누르면',
      '이상없',
    ])) {
      reply = _getNextActionAnswer(context);
    } else if (_containsAny(normalizedQuery, const ['상태', '요약'])) {
      reply = _getStatusSummary(context);
    } else if (_containsAny(normalizedQuery, const ['설명', '단계설명'])) {
      reply = _getStageExplanation(context);
    } else if (_containsAny(normalizedQuery, const ['검토필요', '확인할항목'])) {
      reply = _getReviewNeededSummary(context);
    } else if (_containsAny(normalizedQuery, const ['샘플', '체험'])) {
      reply = 'IEEE-24 샘플을 불러오면 객체 검수부터 조류계산까지 바로 체험할 수 있어요.';
    } else if (_containsAny(normalizedQuery, const ['엑셀', '제원'])) {
      reply =
          "📊 **엑셀 계통 제원 연결 가이드:**\n"
          "1. 상단 메뉴의 [엑셀 가져오기] 버튼을 클릭합니다.\n"
          "2. 모선(Bus) 데이터와 선로(Branch) 임피던스(R, X, B)가 포함된 엑셀(.xlsx) 파일을 선택하세요.\n"
          "3. 연결이 완료되면 조류계산 실행 버튼이 활성화됩니다.";
    } else if (_containsAny(normalizedQuery, const ['조류계산', '조건', '파워플로우'])) {
      reply =
          "⚡ **조류계산 실행 준비 조건:**\n"
          "1. 단선도 검증 완료 (고립 모선 없음, 슬랙 모선 지정됨)\n"
          "2. 엑셀 계통 제원(R, X, P, Q, V) 연결 완료\n"
          "3. 준비가 완료되면 [조류계산 실행]을 눌러 뉴턴-랩슨 수치해석을 진행하세요.";
    } else {
      reply = timeout
          ? '응답이 조금 늦어지고 있어요. 잠시 후 다시 시도하거나, 화면의 현재 안내를 따라 진행해주세요.'
          : '현재 ${_getStageNameKo(stage)} 단계예요. 도면 검수, 단계 이동, 조류계산 실행을 도와드릴 수 있어요.';
      if (selected != null && selected.isNotEmpty) {
        reply += ' 지금은 $selected 항목을 보고 있어요.';
      }
    }
    return reply;
  }

  void _addLocalFallbackMessage(
    String userQuery,
    PowerLensAssistantContext context, {
    bool timeout = false,
  }) {
    final stage = context.workflowStage;
    String reply = generateOfflineFallbackReply(
      userQuery,
      context,
      timeout: timeout,
    );

    final highlightTarget = determineTargetForContext(
      context,
      query: userQuery,
    );
    if (highlightTarget != null) {
      triggerHighlight(highlightTarget);
      if (!reply.contains('반짝')) {
        reply += "\n\n✨ 지금 진행할 위치가 화면에서 반짝반짝 빛나고 있어요!";
      }
    }

    _messages.add(
      PowerLensAIMessageItem(
        id: 'ai_fallback_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'assistant',
        text: _cleanAssistantReply(reply),
        stage: stage,
        suggestedActions: _getQuickActions(stage, context),
        agentStatus: 'LOCAL_READY',
      ),
    );
  }

  String _getStageExplanation(PowerLensAssistantContext ctx) {
    switch (ctx.workflowStage) {
      case 'HOME':
        return "🏠 **홈 (작업 시작 허브):**\n도면 사진을 업로드하거나 IEEE-24 샘플을 선택하여 분석을 시작하는 단계입니다.";
      case 'OBJECT_REVIEW':
        return "🔍 **객체 검수 단계 (1단계):**\nAI가 감지한 심볼 중 확인이 필요한 의심 객체나 누락 후보를 점검하고 [객체 검수 완료]를 눌러 다음 단계로 진행하는 단계입니다.";
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        return "🔢 **모선 번호 확인 단계 (2단계):**\n도면의 모선 바(Bus Bar)들에 올바른 번호(1~24)를 부여하고 발전기/부하의 연결 모선을 확정하는 단계입니다.";
      case 'CONNECTION_REVIEW':
        return "⚡ **결선 검수 단계 (3단계):**\n모선 간 송전선로 및 변압기 결선이 물리적/전기적으로 올바른지 선로별로 확인하는 단계입니다.";
      case 'FINAL':
      case 'FINAL_CAD':
        return "✨ **최종 회로도 및 조류계산 (4단계):**\n검증 완료된 단선도에 계통 제원 엑셀을 연결하고 뉴턴-랩슨 조류계산을 수행하여 전압과 조류를 확인하는 단계입니다.";
      default:
        return "현재 단계: ${_getStageNameKo(ctx.workflowStage)}";
    }
  }

  String _getReviewNeededSummary(PowerLensAssistantContext ctx) {
    if (ctx.workflowStage == 'OBJECT_REVIEW') {
      return ctx.suspiciousObjects > 0
          ? "⚠️ 검토가 필요한 객체가 **${ctx.suspiciousObjects}건** 남아 있습니다. 화면의 [맞음] 또는 [수정]을 눌러 완료해 주세요."
          : "✅ 모든 객체가 정상 검수 완료되었습니다! 하단 [객체 검수 완료]를 눌러 모선 번호 확인으로 넘어가세요.";
    } else if (ctx.workflowStage == 'BUS_MAPPING' ||
        ctx.workflowStage == 'BUS_MAPPING_REVIEW') {
      if (_activeBusCount(ctx) == 0) {
        return BusReviewUiState.noActiveBusMessage;
      }
      return ctx.unresolvedBusNumbers > 0
          ? "⚠️ 아직 확인이 필요한 모선이 **${ctx.unresolvedBusNumbers}개** 있습니다. 번호를 확인하거나 수정한 뒤 [모선 검수 완료]를 눌러주세요."
          : "✅ 모든 모선 번호 확인이 완료되었습니다. [모선 검수 완료]를 눌러주세요.";
    } else if (ctx.workflowStage == 'CONNECTION_REVIEW') {
      final lines = ctx.workingLines
          .map((raw) => ReviewLineItem.fromJson(raw))
          .toList();
      final blockers = ConnectionReviewGateEvaluator.getBlockers(
        workingLines: lines,
        topologyIssues: ctx.topologyIssues,
      );
      return blockers.isNotEmpty
          ? "⚠️ 확인이 필요한 결선 예외가 있습니다. ${blockers.join(' ')} 실제 선로 근거를 확인해주세요."
          : "✅ 확인이 필요한 결선 예외가 없습니다. 전체 네트워크를 마지막으로 확인한 뒤 [결선 검수 완료]를 눌러주세요.";
    }
    return "현재 검토가 지연된 항목이 없습니다. 다음 단계를 진행해보세요!";
  }

  String _getNextActionAnswer(PowerLensAssistantContext ctx) {
    final selected = ctx.selectedElement;
    switch (ctx.workflowStage) {
      case 'HOME':
        return "💡 **다음 할 일 (홈):**\n"
            "• **[도면 사진으로 시작]**을 눌러 갖고 계신 도면을 분석하거나\n"
            "• **[샘플로 빠르게 체험하기]**를 눌러 10초 만에 전체 흐름을 확인해 보세요.";
      case 'OBJECT_REVIEW':
        if (ctx.unresolvedMissingCandidates > 0) {
          return "💡 **다음 할 일 (누락 후보 검토):**\n"
              "• AI가 단선도 분석 중 설비 누락 가능성 **${ctx.unresolvedMissingCandidates}건**(예: 변압기 등)을 감지했습니다.\n"
              "• **실제 계통에 해당 설비가 없는 경우**: 화면 상단의 보라색 [누락 후보] 배지나 좌측 카드의 **[문제 없음]** 버튼을 누르시면 즉시 통과됩니다.\n"
              "• **실제 도면에 존재하는 경우**: **[수동 추가]**를 눌러 도면에서 직접 영역을 지정해 추가하세요.\n"
              "• 누락 후보가 처리되면 하단의 **[객체 검수 완료]** 버튼이 활성화됩니다!";
        }
        final hasSuspicious =
            ctx.suspiciousObjects > 0 ||
            ctx.workingNodes.any(
              (n) =>
                  n['status'] == 'SUSPICIOUS' ||
                  n['review_status'] == 'SUSPICIOUS',
            );

        if (!hasSuspicious) {
          return "💡 **다음 할 일 (객체 검수 완료):**\n"
              "• AI가 확인한 의심 객체가 없습니다 (정상 통과)!\n"
              "• 도면을 전체적으로 한 번 눈으로 대조 확인하신 후, 화면 하단의 파란색 **[객체 검수 완료]** 버튼을 눌러 바로 **모선 번호 매핑(2단계)**으로 넘어가시면 됩니다.";
        }
        if (selected != null && selected.isNotEmpty) {
          return "💡 **다음 할 일 (의심 객체 확인):**\n"
              "• 현재 확인이 필요한 항목이 ${ctx.suspiciousObjects}건 있습니다.\n"
              "• 지금 선택된 **$selected** 기호를 확인 후 **[맞음]**(AI 확정) 또는 **[수정]**(종류 변경/제외)을 선택하세요.\n"
              "• 의심 항목을 모두 해결하면 하단의 **[객체 검수 완료]** 버튼으로 다음 단계로 진행할 수 있습니다.";
        }
        return "💡 **다음 할 일 (의심 객체 확인):**\n"
            "• **확인 필요 항목**: ${ctx.suspiciousObjects}건\n"
            "• 도면에 주황색으로 표시된 의심 객체를 클릭하여 AI 모델 신뢰도와 판단 근거를 확인하고 **[맞음]** 또는 **[수정]**을 선택하세요.";
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        if (_activeBusCount(ctx) == 0) {
          return "💡 **다음 할 일 (모선 인식 확인):**\n"
              "• ${BusReviewUiState.noActiveBusMessage}\n"
              "• 객체 검수에서 모선 인식을 확인한 뒤 다시 시도해주세요.";
        }
        if (selected != null && selected.isNotEmpty) {
          return "💡 **다음 할 일 (모선 번호 확인):**\n"
              "• 현재 **$selected**를 확인 중입니다.\n"
              "• 번호가 틀리거나 비어 있으면 도면 위 표시를 클릭해 번호를 수정하세요.\n"
              "• 전체 번호를 마지막으로 확인한 뒤 하단의 **[모선 검수 완료]**를 눌러주세요.";
        }
        if (ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0) {
          return "💡 **다음 할 일 (모선 번호 확인):**\n"
              "• 미지정 모선 ${ctx.unresolvedBusNumbers}개가 남아 있습니다.\n"
              "• 도면 위 확인 필요 표시를 눌러 번호를 수정한 뒤 [모선 검수 완료]를 눌러주세요.";
        } else {
          return "💡 **다음 할 일 (모선 번호 확인 완료):**\n"
              "• 모든 모선 번호 확인이 끝났습니다!\n"
              "• 하단 **[모선 검수 완료]** 버튼을 눌러주세요.";
        }
      case 'CONNECTION_REVIEW':
        final lines = ctx.workingLines
            .map((raw) => ReviewLineItem.fromJson(raw))
            .toList();
        final blockers = ConnectionReviewGateEvaluator.getBlockers(
          workingLines: lines,
          topologyIssues: ctx.topologyIssues,
        );
        if (blockers.isNotEmpty) {
          return "💡 **다음 할 일 (결선 예외 확인):**\n"
              "• ${blockers.join(' ')}\n"
              "• 도면에서 실제 경로와 양 끝점을 확인하고 필요한 경우 후보 연결을 선택하세요.";
        }
        return "💡 **다음 할 일 (결선 검수 완료):**\n"
            "• 전체 네트워크의 결선 예외가 해결되었습니다.\n"
            "• **[결선 검수 완료]**를 눌러 최종 검증을 시작하세요.";
      case 'FINAL':
      case 'FINAL_CAD':
        if (!ctx.excelLoaded) {
          return "💡 **다음 할 일 (계통 제원 연결):**\n"
              "• 단선도 검증이 끝났습니다!\n"
              "• 상단 메뉴의 **[엑셀 가져오기]**를 눌러 선로 임피던스와 발전/부하 제원 엑셀을 연결하세요.";
        } else if (ctx.powerflowConverged == true) {
          return "💡 **다음 할 일 (해석 완료):**\n"
              "• 조류계산이 성공적으로 수렴했습니다!\n"
              "• 상단 **[수치 결과표]**를 눌러 모선 전압과 선로 조류/손실을 확인하거나 엑셀로 다운로드하세요.";
        } else {
          return "💡 **다음 할 일 (조류계산 실행):**\n"
              "• 제원이 연결되었습니다. 우측 상단의 파란색 **[조류계산 실행]** 버튼을 눌러 수치해석을 시작하세요.";
        }
      default:
        return "💡 현재 단계를 진행하기 위해 화면의 안내 버튼을 확인해주세요.";
    }
  }

  String _getStatusSummary(PowerLensAssistantContext ctx) {
    final sb = StringBuffer();
    sb.writeln("📊 **현재 계통 및 도면 상태 요약:**");
    sb.writeln("• **현재 단계**: ${_getStageNameKo(ctx.workflowStage)}");
    if (ctx.hasDiagram) {
      sb.writeln(
        "• **인식된 객체**: 총 ${ctx.totalObjects}개 (검토 필요: ${ctx.suspiciousObjects}개)",
      );
      if (ctx.totalBuses > 0) {
        sb.writeln(
          "• **모선(Bus)**: ${ctx.totalBuses}개 (미확정: ${ctx.unresolvedBusNumbers}개)",
        );
      }
      if (ctx.totalConnections > 0) {
        sb.writeln(
          "• **연결 선로**: ${ctx.totalConnections}개 (오류: ${ctx.topologyIssueCount}건)",
        );
      }
    } else {
      sb.writeln("• 아직 분석할 단선도가 업로드되지 않았습니다.");
    }
    sb.writeln("• **제원 엑셀**: ${ctx.excelLoaded ? '연결 완료' : '미연결'}");
    sb.writeln("• **조류계산 준비**: ${ctx.powerflowReady ? '준비 완료' : '추가 작업 필요'}");
    return sb.toString();
  }

  String _getStageGreeting(String stage, [PowerLensAssistantContext? ctx]) {
    switch (stage) {
      case 'HOME':
        return "👋 **안녕하세요! PowerLens AI 도우미입니다.**\n"
            "도면 사진으로 시작할까요, 샘플 도면으로 빠르게 체험할까요?\n"
            "처음이시라면 **[샘플 도면 불러오기]**나 중앙의 체험 버튼을 눌러보세요!";
      case 'OBJECT_REVIEW':
        final hasIssues =
            (ctx?.suspiciousObjects ?? 0) > 0 ||
            (ctx?.unresolvedMissingCandidates ?? 0) > 0;
        if (!hasIssues && ctx != null) {
          return "🔍 **객체 검수 단계입니다.**\n"
              "도면 내 모든 객체 인식이 정상적으로 완료되었어요! 검토가 필요한 항목이 없으니 **[객체 검수 완료]**를 눌러 모선 매핑으로 넘어가시면 됩니다.";
        }
        return "🔍 **객체 검수 단계입니다.**\n"
            "객체를 확인해봤어요. 제가 다시 봤으면 하는 의심 객체를 도면 위에 표시해둘게요. "
            "표시된 객체를 클릭하여 AI 판단을 확인하고 **[맞음]** 또는 **[수정]**을 선택해주세요.";
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        if (ctx == null) {
          return "🔢 **모선 번호 확인 단계입니다.**\n"
              "${BusReviewUiState.noActiveBusMessage}\n"
              "객체 검수에서 모선 인식을 확인해주세요.";
        }
        if (_activeBusCount(ctx) == 0) {
          return "🔢 **모선 번호 확인 단계입니다.**\n"
              "${BusReviewUiState.noActiveBusMessage}\n"
              "객체 검수에서 모선 인식을 확인해주세요.";
        }
        final hasBusIssues =
            ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0;
        if (!hasBusIssues) {
          return "🔢 **모선 번호 확인 단계입니다.**\n"
              "제가 다시 확인할 모선은 이제 없어요. 전체 번호를 한번 확인한 뒤 **[모선 검수 완료]**를 눌러주세요.";
        }
        final count = ctx.unresolvedBusNumbers + ctx.duplicateBusNumbers;
        final countStr = count > 0 ? " ${count}개" : "";
        return "🔢 **모선 번호 확인 단계입니다.**\n"
            "모선 번호를 전체 확인했어요. 다시 확인하면 좋은 모선이${countStr} 있어요. 도면에 표시해둘게요.";
      case 'CONNECTION_REVIEW':
        final connectionLines = ctx?.workingLines
                .map((raw) => ReviewLineItem.fromJson(raw))
                .toList() ??
            const <ReviewLineItem>[];
        final connectionBlockers = ctx == null
            ? const <String>[]
            : ConnectionReviewGateEvaluator.getBlockers(
                workingLines: connectionLines,
                topologyIssues: ctx.topologyIssues,
              );
        if (connectionBlockers.isEmpty && ctx != null) {
          return "⚡ **결선 검수 단계입니다.**\n"
              "전체 네트워크를 확인했어요. 예외가 없으므로 **[결선 검수 완료]**를 눌러 최종 검증으로 진행하시면 됩니다.";
        }
        return "⚡ **결선 검수 단계입니다.**\n"
            "확인이 필요한 결선 예외만 실제 경로와 함께 표시할게요. 해당 선로 또는 이슈를 선택해 근거를 확인해주세요.";
      case 'FINAL':
      case 'FINAL_CAD':
        return "✨ **검증이 끝났어요.**\n"
            "이제 엑셀 값을 연결하면 실제 조류계산을 할 수 있어요.";
      default:
        return "👋 PowerLens AI입니다. 무엇이든 편하게 물어보세요!";
    }
  }

  String? _getStageProactiveText(PowerLensAssistantContext ctx) {
    switch (ctx.workflowStage) {
      case 'HOME':
        return "도면 사진으로 시작할까요, 샘플로 체험할까요?";
      case 'OBJECT_REVIEW':
        final hasIssues =
            ctx.suspiciousObjects > 0 || ctx.unresolvedMissingCandidates > 0;
        return hasIssues
            ? "객체를 확인해봤어요. 다시 확인이 필요한 곳을 도면 위에 표시해둘게요."
            : "제가 따로 의심하는 객체는 없어요. 도면을 확인한 뒤 [객체 검수 완료]를 눌러주세요.";
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        if (_activeBusCount(ctx) == 0) {
          return "유효한 모선(Bus) 객체가 없어 모선 번호 검수를 진행할 수 없습니다.";
        }
        final hasBusIssues =
            ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0;
        final count = ctx.unresolvedBusNumbers + ctx.duplicateBusNumbers;
        final countStr = count > 0 ? " ${count}개" : "";
        return hasBusIssues
            ? "모선 번호를 전체 확인했어요. 다시 확인하면 좋은 모선이${countStr} 있어요. 도면에 표시해둘게요."
            : "제가 다시 확인할 모선은 이제 없어요. 전체 번호를 한번 확인한 뒤 [모선 검수 완료]를 눌러주세요.";
      case 'CONNECTION_REVIEW':
        final connectionLines = ctx.workingLines
            .map((raw) => ReviewLineItem.fromJson(raw))
            .toList();
        final connectionBlockers = ConnectionReviewGateEvaluator.getBlockers(
          workingLines: connectionLines,
          topologyIssues: ctx.topologyIssues,
        );
        return connectionBlockers.isNotEmpty
            ? "확인이 필요한 결선 예외를 실제 경로와 함께 표시할게요."
            : "전체 네트워크 결선이 정상 확인되었어요! [결선 검수 완료]를 눌러주세요.";
      case 'FINAL':
      case 'FINAL_CAD':
        return ctx.excelLoaded
            ? "엑셀 값이 연결됐어요. 이제 캔버스로 이동해 실제 조류계산을 실행할 수 있어요."
            : "검증이 끝났어요. 이제 엑셀 값을 연결하면 실제 조류계산을 할 수 있어요.";
      default:
        return null;
    }
  }

  List<String> _getQuickActions(
    String stage, [
    PowerLensAssistantContext? ctx,
  ]) {
    switch (stage) {
      case 'HOME':
        return ['샘플 도면 불러오기', '사진 다시 넣을래', '다음에 뭐 해?'];
      case 'OBJECT_REVIEW':
        final hasIssues =
            (ctx?.suspiciousObjects ?? 0) > 0 ||
            (ctx?.unresolvedMissingCandidates ?? 0) > 0;
        if (hasIssues) {
          return ['검토 필요 항목 보기', '다음에 뭐 해?', '누락 후보 확인'];
        }
        return ['객체 검수 완료하기', '다음 단계로 이동', '다음에 뭐 해?'];
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        if (ctx == null) {
          return ['객체 검수에서 모선 확인', '다음에 뭐 해?', '현재 상태 요약'];
        }
        if (_activeBusCount(ctx) == 0) {
          return ['객체 검수에서 모선 확인', '다음에 뭐 해?', '현재 상태 요약'];
        }
        final hasBusIssues =
            ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0;
        return [
          hasBusIssues ? '미지정 모선 확인' : '모선 검수 완료',
          '다음에 뭐 해?',
          '다음 단계로 이동',
        ];
      case 'CONNECTION_REVIEW':
        final connectionLines = ctx?.workingLines
                .map((raw) => ReviewLineItem.fromJson(raw))
                .toList() ??
            const <ReviewLineItem>[];
        final hasConnIssues = ctx == null
            ? true
            : ConnectionReviewGateEvaluator.getBlockers(
                workingLines: connectionLines,
                topologyIssues: ctx.topologyIssues,
              ).isNotEmpty;
        return [
          hasConnIssues ? '결선 예외 확인' : '결선 검수 완료하기',
          '다음에 뭐 해?',
          '전체 네트워크 요약',
        ];
      case 'FINAL':
      case 'FINAL_CAD':
        return ['조류계산 실행', '흐름 방향 보여줘', '다음에 뭐 해?'];
      default:
        return ['다음에 뭐 해?', '현재 상태 요약', '처음 화면으로 돌아가줘'];
    }
  }

  String _getStageNameKo(String stage) {
    switch (stage) {
      case 'HOME':
        return '홈 (도면 준비)';
      case 'OBJECT_REVIEW':
        return '객체 확인 (1단계)';
      case 'BUS_MAPPING':
      case 'BUS_MAPPING_REVIEW':
        return '모선 번호 확인 (2단계)';
      case 'CONNECTION_REVIEW':
        return '결선 확인 (3단계)';
      case 'FINAL':
      case 'FINAL_CAD':
        return '최종 검증 & CAD (4단계)';
      default:
        return stage;
    }
  }

  List<Map<String, String>> _buildHistoryPayload() {
    return _messages.take(10).map((m) {
      return {'role': m.isUser ? 'user' : 'model', 'content': m.text};
    }).toList();
  }

  void clearHistory() {
    _requestSerial++;
    _messages.clear();
    _lastNotifiedStage = null;
    _lastFailedQuery = null;
    _isLoading = false;
    _mascotState = 'idle';
    notifyListeners();
  }
}
