import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/review_models.dart';
import '../models/review_final_contract.dart';
import '../models/object_visual_sweep.dart';
import '../models/powerlens_assistant_context.dart';
import '../models/connection_visual_sweep.dart';
import '../models/review_coach_policy.dart';
import '../models/bus_mapping_feedback.dart';
import '../services/powerlens_ai_service.dart';
import '../services/review_api_service.dart';
import '../widgets/review_overlay.dart';
import '../widgets/excel_mismatch_dialog.dart';
import '../widgets/powerlens_ai/powerlens_ai_button.dart';
import '../widgets/powerlens_ai/powerlens_ai_panel.dart';
import '../widgets/powerlens_ai/powerlens_companion_layout.dart';
import '../widgets/powerlens_ai/glowing_target_wrapper.dart';
import '../widgets/object_inspector_view.dart';
import '../widgets/object_category_review_bar.dart';
import '../widgets/bus_inspector_view.dart';

enum ReviewPhase {
  objectReview,
  connectionReview,
  busMappingReview,
  verifiedFinal,
}

class ObjectReviewPage extends StatefulWidget {
  final Function(Map<String, dynamic> verifiedSldData)? onProceedToCanvas;
  final Future<bool> Function()? onRequestHome;
  final Uint8List? initialImageBytes;
  final String? initialFilename;

  const ObjectReviewPage({
    super.key,
    this.onProceedToCanvas,
    this.onRequestHome,
    this.initialImageBytes,
    this.initialFilename,
  });

  @override
  State<ObjectReviewPage> createState() => _ObjectReviewPageState();
}

class _ObjectReviewPageState extends State<ObjectReviewPage> {
  final ReviewApiService _apiService = ReviewApiService();

  ReviewPhase _currentPhase = ReviewPhase.objectReview;
  ReviewDocument? _document;
  List<ReviewNodeItem> _workingNodes = [];
  List<ReviewLineItem> _workingLines = [];
  VerifiedSLD? _verifiedSld;

  // Agent Activity Runs
  List<Map<String, dynamic>> _agentRuns = [];
  bool _isLoadingAgentRuns = false;

  // Selected Elements
  ReviewNodeItem? _selectedNode;
  ReviewLineItem? _selectedLine;

  // Filter & Sort
  String _objFilterStatus =
      'ALL'; // ALL, SUSPICIOUS, AUTO_CONFIRMED, HUMAN_CONFIRMED, REJECTED, MISSING
  String _objFilterClass = 'ALL'; // ALL, bus, generator, load, transformer
  String _objSortOption = 'SEVERITY'; // SEVERITY, CONFIDENCE_ASC, ID_ASC

  String _connFilterStatus =
      'ALL'; // ALL, NEEDS_REVIEW, CROSSING, REJECTED, ERROR_ONLY
  String _connSortOption = 'SEVERITY'; // SEVERITY, ID_ASC
  static const int _nodePageSize = 8;
  int _nodePage = 0;
  static const int _linePageSize = 10;
  int _linePage = 0;

  // Bus Number Mapping Review (Phase 2)
  String _busFilterStatus = 'ALL'; // ALL, UNCERTAIN, VERIFIED
  int _busPage = 0;
  static const int _busPageSize = 7;
  final TextEditingController _busNumberEditController =
      TextEditingController();
  Map<String, dynamic>? _importedExcelData;
  Map<String, dynamic>? _excelMismatchReport;

  // UX Simplification & Focus Modes
  bool _busFocusOnly = true;
  bool _lineFocusOnly = true;
  bool _showAllBusesList = false;
  bool _showAllLinesList = false;
  bool _connectionVisualSweepStarted = false;
  bool _connectionVisualSweepComplete = false;
  final Set<String> _visitedConnectionLineIds = <String>{};
  bool _coachTargetSyncQueued = false;
  String? _queuedCoachHighlightTarget;
  bool _showTopologyDetails = false;
  final FocusNode _reviewKeyFocusNode = FocusNode();

  // Loading & Modes
  bool _isLoading = false;
  String? _loadingMessage;
  bool _showCanvasLabels = true;

  // Object Manual Add & Edit
  bool _isManualAddMode = false;
  String _manualAddClass = 'bus';
  bool _isObjectEditExpanded = false;

  // Line Manual Add
  bool _isManualAddLineMode = false;
  ReviewNodeItem? _manualLineStartNode;

  // Global Completeness & Missing Candidates
  List<MissingCandidateItem> _missingCandidates = [];
  String? _completenessAssessment;
  String? _completenessMessageKo;
  bool _humanCompletenessConfirmed = false;
  final ObjectVisualSweepState _objectSweep = ObjectVisualSweepState();

  // Object Gate & Final Gate States
  bool _isObjectVerified = false;
  String? _objectGateMessage;

  bool _isFinalVerified = false;
  List<Map<String, dynamic>> _topologyIssues = [];
  Map<String, dynamic>? _selectedTopologyIssue;

  // Chatbot State
  final TextEditingController _chatInputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final List<ChatMessageItem> _chatHistory = [];
  bool _isChatLoading = false;

  // Statistics (Object)
  int get _objSuspiciousCount =>
      _workingNodes.where((n) => n.reviewStatus == 'SUSPICIOUS').length;
  int get _objDetectedCount =>
      _workingNodes.where((n) => n.reviewStatus == 'DETECTED').length;
  int get _objRejectedCount =>
      _workingNodes.where((n) => n.reviewStatus == 'REJECTED').length;
  int get _unresolvedCandidatesCount =>
      _missingCandidates.where((c) => c.status == 'OPEN').length;

  Set<String> _calculateGuideNodeIds(List<Map<String, dynamic>> focusTargets) {
    if (_currentPhase == ReviewPhase.busMappingReview) {
      return BusReviewGateEvaluator.computeGuideBusIds(
        workingNodes: _workingNodes,
        focusTargets: focusTargets,
      );
    }
    return ObjectReviewGateEvaluator.computeGuideNodeIds(
      workingNodes: _workingNodes,
      focusTargets: focusTargets,
    );
  }

  Set<String> get guideNodeIds =>
      _calculateGuideNodeIds(PowerLensAIService.instance.lastFocusTargets);

  bool get _isCleanAuto => ObjectReviewGateEvaluator.canVerifyGate(
    workingNodes: _workingNodes,
    missingCandidates: _missingCandidates,
  );

  bool get _canVerifyObjectGate => ObjectReviewGateEvaluator.canVerifyGate(
    workingNodes: _workingNodes,
    missingCandidates: _missingCandidates,
  );

  bool get _objectHumanCheckDone => _objectSweep.humanCompleteConfirmed;

  ReviewNodeItem? get _objectReviewCurrentTarget => _objectSweep.currentTarget(
    _workingNodes,
    hasOpenMissingCandidates: _unresolvedCandidatesCount > 0,
  );

  List<ObjectReviewCategoryStatus> get _objectReviewCategoryStatuses =>
      _objectSweep.reviewCategoryKeys(_workingNodes).map((key) {
        final count = _workingNodes
            .where(
              (node) =>
                  node.className.trim().toLowerCase() == key &&
                  node.reviewStatus.toUpperCase() != 'REJECTED',
            )
            .length;
        return ObjectReviewCategoryStatus(
          key: key,
          count: count,
          state: _objectSweep.getCategoryState(key, _workingNodes),
        );
      }).toList();

  String? get _selectedObjectCategoryKey {
    final selected = _objFilterClass.toLowerCase();
    if (_objectSweep.reviewCategoryKeys(_workingNodes).contains(selected)) {
      return selected;
    }
    return _objectSweep.currentCategoryKey;
  }

  ObjectReviewFlowStage get _objectReviewFlowStage => _objectSweep.stage(
    _workingNodes,
    hasOpenMissingCandidates: _unresolvedCandidatesCount > 0,
  );

  bool get _objectGateReadyForUser =>
      _canVerifyObjectGate && _objectHumanCheckDone && _objectHumanCheckReady;

  List<String> get _objectGateBlockers => ObjectReviewGateEvaluator.getBlockers(
    workingNodes: _workingNodes,
    missingCandidates: _missingCandidates,
  );

  // Statistics (Bus Number Mapping)
  List<ReviewNodeItem> get _busNodes =>
      BusReviewUiState.activeBusNodes(_workingNodes);
  List<int> get _duplicateBusNumbers {
    final counts = <int, int>{};
    for (final b in _busNodes) {
      if (b.busNumber != null && b.busNumber! > 0) {
        counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
      }
    }
    return counts.entries.where((e) => e.value > 1).map((e) => e.key).toList();
  }

  BusReviewUiState get _busUiState => BusReviewUiState.fromNodes(_workingNodes);

  int get _busUncertainCount => _busUiState.issueBuses;

  int get _busVerifiedCount => _busUiState.verifiedBuses;

  bool get _canVerifyBusGate =>
      BusReviewGateEvaluator.canVerifyGate(workingNodes: _workingNodes);

  List<String> get _busGateBlockers =>
      BusReviewGateEvaluator.getBlockers(workingNodes: _workingNodes);

  List<ReviewNodeItem> get _filteredAndSortedBusNodes {
    final guideIds = BusReviewGateEvaluator.computeGuideBusIds(
      workingNodes: _workingNodes,
    );
    final list = BusReviewUiState.filter(
      _workingNodes,
      status: _busFilterStatus,
    );
    list.sort((a, b) {
      final aIsIssue = guideIds.contains(a.id);
      final bIsIssue = guideIds.contains(b.id);
      if (aIsIssue && !bIsIssue) return -1;
      if (!aIsIssue && bIsIssue) return 1;
      final na = a.busNumber ?? 9999;
      final nb = b.busNumber ?? 9999;
      return na.compareTo(nb);
    });
    return list;
  }

  // Filtered & Sorted Working Nodes
  List<ReviewNodeItem> get _filteredAndSortedWorkingNodes {
    List<ReviewNodeItem> list = List.from(_workingNodes);

    if (_objFilterStatus == 'SUSPICIOUS') {
      list = list.where((n) => n.reviewStatus == 'SUSPICIOUS').toList();
    } else if (_objFilterStatus == 'AUTO_CONFIRMED') {
      list = list
          .where(
            (n) => n.reviewStatus == 'CONFIRMED' && !n.source.contains('human'),
          )
          .toList();
    } else if (_objFilterStatus == 'HUMAN_CONFIRMED') {
      list = list
          .where(
            (n) => n.reviewStatus == 'CONFIRMED' && n.source.contains('human'),
          )
          .toList();
    } else if (_objFilterStatus == 'DETECTED') {
      list = list.where((n) => n.reviewStatus == 'DETECTED').toList();
    } else if (_objFilterStatus == 'REJECTED') {
      list = list.where((n) => n.reviewStatus == 'REJECTED').toList();
    }

    if (_objFilterClass != 'ALL') {
      list = list
          .where((n) => n.className.toLowerCase() == _objFilterClass)
          .toList();
    }

    if (_objSortOption == 'SEVERITY') {
      list.sort((a, b) {
        int rank(ReviewNodeItem n) {
          if (n.reviewStatus == 'SUSPICIOUS') return 0;
          if (n.reviewStatus == 'DETECTED') return 1;
          if (n.reviewStatus == 'CONFIRMED') return 2;
          return 3;
        }

        return rank(a).compareTo(rank(b));
      });
    } else if (_objSortOption == 'CONFIDENCE_ASC') {
      list.sort((a, b) => a.confidence.compareTo(b.confidence));
    } else if (_objSortOption == 'ID_ASC') {
      list.sort((a, b) => a.id.compareTo(b.id));
    }

    return list;
  }

  // Statistics (Connection)
  int get _lineAmbiguousCount =>
      _activeConnectionLines.where((l) => l.reviewStatus == 'AMBIGUOUS').length;
  int get _lineDetectedCount =>
      _activeConnectionLines.where((l) => l.reviewStatus == 'DETECTED').length;
  int get _lineRejectedCount =>
      _workingLines.where((l) => l.reviewStatus == 'REJECTED').length;
  int get _criticalIssuesCount =>
      ConnectionReviewGateEvaluator.criticalErrorCount(
        workingLines: _workingLines,
        topologyIssues: _topologyIssues,
      );

  List<ReviewLineItem> get _activeConnectionLines =>
      ConnectionReviewGateEvaluator.activeLines(_workingLines);

  List<ReviewLineItem> get _connectionExceptionLines => _activeConnectionLines
      .where(ConnectionReviewGateEvaluator.isExceptionLine)
      .toList();

  int get _connectionCrossingCount => _activeConnectionLines
      .where(ConnectionReviewGateEvaluator.isUnresolvedCrossing)
      .length;

  List<String> get _connectionGateBlockers =>
      ConnectionReviewGateEvaluator.getBlockers(
        workingLines: _workingLines,
        topologyIssues: _topologyIssues,
      );

  Set<String> get _connectionGuideLineIds =>
      ConnectionReviewGateEvaluator.computeGuideLineIds(
        workingLines: _workingLines,
        topologyIssues: _topologyIssues,
        focusTargets: PowerLensAIService.instance.lastFocusTargets,
      );

  List<ReviewLineItem> get _connectionPriorityMissionLines {
    final mission = _workingLines
        .where((line) => line.reviewStatus != 'REJECTED')
        .toList();
    int rank(ReviewLineItem line) {
      if (line.validationIssues.isNotEmpty) return 0;
      if (line.reviewStatus == 'AMBIGUOUS') return 1;
      if (line.reviewStatus == 'DETECTED') return 2;
      return 3;
    }

    mission.sort((a, b) {
      final rankDiff = rank(a).compareTo(rank(b));
      return rankDiff == 0 ? a.lineId.compareTo(b.lineId) : rankDiff;
    });
    return mission.take(math.min(5, mission.length)).toList();
  }

  int get _connectionMissionCompleted => _connectionPriorityMissionLines
      .where((line) => line.reviewStatus == 'CONFIRMED')
      .length;

  bool get _connectionMissionComplete {
    final mission = _connectionPriorityMissionLines;
    return mission.isEmpty || _connectionMissionCompleted == mission.length;
  }

  bool get _canVerifyFinalGate => ConnectionReviewGateEvaluator.canVerifyGate(
    workingLines: _workingLines,
    topologyIssues: _topologyIssues,
  );

  // Filtered & Sorted Working Lines
  List<ReviewLineItem> get _filteredAndSortedWorkingLines {
    final list = ConnectionReviewGateEvaluator.filter(
      _workingLines,
      status: _connFilterStatus,
    );

    if (_connSortOption == 'SEVERITY') {
      list.sort((a, b) {
        int rank(ReviewLineItem l) {
          if (ConnectionReviewGateEvaluator.lineHasCriticalIssue(l)) return 0;
          if (ConnectionReviewGateEvaluator.isUnresolvedCrossing(l)) return 1;
          if (l.reviewStatus == 'AMBIGUOUS') return 2;
          return 3;
        }

        return rank(a).compareTo(rank(b));
      });
    } else if (_connSortOption == 'ID_ASC') {
      list.sort((a, b) => a.lineId.compareTo(b.lineId));
    }

    return list;
  }

  bool _isAiPanelOpen = false;
  bool _connectionFastMode = false;
  bool _connectionFullOverview = false;
  bool _connectionLinesOnlyMode = false;
  final GlobalKey _reviewStackKey = GlobalKey();
  final GlobalKey _reviewFocusTargetKey = GlobalKey();
  final GlobalKey _objectFilterKey = GlobalKey();
  final GlobalKey _connectionMissionKey = GlobalKey();
  final GlobalKey _connectionPrimaryActionKey = GlobalKey();
  final GlobalKey _connectionGateKey = GlobalKey();
  final GlobalKey _finalExcelUploadKey = GlobalKey();
  final GlobalKey _finalCanvasHandoffKey = GlobalKey();
  Alignment? _manualLensyAlignment;
  bool _isLensyDragging = false;
  BusMappingFeedback? _busMappingFeedback;
  String? _stageGateMessage;

  String get _reviewLensyPresenceState {
    if (_stageGateMessage != null || _isLoading) return 'thinking';
    if (_isFinalVerified) return 'success';
    return 'idle';
  }

  ReviewCoachDecision get _reviewCoachDecision =>
      ReviewCoachPolicy.resolve(_buildAssistantContext());

  String get _lensyCoachTarget {
    final decision = _reviewCoachDecision;
    return decision.coachMode == 'BLOCKED' ? '' : decision.coachTarget ?? '';
  }

  void _scheduleReviewLensyTargetSync() {
    final service = PowerLensAIService.instance;
    final target = _reviewCoachDecision.highlightTarget;
    if (service.stageHighlightTarget == target &&
        service.activeHighlightTarget.value == target) {
      return;
    }
    if (_coachTargetSyncQueued && _queuedCoachHighlightTarget == target) {
      return;
    }
    _coachTargetSyncQueued = true;
    _queuedCoachHighlightTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _coachTargetSyncQueued = false;
      final currentTarget = _reviewCoachDecision.highlightTarget;
      _queuedCoachHighlightTarget = currentTarget;
      service.setStageHighlightTarget(currentTarget);
    });
  }

  Alignment _effectiveReviewLensyAlignment(
    String target, {
    required bool isMobile,
  }) {
    if (_manualLensyAlignment != null) {
      return _manualLensyAlignment!;
    }
    return PowerLensCompanionLayout.defaultAlignmentForCoachTarget(target);
  }

  void _handleReviewLensyDrag(
    Offset delta,
    String target, {
    required bool isMobile,
  }) {
    final size =
        _reviewStackKey.currentContext?.size ?? MediaQuery.of(context).size;
    final current = _effectiveReviewLensyAlignment(target, isMobile: isMobile);
    double clampAlignment(double value) => value.clamp(-0.94, 0.94).toDouble();
    if (!isMobile) {
      final viewport = Size(size.width, size.height);
      final panelBounds = _panelBoundsForViewport(viewport);
      final currentRect = _desktopLensyGroupRect(
        viewport,
        current,
        panelOpen: _isAiPanelOpen,
        panelBounds: panelBounds,
      );
      final nextCenter =
          PowerLensCompanionLayout.robotCenter(currentRect) + delta;
      final proposed = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: PowerLensCompanionLayout.alignmentForRobotCenter(
          nextCenter,
          viewport,
        ),
        panelOpen: _isAiPanelOpen,
        panelBounds: panelBounds,
      );
      setState(() {
        _manualLensyAlignment =
            PowerLensCompanionLayout.alignmentForRobotCenter(
              PowerLensCompanionLayout.robotCenter(proposed),
              viewport,
            );
      });
      return;
    }
    setState(() {
      _manualLensyAlignment = Alignment(
        clampAlignment(current.x + delta.dx / math.max(size.width / 2, 1)),
        clampAlignment(current.y + delta.dy / math.max(size.height / 2, 1)),
      );
    });
  }

  Size _panelBoundsForViewport(Size viewport) {
    final requestedWidth = (viewport.width * 0.76)
        .clamp(380.0, 980.0)
        .toDouble();
    final width = math.min(
      requestedWidth,
      math.max(320.0, viewport.width - 24),
    );
    final reservedHeight =
        PowerLensCompanionLayout.robotAnchorHeight +
        PowerLensCompanionLayout.panelGap +
        24;
    final height = math.min(
      760.0,
      math.max(120.0, viewport.height - reservedHeight),
    );
    return Size(width, height);
  }

  Rect _desktopLensyGroupRect(
    Size viewport,
    Alignment alignment, {
    required bool panelOpen,
    required Size panelBounds,
  }) => PowerLensCompanionLayout.groupRect(
    viewport: viewport,
    robotCenterAlignment: alignment,
    panelOpen: panelOpen,
    panelBounds: panelBounds,
  );

  void _setAiPanelOpen(bool isOpen, Size viewport) {
    final alignment = _effectiveReviewLensyAlignment(
      _lensyCoachTarget,
      isMobile: false,
    );
    final bounds = _panelBoundsForViewport(viewport);
    final proposed = _desktopLensyGroupRect(
      viewport,
      alignment,
      panelOpen: isOpen,
      panelBounds: bounds,
    );
    final center = PowerLensCompanionLayout.robotCenter(proposed);
    setState(() {
      _manualLensyAlignment = PowerLensCompanionLayout.alignmentForRobotCenter(
        center,
        viewport,
      );
      _isAiPanelOpen = isOpen;
    });
  }

  void _handleReviewLensyDragStart() {
    if (!mounted) return;
    setState(() => _isLensyDragging = true);
  }

  void _handleReviewLensyDragEnd() {
    if (!mounted || !_isLensyDragging) return;
    setState(() => _isLensyDragging = false);
  }

  void _resetReviewLensyPosition() {
    PowerLensAIService.instance.resetPanelOffset();
    setState(() {
      _manualLensyAlignment = null;
      _isLensyDragging = false;
    });
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalReviewKeyEvent);
    PowerLensAIService.instance.registerActionHandler(_handleAppAction);
    if (widget.initialImageBytes != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _processImageBytes(
          widget.initialImageBytes!,
          widget.initialFilename ?? 'sample_diagram_ieee24.jpg',
        );
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalReviewKeyEvent);
    PowerLensAIService.instance.unregisterActionHandler(_handleAppAction);
    _busNumberEditController.dispose();
    _reviewKeyFocusNode.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  Future<bool> _handleAppAction(
    PowerLensAppAction action,
    Map<String, dynamic>? params,
  ) async {
    if (!mounted) return false;

    switch (action) {
      case PowerLensAppAction.goHome:
        final handled = await widget.onRequestHome?.call() ?? true;
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        return handled;
      case PowerLensAppAction.triggerPhotoUpload:
        if (_isLoading) return false;
        return _pickAndUploadImage();
      case PowerLensAppAction.triggerExcelUpload:
        if (_isLoading ||
            !ReviewFinalContract.canImportExcel(
              isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
              verifiedSld: _verifiedSld,
            )) {
          return false;
        }
        await _importExcelInReview();
        // Opening the native/web picker is the action requested by the user.
        // A cancelled picker must not be reported as an unsupported action.
        return true;
      case PowerLensAppAction.loadSampleDiagram:
        if (_isLoading) return false;
        final previousDocumentId = _document?.documentId;
        await _loadSampleDiagram();
        return mounted &&
            _document?.documentId != null &&
            _document?.documentId != previousDocumentId;
      case PowerLensAppAction.showReviewIssues:
        return _focusReviewIssueForAgent();
      case PowerLensAppAction.approveCurrentAndNext:
        return _approveCurrentAndNextForAgent();
      case PowerLensAppAction.approveAllClean:
        return false;
      case PowerLensAppAction.connectionFullReview:
        return _showConnectionFullReviewForAgent();
      case PowerLensAppAction.connectionLinesOnly:
        return _showConnectionLinesOnlyForAgent();
      case PowerLensAppAction.connectionNextLine:
        return _showConnectionNextLineForAgent();
      case PowerLensAppAction.confirmBusNumber:
        return _confirmBusNumberFromAgent(params?['bus_number']);
      case PowerLensAppAction.confirmObjectCompleteness:
        return _confirmObjectCompletenessFromAgent();
      case PowerLensAppAction.handoffToCanvas:
        return _handoffToFlutterCanvas();
      case PowerLensAppAction.goToNextStage:
        return _advanceReviewStageForAgent();
      case PowerLensAppAction.goToPreviousStage:
        return _returnToPreviousReviewStageForAgent();
      case PowerLensAppAction.runPowerFlow:
        if (_currentPhase == ReviewPhase.verifiedFinal &&
            _verifiedSld != null) {
          return _handoffToFlutterCanvas();
        }
        return false;
      case PowerLensAppAction.showPowerFlowResults:
        return false;
      case PowerLensAppAction.explainCurrentStage:
        return false;
      case PowerLensAppAction.toggleFlowDirection:
      case PowerLensAppAction.showFlowDirection:
      case PowerLensAppAction.hideFlowDirection:
      case PowerLensAppAction.toggleValueLabels:
      case PowerLensAppAction.showValueLabels:
      case PowerLensAppAction.hideValueLabels:
        // These actions belong to the CAD/power-flow canvas. Returning false
        // lets the root canvas handler receive them through the handler stack.
        return false;
    }
  }

  Future<bool> _confirmObjectCompletenessFromAgent() async {
    if (_currentPhase != ReviewPhase.objectReview || _isLoading) return false;
    if (!_objectHumanCheckReady) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage =
              '남아 있는 의심 항목과 설비 종류별 확인을 마친 뒤 “확인했어”라고 알려주세요.';
        });
      }
      return false;
    }
    if (!_canVerifyObjectGate) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage = _objectGateBlockers.isEmpty
              ? '아직 객체 검수를 완료할 수 없습니다.'
              : '객체 검수 전에 남은 항목이 있어요: ${_objectGateBlockers.first}';
        });
      }
      return false;
    }
    setState(() {
      _objectSweep.confirmHumanComplete(
        _workingNodes,
        hasOpenMissingCandidates: _unresolvedCandidatesCount > 0,
      );
      _humanCompletenessConfirmed = true;
      _stageGateMessage = '좋습니다. 마지막으로 아래 [객체 검수 완료]를 눌러주세요.';
    });
    _announceReviewStage();
    return true;
  }

  Future<bool> _confirmBusNumberFromAgent(Object? rawNumber) async {
    if (_currentPhase != ReviewPhase.busMappingReview || _isLoading)
      return false;
    final number = rawNumber is num
        ? rawNumber.toInt()
        : int.tryParse(rawNumber?.toString() ?? '');
    final active = _selectedNode;
    if (number == null ||
        number < 1 ||
        number > 50 ||
        active == null ||
        active.className.toLowerCase() != 'bus') {
      setState(() {
        _stageGateMessage = '모선 번호는 1부터 50 사이에서 입력하고, 도면에서 모선을 먼저 선택해주세요.';
      });
      return false;
    }
    final duplicate = _busNodes.any(
      (node) => node.id != active.id && node.busNumber == number,
    );
    if (duplicate) {
      setState(() {
        _stageGateMessage = '이미 사용 중인 모선 번호라 적용하지 않았어요. 중복되지 않는 번호를 입력해주세요.';
      });
      return false;
    }
    _handleApplyBusNumber(active, number);
    return true;
  }

  bool get _objectHumanCheckReady => _objectSweep.isComplete(
    _workingNodes,
    hasOpenMissingCandidates: _unresolvedCandidatesCount > 0,
  );

  void _selectReviewNode(ReviewNodeItem node, {int? listPage}) {
    setState(() {
      _selectedNode = node;
      _isObjectEditExpanded = false;
      if (listPage != null) _nodePage = listPage;
    });
    if (node.reviewStatus == 'SUSPICIOUS' && node.agentExplanation == null) {
      _triggerAgentReviewNode(node);
    }
    if (_currentPhase == ReviewPhase.objectReview) _announceReviewStage();
  }

  void _refreshObjectReviewFocus({bool exceptionResolved = false}) {
    if (_currentPhase != ReviewPhase.objectReview) return;
    final unresolved = _objectSweep.unresolvedExceptions(_workingNodes);
    final hasOpenCandidates = _unresolvedCandidatesCount > 0;
    final target = _objectSweep.currentTarget(
      _workingNodes,
      hasOpenMissingCandidates: hasOpenCandidates,
    );
    setState(() {
      if (!_objectHumanCheckReady) _objectSweep.invalidateHumanComplete();
      if (unresolved.isNotEmpty) {
        _objFilterStatus = 'SUSPICIOUS';
        _objFilterClass = 'ALL';
        _selectedNode = unresolved.first;
        _stageGateMessage =
            'AI가 확인이 필요한 객체 ${unresolved.length}개를 찾았습니다. 먼저 반짝이는 객체부터 확인해 주세요.';
      } else {
        _objFilterStatus = 'ALL';
        if (hasOpenCandidates) {
          _objFilterClass = 'ALL';
        } else if (_objectSweep.isAllCategoriesReviewed(_workingNodes)) {
          _runFinalObjectDeterministicCheck();
        } else {
          _objectSweep.selectCategory('bus', _workingNodes);
          _objFilterClass = 'bus';
          final busNodes = _workingNodes
              .where(
                (node) =>
                    node.className.trim().toLowerCase() == 'bus' &&
                    node.reviewStatus.toUpperCase() != 'REJECTED',
              )
              .toList();
          _selectedNode = busNodes.isNotEmpty ? busNodes.first : null;
          _stageGateMessage =
              'AI 1차 검수에서 확인이 필요한 객체는 모두 정리됐어요.\n'
              '이제 객체 종류별로 전체 도면을 한 번 확인해 주세요.\n'
              '먼저 Bus 객체부터 확인하겠습니다.\n'
              '모선이 빠짐없이 잡혔는지 확인한 뒤 오른쪽 화살표를 눌러주세요.';
        }
      }
    });
    if (_selectedNode?.reviewStatus == 'SUSPICIOUS' &&
        _selectedNode?.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
    _announceReviewStage();
  }

  void _selectObjectReviewCategory(String categoryKey) {
    final key = categoryKey.trim().toLowerCase();
    if (!_objectSweep.reviewCategoryKeys(_workingNodes).contains(key)) return;
    final categoryNodes = _workingNodes
        .where(
          (node) =>
              node.className.trim().toLowerCase() == key &&
              node.reviewStatus.toUpperCase() != 'REJECTED',
        )
        .toList();
    setState(() {
      _objectSweep.selectCategory(key, _workingNodes);
      _objFilterStatus = 'ALL';
      _objFilterClass = key;
      _nodePage = 0;
      _selectedNode = categoryNodes.isEmpty ? null : categoryNodes.first;
      _stageGateMessage = '${_objectCategoryLabel(key)} 객체를 보고 있어요. 도면을 확인해주세요.';
    });
    _announceReviewStage();
  }

  void _handleObjectCategoryConfirmAndNext() {
    final currentKey = _objectSweep.currentCategoryKey;
    setState(() {
      final advanced = _objectSweep.confirmCurrentAndGoNext(_workingNodes);
      final nextKey = _objectSweep.currentCategoryKey;
      _objFilterStatus = 'ALL';
      _objFilterClass = nextKey;
      _nodePage = 0;
      final nextNodes = _workingNodes
          .where(
            (node) =>
                node.className.trim().toLowerCase() == nextKey &&
                node.reviewStatus.toUpperCase() != 'REJECTED',
          )
          .toList();
      _selectedNode = nextNodes.isNotEmpty ? nextNodes.first : null;

      if (advanced) {
        if (currentKey == 'bus' && nextKey == 'load') {
          _stageGateMessage = 'Bus 확인을 마쳤어요.\n이번에는 Load 객체를 확인해주세요.';
        } else if (currentKey == 'load' && nextKey == 'generator') {
          _stageGateMessage = 'Load 확인을 마쳤어요.\n이번에는 Generator 객체를 확인해주세요.';
        } else if (currentKey == 'generator' && nextKey == 'transformer') {
          _stageGateMessage =
              'Generator 확인을 마쳤어요.\n마지막으로 Transformer 객체를 확인해주세요.';
        } else {
          _stageGateMessage =
              '${_objectCategoryLabel(currentKey)} 확인을 마쳤어요.\n이번에는 ${_objectCategoryLabel(nextKey)} 객체를 확인해주세요.';
        }
      } else {
        // Last category (Transformer) confirmed!
        _stageGateMessage =
            'Bus, Load, Generator, Transformer를 모두 확인했어요.\n검사해 주셔서 감사합니다. 나머지는 제가 한 번 더 확인할게요.';
        _runFinalObjectDeterministicCheck();
      }
    });
    _announceReviewStage();
  }

  void _handleObjectCategoryPrevious() {
    setState(() {
      final wentBack = _objectSweep.goPreviousCategory(_workingNodes);
      if (wentBack) {
        final prevKey = _objectSweep.currentCategoryKey;
        _objFilterStatus = 'ALL';
        _objFilterClass = prevKey;
        _nodePage = 0;
        final prevNodes = _workingNodes
            .where(
              (node) =>
                  node.className.trim().toLowerCase() == prevKey &&
                  node.reviewStatus.toUpperCase() != 'REJECTED',
            )
            .toList();
        _selectedNode = prevNodes.isNotEmpty ? prevNodes.first : null;
        _stageGateMessage =
            '${_objectCategoryLabel(prevKey)} 객체를 다시 보여드릴게요.\n필요한 부분을 다시 확인해주세요.';
      }
    });
    _announceReviewStage();
  }

  void _handleObjectCategorySelectAll() {
    setState(() {
      _objFilterStatus = 'ALL';
      _objFilterClass = 'ALL';
      _nodePage = 0;
      _stageGateMessage = '전체 도면의 객체를 보고 있어요.';
    });
    _announceReviewStage();
  }

  void _runFinalObjectDeterministicCheck() {
    final suspicious = _objectSweep.unresolvedExceptions(_workingNodes);
    final missing = _unresolvedCandidatesCount;
    final blockers = _objectGateBlockers;
    final validNodes = _workingNodes
        .where((n) => n.reviewStatus.toUpperCase() != 'REJECTED')
        .toList();

    if (suspicious.isEmpty &&
        missing == 0 &&
        blockers.isEmpty &&
        validNodes.isNotEmpty) {
      _objectSweep.confirmHumanComplete(_workingNodes);
      setState(() {
        _stageGateMessage = '객체 검수가 모두 완료됐습니다.\n아래 [객체 검수 완료]를 눌러주세요.';
      });
      PowerLensAIService.instance
          .setStageHighlightTarget('object_gate');
    } else {
      setState(() {
        if (suspicious.isNotEmpty) {
          _stageGateMessage = '아직 확인이 필요한 의심 객체가 ${suspicious.length}개 있습니다.';
        } else if (missing > 0) {
          _stageGateMessage = '해결되지 않은 누락 후보가 ${missing}개 있습니다.';
        } else if (blockers.isNotEmpty) {
          _stageGateMessage = '객체 검수 완료를 위해 확인이 필요합니다: ${blockers.first}';
        }
      });
    }
  }

  void _handleObjectReviewPrimaryAction() {
    if (_objSuspiciousCount > 0 || _unresolvedCandidatesCount > 0) {
      _focusNextReviewTask();
      return;
    }
    if (!_objectHumanCheckReady &&
        _objectReviewFlowStage == ObjectReviewFlowStage.categoryReview) {
      _handleObjectCategoryConfirmAndNext();
      return;
    }
    if (_objectHumanCheckReady && !_objectHumanCheckDone) {
      _runFinalObjectDeterministicCheck();
      return;
    }
    _focusNextReviewTask();
  }

  String _objectCategoryLabel(String key) {
    switch (key.toLowerCase()) {
      case 'bus':
        return 'Bus';
      case 'load':
        return 'Load';
      case 'generator':
        return 'Generator';
      case 'transformer':
        return 'Transformer';
      default:
        if (key.isEmpty) return key;
        return '${key[0].toUpperCase()}${key.substring(1)}';
    }
  }

  bool _focusReviewIssueForAgent() {
    setState(() {
      if (_currentPhase == ReviewPhase.objectReview) {
        final suspicious = _workingNodes
            .where((node) => node.reviewStatus == 'SUSPICIOUS')
            .toList();
        if (suspicious.isNotEmpty) {
          _objFilterStatus = 'SUSPICIOUS';
          _objFilterClass = 'ALL';
          _selectedNode = suspicious.first;
          _nodePage = 0;
        } else {
          _objFilterStatus = 'ALL';
          _objFilterClass = 'ALL';
          if (_selectedNode == null && _workingNodes.isNotEmpty) {
            _selectedNode = _workingNodes.first;
          }
        }
      } else if (_currentPhase == ReviewPhase.busMappingReview) {
        final hasIssues = _busUiState.isBlocked;
        if (hasIssues) {
          _busFilterStatus = 'UNCERTAIN';
          final uncertain = _filteredAndSortedBusNodes;
          _selectedNode = uncertain.isNotEmpty ? uncertain.first : null;
        } else {
          _busFilterStatus = 'ALL';
          final allBuses = _filteredAndSortedBusNodes;
          _selectedNode = allBuses.isNotEmpty ? allBuses.first : null;
        }
        _busPage = 0;
        _selectedLine = null;
      } else if (_currentPhase == ReviewPhase.connectionReview) {
        final guideIds = _connectionGuideLineIds;
        _linePage = 0;
        _connFilterStatus = guideIds.isNotEmpty ? 'NEEDS_REVIEW' : 'ALL';
        _showAllLinesList = true;
        _showTopologyDetails = _topologyIssues.isNotEmpty;
        final issues = _filteredAndSortedWorkingLines;
        _selectedLine = issues.isNotEmpty ? issues.first : null;
        _selectedNode = null;
      }
    });

    if (_selectedNode?.reviewStatus == 'SUSPICIOUS' &&
        _selectedNode?.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
    if (_currentPhase == ReviewPhase.objectReview &&
        _objSuspiciousCount == 0 &&
        _unresolvedCandidatesCount == 0) {
      _focusNextReviewTask();
    }
    return true;
  }

  bool _showConnectionFullReviewForAgent() {
    return false;
  }

  bool _showConnectionLinesOnlyForAgent() {
    if (_currentPhase != ReviewPhase.connectionReview) return false;
    if (_connectionGateBlockers.isNotEmpty) {
      return _focusReviewIssueForAgent();
    }
    if (!_connectionVisualSweepStarted) {
      _startConnectionVisualSweep();
      return _connectionVisualSweepStarted;
    }
    setState(() => _lineFocusOnly = true);
    return true;
  }

  bool _showConnectionNextLineForAgent() {
    return false;
  }

  bool _approveCurrentAndNextForAgent() {
    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        // Object Review V2: sequential approveCurrentAndNext does not exist
        return false;
      case ReviewPhase.busMappingReview:
        // Bus Mapping V2: sequential approveCurrentAndNext does not exist
        return false;
      case ReviewPhase.connectionReview:
        // Connection Review V2 has no implicit approval or auto-next action.
        return false;
      case ReviewPhase.verifiedFinal:
        return false;
    }
  }

  Future<bool> _advanceReviewStageForAgent() async {
    if (_isLoading) return false;

    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        await _completeObjectReview();
        return _currentPhase == ReviewPhase.busMappingReview;
      case ReviewPhase.busMappingReview:
        await _completeBusReview();
        return _currentPhase == ReviewPhase.connectionReview;
      case ReviewPhase.connectionReview:
        await _verifyFinalGate();
        return _currentPhase == ReviewPhase.verifiedFinal;
      case ReviewPhase.verifiedFinal:
        return _handoffToFlutterCanvas();
    }
  }

  bool _returnToPreviousReviewStageForAgent() {
    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        return false;
      case ReviewPhase.busMappingReview:
        setState(() {
          _currentPhase = ReviewPhase.objectReview;
          _selectedLine = null;
          _objFilterStatus = 'SUSPICIOUS';
          final nodes = _filteredAndSortedWorkingNodes;
          _selectedNode = nodes.isNotEmpty
              ? nodes.first
              : _workingNodes.firstOrNull;
        });
        return true;
      case ReviewPhase.connectionReview:
        setState(() {
          _currentPhase = ReviewPhase.busMappingReview;
          _selectedLine = null;
          _busFilterStatus = 'ALL';
          final buses = _filteredAndSortedBusNodes;
          _selectedNode = buses.isNotEmpty ? buses.first : null;
        });
        return true;
      case ReviewPhase.verifiedFinal:
        setState(() {
          _currentPhase = ReviewPhase.connectionReview;
          _connectionFullOverview = false;
          _connectionLinesOnlyMode = false;
          _connectionFastMode = false;
          _lineFocusOnly = false;
          _connectionVisualSweepStarted = false;
          _connectionVisualSweepComplete = false;
          _showAllLinesList = false;
          _selectedNode = null;
          _connFilterStatus = 'ALL';
          _selectedLine = null;
        });
        FocusManager.instance.primaryFocus?.unfocus();
        return true;
    }
  }

  PowerLensAssistantContext _buildAssistantContext() {
    final connectionBlockers = _connectionGateBlockers;

    return PowerLensAssistantContext(
      currentScreen: 'REVIEW_PAGE',
      workflowStage: _currentPhase == ReviewPhase.objectReview
          ? 'OBJECT_REVIEW'
          : _currentPhase == ReviewPhase.busMappingReview
          ? 'BUS_MAPPING'
          : _currentPhase == ReviewPhase.connectionReview
          ? 'CONNECTION_REVIEW'
          : 'FINAL',
      documentId: _document?.documentId ?? '',
      hasDiagram: _document != null,
      totalObjects: _workingNodes.length,
      suspiciousObjects: _objSuspiciousCount,
      unresolvedMissingCandidates: _unresolvedCandidatesCount,
      totalBuses: _busNodes.length,
      unresolvedBusNumbers: _busUncertainCount,
      duplicateBusNumbers: _duplicateBusNumbers.length,
      totalConnections: _activeConnectionLines.length,
      ambiguousConnections: _connectionExceptionLines.length,
      topologyIssueCount: _topologyIssues
          .where(ConnectionReviewGateEvaluator.isCriticalIssue)
          .length,
      connectionVisualSweepStarted: _connectionVisualSweepStarted,
      connectionVisualSweepComplete: _connectionVisualSweepComplete,
      finalVerified: _verifiedSld != null,
      excelLoaded: _importedExcelData != null,
      excelMappingStatus: _importedExcelData == null
          ? 'NONE'
          : _excelMismatchReport?['is_matched'] == true
          ? 'MATCHED'
          : _excelMismatchReport?['is_matched'] == false
          ? 'MISMATCH'
          : 'UNKNOWN',
      selectedNode: _selectedNode?.toJson(),
      selectedLine: _selectedLine?.toJson(),
      workingNodes: _workingNodes.map((node) => node.toJson()).toList(),
      workingLines: _workingLines.map((line) => line.toJson()).toList(),
      missingCandidates: _missingCandidates
          .map((candidate) => candidate.toJson())
          .toList(),
      topologyIssues: _topologyIssues,
      selectedElement: _currentPhase == ReviewPhase.busMappingReview
          ? (_selectedNode?.busNumber != null
                ? "Bus ${_selectedNode!.busNumber}"
                : _selectedNode?.id)
          : (_currentPhase == ReviewPhase.connectionReview
                ? _selectedLine?.effectiveDisplayLabel
                : _selectedNode?.effectiveDisplayLabel),
      currentBlockers: _currentPhase == ReviewPhase.objectReview
          ? _objectGateBlockers
          : _currentPhase == ReviewPhase.busMappingReview
          ? _busGateBlockers
          : connectionBlockers,
      objectHumanCompletenessConfirmed:
          _objectHumanCheckDone && _objectHumanCheckReady,
      objectReviewStage: _objectReviewFlowStage.wireName,
      objectVisualSweepVisited: _objectSweep.reviewedCategoryCount(
        _workingNodes,
      ),
      objectVisualSweepTotal: _objectSweep.reviewCategoryKeys(
        _workingNodes,
      ).length,
      objectVisualSweepCurrentId: _objectReviewCurrentTarget?.id,
      busMappingAiReading: _isLinkingBusNumbers,
      activeBusId: _selectedNode?.className.toLowerCase() == 'bus'
          ? _selectedNode?.id
          : null,
      busModelUsed: _busModelUsed,
      busFallbackUsed: _busFallbackUsed,
      busFailureCode: _busHttpCode?.toString(),
    );
  }

  void _announceReviewStage() {
    final stage = _currentPhase == ReviewPhase.objectReview
        ? 'OBJECT_REVIEW'
        : _currentPhase == ReviewPhase.busMappingReview
        ? 'BUS_MAPPING'
        : _currentPhase == ReviewPhase.connectionReview
        ? 'CONNECTION_REVIEW'
        : 'FINAL';
    PowerLensAIService.instance.onStageChanged(stage, _buildAssistantContext());
  }

  // --- Step 1: Upload & Object Detection ---

  Future<void> _processImageBytes(Uint8List bytes, String filename) async {
    try {
      setState(() {
        _isLoading = true;
        _loadingMessage = "AI 객체 검출 및 근거 수집 중... 🔍";
        _selectedNode = null;
        _selectedLine = null;
        _isObjectVerified = false;
        _objectGateMessage = null;
        _currentPhase = ReviewPhase.objectReview;
        _workingLines.clear();
        _verifiedSld = null;
        _missingCandidates.clear();
        _completenessAssessment = null;
        _completenessMessageKo = null;
        _humanCompletenessConfirmed = false;
        _objectSweep.reset();
        _visitedConnectionLineIds.clear();
        _busModelUsed = null;
        _busFallbackUsed = false;
        _busHttpCode = null;
        _objFilterStatus = 'ALL';
        _objFilterClass = 'ALL';
        _nodePage = 0;
        _chatHistory.clear();
      });
      PowerLensAIService.instance.clearFocusTargets();

      final doc = await _apiService.detectObjects(bytes, filename);
      PowerLensAIService.instance.setProviderMode(
        doc.proactiveSummary?.providerMode,
      );

      setState(() {
        _document = doc;
        _workingNodes = List.from(doc.nodes);
        final suspiciousNodes = _objectSweep.unresolvedExceptions(
          _workingNodes,
        );
        _objFilterStatus = suspiciousNodes.isNotEmpty ? 'SUSPICIOUS' : 'ALL';

        _selectedNode = _objectSweep.currentTarget(_workingNodes);
        if (suspiciousNodes.isEmpty) {
          _objectSweep.selectCategory('bus', _workingNodes);
          _objFilterClass = 'bus';
          final busNodes = _workingNodes
              .where(
                (n) =>
                    n.className.trim().toLowerCase() == 'bus' &&
                    n.reviewStatus.toUpperCase() != 'REJECTED',
              )
              .toList();
          _selectedNode = busNodes.isNotEmpty ? busNodes.first : null;
          _stageGateMessage =
              'AI 1차 검수에서 확인이 필요한 객체는 모두 정리됐어요.\n'
              '이제 객체 종류별로 전체 도면을 한 번 확인해 주세요.\n'
              '먼저 Bus 객체부터 확인하겠습니다.\n'
              '모선이 빠짐없이 잡혔는지 확인한 뒤 오른쪽 화살표를 눌러주세요.';
        }
        _isLoading = false;

        // Greeting and Proactive Summary in Chat
        final suspiciousCount = suspiciousNodes.length;
        final summaryMsg = suspiciousCount == 0
            ? 'AI 1차 검수에서 확인이 필요한 객체는 모두 정리됐어요. 이제 객체 종류별로 전체 도면을 한 번 확인해 주세요. 먼저 Bus 객체부터 확인하겠습니다. 모선이 빠짐없이 잡혔는지 확인한 뒤 오른쪽 화살표를 눌러주세요.'
            : 'AI가 확인이 필요한 객체 ${suspiciousCount}개를 찾았습니다. 먼저 반짝이는 객체부터 확인해 주세요.';

        _chatHistory.add(
          ChatMessageItem(
            role: "assistant",
            text: summaryMsg,
            agentStatus: "LOCAL_READY",
            providerMode: doc.proactiveSummary?.providerMode,
          ),
        );
      });

      _announceReviewStage();

      // Auto run Global Completeness Review
      _triggerCompletenessReview();

      if (_selectedNode != null &&
          _selectedNode!.reviewStatus == 'SUSPICIOUS') {
        _triggerAgentReviewNode(_selectedNode!);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("도면 분석 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<bool> _pickAndUploadImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) return false;

      final Uint8List bytes = await file.readAsBytes();
      final String filename = file.name;
      await _processImageBytes(bytes, filename);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("이미지 선택 오류: $e"), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  // --- Global Completeness Review Logic ---

  Future<void> _triggerCompletenessReview() async {
    if (_document == null) return;
    try {
      final res = await _apiService.checkCompleteness(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
      );
      setState(() {
        _missingCandidates = List.from(res.candidates);
        _completenessAssessment = res.assessment;
        _completenessMessageKo = res.messageKo;
      });
      _refreshObjectReviewFocus();
    } catch (e) {
      print("완결성 검사 호출 오류: $e");
    }
  }

  void _dismissCandidate(MissingCandidateItem cand) {
    setState(() {
      cand.status = 'DISMISSED_BY_HUMAN';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "✓ '${_classNameKo(cand.suspectedClass)}' 누락 후보를 [문제 없음]으로 처리했습니다.",
        ),
        backgroundColor: const Color(0xFF16A34A),
        duration: const Duration(seconds: 2),
      ),
    );
    _refreshObjectReviewFocus(
      exceptionResolved: _objectSweep.hasResolvedExceptions,
    );
  }

  Future<void> _fetchAgentRuns() async {
    if (_document == null) return;
    setState(() => _isLoadingAgentRuns = true);
    try {
      final runs = await _apiService.fetchAgentRuns(_document!.documentId);
      if (mounted) {
        setState(() {
          _agentRuns = runs;
          _isLoadingAgentRuns = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingAgentRuns = false);
    }
  }

  // --- Step 2: Agent Node Review & Human Correction ---

  Future<void> _triggerAgentReviewNode(ReviewNodeItem node) async {
    if (_document == null) return;
    try {
      final res = await _apiService.agentReviewNode(
        _document!.documentId,
        node,
      );
      setState(() {
        node.agentExplanation = (res['explanation_ko'] ?? res['message_ko'])
            ?.toString();
        node.recommendedAction = res['recommended_action']?.toString();
        if (res['review_reasons'] is List) {
          node.reviewReasons = (res['review_reasons'] as List)
              .map((reason) => reason.toString())
              .toList();
        }
        if (res['evidence'] is Map) {
          node.evidence = Map<String, dynamic>.from(res['evidence'] as Map);
        }
        if (res['metadata'] is Map) {
          node.metadata = Map<String, dynamic>.from(res['metadata'] as Map);
        }
        if (res['suggested_classes'] is List) {
          node.suggestedClasses = (res['suggested_classes'] as List)
              .map((e) => e.toString())
              .toList();
        }
      });
    } catch (e) {
      print("Agent 검수 호출 오류: $e");
    }
  }

  void _rejectNode(ReviewNodeItem node) {
    final wasException = node.reviewStatus.toUpperCase() == 'SUSPICIOUS';
    _objectSweep.markExceptionResolved(
      node.id,
      wasException: wasException,
      categoryKey: node.className,
    );
    final removedLineIds = _workingLines
        .where((line) => line.connectedTo.contains(node.id))
        .map((line) => line.lineId)
        .toSet();

    setState(() {
      _workingNodes.removeWhere((item) => item.id == node.id);
      _workingLines.removeWhere((line) => removedLineIds.contains(line.lineId));

      if (_selectedLine != null &&
          removedLineIds.contains(_selectedLine!.lineId)) {
        _selectedLine = null;
      }

      final remainingSuspicious = _workingNodes
          .where((item) => item.reviewStatus == 'SUSPICIOUS')
          .toList();
      final remainingVisible = _filteredAndSortedWorkingNodes;
      _selectedNode = remainingSuspicious.isNotEmpty
          ? remainingSuspicious.first
          : (remainingVisible.isNotEmpty ? remainingVisible.first : null);
      _isObjectVerified = false;
      _isFinalVerified = false;
    });

    if (_selectedNode?.agentExplanation == null &&
        _selectedNode?.reviewStatus == 'SUSPICIOUS') {
      _triggerAgentReviewNode(_selectedNode!);
    }
    if (_currentPhase == ReviewPhase.connectionReview && _document != null) {
      _triggerTopologyValidation();
    }
    _refreshObjectReviewFocus(exceptionResolved: wasException);

    final removedLineMessage = removedLineIds.isEmpty
        ? ''
        : ' 연결된 선로 ${removedLineIds.length}개도 함께 삭제했습니다.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${node.effectiveDisplayLabel} 객체를 삭제했습니다.$removedLineMessage',
        ),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  void _changeNodeClass(ReviewNodeItem node, String newClass) {
    final wasException = node.reviewStatus.toUpperCase() == 'SUSPICIOUS';
    _objectSweep.markExceptionResolved(
      node.id,
      wasException: wasException,
      categoryKey: node.className,
    );
    setState(() {
      node.className = newClass;
      node.reviewStatus = 'CONFIRMED';
      node.source = 'human_class_changed';
    });
    _refreshObjectReviewFocus(exceptionResolved: wasException);
  }

  // Navigation Logic
  void _selectNextSuspiciousNode() {
    final suspicious = _workingNodes
        .where((n) => n.reviewStatus == 'SUSPICIOUS')
        .toList();
    if (suspicious.isEmpty) {
      setState(() => _selectedNode = null);
      return;
    }

    int currentIdx = _selectedNode != null
        ? suspicious.indexOf(_selectedNode!)
        : -1;
    int nextIdx = (currentIdx + 1) % suspicious.length;
    setState(() {
      _selectedNode = suspicious[nextIdx];
    });
    if (_selectedNode!.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
  }

  void _selectPreviousSuspiciousNode() {
    final suspicious = _workingNodes
        .where((n) => n.reviewStatus == 'SUSPICIOUS')
        .toList();
    if (suspicious.isEmpty) {
      setState(() => _selectedNode = null);
      return;
    }

    int currentIdx = _selectedNode != null
        ? suspicious.indexOf(_selectedNode!)
        : 0;
    int prevIdx = (currentIdx - 1 + suspicious.length) % suspicious.length;
    setState(() {
      _selectedNode = suspicious[prevIdx];
    });
    if (_selectedNode!.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
  }

  // --- Bus Mapping V2 Methods ---
  String? _validateBusNumberInput(ReviewNodeItem busNode, int num) {
    if (num < 1 || num > 50) return '모선 번호는 1부터 50 사이에서 입력해주세요.';
    final duplicate = _busNodes.any(
      (other) => other.id != busNode.id && other.busNumber == num,
    );
    if (duplicate) return '이미 사용 중인 모선 번호라 적용하지 않았어요. 중복되지 않는 번호를 입력해주세요.';
    return null;
  }

  void _handleApplyBusNumber(ReviewNodeItem busNode, int num) {
    final validationMessage = _validateBusNumberInput(busNode, num);
    if (validationMessage != null) {
      setState(() => _stageGateMessage = validationMessage);
      return;
    }

    // A human edit resolves the current agent focus for this node. The
    // deterministic Bus evaluator will add it back only if the edit leaves a
    // real issue, such as a duplicate number.
    PowerLensAIService.instance.removeFocusTarget(busNode.id);

    setState(() {
      final oldNum = busNode.busNumber;
      busNode.busNumber = num;
      busNode.source = busNode.source.contains('human')
          ? busNode.source
          : '${busNode.source}_human_modified';

      busNode.busNumberStatus = 'VERIFIED';
      busNode.displayLabel = "Bus $num";
      busNode.busNumberReasons.removeWhere(
        (r) =>
            r.startsWith('DUPLICATE_BUS_NUMBER_') ||
            r == 'NO_BUS_NUMBER_FOUND' ||
            r.startsWith('INVALID_BUS_NUMBER_'),
      );
      _propagateBusNumber(busNode, num, isDuplicate: false);

      // Check if previous duplicate for oldNum got resolved
      if (oldNum != null && oldNum != num) {
        final remainingWithOld = _busNodes
            .where((b) => b.busNumber == oldNum)
            .toList();
        if (remainingWithOld.length == 1) {
          final solo = remainingWithOld.first;
          solo.busNumberReasons.removeWhere(
            (r) => r == 'DUPLICATE_BUS_NUMBER_$oldNum',
          );
          if (solo.busNumberReasons.isEmpty) {
            solo.busNumberStatus = 'VERIFIED';
            solo.displayLabel = "Bus $oldNum";
            _propagateBusNumber(solo, oldNum, isDuplicate: false);
          }
        }
      }
    });

    final next = _filteredAndSortedBusNodes.firstWhere(
      (bus) => BusReviewGateEvaluator.computeGuideBusIds(
        workingNodes: _workingNodes,
      ).contains(bus.id),
      orElse: () => _filteredAndSortedBusNodes.firstWhere(
        (bus) => bus.id != busNode.id,
        orElse: () => busNode,
      ),
    );
    setState(() {
      _selectedNode = next;
      _busNumberEditController.text = next.busNumber?.toString() ?? '';
      _stageGateMessage = _canVerifyBusGate
          ? '모든 모선 번호가 확인됐어요. 결선 검수로 자동 이동합니다.'
          : '번호를 적용했어요. 다음 확인 모선을 표시했습니다.';
    });
    _announceReviewStage();
    if (_canVerifyBusGate && mounted && !_isLoading) {
      _verifyBusGateAutomatically();
    }
  }

  List<ReviewNodeItem> _getConnectedGensForBus(ReviewNodeItem busNode) {
    final gens = <ReviewNodeItem>[];
    for (final line in _workingLines) {
      if (line.connectedTo.contains(busNode.id)) {
        final otherId = line.connectedTo.first == busNode.id
            ? (line.connectedTo.length > 1 ? line.connectedTo[1] : null)
            : line.connectedTo.first;
        if (otherId != null) {
          final other = _workingNodes.firstWhere(
            (n) => n.id == otherId,
            orElse: () => busNode,
          );
          if (other.id != busNode.id &&
              other.className.toLowerCase().contains('gen')) {
            gens.add(other);
          }
        }
      }
    }
    return gens;
  }

  List<ReviewNodeItem> _getConnectedLoadsForBus(ReviewNodeItem busNode) {
    final loads = <ReviewNodeItem>[];
    for (final line in _workingLines) {
      if (line.connectedTo.contains(busNode.id)) {
        final otherId = line.connectedTo.first == busNode.id
            ? (line.connectedTo.length > 1 ? line.connectedTo[1] : null)
            : line.connectedTo.first;
        if (otherId != null) {
          final other = _workingNodes.firstWhere(
            (n) => n.id == otherId,
            orElse: () => busNode,
          );
          if (other.id != busNode.id &&
              other.className.toLowerCase().contains('load')) {
            loads.add(other);
          }
        }
      }
    }
    return loads;
  }

  String _getReviewStageSpeechBubbleText() {
    if (_stageGateMessage != null && _stageGateMessage!.isNotEmpty) {
      return _stageGateMessage!;
    }
    return _reviewCoachDecision.coachMessage;
  }

  void _startConnectionVisualSweep() {
    if (_connectionGateBlockers.isNotEmpty) return;
    final ordered = ConnectionVisualSweep.orderedLines(_activeConnectionLines);
    if (ordered.isEmpty) return;
    setState(() {
      _connectionVisualSweepStarted = true;
      _connectionVisualSweepComplete = ordered.length == 1;
      _visitedConnectionLineIds.clear();
      _lineFocusOnly = true;
      _connFilterStatus = ConnectionReviewGateEvaluator.filterAll;
      _showAllLinesList = false;
      _selectedLine = ordered.first;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _linePage = 0;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _moveConnectionVisualSweep(int delta) {
    if (_connectionGateBlockers.isNotEmpty) return;
    if (!_connectionVisualSweepStarted) {
      if (delta > 0) _startConnectionVisualSweep();
      return;
    }
    final ordered = ConnectionVisualSweep.orderedLines(_activeConnectionLines);
    final next = ConnectionVisualSweep.adjacentLine(
      orderedLines: ordered,
      selectedLineId: _selectedLine?.lineId,
      delta: delta,
    );
    if (next == null) return;
    final index = ConnectionVisualSweep.indexOf(ordered, next.lineId);
    setState(() {
      if (_selectedLine != null && _selectedLine!.lineId != next.lineId) {
        _visitedConnectionLineIds.add(_selectedLine!.lineId);
      }
      _lineFocusOnly = true;
      _connFilterStatus = ConnectionReviewGateEvaluator.filterAll;
      _showAllLinesList = false;
      _selectedLine = next;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _connectionVisualSweepComplete = index == ordered.length - 1;
      _linePage = index < 0 ? 0 : index ~/ _linePageSize;
    });
  }

  bool _handleGlobalReviewKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;

    final focusedWidget = FocusManager.instance.primaryFocus;
    final isTyping =
        focusedWidget != null &&
        focusedWidget.hasFocus &&
        focusedWidget.context?.mounted == true &&
        (focusedWidget.context?.widget is EditableText ||
            focusedWidget.toString().contains('EditableText') ||
            focusedWidget.toString().contains('TextField'));

    if (isTyping) {
      return false;
    }

    if (BusReviewUiPolicy.shouldIgnoreGlobalKeyForBus(
      isBusPhase: _currentPhase == ReviewPhase.busMappingReview,
      isTyping: isTyping,
      keyLabel: event.logicalKey.keyLabel,
    )) {
      // Bus Mapping is an explicit-number review; global arrows/Enter must
      // not advance a hidden sequential queue. TextField Enter returned
      // above so the inspector can apply its edited number.
      return true;
    }

    // Arrow Right or Down: Navigate to Next
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_currentPhase == ReviewPhase.connectionReview) {
        _moveConnectionVisualSweep(1);
        return true;
      }
    }

    // Arrow Left or Up: Navigate to Previous
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_currentPhase == ReviewPhase.connectionReview) {
        _moveConnectionVisualSweep(-1);
        return true;
      }
    }

    // Enter: Confirm and Next
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_currentPhase == ReviewPhase.connectionReview &&
          _selectedLine != null) {
        // Enter is deliberately not an approval shortcut in Connection V2.
        return true;
      }
    }

    // Delete or Backspace: Reject/Exclude
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      if (_currentPhase == ReviewPhase.objectReview && _selectedNode != null) {
        _rejectNode(_selectedNode!);
        return true;
      } else if (_currentPhase == ReviewPhase.connectionReview &&
          _selectedLine != null) {
        _rejectLine(_selectedLine!);
        return true;
      }
    }

    return false;
  }

  void _handleReviewKeyEvent(KeyEvent event) {
    // Handled globally via HardwareKeyboard.instance.addHandler(_handleGlobalReviewKeyEvent)
  }

  void _editNodeDisplayLabel(ReviewNodeItem node) {
    final controller = TextEditingController(text: node.effectiveDisplayLabel);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(
          "${node.id} 표시명 / 번호 수정",
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "도면의 실제 번호와 일치하도록 표시명을 수정하세요:",
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              style: const TextStyle(color: Color(0xFF0F172A)),
              decoration: const InputDecoration(
                labelText: "표시 이름 (예: BUS 4, LOAD 2)",
                labelStyle: TextStyle(color: Color(0xFF2563EB)),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            onPressed: () {
              final newText = controller.text.trim();
              if (newText.isNotEmpty) {
                setState(() {
                  node.displayLabel = newText;
                });
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
            child: const Text("저장"),
          ),
        ],
      ),
    );
  }

  // --- Manual Add Handlers ---

  void _handleManualAddComplete(List<double> bbox, String className) {
    final newId =
        "manual_${className}_${DateTime.now().millisecondsSinceEpoch % 10000}";
    final count =
        _workingNodes.where((n) => n.className == className).length + 1;
    final prefix = className == 'bus'
        ? 'BUS'
        : (className == 'generator'
              ? 'GEN'
              : (className == 'load' ? 'LOAD' : 'TRANS'));
    final dispLabel = "$prefix $count";

    final newNode = ReviewNodeItem(
      id: newId,
      className: className,
      bbox: bbox,
      confidence: 1.0,
      source: 'human_manual_add',
      reviewStatus: 'CONFIRMED',
      reviewReasons: ['수동으로 추가된 객체'],
      displayLabel: dispLabel,
      displayNumber: count,
    );

    setState(() {
      _workingNodes.add(newNode);
      _selectedNode = newNode;
      _isManualAddMode = false;

      for (var cand in _missingCandidates) {
        if (cand.status == 'OPEN' && cand.suspectedClass == className) {
          cand.status = 'RESOLVED_BY_MANUAL_ADD';
          break;
        }
      }
    });
    _refreshObjectReviewFocus(
      exceptionResolved: _objectSweep.hasResolvedExceptions,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("$dispLabel ($className) 객체가 수동 추가되었습니다."),
        backgroundColor: Colors.purple,
      ),
    );
  }

  Future<bool> _runReviewStageGate({
    required bool Function() canProceed,
    required List<String> Function() blockers,
  }) async {
    if (!mounted) return false;
    setState(() {
      _stageGateMessage = '잠깐만요. 제가 마지막으로 한번 확인하고 넘어갈게요.';
    });
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (!mounted) return false;
    if (!canProceed()) {
      final remaining = blockers();
      setState(() {
        _stageGateMessage = remaining.isEmpty
            ? '마지막 확인에서 아직 완료되지 않은 항목이 있어요. 제가 해당 위치를 가리킬게요.'
            : '마지막 확인에서 다음 항목이 남아 있어요:\n• ${remaining.join('\n• ')}';
      });
      return false;
    }
    return true;
  }

  // --- Step 3: Object Gate Verification & Unified Completion ---

  Future<void> _completeObjectReview() async {
    if (_document == null || _isLoading) return;

    if (!_objectHumanCheckDone || !_objectHumanCheckReady) {
      setState(() {
        _stageGateMessage = '설비 종류별 확인을 마친 뒤 Lensy에게 “확인했어”라고 말씀해 주세요.';
      });
      _focusNextReviewTask();
      return;
    }

    if (!_canVerifyObjectGate) {
      final blockers = _objectGateBlockers;
      final blockerCount = _objSuspiciousCount + _unresolvedCandidatesCount;
      setState(() {
        _stageGateMessage = blockerCount > 0
            ? "아직 확인이 필요한 객체가 $blockerCount개 있어요. 표시해드릴게요."
            : (blockers.isNotEmpty ? blockers.first : "확인이 필요한 항목이 남아있습니다.");
      });
      _focusNextReviewTask();
      return;
    }

    _humanCompletenessConfirmed = true;
    await _verifyObjectGate();
  }

  Future<void> _verifyObjectGate() async {
    if (_document == null) return;

    final gateReady = await _runReviewStageGate(
      canProceed: () => _canVerifyObjectGate,
      blockers: () => _objectGateBlockers,
    );
    if (!gateReady) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage = _objectGateBlockers.isEmpty
              ? '마지막 확인에서 다시 볼 객체를 찾았어요. 제가 첫 번째 항목을 가리켰습니다.'
              : '마지막 확인에서 다음 항목이 남아 있어요:\n• ${_objectGateBlockers.join('\n• ')}';
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = "객체 확정 Gate 검증 중... 🚪";
      _objectGateMessage = null;
    });

    try {
      final res = await _apiService.verifyObjectsGate(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
        missingCandidates: _missingCandidates,
        humanCompletenessConfirmed: _humanCompletenessConfirmed || _isCleanAuto,
      );

      setState(() {
        _isLoading = false;
        _isObjectVerified = res['gate_status'] == 'OBJECT_VERIFIED';
        _objectGateMessage = res['message']?.toString();
        _stageGateMessage = _isObjectVerified
            ? null
            : (_objectGateMessage ?? '객체 Gate에서 다시 확인이 필요해요.');
      });

      if (mounted) {
        if (_isObjectVerified) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✓ 객체 검수 Gate 통과! 모선 번호 매핑 단계로 진행합니다."),
              backgroundColor: Colors.green,
            ),
          );
          _proceedToBusMappingReview();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_objectGateMessage ?? "객체 Gate 차단됨"),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _stageGateMessage = '객체 마지막 확인에 실패했어요. 잠시 후 다시 시도해주세요.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("단계 검증 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Step 4: Bus Gate Verification & Unified Completion ---

  Future<void> _completeBusReview() async {
    if (_document == null || _isLoading) return;

    if (!_canVerifyBusGate) {
      final blockers = _busGateBlockers;
      final issueCount = BusReviewGateEvaluator.computeGuideBusIds(
        workingNodes: _workingNodes,
      ).length;
      setState(() {
        _stageGateMessage = issueCount > 0
            ? "아직 번호 확인이 필요한 모선이 ${issueCount}개 있어요. 표시해드릴게요."
            : (blockers.isNotEmpty ? blockers.first : "확인이 필요한 항목이 남아있습니다.");
      });
      _focusNextReviewTask();
      return;
    }

    await _verifyBusGate();
  }

  Future<void> _verifyBusGate() async {
    if (_document == null) return;

    final gateReady = await _runReviewStageGate(
      canProceed: () => _canVerifyBusGate,
      blockers: () => _busGateBlockers,
    );
    if (!gateReady) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage = _busGateBlockers.isEmpty
              ? '마지막 확인에서 다시 볼 모선을 찾았어요. 제가 첫 번째 항목을 가리켰습니다.'
              : '마지막 확인에서 다음 항목이 남아 있어요:\n• ${_busGateBlockers.join('\n• ')}';
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = "모선 번호 Gate 검증 중... 🚪";
      _stageGateMessage = null;
    });

    try {
      final res = await _apiService.verifyBusGate(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
      );

      final isBusVerified = res['gate_status'] == 'BUS_VERIFIED';
      final gateMsg = res['message']?.toString();

      setState(() {
        _isLoading = false;
        _stageGateMessage = isBusVerified
            ? null
            : (gateMsg ?? '모선 Gate에서 다시 확인이 필요해요.');
      });

      if (mounted) {
        if (isBusVerified) {
          PowerLensAIService.instance.clearFocusTargets();
          await _proceedToConnectionReview();
        } else {
          _focusNextReviewTask();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(gateMsg ?? "모선 Gate 차단됨"),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _stageGateMessage = '모선 마지막 확인에 실패했어요. 잠시 후 다시 시도해주세요.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("단계 검증 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Phase 3: Connection Detection & Review ---

  Future<void> _proceedToConnectionReview() async {
    if (!_isObjectVerified || _document == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("먼저 객체 검수를 완료해야 합니다."),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (_isLoading) return;

    final gateReady = await _runReviewStageGate(
      canProceed: () => _canVerifyBusGate,
      blockers: () => _busGateBlockers,
    );
    if (!gateReady) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage = _busGateBlockers.isEmpty
              ? '마지막 확인에서 다시 볼 모선을 찾았어요. 제가 첫 번째 항목을 가리켰습니다.'
              : '마지막 확인에서 다음 항목이 남아 있어요:\n• ${_busGateBlockers.join('\n• ')}';
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _stageGateMessage = '확인됐어요. 선로 연결을 준비하고 있어요.';
      _loadingMessage = "확정 객체 기반 결선 인식 중... 🔗";
      _connFilterStatus = 'ALL';
      _linePage = 0;
      _showAllLinesList = false;
      _connectionFullOverview = false;
      _connectionLinesOnlyMode = false;
      _connectionFastMode = false;
      _connectionVisualSweepStarted = false;
      _connectionVisualSweepComplete = false;
      _visitedConnectionLineIds.clear();
      _lineFocusOnly = false;
      _selectedLine = null;
      _selectedNode = null;
    });

    try {
      final confirmedNodes = _workingNodes
          .where(
            (n) =>
                n.reviewStatus == 'CONFIRMED' || n.reviewStatus == 'DETECTED',
          )
          .toList();
      final res = await _apiService.detectConnections(
        _document!.documentId,
        confirmedNodes,
      );
      final rawLines = res['lines'] as List? ?? [];
      final parsedLines = rawLines
          .map((l) => ReviewLineItem.fromJson(l as Map<String, dynamic>))
          .toList();
      final rawNodes = res['nodes'] as List?;
      List<ReviewNodeItem>? parsedNodes;
      if (rawNodes != null && rawNodes.isNotEmpty) {
        parsedNodes = rawNodes
            .map((n) => ReviewNodeItem.fromJson(n as Map<String, dynamic>))
            .toList();
      }

      setState(() {
        _currentPhase = ReviewPhase.connectionReview;
        if (parsedNodes != null) {
          _workingNodes = parsedNodes;
        }
        _workingLines = parsedLines;
        _selectedLine = null;
        _selectedNode = null;
        _isLoading = false;
        _stageGateMessage = null;
        _connectionFullOverview = false;
        _connectionLinesOnlyMode = false;
        _connectionFastMode = false;
        _connectionVisualSweepStarted = false;
        _connectionVisualSweepComplete = false;
        _visitedConnectionLineIds.clear();
        _lineFocusOnly = false;
      });

      FocusManager.instance.primaryFocus?.unfocus();
      PowerLensAIService.instance.clearFocusTargets();
      _announceReviewStage();
      _triggerTopologyValidation();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _stageGateMessage = '선로 연결 준비에 실패했어요. 현재 단계에서 다시 확인해주세요.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("결선 검출 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Step 5: Topology Validation & Connection Review ---

  Future<void> _triggerTopologyValidation() async {
    if (_document == null) return;
    try {
      final res = await _apiService.validateTopology(
        documentId: _document!.documentId,
        nodes: _workingNodes,
        lines: _workingLines,
      );

      final rawAnnotated = res['annotated_lines'];
      final annotatedById = <String, ReviewLineItem>{};
      if (rawAnnotated is List) {
        for (final raw in rawAnnotated) {
          if (raw is Map) {
            final parsed = ReviewLineItem.fromJson(
              Map<String, dynamic>.from(raw),
            );
            annotatedById[parsed.lineId] = parsed;
          }
        }
      }

      setState(() {
        _topologyIssues = List<Map<String, dynamic>>.from(res['issues'] ?? []);
        _connectionVisualSweepComplete = false;
        if (annotatedById.isNotEmpty) {
          _workingLines = _workingLines.map((current) {
            final annotated = annotatedById[current.lineId];
            if (annotated == null) return current;
            annotated.connectionReviewResolution =
                current.connectionReviewResolution;
            if (annotated.candidateTargets.isEmpty) {
              annotated.candidateTargets = List.from(current.candidateTargets);
            }
            return annotated;
          }).toList();
          if (_selectedLine != null) {
            final matching = _workingLines.where(
              (line) => line.lineId == _selectedLine!.lineId,
            );
            _selectedLine = matching.isEmpty ? null : matching.first;
          }
        }
        final gateBlockers = _connectionGateBlockers;
        if (gateBlockers.isNotEmpty) {
          final guideIds = ConnectionReviewGateEvaluator.computeGuideLineIds(
            workingLines: _workingLines,
            topologyIssues: _topologyIssues,
          );
          final guidedLines = ConnectionVisualSweep.orderedLines(
            _activeConnectionLines.where(
              (line) => guideIds.contains(line.lineId),
            ),
          );
          if (_selectedLine == null ||
              !guideIds.contains(_selectedLine!.lineId)) {
            _selectedLine = guidedLines.isEmpty ? null : guidedLines.first;
          }
        } else if (!_connectionVisualSweepStarted) {
          _selectedLine = null;
        }
      });

      final validLineIds = _connectionGuideLineIds;
      final validIssueIds = ConnectionReviewGateEvaluator.computeGuideIssueIds(
        topologyIssues: _topologyIssues,
        workingLines: _workingLines,
      );
      PowerLensAIService.instance.setFocusTargets(
        PowerLensAIService.instance.lastFocusTargets.where((target) {
          final type = target['type']?.toString().toUpperCase();
          final id = target['id']?.toString();
          if (type == 'LINE') return id != null && validLineIds.contains(id);
          if (type == 'ISSUE') return id != null && validIssueIds.contains(id);
          return true;
        }).toList(),
      );
    } catch (e) {
      print("토폴로지 검증 오류: $e");
    }
  }

  Future<void> _handleManualAddLineComplete(
    ReviewNodeItem startNode,
    ReviewNodeItem endNode,
  ) async {
    if (_document == null) return;
    final requestedPair = {startNode.id, endNode.id};
    final alreadyExists = _workingLines.any(
      (line) =>
          line.connectedTo.toSet().containsAll(requestedPair) &&
          requestedPair.containsAll(line.connectedTo.toSet()),
    );
    if (alreadyExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이미 같은 두 객체를 연결하는 선로가 있습니다.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = '원본 이미지에서 실제 선 픽셀 경로를 추적하는 중...';
    });

    try {
      final result = await _apiService.traceConnectionCandidate(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
        sourceNodeId: startNode.id,
        targetNodeId: endNode.id,
      );
      if (!mounted) return;
      if (result['status'] != 'success' || result['path_found'] != true) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result['message']?.toString() ??
                    '두 객체 사이의 실제 선 픽셀 경로를 찾지 못했습니다.',
              ),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
        return;
      }

      final rawLine = Map<String, dynamic>.from(result['line'] as Map);
      final newLineId =
          "manual_line_${DateTime.now().millisecondsSinceEpoch % 10000}";
      final lineNum = _workingLines.length + 1;
      final dispLabel = "L$lineNum";
      final endpointsStr =
          "${startNode.effectiveDisplayLabel} ↔ ${endNode.effectiveDisplayLabel}";

      rawLine.addAll({
        'line_id': newLineId,
        'review_status': 'CONFIRMED',
        'source': 'human_approved_pixel_trace',
        'trace_method': 'human_requested_source_pixel_trace',
        'display_label': dispLabel,
        'display_name': "$dispLabel ($endpointsStr)",
        'endpoints_display': endpointsStr,
      });
      final newLine = ReviewLineItem.fromJson(rawLine);

      setState(() {
        _workingLines.add(newLine);
        _selectedLine = newLine;
        _isManualAddLineMode = false;
        _manualLineStartNode = null;
        _isLoading = false;
      });

      _triggerTopologyValidation();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("$dispLabel ($endpointsStr) 실제 픽셀 선로가 추가되었습니다."),
          backgroundColor: Colors.purple,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('선로 픽셀 재추적 실패: $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  // --- Step 6: Final Gate & Handoff ---

  Future<void> _verifyFinalGate() async {
    if (_document == null) return;
    if (_isLoading) return;

    final gateReady = await _runReviewStageGate(
      canProceed: () => _canVerifyFinalGate,
      blockers: () => _connectionGateBlockers,
    );
    if (!gateReady) {
      _focusNextReviewTask();
      if (mounted) {
        setState(() {
          _stageGateMessage = '마지막 확인에서 선로 검토가 더 필요해요. 제가 첫 번째 문제 위치를 가리켰습니다.';
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _stageGateMessage = '확인됐어요. Verified SLD를 만드는 중이에요.';
      _loadingMessage = "최종 토폴로지 검증 및 VerifiedSLD 생성 중... ⚡";
    });

    try {
      final res = await _apiService.verifyFinalGate(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
        workingLines: _workingLines,
        humanCompletenessConfirmed: _humanCompletenessConfirmed,
      );

      setState(() {
        _isLoading = false;
        _isFinalVerified = res['gate_status'] == 'VERIFIED';
        _stageGateMessage = _isFinalVerified ? null : '최종 확인에서 다시 검토할 선로가 있어요.';
        if (res['verified_sld'] != null) {
          _verifiedSld = VerifiedSLD.fromJson(
            res['verified_sld'] as Map<String, dynamic>,
          );
          _currentPhase = ReviewPhase.verifiedFinal;
        }
      });
      if (_isFinalVerified) _announceReviewStage();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _stageGateMessage = '최종 확인에 실패했어요. 현재 선로 상태를 다시 확인해주세요.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("최종 검증 오류: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  bool _handoffToFlutterCanvas() {
    final canImport = ReviewFinalContract.canImportExcel(
      isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
      verifiedSld: _verifiedSld,
    );
    if (!canImport) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("최종 검증을 통과한 회로도만 편집 화면으로 전달할 수 있습니다."),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
    if (_importedExcelData == null) {
      PowerLensAIService.instance.triggerHighlight('final_excel_upload');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("검증이 끝났어요. 먼저 조류계산에 사용할 Excel 제원을 연결해주세요."),
          backgroundColor: Color(0xFF0F766E),
        ),
      );
      return false;
    }
    if (!ReviewFinalContract.hasVerifiedExcelMatch(_excelMismatchReport)) {
      PowerLensAIService.instance.triggerHighlight(
        _excelMismatchReport == null
            ? 'final_excel_upload'
            : 'excel_mismatch_btn',
      );
      final reportMessage = _excelMismatchReport?['summary']?.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reportMessage == null || reportMessage.isEmpty
                ? "Excel 대조 결과를 확인하지 못해 CAD로 전달할 수 없습니다. 파일을 다시 불러와주세요."
                : "Excel 불일치가 남아 있어요: $reportMessage",
          ),
          backgroundColor: Colors.orange.shade900,
        ),
      );
      return false;
    }

    final data = _verifiedSld!.toJson();
    data['excel_data'] = _importedExcelData;
    data['mismatch_report'] = _excelMismatchReport;
    widget.onProceedToCanvas?.call(data);
    if (Navigator.canPop(context)) {
      Navigator.pop(context, data);
    }
    return true;
  }

  Future<void> _confirmResetToBeginning() async {
    final bool? shouldReset = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.restart_alt, color: Color(0xFFDC2626), size: 24),
            SizedBox(width: 8),
            Text(
              "검수 처음으로 돌아가기",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Color(0xFF0F172A),
              ),
            ),
          ],
        ),
        content: const Text(
          "검수를 처음 단계(① 객체 검수)로 되돌리시겠습니까?\n\n"
          "• 적용된 엑셀 데이터 및 불일치 알림이 초기화됩니다.\n"
          "• 선로 결선 및 최종 검증 상태가 리셋되며, 최초 도면 AI 인식 객체 목록으로 복원됩니다.",
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Color(0xFF334155),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("취소", style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text("처음으로 돌아가기"),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
        ],
      ),
    );

    if (shouldReset == true) {
      _resetToReviewBeginning();
    }
  }

  void _resetToReviewBeginning() {
    ScaffoldMessenger.of(context).clearSnackBars();
    setState(() {
      _importedExcelData = null;
      _excelMismatchReport = null;
      _currentPhase = ReviewPhase.objectReview;
      _connectionVisualSweepStarted = false;
      _connectionVisualSweepComplete = false;
      _isObjectVerified = false;
      _isFinalVerified = false;
      _objectGateMessage = null;
      _humanCompletenessConfirmed = false;
      _objectSweep.reset();
      _workingLines.clear();
      _verifiedSld = null;
      _topologyIssues.clear();
      _selectedTopologyIssue = null;
      _selectedLine = null;
      _missingCandidates.clear();
      _completenessAssessment = null;
      _completenessMessageKo = null;
      _objFilterStatus = 'ALL';
      _objFilterClass = 'ALL';

      if (_document != null) {
        _workingNodes = _document!.nodes
            .map((n) => ReviewNodeItem.fromJson(n.toJson()))
            .toList();
        _selectedNode = _objectSweep.currentTarget(_workingNodes);
      }
      _busNumberEditController.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("🔄 검수 첫 단계(① 객체 검수)로 돌아왔습니다. 엑셀 연계가 초기화되었습니다."),
        backgroundColor: Color(0xFF2563EB),
        duration: Duration(seconds: 3),
        showCloseIcon: true,
        closeIconColor: Colors.white,
      ),
    );
  }

  // --- Chat Assistant Logic ---

  Future<void> _sendChatMessage(String text) async {
    if (text.trim().isEmpty || _document == null) return;

    final userMsg = ChatMessageItem(role: "user", text: text.trim());
    setState(() {
      _chatHistory.add(userMsg);
      if (_chatHistory.length > 20) {
        _chatHistory.removeRange(0, _chatHistory.length - 20);
      }
      _isChatLoading = true;
      _chatInputController.clear();
    });

    _scrollChatToBottom();

    try {
      final stageStr = _currentPhase == ReviewPhase.objectReview
          ? "OBJECT_REVIEW"
          : (_currentPhase == ReviewPhase.busMappingReview
                ? "BUS_MAPPING_REVIEW"
                : (_currentPhase == ReviewPhase.connectionReview
                      ? "CONNECTION_REVIEW"
                      : "FINAL"));

      final res = await _apiService.sendAgentChat(
        documentId: _document!.documentId,
        message: userMsg.text,
        stage: stageStr,
        selectedNode: _selectedNode,
        selectedLine: _selectedLine,
        workingNodes: _workingNodes,
        workingLines: _workingLines,
        missingCandidates: _missingCandidates,
        topologyIssues: _topologyIssues,
        history: _chatHistory,
      );

      final reply = res['reply_ko']?.toString() ?? "답변을 가져올 수 없습니다.";
      final agentStatus = res['agent_status']?.toString();
      final providerMode = res['provider_mode']?.toString();

      setState(() {
        _chatHistory.add(
          ChatMessageItem(
            role: "assistant",
            text: reply,
            agentStatus: agentStatus,
            providerMode: providerMode,
          ),
        );
        _isChatLoading = false;
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(
          ChatMessageItem(
            role: "assistant",
            text: "오류가 발생했습니다: $e",
            agentStatus: "ERROR",
          ),
        );
        _isChatLoading = false;
      });
    }

    _scrollChatToBottom();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- UI Helpers & Colors ---

  Color _getClassColor(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return const Color(0xFF00E676);
    if (cls.contains('load')) return const Color(0xFFFF9100);
    if (cls.contains('trans')) return const Color(0xFFD500F9);
    return const Color(0xFF2979FF); // Bus
  }

  IconData _getClassIcon(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return Icons.bolt;
    if (cls.contains('load')) return Icons.arrow_downward;
    if (cls.contains('trans')) return Icons.sync_alt;
    return Icons.horizontal_rule;
  }

  String _classNameKo(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return '발전기';
    if (cls.contains('load')) return '부하';
    if (cls.contains('trans')) return '변압기';
    return '모선';
  }

  String _completenessAssessmentKo(String assessment) {
    switch (assessment) {
      case 'ALL_EXPECTED_PRESENT':
        return '누락 없음';
      case 'POSSIBLE_MISSING_COMPONENT':
        return '누락 후보 발견';
      default:
        return '확인 필요';
    }
  }

  String _candidateStatusKo(String status) {
    switch (status) {
      case 'OPEN':
        return '검토 필요';
      case 'RESOLVED_BY_MANUAL_ADD':
        return '복구 완료';
      case 'DISMISSED_BY_HUMAN':
        return '문제 없음';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReviewLensyTargetSync();
    final canEnterBusMapping = BusReviewUiPolicy.canEnterBusMapping(
      objectGateVerified: _isObjectVerified,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        toolbarHeight: 42,
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt, color: Color(0xFF2563EB), size: 20),
              const SizedBox(width: 6),
              Text(
                _currentPhase == ReviewPhase.objectReview
                    ? "PowerLens AI 도면 검수 · ① 객체 검수"
                    : _currentPhase == ReviewPhase.busMappingReview
                    ? "PowerLens AI 도면 검수 · ② 모선 번호 매핑"
                    : _currentPhase == ReviewPhase.connectionReview
                    ? "PowerLens AI 도면 검수 · ③ 선로 결선 검수"
                    : "PowerLens AI 도면 검수 · ④ 최종 확인 & 엑셀",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        actions: [
          // Step Badges
          GlowingTargetWrapper(
            targetId: 'phase_step_1',
            borderRadius: BorderRadius.circular(6),
            guideLabel: "✨ ① 객체 검수 단계",
            child: _buildPhaseBadge(
              "① 객체 검수",
              _currentPhase == ReviewPhase.objectReview,
              _isObjectVerified,
              onTap: () {
                setState(() {
                  _currentPhase = ReviewPhase.objectReview;
                  _selectedLine = null;
                  _selectedNode = _workingNodes.isNotEmpty
                      ? _workingNodes.first
                      : null;
                });
              },
            ),
          ),
          const Icon(Icons.arrow_right, color: Color(0xFF94A3B8), size: 14),
          GlowingTargetWrapper(
            targetId: 'phase_step_2',
            borderRadius: BorderRadius.circular(6),
            guideLabel: "✨ ② 모선 매핑 단계",
            child: _buildPhaseBadge(
              "② 모선 매핑",
              _currentPhase == ReviewPhase.busMappingReview,
              canEnterBusMapping && _canVerifyBusGate,
              onTap: canEnterBusMapping && _workingNodes.isNotEmpty
                  ? () {
                      setState(() {
                        _currentPhase = ReviewPhase.busMappingReview;
                        _selectedLine = null;
                        final buses = _filteredAndSortedBusNodes;
                        _selectedNode = buses.isNotEmpty ? buses.first : null;
                      });
                    }
                  : null,
            ),
          ),
          const Icon(Icons.arrow_right, color: Color(0xFF94A3B8), size: 14),
          GlowingTargetWrapper(
            targetId: 'phase_step_3',
            borderRadius: BorderRadius.circular(6),
            guideLabel: "✨ ③ 결선 검수 단계",
            child: _buildPhaseBadge(
              "③ 결선 검수",
              _currentPhase == ReviewPhase.connectionReview,
              _canVerifyFinalGate,
              onTap: _activeConnectionLines.isNotEmpty
                  ? () {
                      setState(() {
                        _currentPhase = ReviewPhase.connectionReview;
                        _selectedNode = null;
                        _selectedLine = null;
                        _lineFocusOnly = false;
                        _connectionVisualSweepStarted = false;
                        _connectionVisualSweepComplete = false;
                        _showAllLinesList = false;
                        _connectionFullOverview = false;
                        _connectionLinesOnlyMode = false;
                        _connectionFastMode = false;
                      });
                    }
                  : null,
            ),
          ),
          const Icon(Icons.arrow_right, color: Color(0xFF94A3B8), size: 14),
          GlowingTargetWrapper(
            targetId: 'phase_step_4',
            borderRadius: BorderRadius.circular(6),
            guideLabel: "✨ ④ 최종 & 엑셀 단계",
            child: _buildPhaseBadge(
              "④ 최종 & 엑셀",
              _currentPhase == ReviewPhase.verifiedFinal,
              _isFinalVerified,
              onTap: _verifiedSld != null
                  ? () {
                      setState(() {
                        _currentPhase = ReviewPhase.verifiedFinal;
                      });
                    }
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          if (_document != null) ...[
            GlowingTargetWrapper(
              targetId: 'reset_to_beginning',
              borderRadius: BorderRadius.circular(6),
              guideLabel: "✨ 검수 처음으로 리셋",
              child: OutlinedButton.icon(
                onPressed: _confirmResetToBeginning,
                icon: const Icon(
                  Icons.restart_alt,
                  size: 14,
                  color: Color(0xFFDC2626),
                ),
                label: const Text(
                  "검수 처음으로",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFDC2626),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFFEF2F2),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          ElevatedButton.icon(
            onPressed:
                ReviewFinalContract.canImportExcel(
                  isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
                  verifiedSld: _verifiedSld,
                )
                ? _importExcelInReview
                : null,
            icon: Icon(
              Icons.table_chart,
              size: 14,
              color:
                  (_importedExcelData != null &&
                      !ReviewFinalContract.hasVerifiedExcelMatch(
                        _excelMismatchReport,
                      ))
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF0D9488),
            ),
            label: Text(
              _importedExcelData != null
                  ? (!ReviewFinalContract.hasVerifiedExcelMatch(
                          _excelMismatchReport,
                        )
                        ? "⚠️ 대조 확인 필요"
                        : "제원 확인됨 (#${_importedExcelData!['slack_bus_number'] ?? '?'})")
                  : "Excel 가져오기",
              style: TextStyle(
                fontSize: 11,
                color:
                    (_importedExcelData != null &&
                        !ReviewFinalContract.hasVerifiedExcelMatch(
                          _excelMismatchReport,
                        ))
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  (_importedExcelData != null &&
                      !ReviewFinalContract.hasVerifiedExcelMatch(
                        _excelMismatchReport,
                      ))
                  ? const Color(0xFFFEF2F2)
                  : const Color(0xFFF1F5F9),
              foregroundColor: const Color(0xFF0F172A),
              elevation: 0,
              side: BorderSide(
                color:
                    (_importedExcelData != null &&
                        !ReviewFinalContract.hasVerifiedExcelMatch(
                          _excelMismatchReport,
                        ))
                    ? const Color(0xFFFCA5A5)
                    : const Color(0xFFCBD5E1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: () {
              _pickAndUploadImage();
            },
            icon: const Icon(Icons.file_upload, size: 15),
            label: const Text(
              "도면 이미지 업로드",
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: KeyboardListener(
        focusNode: _reviewKeyFocusNode,
        autofocus: true,
        onKeyEvent: _handleReviewKeyEvent,
        child: Stack(
          key: _reviewStackKey,
          children: [
            _document == null
                ? _buildEmptyUploadArea()
                : _currentPhase == ReviewPhase.verifiedFinal
                ? _buildVerifiedFinalView()
                : _buildMainReviewView(),
            if (_isLoading)
              Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: Card(
                    color: Colors.white,
                    elevation: 6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: Color(0xFF2563EB),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _loadingMessage ?? "처리 중...",
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final isMobile = viewport.width < 768;
                  final coachTarget = _lensyCoachTarget;
                  final alignment = _effectiveReviewLensyAlignment(
                    coachTarget,
                    isMobile: isMobile,
                  );
                  if (isMobile) {
                    return AnimatedAlign(
                      alignment: alignment,
                      duration: _isLensyDragging
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: PowerLensAIFloatingButton(
                        coachTarget: coachTarget,
                        onDragDelta: (delta) => _handleReviewLensyDrag(
                          delta,
                          coachTarget,
                          isMobile: true,
                        ),
                        onDragStart: _handleReviewLensyDragStart,
                        onDragEnd: _handleReviewLensyDragEnd,
                        onResetPosition: _resetReviewLensyPosition,
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (ctx) => PowerLensAIPanel(
                              assistantContext: _buildAssistantContext(),
                              onClose: () => Navigator.pop(ctx),
                              isMobile: true,
                            ),
                          );
                        },
                        isOpen: false,
                        isMobile: true,
                        presenceState: _reviewLensyPresenceState,
                        alertCount: _objSuspiciousCount > 0
                            ? _objSuspiciousCount
                            : null,
                        speechBubbleText: _getReviewStageSpeechBubbleText(),
                        coachMessage: _getReviewStageSpeechBubbleText(),
                      ),
                    );
                  }

                  final panelBounds = _panelBoundsForViewport(viewport);
                  final groupRect = _desktopLensyGroupRect(
                    viewport,
                    alignment,
                    panelOpen: _isAiPanelOpen,
                    panelBounds: panelBounds,
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedPositioned(
                        left: groupRect.left,
                        top: groupRect.top,
                        width: groupRect.width,
                        height: groupRect.height,
                        duration: _isLensyDragging
                            ? Duration.zero
                            : const Duration(milliseconds: 210),
                        curve: Curves.easeOutCubic,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (_isAiPanelOpen)
                              Positioned(
                                right: 0,
                                bottom:
                                    PowerLensCompanionLayout.robotAnchorHeight +
                                    PowerLensCompanionLayout.panelGap,
                                child: PowerLensAIPanel(
                                  assistantContext: _buildAssistantContext(),
                                  onClose: () =>
                                      _setAiPanelOpen(false, viewport),
                                  isMobile: false,
                                  onCompanionDragDelta: (delta) =>
                                      _handleReviewLensyDrag(
                                        delta,
                                        coachTarget,
                                        isMobile: false,
                                      ),
                                  onCompanionDragStart:
                                      _handleReviewLensyDragStart,
                                  onCompanionDragEnd: _handleReviewLensyDragEnd,
                                  onCompanionReset: _resetReviewLensyPosition,
                                  isCompanionMoved:
                                      _manualLensyAlignment != null,
                                  desktopMaxSize: panelBounds,
                                ),
                              ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: PowerLensAIFloatingButton(
                                coachTarget: coachTarget,
                                onDragDelta: (delta) => _handleReviewLensyDrag(
                                  delta,
                                  coachTarget,
                                  isMobile: false,
                                ),
                                onDragStart: _handleReviewLensyDragStart,
                                onDragEnd: _handleReviewLensyDragEnd,
                                onResetPosition: _resetReviewLensyPosition,
                                onPressed: () =>
                                    _setAiPanelOpen(!_isAiPanelOpen, viewport),
                                isOpen: _isAiPanelOpen,
                                isMobile: false,
                                presenceState: _reviewLensyPresenceState,
                                alertCount: _objSuspiciousCount > 0
                                    ? _objSuspiciousCount
                                    : null,
                                speechBubbleText:
                                    _getReviewStageSpeechBubbleText(),
                                coachMessage: _getReviewStageSpeechBubbleText(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseBadge(
    String label,
    bool isCurrent,
    bool isCompleted, {
    VoidCallback? onTap,
  }) {
    Color bg = const Color(0xFFF1F5F9);
    Color text = const Color(0xFF64748B);
    Color border = const Color(0xFFE2E8F0);
    if (isCompleted) {
      bg = const Color(0xFFDCFCE7);
      text = const Color(0xFF16A34A);
      border = const Color(0xFF86EFAC);
    } else if (isCurrent) {
      bg = const Color(0xFFDBEAFE);
      text = const Color(0xFF2563EB);
      border = const Color(0xFF93C5FD);
    }

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Text(
        isCompleted ? "$label ✓" : label,
        style: TextStyle(
          color: text,
          fontSize: 11,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: badge,
        ),
      );
    }
    return badge;
  }

  Widget _buildEmptyUploadArea() {
    return Center(
      child: GestureDetector(
        onTap: () {
          _pickAndUploadImage();
        },
        child: Container(
          width: 550,
          height: 320,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFCBD5E1), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                size: 72,
                color: Color(0xFF2563EB),
              ),
              const SizedBox(height: 16),
              const Text(
                "전력계통 단선도(SLD) 이미지를 업로드하세요",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "객체 확인 → 결선 확인 → 전기 검증 → 회로도 생성",
                style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      _pickAndUploadImage();
                    },
                    icon: const Icon(Icons.add_photo_alternate, size: 16),
                    label: const Text("도면 파일 선택"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _loadSampleDiagram,
                    icon: const Icon(
                      Icons.flash_on,
                      size: 16,
                      color: Color(0xFFD97706),
                    ),
                    label: const Text("IEEE-24 샘플로 체험"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD97706),
                      side: const BorderSide(color: Color(0xFFFDE68A)),
                      backgroundColor: const Color(0xFFFFFBEB),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadSampleDiagram() async {
    try {
      setState(() {
        _isLoading = true;
        _loadingMessage = "IEEE-24 샘플 도면을 불러오는 중... ⚡";
      });
      final bytes = await _apiService.fetchSampleDiagramBytes();
      await _processImageBytes(bytes, 'sample_diagram_ieee24.jpg');
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("샘플 도면 불러오기 실패: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // --- Proactive AI Summary Top Banner ---

  String get _nextReviewActionText {
    if (_currentPhase == ReviewPhase.objectReview) {
      if (_objSuspiciousCount > 0) {
        return '검토가 필요한 객체 $_objSuspiciousCount개를 승인하거나 제외하세요.';
      }
      if (_unresolvedCandidatesCount > 0) {
        return '누락 의심 설비 $_unresolvedCandidatesCount개를 복구하거나 문제없음 처리하세요.';
      }
      if (!_objectHumanCheckDone && !_objectHumanCheckReady) {
        final pending = _objectSweep.pendingCategoryKeys(_workingNodes);
        if (pending.isNotEmpty) {
          return '설비 종류별로 확인해 주세요. 다음은 ${_objectCategoryLabel(pending.first)} 유형입니다.';
        }
        return '도면에서 설비 종류별 확인을 마쳐주세요.';
      }
      if (!_objectHumanCheckDone && _objectHumanCheckReady) {
        return '설비 종류별 확인이 끝났어요. 문제가 없다면 “확인했어”라고 알려주세요.';
      }
      return '객체 확인이 완료되었습니다. 모선 번호 매핑으로 이동할 수 있습니다.';
    }
    if (_currentPhase == ReviewPhase.busMappingReview) {
      return _busUiState.nextActionText;
    }
    if (_connectionGateBlockers.isNotEmpty) {
      return _connectionGateBlockers.first;
    }
    return '결선 확인이 완료되었습니다. [결선 검수 완료]를 눌러 최종 검증을 진행하세요.';
  }

  void _focusNextReviewTask() {
    final needsCompletenessCheck =
        _currentPhase == ReviewPhase.objectReview &&
        _objSuspiciousCount == 0 &&
        _unresolvedCandidatesCount == 0 &&
        !_objectHumanCheckDone &&
        !_objectHumanCheckReady;
    setState(() {
      if (_currentPhase == ReviewPhase.objectReview) {
        final suspicious = _objectSweep.unresolvedExceptions(_workingNodes);
        if (suspicious.isNotEmpty) {
          _objFilterStatus = 'SUSPICIOUS';
          _objFilterClass = 'ALL';
          _selectedNode = suspicious.first;
        } else if (_unresolvedCandidatesCount == 0) {
          final pending = _objectSweep.pendingCategoryKeys(_workingNodes);
          if (pending.isNotEmpty) {
            final next = pending.first;
            _objFilterStatus = 'ALL';
            _objFilterClass = next;
            final matches = _workingNodes
                .where(
                  (node) =>
                      node.className.trim().toLowerCase() == next &&
                      node.reviewStatus.toUpperCase() != 'REJECTED',
                )
                .toList();
            _selectedNode = matches.isEmpty ? null : matches.first;
            _stageGateMessage = '${_objectCategoryLabel(next)} 유형을 확인해 주세요.';
          } else if (_objectHumanCheckReady) {
            _stageGateMessage = '설비 종류별 확인이 끝났어요. 문제가 없다면 “확인했어”라고 말씀해 주세요.';
          }
        }
      } else if (_currentPhase == ReviewPhase.busMappingReview) {
        _busFilterStatus = 'UNCERTAIN';
        _busPage = 0;
        final buses = _filteredAndSortedBusNodes;
        _selectedNode = buses.isNotEmpty ? buses.first : null;
        _selectedLine = null;
      } else if (_currentPhase == ReviewPhase.connectionReview) {
        final guideIds = _connectionGuideLineIds;
        _connFilterStatus = guideIds.isNotEmpty ? 'NEEDS_REVIEW' : 'ALL';
        _showAllLinesList = true;
        _showTopologyDetails = _topologyIssues.isNotEmpty;
        final lines = _filteredAndSortedWorkingLines;
        final nextIndex = lines.indexWhere(
          (line) => guideIds.contains(line.lineId),
        );
        if (nextIndex >= 0) {
          _selectedLine = lines[nextIndex];
          _linePage = nextIndex ~/ _linePageSize;
        }
      }
    });
    if (_selectedNode?.reviewStatus == 'SUSPICIOUS' &&
        _selectedNode?.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
    if (needsCompletenessCheck) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('도면 위 설비 종류 탭을 눌러 유형별로 확인해 주세요.'),
          backgroundColor: Colors.blueAccent,
        ),
      );
    }
  }

  Widget _buildAiMetric(
    String label,
    int count,
    Color color, {
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            '$label $count',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProactiveSummaryBanner() {
    final isObjectPhase = _currentPhase == ReviewPhase.objectReview;
    final isBusPhase = _currentPhase == ReviewPhase.busMappingReview;
    final isConnectionPhase = _currentPhase == ReviewPhase.connectionReview;
    final busState = _busUiState;
    final hasNextTask = isObjectPhase
        ? (_objSuspiciousCount > 0 ||
              _unresolvedCandidatesCount > 0 ||
              !_objectHumanCheckDone)
        : isBusPhase
        ? busState.isBlocked
        : isConnectionPhase && _connectionGateBlockers.isNotEmpty;
    final autoConfirmedCount = isObjectPhase
        ? _workingNodes
              .where(
                (node) =>
                    node.reviewStatus == 'CONFIRMED' &&
                    !node.source.contains('human'),
              )
              .length
        : isBusPhase
        ? _busVerifiedCount
        : _activeConnectionLines.length;
    final providerMode = _document?.proactiveSummary?.providerMode
        .toLowerCase();
    final providerLabel = providerMode?.startsWith('gemini') == true
        ? 'Gemini'
        : 'Local';

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Color(0xFF2563EB),
              size: 14,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'AI 검토 현황',
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  isObjectPhase
                      ? '객체 인식 검수'
                      : isBusPhase
                      ? busState.subtitle
                      : '결선 및 전기 검수',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 8.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: providerLabel == 'Gemini'
                  ? const Color(0xFFECFDF5)
                  : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: providerLabel == 'Gemini'
                    ? const Color(0xFF86EFAC)
                    : const Color(0xFFCBD5E1),
              ),
            ),
            child: Text(
              providerLabel,
              style: TextStyle(
                color: providerLabel == 'Gemini'
                    ? const Color(0xFF15803D)
                    : const Color(0xFF64748B),
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (isBusPhase) ...[
            _buildAiMetric(
              '전체 모선',
              busState.totalBuses,
              const Color(0xFF2563EB),
            ),
            const SizedBox(width: 4),
            _buildAiMetric('확인됨', _busVerifiedCount, const Color(0xFF16A34A)),
            const SizedBox(width: 4),
            _buildAiMetric(
              '확인 필요',
              _busUncertainCount,
              const Color(0xFFD97706),
              icon: Icons.warning_amber_rounded,
            ),
          ] else if (isConnectionPhase) ...[
            _buildAiMetric(
              '전체 결선',
              _activeConnectionLines.length,
              const Color(0xFF2563EB),
            ),
            const SizedBox(width: 4),
            _buildAiMetric(
              '확인 필요',
              _connectionExceptionLines.length,
              const Color(0xFFD97706),
              icon: Icons.warning_amber_rounded,
            ),
            const SizedBox(width: 4),
            _buildAiMetric(
              '전기 오류',
              _criticalIssuesCount,
              const Color(0xFFDC2626),
              icon: Icons.error_outline,
            ),
          ] else ...[
            _buildAiMetric(
              '자동 승인',
              autoConfirmedCount,
              const Color(0xFF16A34A),
            ),
            const SizedBox(width: 4),
            _buildAiMetric(
              '검토 필요',
              isObjectPhase ? _objSuspiciousCount : _lineAmbiguousCount,
              const Color(0xFFD97706),
              icon: Icons.warning_amber_rounded,
            ),
            const SizedBox(width: 4),
            _buildAiMetric(
              isObjectPhase ? '누락 후보' : '전기 오류',
              isObjectPhase ? _unresolvedCandidatesCount : _criticalIssuesCount,
              isObjectPhase ? const Color(0xFF9333EA) : const Color(0xFFDC2626),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _nextReviewActionText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF334155), fontSize: 10.5),
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: hasNextTask
                ? (isObjectPhase
                      ? _handleObjectReviewPrimaryAction
                      : _focusNextReviewTask)
                : null,
            icon: Icon(
              hasNextTask ? Icons.arrow_forward_rounded : Icons.check_rounded,
              size: 13,
            ),
            label: Text(
              isConnectionPhase
                  ? (hasNextTask ? '예외 보기' : '정상 확인')
                  : isObjectPhase
                  ? (_objSuspiciousCount > 0 || _unresolvedCandidatesCount > 0
                        ? '예외 보기'
                        : !_objectHumanCheckReady
                        ? (_selectedObjectCategoryKey != null &&
                                  _objectSweep.isCategoryReviewed(
                                    _selectedObjectCategoryKey!,
                                    _workingNodes,
                                  )
                              ? '다음 유형 보기'
                              : '현재 유형 확인')
                        : '전체 확인했어요')
                  : (hasNextTask ? '다음 검토' : '정리 완료'),
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2563EB),
              side: const BorderSide(color: Color(0xFF3B82F6)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainReviewView() {
    final isConnectionPhase = _currentPhase == ReviewPhase.connectionReview;

    return Column(
      children: [
        // 1. Proactive AI Summary Banner
        _buildProactiveSummaryBanner(),

        // 2. Main Content (Canvas + Right Panel)
        Expanded(
          child: Row(
            children: [
              // Left Column: Original Image + Overlays (Bbox + Lines)
              Expanded(
                flex: 65,
                child: Column(
                  children: [
                    // Top Tool Header
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(
                            color: Color(0xFFE2E8F0),
                            width: 1,
                          ),
                        ),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text(
                              "도면 해상도: ${_document!.image.width} × ${_document!.image.height} px",
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              avatar: Icon(
                                _showCanvasLabels
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                size: 13,
                                color: _showCanvasLabels
                                    ? const Color(0xFF2563EB)
                                    : const Color(0xFF64748B),
                              ),
                              label: Text(
                                _showCanvasLabels ? "라벨 표시" : "라벨 숨김",
                                style: TextStyle(
                                  color: _showCanvasLabels
                                      ? const Color(0xFF2563EB)
                                      : const Color(0xFF64748B),
                                  fontSize: 10.5,
                                  fontWeight: _showCanvasLabels
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: _showCanvasLabels,
                              onSelected: (val) =>
                                  setState(() => _showCanvasLabels = val),
                              selectedColor: const Color(0xFFEFF6FF),
                              backgroundColor: const Color(0xFFF1F5F9),
                              side: BorderSide(
                                color: _showCanvasLabels
                                    ? const Color(0xFF3B82F6)
                                    : const Color(0xFFCBD5E1),
                                width: 1.0,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            const SizedBox(width: 12),
                            if (!isConnectionPhase) ...[
                              if (_objSuspiciousCount > 0) ...[
                                IconButton(
                                  icon: const Icon(
                                    Icons.history_toggle_off,
                                    size: 15,
                                    color: Color(0xFFD97706),
                                  ),
                                  tooltip: "이전 의심 객체",
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _selectPreviousSuspiciousNode,
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 15,
                                    color: Color(0xFFD97706),
                                  ),
                                  tooltip: "다음 의심 객체",
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _selectNextSuspiciousNode,
                                ),
                                const SizedBox(width: 6),
                              ],
                              ChoiceChip(
                                label: Text(
                                  _isManualAddMode
                                      ? "객체 드래그 추가 중..."
                                      : "➕ 객체 추가",
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                selected: _isManualAddMode,
                                onSelected: (val) =>
                                    setState(() => _isManualAddMode = val),
                                selectedColor: const Color(0xFFF3E8FF),
                                backgroundColor: const Color(0xFFF1F5F9),
                                side: BorderSide(
                                  color: _isManualAddMode
                                      ? const Color(0xFF9333EA)
                                      : const Color(0xFFCBD5E1),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              if (_isManualAddMode) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: const Color(0xFFCBD5E1),
                                    ),
                                  ),
                                  child: DropdownButton<String>(
                                    value: _manualAddClass,
                                    dropdownColor: Colors.white,
                                    isDense: true,
                                    underline: const SizedBox.shrink(),
                                    style: const TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontSize: 11,
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'bus',
                                        child: Text('Bus'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'generator',
                                        child: Text('Generator'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'load',
                                        child: Text('Load'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'transformer',
                                        child: Text('Transformer'),
                                      ),
                                    ],
                                    onChanged: (val) => setState(
                                      () => _manualAddClass = val ?? 'bus',
                                    ),
                                  ),
                                ),
                              ],
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFFCBD5E1),
                                  ),
                                ),
                                child: const Text(
                                  '정상 결선은 자동 확인 · 예외만 검토',
                                  style: TextStyle(
                                    color: Color(0xFF475569),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                label: Text(
                                  _isManualAddLineMode
                                      ? (_manualLineStartNode == null
                                            ? "시작 객체 선택..."
                                            : "끝 객체 선택...")
                                      : "➕ 선로 추가",
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                selected: _isManualAddLineMode,
                                onSelected: (val) {
                                  setState(() {
                                    _isManualAddLineMode = val;
                                    _manualLineStartNode = null;
                                  });
                                },
                                selectedColor: const Color(0xFFF3E8FF),
                                backgroundColor: const Color(0xFFF1F5F9),
                                side: BorderSide(
                                  color: _isManualAddLineMode
                                      ? const Color(0xFF9333EA)
                                      : const Color(0xFFCBD5E1),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // Canvas View with Draggable Labels and Leader Lines
                    Expanded(
                      child: Container(
                        color: const Color(0xFFF1F5F9),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                                valueListenable: PowerLensAIService
                                    .instance
                                    .focusTargetsNotifier,
                                builder: (context, focusTargets, _) {
                                  return ReviewOverlayView(
                                    focusTargetKey: _reviewFocusTargetKey,
                                    imageBytes: _document!.rawBytes,
                                    imageUrl: _apiService.getOriginalImageUrl(
                                      _document!.documentId,
                                    ),
                                    originalWidth: _document!.image.width,
                                    originalHeight: _document!.image.height,
                                    nodes: _workingNodes,
                                    selectedNode: _selectedNode,
                                    currentObjectReviewId:
                                        _objectReviewCurrentTarget?.id,
                                    objectReviewTargetActive:
                                        _currentPhase ==
                                            ReviewPhase.objectReview &&
                                        _objectReviewCurrentTarget != null,
                                    visitedObjectIds:
                                        _objectSweep.visitedObjectIds,
                                    guideNodeIds:
                                        (_currentPhase ==
                                                ReviewPhase.objectReview ||
                                            _currentPhase ==
                                                ReviewPhase.busMappingReview)
                                        ? _calculateGuideNodeIds(focusTargets)
                                        : const {},
                                    currentCoachNodeId:
                                        _reviewCoachDecision.focusNodeId,
                                    isObjectCategorySweepActive:
                                        _currentPhase ==
                                                ReviewPhase.objectReview &&
                                            _objSuspiciousCount == 0 &&
                                            _unresolvedCandidatesCount == 0,
                                    currentCategoryHighlightKey:
                                        _objectSweep.currentCategoryKey,
                                    openMissingCandidates:
                                        (_currentPhase ==
                                            ReviewPhase.objectReview)
                                        ? _missingCandidates
                                              .where((c) => c.status == 'OPEN')
                                              .toList()
                                        : const [],
                                    onSelectCandidate: (cand) {
                                      _showMissingCandidatesDialog(
                                        initialCandidateId: cand.id,
                                      );
                                    },
                                    onSelectNode: (node) {
                                      if (_currentPhase ==
                                          ReviewPhase.objectReview) {
                                        _selectReviewNode(node);
                                        return;
                                      }
                                      setState(() {
                                        _selectedNode = node;
                                        _isObjectEditExpanded = false;
                                        if (_isManualAddLineMode &&
                                            _manualLineStartNode == null) {
                                          _manualLineStartNode = node;
                                        }
                                        if (_currentPhase ==
                                            ReviewPhase.connectionReview) {
                                          final matchedIssue = _topologyIssues
                                              .firstWhere(
                                                (i) =>
                                                    (i['component_ids']
                                                                as List? ??
                                                            [])
                                                        .map(
                                                          (e) => e.toString(),
                                                        )
                                                        .contains(node.id),
                                                orElse: () => {},
                                              );
                                          _selectedTopologyIssue =
                                              matchedIssue.isNotEmpty
                                              ? matchedIssue
                                              : null;
                                          _selectedLine = null;
                                        }
                                      });
                                      if (node.reviewStatus == 'SUSPICIOUS' &&
                                          node.agentExplanation == null) {
                                        _triggerAgentReviewNode(node);
                                      }
                                    },
                                    onNodeOffsetChanged: (nodeId, dx, dy) {
                                      setState(() {
                                        for (var n in _workingNodes) {
                                          if (n.id == nodeId) {
                                            n.labelOffsetDx = dx;
                                            n.labelOffsetDy = dy;
                                            break;
                                          }
                                        }
                                      });
                                    },
                                    showNodeLabels: _showCanvasLabels,
                                    showLineLabels: _showCanvasLabels,
                                    busFocusOnly:
                                        (_currentPhase ==
                                            ReviewPhase.busMappingReview &&
                                        _busFocusOnly),
                                    lineFocusOnly:
                                        (_currentPhase ==
                                            ReviewPhase.connectionReview &&
                                        _lineFocusOnly),
                                    linesOnlyMode:
                                        (_currentPhase ==
                                            ReviewPhase.connectionReview &&
                                        _connectionLinesOnlyMode),
                                    lines:
                                        (_currentPhase ==
                                            ReviewPhase.objectReview)
                                        ? const []
                                        : _workingLines,
                                    selectedLine: _selectedLine,
                                    visitedLineIds: _visitedConnectionLineIds,
                                    onSelectLine: (line) {
                                      setState(() {
                                        if (_currentPhase ==
                                                ReviewPhase.connectionReview &&
                                            _selectedLine != null &&
                                            _selectedLine!.lineId !=
                                                line.lineId) {
                                          _visitedConnectionLineIds.add(
                                            _selectedLine!.lineId,
                                          );
                                        }
                                        _selectedLine = line;
                                        if (_currentPhase ==
                                            ReviewPhase.connectionReview) {
                                          _selectedNode = null;
                                          _selectedTopologyIssue = null;
                                          if (!_filteredAndSortedWorkingLines
                                              .any(
                                                (l) => l.lineId == line.lineId,
                                              )) {
                                            _connFilterStatus = 'ALL';
                                          }
                                        }
                                        final index =
                                            _filteredAndSortedWorkingLines
                                                .indexWhere(
                                                  (item) =>
                                                      item.lineId ==
                                                      line.lineId,
                                                );
                                        if (index >= 0) {
                                          _linePage = index ~/ _linePageSize;
                                        }
                                      });
                                    },
                                    onLineOffsetChanged: (lineId, dx, dy) {
                                      setState(() {
                                        for (var l in _workingLines) {
                                          if (l.lineId == lineId) {
                                            l.labelOffsetDx = dx;
                                            l.labelOffsetDy = dy;
                                            break;
                                          }
                                        }
                                      });
                                    },
                                    isManualAddMode: _isManualAddMode,
                                    manualAddClass: _manualAddClass,
                                    onManualAddComplete:
                                        _handleManualAddComplete,
                                    isManualAddLineMode: _isManualAddLineMode,
                                    manualLineStartNode: _manualLineStartNode,
                                    onManualAddLineComplete:
                                        _handleManualAddLineComplete,
                                    violationNodeIds: _topologyIssues
                                        .where((i) => i['severity'] == 'error')
                                        .expand(
                                          (i) =>
                                              (i['component_ids'] as List? ??
                                                      [])
                                                  .map((e) => e.toString()),
                                        )
                                        .toSet(),
                                  );
                                },
                              ),
                            ),
                            // Floating HUD on Canvas: Direct Label & Focus Toggles
                            Positioned(
                              top: 10,
                              right: 12,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_currentPhase ==
                                      ReviewPhase.busMappingReview) ...[
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => setState(
                                          () => _busFocusOnly = !_busFocusOnly,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _busFocusOnly
                                                ? const Color(0xFFEFF6FF)
                                                : Colors.white.withValues(
                                                    alpha: 0.95,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: _busFocusOnly
                                                  ? const Color(0xFF2563EB)
                                                  : const Color(0xFFCBD5E1),
                                              width: 1.2,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black12,
                                                blurRadius: 4,
                                                offset: Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.center_focus_strong,
                                                size: 14,
                                                color: _busFocusOnly
                                                    ? const Color(0xFF2563EB)
                                                    : const Color(0xFF64748B),
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                _busFocusOnly
                                                    ? "버스만 집중 모드 (ON)"
                                                    : "전체 기기 표시 (OFF)",
                                                style: TextStyle(
                                                  color: _busFocusOnly
                                                      ? const Color(0xFF2563EB)
                                                      : const Color(0xFF64748B),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (_currentPhase ==
                                      ReviewPhase.connectionReview) ...[
                                    GlowingTargetWrapper(
                                      targetId: 'connection_focus_toggle',
                                      guideLabel: '✨ 선로를 하나씩 육안 확인',
                                      borderRadius: BorderRadius.circular(6),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          onTap: () {
                                            if (!_connectionVisualSweepStarted &&
                                                _connectionGateBlockers
                                                    .isEmpty) {
                                              _startConnectionVisualSweep();
                                              return;
                                            }
                                            setState(() {
                                              _lineFocusOnly = !_lineFocusOnly;
                                              if (!_lineFocusOnly) {
                                                _connectionVisualSweepStarted =
                                                    false;
                                                _connectionVisualSweepComplete =
                                                    false;
                                              }
                                            });
                                          },
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: _lineFocusOnly
                                                  ? const Color(0xFFEFF6FF)
                                                  : Colors.white.withValues(
                                                      alpha: 0.95,
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: _lineFocusOnly
                                                    ? const Color(0xFF0284C7)
                                                    : const Color(0xFFCBD5E1),
                                                width: 1.2,
                                              ),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black12,
                                                  blurRadius: 4,
                                                  offset: Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.timeline,
                                                  size: 14,
                                                  color: _lineFocusOnly
                                                      ? const Color(0xFF0284C7)
                                                      : const Color(0xFF64748B),
                                                ),
                                                const SizedBox(width: 5),
                                                Text(
                                                  _lineFocusOnly
                                                      ? "선로만 집중 모드 (ON)"
                                                      : "전체 선로 표시 (OFF)",
                                                  style: TextStyle(
                                                    color: _lineFocusOnly
                                                        ? const Color(
                                                            0xFF0284C7,
                                                          )
                                                        : const Color(
                                                            0xFF64748B,
                                                          ),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () => setState(
                                        () => _showCanvasLabels =
                                            !_showCanvasLabels,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.95,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: _showCanvasLabels
                                                ? const Color(0xFF3B82F6)
                                                : const Color(0xFFF59E0B),
                                            width: 1.2,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black12,
                                              blurRadius: 4,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _showCanvasLabels
                                                  ? Icons.visibility
                                                  : Icons.visibility_off,
                                              size: 14,
                                              color: _showCanvasLabels
                                                  ? const Color(0xFF2563EB)
                                                  : const Color(0xFFD97706),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              _showCanvasLabels
                                                  ? "라벨 숨기기"
                                                  : "라벨 보이기",
                                              style: TextStyle(
                                                color: _showCanvasLabels
                                                    ? const Color(0xFF0F172A)
                                                    : const Color(0xFFD97706),
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const VerticalDivider(width: 1, color: Color(0xFFE2E8F0)),

              // Right Column: One focused review panel. Lensy AI is the only
              // assistant entry point; legacy activity/chat widgets remain in
              // the source for compatibility but are intentionally not
              // exposed as competing tabs here.
              Expanded(
                flex: 35,
                child: Container(
                  color: Colors.white,
                  child: Column(
                    children: [
                      _buildRightPanelHeader(),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child:
                                    _currentPhase ==
                                        ReviewPhase.busMappingReview
                                    ? _buildBusMappingReviewSidePanel()
                                    : isConnectionPhase
                                    ? _buildConnectionReviewV2SidePanel()
                                    : _buildObjectReviewSidePanel(),
                              ),
                            ),
                            const Divider(color: Color(0xFFE2E8F0), height: 1),
                            _buildBottomGateFooter(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRightPanelHeader() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(
            Icons.fact_check_outlined,
            size: 16,
            color: Color(0xFF2563EB),
          ),
          const SizedBox(width: 6),
          const Text(
            "현재 검수 작업",
            style: TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 12, color: Color(0xFF2563EB)),
                SizedBox(width: 4),
                Text(
                  "Lensy AI 안내",
                  style: TextStyle(
                    color: Color(0xFF1D4ED8),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Object Queue Header ---

  Widget _buildObjectQueueHeader() {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "객체 검수",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                _objSuspiciousCount > 0
                    ? "검토 필요 $_objSuspiciousCount개"
                    : "자동 확인 가능",
                style: TextStyle(
                  color: _objSuspiciousCount > 0
                      ? const Color(0xFFD97706)
                      : const Color(0xFF16A34A),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Keep the class filter visible in the beginner path. Detailed
          // counts, sorting and batch operations remain behind the advanced
          // disclosure below.
          Container(
            key: _objectFilterKey,
            child:
                _currentPhase == ReviewPhase.objectReview &&
                    _objSuspiciousCount == 0 &&
                    _unresolvedCandidatesCount == 0
                ? ObjectCategoryReviewBar(
                    totalCount: _workingNodes
                        .where((n) => n.reviewStatus.toUpperCase() != 'REJECTED')
                        .length,
                    categories: _objectReviewCategoryStatuses,
                    selectedCategoryKey: _objectSweep.currentCategoryKey,
                    allReviewed:
                        _objectSweep.isAllCategoriesReviewed(_workingNodes),
                    onSelectCategory: _selectObjectReviewCategory,
                    onConfirmCurrentAndNext: _handleObjectCategoryConfirmAndNext,
                    onPreviousCategory:
                        _objectSweep.canGoPrevious(_workingNodes)
                            ? _handleObjectCategoryPrevious
                            : null,
                    onSelectAll: _handleObjectCategorySelectAll,
                  )
                : Wrap(
                    spacing: 3.5,
                    runSpacing: 4.0,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        "도면 표시:",
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 9.5,
                        ),
                      ),
                      _buildObjectClassFilter("전체", 'ALL'),
                      _buildObjectClassFilter("Bus", 'bus'),
                      _buildObjectClassFilter("Load", 'load'),
                      _buildObjectClassFilter("Generator", 'generator'),
                      _buildObjectClassFilter("Transformer", 'transformer'),
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: const Text(
              "고급: 필터 및 정렬",
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: DropdownButton<String>(
                  value: _objSortOption,
                  dropdownColor: Colors.white,
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 11,
                  ),
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(
                      value: 'SEVERITY',
                      child: Text("정렬: 위험도순"),
                    ),
                    DropdownMenuItem(
                      value: 'CONFIDENCE_ASC',
                      child: Text("정렬: 신뢰도낮은순"),
                    ),
                    DropdownMenuItem(value: 'ID_ASC', child: Text("정렬: ID순")),
                  ],
                  onChanged: (val) =>
                      setState(() => _objSortOption = val ?? 'SEVERITY'),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterableStatBadge(
                      "전체 보기",
                      _workingNodes.length,
                      const Color(0xFF475569),
                      'ALL',
                    ),
                    const SizedBox(width: 4),
                    _buildFilterableStatBadge(
                      "검토 필요",
                      _objSuspiciousCount,
                      const Color(0xFFD97706),
                      'SUSPICIOUS',
                    ),
                    const SizedBox(width: 4),
                    _buildFilterableStatBadge(
                      "자동 승인",
                      _workingNodes
                          .where(
                            (n) =>
                                n.reviewStatus == 'CONFIRMED' &&
                                !n.source.contains('human'),
                          )
                          .length,
                      const Color(0xFF0D9488),
                      'AUTO_CONFIRMED',
                    ),
                    const SizedBox(width: 4),
                    _buildFilterableStatBadge(
                      "수동 승인",
                      _workingNodes
                          .where(
                            (n) =>
                                n.reviewStatus == 'CONFIRMED' &&
                                n.source.contains('human'),
                          )
                          .length,
                      const Color(0xFF16A34A),
                      'HUMAN_CONFIRMED',
                    ),
                    const SizedBox(width: 4),
                    _buildFilterableStatBadge(
                      "미검수",
                      _objDetectedCount,
                      const Color(0xFF2563EB),
                      'DETECTED',
                    ),
                    const SizedBox(width: 4),
                    _buildFilterableStatBadge(
                      "제외",
                      _objRejectedCount,
                      const Color(0xFF64748B),
                      'REJECTED',
                    ),
                    const SizedBox(width: 4),
                    GlowingTargetWrapper(
                      targetId: 'missing_candidates',
                      borderRadius: BorderRadius.circular(4),
                      guideLabel: "✨ 누락 후보 확인",
                      child: _buildMissingCandidateBadge(
                        "누락 후보",
                        _unresolvedCandidatesCount,
                        _unresolvedCandidatesCount > 0
                            ? const Color(0xFF9333EA)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildObjectReviewSidePanel() {
    final visibleNodes = _filteredAndSortedWorkingNodes;
    if (_selectedNode == null && visibleNodes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedNode != null) return;
        setState(() {
          _selectedNode = _filteredAndSortedWorkingNodes.isNotEmpty
              ? _filteredAndSortedWorkingNodes.first
              : null;
        });
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildObjectQueueHeader(),
        const Divider(color: Color(0xFFE2E8F0), height: 1),
        const SizedBox(height: 12),

        if (_unresolvedCandidatesCount > 0) ...[
          GlowingTargetWrapper(
            targetId: 'missing_candidates',
            borderRadius: BorderRadius.circular(8),
            guideLabel: "✨ 누락 후보 처리",
            child: _buildMissingCandidatesAlertCard(),
          ),
          const SizedBox(height: 12),
        ],

        // The selected object is the primary card. Queue details and the
        // whole-diagram completeness view stay available without competing
        // with the one-by-one review decision.
        if (_selectedNode == null)
          _buildNoSelectionPrompt("객체")
        else
          _buildSelectedNodePanel(),
        const SizedBox(height: 10),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: _unresolvedCandidatesCount > 0,
          title: const Text(
            "고급: 전체 완결성·객체 목록",
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            _buildGlobalCompletenessSection(),
            const SizedBox(height: 12),
            _buildNodeSelectionChips(),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildNodeSelectionChips() {
    final list = _filteredAndSortedWorkingNodes;
    if (list.isEmpty) return const SizedBox.shrink();

    final pageCount = (list.length / _nodePageSize).ceil();
    final currentPage = _nodePage.clamp(0, pageCount - 1).toInt();
    final startIndex = currentPage * _nodePageSize;
    final endIndex = (startIndex + _nodePageSize).clamp(0, list.length).toInt();
    final pageNodes = list.sublist(startIndex, endIndex);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.list_alt, size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 4),
                Text(
                  "객체 목록 (${list.length}개) · ${currentPage + 1}/$pageCount 페이지",
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (pageCount > 1)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '이전 페이지',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    onPressed: currentPage > 0
                        ? () => setState(() => _nodePage = currentPage - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left, size: 18),
                  ),
                  Text(
                    '${currentPage + 1}/$pageCount',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                    ),
                  ),
                  IconButton(
                    tooltip: '다음 페이지',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    onPressed: currentPage < pageCount - 1
                        ? () => setState(() => _nodePage = currentPage + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right, size: 18),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: pageNodes.map((n) {
            final isSelected = _selectedNode?.id == n.id;
            final isCurrentTarget = _objectReviewCurrentTarget?.id == n.id;
            final isVisited =
                _objectSweep.visitedObjectIds.contains(n.id) &&
                !isCurrentTarget;
            final isSuspicious = n.reviewStatus == 'SUSPICIOUS';
            final isConfirmed = n.reviewStatus == 'CONFIRMED';
            final isRejected = n.reviewStatus == 'REJECTED';
            final classColor = _getClassColor(n.className);

            return GestureDetector(
              onTap: () => _selectReviewNode(n, listPage: currentPage),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? classColor.withValues(alpha: 0.22)
                      : (isVisited
                            ? const Color(0xFFFFFBEB)
                            : const Color(0xFFF8FAFC)),
                  border: Border.all(
                    color: isCurrentTarget
                        ? const Color(0xFF06B6D4)
                        : isSelected
                        ? const Color(0xFFF59E0B)
                        : (isVisited
                              ? const Color(0xFFF59E0B)
                              : (isSuspicious
                                    ? const Color(0xFFF97316)
                                    : classColor.withValues(alpha: 0.6))),
                    width: isCurrentTarget ? 2.2 : (isSelected ? 1.8 : 1.2),
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getClassIcon(n.className),
                      size: 11,
                      color: classColor,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      n.effectiveDisplayLabel,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF0F172A)
                            : const Color(0xFF334155),
                        fontSize: 10.5,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        decoration: isRejected
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    if (isSuspicious) ...[
                      const SizedBox(width: 2.5),
                      const Text("⚠️", style: TextStyle(fontSize: 8)),
                    ] else if (isConfirmed) ...[
                      const SizedBox(width: 2.5),
                      const Icon(
                        Icons.check,
                        size: 10,
                        color: Color(0xFF16A34A),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        if (pageCount > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '이전 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: currentPage > 0
                    ? () => setState(() => _nodePage = currentPage - 1)
                    : null,
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              for (var page = 0; page < pageCount; page++)
                ChoiceChip(
                  label: Text('${page + 1}'),
                  selected: page == currentPage,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => setState(() => _nodePage = page),
                ),
              IconButton(
                tooltip: '다음 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: currentPage < pageCount - 1
                    ? () => setState(() => _nodePage = currentPage + 1)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildGlobalCompletenessSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _unresolvedCandidatesCount > 0
              ? const Color(0xFFC084FC)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _unresolvedCandidatesCount > 0
                    ? Icons.warning_amber
                    : Icons.verified_outlined,
                size: 18,
                color: _unresolvedCandidatesCount > 0
                    ? const Color(0xFF9333EA)
                    : const Color(0xFF2563EB),
              ),
              const SizedBox(width: 6),
              const Text(
                "전체 도면 완결성 검사",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              if (_completenessAssessment != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: _completenessAssessment == 'ALL_EXPECTED_PRESENT'
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFF3E8FF),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    _completenessAssessmentKo(_completenessAssessment!),
                    style: TextStyle(
                      color: _completenessAssessment == 'ALL_EXPECTED_PRESENT'
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF9333EA),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
                tooltip: "완결성 재검사",
                onPressed: _triggerCompletenessReview,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _completenessMessageKo ?? "전체 도면 내 미검출 설비 누락 가능성을 점검 중입니다...",
            style: const TextStyle(
              color: Color(0xFF475569),
              fontSize: 11,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),

          // Missing Candidates List
          if (_missingCandidates.isNotEmpty) ...[
            ..._missingCandidates.map((c) {
              final isOpen = c.status == 'OPEN';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isOpen
                      ? const Color(0xFFFAF5FF)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isOpen
                        ? const Color(0xFFD8B4FE)
                        : const Color(0xFFCBD5E1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "⚠️ ${_classNameKo(c.suspectedClass)} 누락 후보",
                          style: TextStyle(
                            color: isOpen
                                ? const Color(0xFF9333EA)
                                : const Color(0xFF64748B),
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isOpen
                                ? const Color(0xFF9333EA)
                                : const Color(0xFF94A3B8),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            _candidateStatusKo(c.status),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      c.descriptionKo,
                      style: const TextStyle(
                        color: Color(0xFF1E293B),
                        fontSize: 11,
                      ),
                    ),
                    if (isOpen) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _isManualAddMode = true;
                                _manualAddClass = c.suspectedClass;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    "도면에서 ${_classNameKo(c.suspectedClass)} 영역을 드래그하여 추가하세요.",
                                  ),
                                  backgroundColor: const Color(0xFF9333EA),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF9333EA),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: const Size(0, 26),
                            ),
                            child: const Text(
                              "객체 수동 추가",
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            onPressed: () => _dismissCandidate(c),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF475569),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: const Size(0, 26),
                            ),
                            child: const Text(
                              "문제 없음",
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectedNodePanel() {
    final node = _selectedNode!;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _selectReviewNode(node),
      child: ObjectInspectorView(
        node: node,
        isEditExpanded: _isObjectEditExpanded,
        onMatch: () {
          setState(() {
            _objectSweep.markExceptionResolved(
              node.id,
              categoryKey: node.className,
            );
            node.reviewStatus = 'CONFIRMED';
            node.source = '${node.source}_human_confirmed';
          });
          _refreshObjectReviewFocus(exceptionResolved: true);
        },
        onEditToggle: () {
          setState(() {
            _isObjectEditExpanded = !_isObjectEditExpanded;
          });
        },
        onClassChanged: (cls) {
          _changeNodeClass(node, cls);
          setState(() {
            _isObjectEditExpanded = false;
          });
        },
        onReject: () => _rejectNode(node),
        onEditDisplayLabel: () => _editNodeDisplayLabel(node),
      ),
    );
  }

  // --- Connection Queue Header & Panel ---

  Widget _buildConnectionQueueHeader() {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "결선 검수",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              // Sort dropdown
              DropdownButton<String>(
                value: _connSortOption,
                dropdownColor: Colors.white,
                style: const TextStyle(color: Color(0xFF334155), fontSize: 11),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'SEVERITY', child: Text("정렬: 위험도순")),
                  DropdownMenuItem(
                    value: 'ID_ASC',
                    child: Text("정렬: Line ID순"),
                  ),
                ],
                onChanged: (val) => setState(() {
                  _connSortOption = val ?? 'SEVERITY';
                  _linePage = 0;
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterableConnStatBadge(
                  "전체 보기",
                  _workingLines.length,
                  const Color(0xFF475569),
                  'ALL',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "오류만 보기",
                  _criticalIssuesCount,
                  const Color(0xFFDC2626),
                  'ERROR_ONLY',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "검토 필요",
                  _lineAmbiguousCount,
                  const Color(0xFFD97706),
                  'AMBIGUOUS',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "자동 승인",
                  _workingLines
                      .where(
                        (l) =>
                            l.reviewStatus == 'CONFIRMED' &&
                            !l.source.contains('human'),
                      )
                      .length,
                  const Color(0xFF0D9488),
                  'AUTO_CONFIRMED',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "수동 승인",
                  _workingLines
                      .where(
                        (l) =>
                            l.reviewStatus == 'CONFIRMED' &&
                            l.source.contains('human'),
                      )
                      .length,
                  const Color(0xFF16A34A),
                  'HUMAN_CONFIRMED',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "미검수",
                  _lineDetectedCount,
                  const Color(0xFF2563EB),
                  'DETECTED',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "제외",
                  _lineRejectedCount,
                  const Color(0xFF64748B),
                  'REJECTED',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _focusConnectionMission() {
    final mission = _connectionPriorityMissionLines;
    if (mission.isEmpty) return;
    final firstOpen = mission.firstWhere(
      (line) => line.reviewStatus != 'CONFIRMED',
      orElse: () => mission.first,
    );
    setState(() {
      _connectionFullOverview = false;
      _connectionLinesOnlyMode = false;
      _connectionFastMode = false;
      _lineFocusOnly = true;
      _connFilterStatus = 'ALL';
      _connSortOption = 'SEVERITY';
      _showAllLinesList = false;
      _selectedLine = firstOpen;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      final idx = _filteredAndSortedWorkingLines.indexWhere(
        (line) => line.lineId == firstOpen.lineId,
      );
      _linePage = idx < 0 ? 0 : idx ~/ _linePageSize;
    });
  }

  Widget _buildConnectionMissionCard() {
    final mission = _connectionPriorityMissionLines;
    final total = mission.length;
    final completed = _connectionMissionCompleted;
    final done = _connectionMissionComplete;
    final progress = total == 0 ? 1.0 : completed / total;

    return Container(
      key: _connectionMissionKey,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFF0FDF4) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: done ? const Color(0xFF86EFAC) : const Color(0xFF93C5FD),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                done ? Icons.task_alt : Icons.flag_outlined,
                size: 17,
                color: done ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Lensy 결선 검토 미션',
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: done ? const Color(0xFFDCFCE7) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: done
                        ? const Color(0xFF86EFAC)
                        : const Color(0xFFBFDBFE),
                  ),
                ),
                child: Text(
                  '예외 확인 $completed/$total',
                  style: TextStyle(
                    color: done
                        ? const Color(0xFF15803D)
                        : const Color(0xFF1D4ED8),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            done
                ? '오류·모호 선로 우선 검토가 끝났습니다. 전체 선로를 빠르게 확인할 수 있어요.'
                : '오류·모호 선로부터 최대 5개를 먼저 확인합니다. 선택 선로만 캔버스에 남겨집니다.',
            style: const TextStyle(
              color: Color(0xFF475569),
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: Colors.white,
              valueColor: AlwaysStoppedAnimation(
                done ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              TextButton.icon(
                onPressed: total == 0 ? null : _focusConnectionMission,
                icon: const Icon(Icons.center_focus_strong, size: 14),
                label: const Text('핵심 항목 보기'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1D4ED8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              if (done)
                ElevatedButton.icon(
                  onPressed: () => setState(
                    () => _connectionFastMode = !_connectionFastMode,
                  ),
                  icon: const Icon(Icons.flash_on, size: 14),
                  label: Text(_connectionFastMode ? '전체 빠른 확인 중' : '전체 빠른 확인'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _connectionFastMode
                        ? const Color(0xFF64748B)
                        : const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionDisplayModeCard() {
    final linesOnly = _connectionLinesOnlyMode;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: linesOnly ? const Color(0xFFF0FDFA) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: linesOnly ? const Color(0xFF99F6E4) : const Color(0xFFFDE68A),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            linesOnly ? Icons.timeline : Icons.grid_view_rounded,
            size: 17,
            color: linesOnly
                ? const Color(0xFF0F766E)
                : const Color(0xFFB45309),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  linesOnly ? '전체 선로만 보기' : '전체 결선 한눈에 보기',
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  linesOnly
                      ? '다른 기호의 라벨과 강조를 줄이고 모든 선로를 표시합니다.'
                      : '전체 선로를 한 번에 확인하고 의심 항목을 우선 요약합니다.',
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 10.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              _showConnectionNextLineForAgent();
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1D4ED8),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('예외 목록 보기', style: TextStyle(fontSize: 10)),
          ),
        ],
      ),
    );
  }

  Color _connectionLineColor(ReviewLineItem line) {
    if (line.reviewStatus == 'REJECTED') return const Color(0xFF94A3B8);
    if (ConnectionReviewGateEvaluator.lineHasCriticalIssue(line)) {
      return const Color(0xFFDC2626);
    }
    if (ConnectionReviewGateEvaluator.isUnresolvedCrossing(line)) {
      return const Color(0xFF9333EA);
    }
    if (line.reviewStatus == 'AMBIGUOUS') return const Color(0xFFD97706);
    return const Color(0xFF64748B);
  }

  Widget _buildConnectionReviewV2SidePanel() {
    final active = _activeConnectionLines;
    final filtered = _filteredAndSortedWorkingLines;
    final issueLines = ConnectionVisualSweep.orderedLines(
      active.where((line) => _connectionGuideLineIds.contains(line.lineId)),
    );
    final selected = ConnectionReviewGateEvaluator.selectedLineForFilter(
      workingLines: _workingLines,
      status: _connFilterStatus,
      selectedLine: _selectedLine,
    );
    final visible = filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.account_tree_outlined,
              size: 17,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '전체 네트워크 결선 검수',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            Text(
              '${active.length}개',
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _connectionGateBlockers.isEmpty
              ? '정상 결선은 자동 확인되고, 예외만 실제 경로와 함께 표시됩니다.'
              : '확인이 필요한 예외를 선택해 끝점·경로·전기 근거를 확인하세요.',
          style: const TextStyle(
            color: Color(0xFF475569),
            fontSize: 10.5,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _buildFilterableConnStatBadge(
              '전체',
              active.length,
              const Color(0xFF475569),
              ConnectionReviewGateEvaluator.filterAll,
            ),
            _buildFilterableConnStatBadge(
              '확인 필요',
              _connectionExceptionLines.length,
              const Color(0xFFD97706),
              ConnectionReviewGateEvaluator.filterNeedsReview,
            ),
            _buildFilterableConnStatBadge(
              '교차',
              _connectionCrossingCount,
              const Color(0xFF9333EA),
              ConnectionReviewGateEvaluator.filterCrossing,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (active.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFDBA74)),
            ),
            child: const Text(
              ConnectionReviewGateEvaluator.noActiveLineMessage,
              style: TextStyle(
                color: Color(0xFF9A3412),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        else ...[
          if (issueLines.isNotEmpty) ...[
            const Text(
              '확인 필요한 예외',
              style: TextStyle(
                color: Color(0xFF334155),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: issueLines.map((line) {
                final color = _connectionLineColor(line);
                final isSelected = selected?.lineId == line.lineId;
                return ChoiceChip(
                  label: Text(line.effectiveDisplayLabel),
                  selected: isSelected,
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                  selectedColor: color,
                  backgroundColor: color.withValues(alpha: 0.08),
                  side: BorderSide(color: color.withValues(alpha: 0.55)),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _selectConnectionLine(line),
                );
              }).toList(),
            ),
          ] else if (_connectionGateBlockers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '확인이 필요한 결선 예외가 없습니다.',
                style: TextStyle(
                  color: Color(0xFF0F766E),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (_connectionVisualSweepStarted) ...[
            const SizedBox(height: 9),
            _buildConnectionVisualSweepProgress(),
          ],
          const SizedBox(height: 8),
          InkWell(
            onTap: () => setState(() => _showAllLinesList = !_showAllLinesList),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _showAllLinesList ? Icons.expand_less : Icons.expand_more,
                    size: 17,
                    color: const Color(0xFF475569),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '전체 선로 목록 보기 (${active.length})',
                      style: const TextStyle(
                        color: Color(0xFF334155),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    _showAllLinesList ? '접기' : '펼치기',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showAllLinesList) ...[
            const SizedBox(height: 4),
            if (visible.isEmpty)
              _buildConnectionFilterEmptyState()
            else
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: visible.map((line) {
                  final color = _connectionLineColor(line);
                  final isSelected = selected?.lineId == line.lineId;
                  return ChoiceChip(
                    label: Text(line.effectiveDisplayLabel),
                    selected: isSelected,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : color,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                    selectedColor: color,
                    backgroundColor: color.withValues(alpha: 0.08),
                    side: BorderSide(color: color.withValues(alpha: 0.55)),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _selectConnectionLine(line),
                  );
                }).toList(),
              ),
          ],
          const SizedBox(height: 10),
          if (selected != null)
            _buildConnectionReviewV2Inspector(selected)
          else
            _buildNoSelectionPrompt('결선'),
        ],
        const SizedBox(height: 12),
        _buildConnectionV2TopologySummary(),
      ],
    );
  }

  void _selectConnectionLine(ReviewLineItem line) {
    setState(() {
      _selectedLine = line;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      if (!_filteredAndSortedWorkingLines.any(
        (candidate) => candidate.lineId == line.lineId,
      )) {
        _connFilterStatus = ConnectionReviewGateEvaluator.filterAll;
      }
    });
  }

  Widget _buildConnectionVisualSweepProgress() {
    final ordered = ConnectionVisualSweep.orderedLines(_activeConnectionLines);
    final rawIndex = ConnectionVisualSweep.indexOf(
      ordered,
      _selectedLine?.lineId,
    );
    final index = rawIndex < 0 ? 0 : rawIndex;
    final progress = ordered.isEmpty ? 0 : (index + 1) / ordered.length;
    return Container(
      key: const ValueKey('ConnectionVisualSweepProgress'),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDFA),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFF99F6E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '최종 육안 확인 ${ordered.isEmpty ? 0 : index + 1} / ${ordered.length}',
            style: const TextStyle(
              color: Color(0xFF0F766E),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: progress.toDouble(),
            minHeight: 4,
            backgroundColor: Colors.white,
            valueColor: const AlwaysStoppedAnimation(Color(0xFF14B8A6)),
          ),
          const SizedBox(height: 5),
          const Text(
            '선택된 선로와 양 끝점을 눈으로 확인합니다. 검수 상태나 Gate는 자동 변경되지 않습니다.',
            style: TextStyle(
              color: Color(0xFF475569),
              fontSize: 10,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionFilterEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: const Text(
        '해당 조건의 결선이 없습니다.',
        style: TextStyle(
          color: Color(0xFF64748B),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildConnectionV2TopologySummary() {
    final critical = _topologyIssues
        .where(ConnectionReviewGateEvaluator.isCriticalIssue)
        .toList();
    final warnings = _topologyIssues
        .where((issue) => !ConnectionReviewGateEvaluator.isCriticalIssue(issue))
        .toList();
    final hasCritical = critical.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: hasCritical ? const Color(0xFFFFF1F2) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasCritical
              ? const Color(0xFFFCA5A5)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasCritical ? Icons.error_outline : Icons.fact_check_outlined,
                size: 16,
                color: hasCritical
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF64748B),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  hasCritical
                      ? '전기 오류 ${critical.length}개'
                      : '토폴로지 재검증 완료 · 경고 ${warnings.length}건',
                  style: TextStyle(
                    color: hasCritical
                        ? const Color(0xFFB91C1C)
                        : const Color(0xFF475569),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '토폴로지 재검증',
                visualDensity: VisualDensity.compact,
                onPressed: _triggerTopologyValidation,
                icon: const Icon(Icons.refresh, size: 16),
              ),
            ],
          ),
          if (hasCritical) ...[
            const SizedBox(height: 4),
            ...critical
                .take(3)
                .map(
                  (issue) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      _formatTopologyIssueKo(issue),
                      style: const TextStyle(
                        color: Color(0xFF7F1D1D),
                        fontSize: 10.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
          ] else if (warnings.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text(
                'warning/info는 최종 게이트를 막지 않습니다.',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConnectionReviewV2Inspector(ReviewLineItem line) {
    final color = _connectionLineColor(line);
    final status = ConnectionReviewGateEvaluator.lineStatusLabel(line);
    final connStr =
        line.endpointsDisplay ??
        (line.connectedTo.isEmpty ? '미연결' : line.connectedTo.join(' ↔ '));
    final hasCrossing = ConnectionReviewGateEvaluator.hasCrossingEvidence(line);
    final isIssue = ConnectionReviewGateEvaluator.isExceptionLine(line);
    final pathSummary = line.path.length >= 2
        ? '${line.path.length}개 점 · ${line.path.first.join(', ')} → ${line.path.last.join(', ')}'
        : '실제 픽셀 경로 점 ${line.path.length}개';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${line.effectiveDisplayLabel} · ${line.lineId}',
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connStr,
                      style: const TextStyle(
                        color: Color(0xFF334155),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildConnectionEvidenceRow('실제 경로', pathSummary),
          _buildConnectionEvidenceRow(
            '추적/단자',
            '${line.traceMethod} · ${line.sourcePort} → ${line.targetPort}',
          ),
          if (line.agentExplanation != null &&
              line.agentExplanation!.trim().isNotEmpty)
            _buildConnectionEvidenceRow('AI 설명', line.agentExplanation!),
          if (line.validationIssues.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              '검증 근거',
              style: TextStyle(
                color: Color(0xFF334155),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            ...line.validationIssues.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '• ${issue['message'] ?? issue['code'] ?? '검증 이슈'}',
                  style: TextStyle(
                    color: ConnectionReviewGateEvaluator.isCriticalIssue(issue)
                        ? const Color(0xFFB91C1C)
                        : const Color(0xFF92400E),
                    fontSize: 10.5,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
          if (line.candidateTargets.isNotEmpty) ...[
            const SizedBox(height: 9),
            const Text(
              '후보 끝점 · 직접 선택하면 재검증합니다',
              style: TextStyle(
                color: Color(0xFF334155),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: line.candidateTargets.map((target) {
                return ActionChip(
                  label: Text(target, style: const TextStyle(fontSize: 10.5)),
                  onPressed: () => _reassignConnectionEndpoint(line, target),
                );
              }).toList(),
            ),
          ],
          if (hasCrossing) ...[
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFAF5FF),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFD8B4FE)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '실제 교차 근거가 감지되었습니다.',
                    style: TextStyle(
                      color: Color(0xFF7E22CE),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 5,
                    children: [
                      OutlinedButton(
                        onPressed: () =>
                            _resolveConnectionCrossing(line, 'CONNECTED'),
                        child: const Text(
                          '연결됨',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _resolveConnectionCrossing(line, 'CROSSING_ONLY'),
                        child: const Text(
                          '교차만 함',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 9),
          if (isIssue)
            OutlinedButton.icon(
              onPressed: line.reviewStatus == 'REJECTED'
                  ? null
                  : () => _rejectLine(line),
              icon: const Icon(Icons.remove_circle_outline, size: 15),
              label: const Text('선로 제외', style: TextStyle(fontSize: 10.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF64748B),
                visualDensity: VisualDensity.compact,
              ),
            )
          else
            const Text(
              '정상 결선은 개별 승인하지 않습니다. 전체 네트워크를 확인한 뒤 최종 CTA를 사용하세요.',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10.5,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConnectionEvidenceRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFF334155), fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  void _reassignConnectionEndpoint(ReviewLineItem line, String targetId) {
    final index = _workingLines.indexWhere(
      (item) => item.lineId == line.lineId,
    );
    if (index < 0) return;
    final updated = ConnectionReviewGateEvaluator.reassignTarget(
      line,
      targetId,
    );
    setState(() {
      _workingLines[index] = updated;
      _selectedLine = updated;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _isFinalVerified = false;
    });
    PowerLensAIService.instance.removeFocusTarget(line.lineId);
    _triggerTopologyValidation();
  }

  void _resolveConnectionCrossing(ReviewLineItem line, String resolution) {
    final index = _workingLines.indexWhere(
      (item) => item.lineId == line.lineId,
    );
    if (index < 0) return;
    setState(() {
      final updated = line.copyWith(
        reviewStatus: 'CONFIRMED',
        source: 'human_crossing_review',
      );
      updated.connectionReviewResolution = resolution;
      _workingLines[index] = updated;
      _selectedLine = updated;
      _isFinalVerified = false;
    });
    PowerLensAIService.instance.removeFocusTarget(line.lineId);
    _triggerTopologyValidation();
  }

  void _rejectLine(ReviewLineItem line) {
    final index = _workingLines.indexWhere(
      (item) => item.lineId == line.lineId,
    );
    if (index < 0) return;
    setState(() {
      line.reviewStatus = 'REJECTED';
      line.source = 'human_rejected';
      _workingLines[index] = line;
      _selectedLine = null;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _isFinalVerified = false;
    });
    PowerLensAIService.instance.removeFocusTarget(line.lineId);
    _triggerTopologyValidation();
  }

  // Legacy wrapper retained only for source compatibility; the active
  // Connection Review path uses _buildConnectionReviewV2SidePanel.
  // ignore: unused_element
  Widget _buildConnectionReviewSidePanel() {
    var lines = _filteredAndSortedWorkingLines;
    if (lines.isEmpty) {
      lines = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
      if (lines.isEmpty) lines = _workingLines;
    }
    if (_selectedLine == null &&
        lines.isNotEmpty &&
        _selectedTopologyIssue == null &&
        _selectedNode == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedLine == null && lines.isNotEmpty) {
          setState(() {
            if (_connFilterStatus != 'ALL' &&
                _filteredAndSortedWorkingLines.isEmpty) {
              _connFilterStatus = 'ALL';
            }
            _selectedLine = lines.first;
          });
        }
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildConnectionQueueHeader(),
        const SizedBox(height: 8),
        _buildConnectionMissionCard(),
        if (_connectionFullOverview || _connectionLinesOnlyMode) ...[
          const SizedBox(height: 8),
          _buildConnectionDisplayModeCard(),
        ],
        const Divider(color: Color(0xFFE2E8F0), height: 1),
        const SizedBox(height: 12),

        // 1. Hero Sequential Line Review Card
        if (_selectedLine != null)
          _buildSelectedLinePanel()
        else if (_selectedTopologyIssue != null && _selectedNode != null)
          _buildTopologyIssueDetailPanel()
        else
          _buildNoSelectionPrompt("선로"),

        const SizedBox(height: 14),
        const Divider(color: Color(0xFFE2E8F0), height: 1),
        const SizedBox(height: 10),

        // 2. Collapsible Queue / All Lines List
        InkWell(
          onTap: () => setState(() => _showAllLinesList = !_showAllLinesList),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _showAllLinesList ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF64748B),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "전체 선로 대기열 (${lines.length}개)",
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Text(
                  _showAllLinesList ? "접기" : "펼치기",
                  style: const TextStyle(
                    color: Color(0xFF0284C7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showAllLinesList) ...[
          const SizedBox(height: 8),
          _buildLineSelectionChips(),
        ],

        const SizedBox(height: 12),
        const Divider(color: Color(0xFFE2E8F0), height: 1),
        const SizedBox(height: 10),

        // 3. Topology Validation Issues Summary
        _buildTopologyIssuesSection(),
      ],
    );
  }

  Widget _buildTopologyIssuesSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _criticalIssuesCount > 0
              ? const Color(0xFFFCA5A5)
              : const Color(0xFF86EFAC),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _criticalIssuesCount > 0
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 18,
                color: _criticalIssuesCount > 0
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF16A34A),
              ),
              const SizedBox(width: 6),
              const Text(
                "토폴로지 전기적 무결성 검증",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
                tooltip: "토폴로지 재검증",
                onPressed: _triggerTopologyValidation,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _criticalIssuesCount > 0
                ? "전기적 규칙 위반 이슈 $_criticalIssuesCount건이 감지되었습니다."
                : "모든 결선이 전기적 무결성 검증을 통과했습니다.",
            style: TextStyle(
              color: _criticalIssuesCount > 0
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF16A34A),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (_topologyIssues.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () =>
                  setState(() => _showTopologyDetails = !_showTopologyDetails),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      _showTopologyDetails
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: const Color(0xFF64748B),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _showTopologyDetails ? "토폴로지 상세 접기" : "토폴로지 상세 보기",
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showTopologyDetails) ...[
              const SizedBox(height: 4),
              ..._topologyIssues.map((iss) {
                final isError = iss['severity'] == 'error';
                final isSelected = _selectedTopologyIssue == iss;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _onSelectTopologyIssue(iss),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? (isError
                                  ? const Color(0xFFFEE2E2)
                                  : const Color(0xFFFEF3C7))
                            : (isError
                                  ? const Color(0xFFFFF1F2)
                                  : const Color(0xFFFFFBEB)),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFF59E0B)
                              : (isError
                                    ? const Color(0xFFFCA5A5)
                                    : const Color(0xFFFDE68A)),
                          width: isSelected ? 1.8 : 1.0,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              isError ? Icons.cancel : Icons.warning,
                              size: 13,
                              color: isError
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFFD97706),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _formatTopologyIssueKo(iss),
                                  style: TextStyle(
                                    color: const Color(0xFF0F172A),
                                    fontSize: 10.5,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.touch_app,
                                      size: 10,
                                      color: isSelected
                                          ? const Color(0xFFB45309)
                                          : const Color(0xFF64748B),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      isSelected
                                          ? "캔버스 위치 강조됨 · 아래에서 바로 선로 연결"
                                          : "클릭하여 캔버스 위치 확인 및 선로 연결",
                                      style: TextStyle(
                                        color: isSelected
                                            ? const Color(0xFFB45309)
                                            : const Color(0xFF64748B),
                                        fontSize: 9.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (isSelected)
                            const Padding(
                              padding: EdgeInsets.only(left: 4, top: 2),
                              child: Icon(
                                Icons.arrow_forward_ios,
                                size: 11,
                                color: Color(0xFFB45309),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ],
        ],
      ),
    );
  }

  void _onSelectTopologyIssue(Map<String, dynamic> iss) {
    setState(() {
      _selectedTopologyIssue = iss;
      final compIds = iss['component_ids'];
      if (compIds is List && compIds.isNotEmpty) {
        final firstId = compIds.first.toString();
        // Check if it's a node
        ReviewNodeItem? matchedNode;
        for (final n in _workingNodes) {
          if (n.id == firstId) {
            matchedNode = n;
            break;
          }
        }
        if (matchedNode != null) {
          _selectedNode = matchedNode;
          _selectedLine = null;
        } else {
          // Check if it's a line
          ReviewLineItem? matchedLine;
          for (final l in _workingLines) {
            if (l.lineId == firstId) {
              matchedLine = l;
              break;
            }
          }
          if (matchedLine != null) {
            _selectedLine = matchedLine;
            _selectedNode = null;
          }
        }
      }
    });

    if (_selectedNode != null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "캔버스에서 ${_selectedNode!.effectiveDisplayLabel} 부품 위치가 강조 표시되었습니다.",
          ),
          backgroundColor: Colors.purple.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildTopologyIssueDetailPanel() {
    if (_selectedTopologyIssue == null || _selectedNode == null) {
      return const SizedBox.shrink();
    }
    final iss = _selectedTopologyIssue!;
    final node = _selectedNode!;
    final isError = iss['severity'] == 'error';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? const Color(0xFFDC2626) : const Color(0xFFF59E0B),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isError
                      ? const Color(0xFFDC2626)
                      : const Color(0xFFF59E0B),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isError ? "규칙 위반 상세" : "경고 상세",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.effectiveDisplayLabel,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
                tooltip: "닫기",
                onPressed: () => setState(() => _selectedTopologyIssue = null),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _getTopologyIssueExplanation(iss, node),
            style: const TextStyle(
              color: Color(0xFF334155),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isManualAddLineMode = true;
                      _manualLineStartNode = node;
                    });
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "👉 도면(캔버스)에서 ${node.effectiveDisplayLabel}와 연결할 모선(Bus)을 클릭하세요.",
                        ),
                        backgroundColor: Colors.purple,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_link, size: 15),
                  label: const Text(
                    "➕ 지금 선로 연결하기",
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purpleAccent.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getTopologyIssueExplanation(
    Map<String, dynamic> iss,
    ReviewNodeItem node,
  ) {
    final code = iss['code']?.toString() ?? '';
    final cls = node.className.toLowerCase();
    if (code == 'invalid_terminal_degree') {
      if (cls.contains('load')) {
        return "전력 계통 규칙상 부하(Load)는 모선(Bus)과 반드시 1개의 선로로 연결되어야 합니다. 현재 도면에서 연결 선로가 검출되지 않았으므로, 아래 버튼을 눌러 인접한 모선과 선로를 연결해주세요.";
      } else if (cls.contains('gen')) {
        return "전력 계통 규칙상 발전기(Generator)는 모선(Bus)과 1개의 선로로 연결되어야 합니다. 현재 도면에서 연결 선로가 검출되지 않았습니다.";
      } else if (cls.contains('trans')) {
        return "변압기(Transformer)는 1차측과 2차측 2개의 모선과 연결되어야 합니다. 연결된 선로 수를 확인해주세요.";
      } else if (cls.contains('bus')) {
        return "모선(Bus)에 연결된 선로가 없습니다. 고립된 모선인지 확인해주세요.";
      }
    } else if (code == 'isolated_subgraph') {
      return "이 부품이 속한 영역이 주 전력 계통망과 단절되어 고립되어 있습니다. 계통 간 연계 선로를 확인해주세요.";
    } else if (code == 'invalid_device_pair') {
      return "발전기나 부하 간에 모선 없이 직접 연결되었습니다. 실제 계통에서는 모선을 거쳐 연결되어야 합니다.";
    } else if (code == 'nested_bus_collision') {
      return "동일한 전력 모선(Bus) 위치에 2개 이상의 모선 바가 물리적으로 겹쳐 검출되었습니다. 중복 검출된 모선 오류이므로 하나의 올바른 모선만 남기고 중복 모선을 제거하세요.";
    }
    return iss['message']?.toString() ?? "전기적 규칙 위반이 감지되었습니다.";
  }

  Widget _buildLineSelectionChips() {
    final list = _filteredAndSortedWorkingLines;
    if (list.isEmpty) return const SizedBox.shrink();
    final pageCount = (list.length / _linePageSize).ceil();
    final currentPage = _linePage.clamp(0, pageCount - 1).toInt();
    final startIndex = currentPage * _linePageSize;
    final endIndex = (startIndex + _linePageSize).clamp(0, list.length).toInt();
    final pageLines = list.sublist(startIndex, endIndex);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.timeline, size: 14, color: Color(0xFF64748B)),
            const SizedBox(width: 4),
            Text(
              "선로 목록 (${list.length}개) · ${currentPage + 1}/$pageCount 페이지",
              style: const TextStyle(
                color: Color(0xFF475569),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: pageLines.map((l) {
            final isSelected = _selectedLine?.lineId == l.lineId;
            final isAmbiguous = l.reviewStatus == 'AMBIGUOUS';
            final color = isAmbiguous
                ? const Color(0xFFD97706)
                : (l.reviewStatus == 'CONFIRMED'
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF0284C7));

            return GestureDetector(
              onTap: () => setState(() {
                _selectedLine = l;
                _linePage = currentPage;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? color.withValues(alpha: 0.15)
                      : const Color(0xFFF8FAFC),
                  border: Border.all(
                    color: isSelected ? color : const Color(0xFFCBD5E1),
                    width: isSelected ? 1.8 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  l.effectiveDisplayLabel,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF0F172A)
                        : const Color(0xFF334155),
                    fontSize: 11,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (pageCount > 1) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '이전 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: currentPage > 0
                    ? () => setState(() => _linePage = currentPage - 1)
                    : null,
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              for (var page = 0; page < pageCount; page++)
                ChoiceChip(
                  label: Text('${page + 1}'),
                  selected: page == currentPage,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => setState(() => _linePage = page),
                ),
              IconButton(
                tooltip: '다음 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: currentPage < pageCount - 1
                    ? () => setState(() => _linePage = currentPage + 1)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSelectedLinePanel() {
    final line = _selectedLine!;
    var lines = _filteredAndSortedWorkingLines;
    if (lines.isEmpty || !lines.any((l) => l.lineId == line.lineId)) {
      lines = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
      if (lines.isEmpty) lines = _workingLines;
    }
    final currentIndex = lines.indexWhere((l) => l.lineId == line.lineId);
    final totalCount = lines.length;
    final isAmbiguous = line.reviewStatus == 'AMBIGUOUS';
    final isConfirmed = line.reviewStatus == 'CONFIRMED';
    final connStr =
        line.endpointsDisplay ??
        (line.connectedTo.isNotEmpty ? line.connectedTo.join(" ↔ ") : "미연결");

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isConfirmed
              ? const Color(0xFF86EFAC)
              : (isAmbiguous
                    ? const Color(0xFFFDE68A)
                    : const Color(0xFFBAE6FD)),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Sequential Progress Bar & Indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "⚡ 선로 결선 근거 확인",
                style: TextStyle(
                  color: Color(0xFF334155),
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                totalCount > 0
                    ? "$totalCount개 중 ${currentIndex >= 0 ? currentIndex + 1 : 1}번째"
                    : "",
                style: const TextStyle(
                  color: Color(0xFF0284C7),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: totalCount > 0
                  ? (((currentIndex >= 0 ? currentIndex : 0) + 1) / totalCount)
                        .clamp(0.0, 1.0)
                  : 1.0,
              minHeight: 5,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF0284C7)),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Hero Line Banner (Prominent Endpoints & Status)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isConfirmed
                    ? const Color(0xFF86EFAC)
                    : const Color(0xFFBAE6FD),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      (isConfirmed
                              ? const Color(0xFF16A34A)
                              : const Color(0xFF0284C7))
                          .withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color:
                            (isConfirmed
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF0284C7))
                                .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.alt_route_rounded,
                        color: isConfirmed
                            ? const Color(0xFF16A34A)
                            : const Color(0xFF0284C7),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            connStr,
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "선로 ID: ${line.lineId} (${line.effectiveDisplayLabel})",
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isConfirmed
                            ? const Color(0xFFDCFCE7)
                            : (isAmbiguous
                                  ? const Color(0xFFFEF3C7)
                                  : const Color(0xFFE0F2FE)),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isConfirmed
                              ? const Color(0xFF86EFAC)
                              : (isAmbiguous
                                    ? const Color(0xFFFDE68A)
                                    : const Color(0xFFBAE6FD)),
                        ),
                      ),
                      child: Text(
                        isConfirmed
                            ? "승인 완료"
                            : (isAmbiguous ? "검토 필요" : "확인 대기"),
                        style: TextStyle(
                          color: isConfirmed
                              ? const Color(0xFF16A34A)
                              : (isAmbiguous
                                    ? const Color(0xFFB45309)
                                    : const Color(0xFF0284C7)),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. AI Detection & Tracing Summary
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 14,
                      color: Color(0xFF6366F1),
                    ),
                    SizedBox(width: 6),
                    Text(
                      "AI 선로 추적 진단:",
                      style: TextStyle(
                        color: Color(0xFF334155),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "• 추적 알고리즘: ${line.traceMethod}  |  연결 단자: ${line.sourcePort} ➔ ${line.targetPort}",
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 4. Reconnect Candidate Chips (if any)
          if (line.candidateTargets.isNotEmpty) ...[
            const Text(
              "연결 대상 Bus 재지정:",
              style: TextStyle(
                color: Color(0xFF475569),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: line.candidateTargets.map((busId) {
                return ActionChip(
                  label: Text("➔ $busId", style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    setState(() {
                      if (line.connectedTo.length >= 2) {
                        line.connectedTo[1] = busId;
                      } else if (line.connectedTo.length == 1) {
                        line.connectedTo.add(busId);
                      }
                      line.reviewStatus = 'CONFIRMED';
                      line.source = 'human_reconnected';
                    });
                    _triggerTopologyValidation();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
          ],

          // 5. Big Primary Action CTA
          ElevatedButton.icon(
            key: _connectionPrimaryActionKey,
            onPressed: null,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text(
              "정상 결선은 자동 확인",
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 6. Secondary Navigation Row
          Row(
            children: [
              Expanded(
                child: GlowingTargetWrapper(
                  targetId: 'line_prev',
                  borderRadius: BorderRadius.circular(4),
                  guideLabel: "✨ 이전 선로 (◀)",
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.arrow_back, size: 13),
                    label: const Text("이전 (◀)", style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlowingTargetWrapper(
                  targetId: 'line_reject',
                  borderRadius: BorderRadius.circular(4),
                  guideLabel: "✨ 선로 제외/삭제",
                  child: OutlinedButton.icon(
                    onPressed: () => _rejectLine(line),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 13,
                      color: Color(0xFFDC2626),
                    ),
                    label: const Text(
                      "제외/삭제",
                      style: TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      side: const BorderSide(color: Color(0xFFFCA5A5)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlowingTargetWrapper(
                  targetId: 'line_skip',
                  borderRadius: BorderRadius.circular(4),
                  guideLabel: "✨ 선로 건너뛰기",
                  child: OutlinedButton(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    child: const Text(
                      "건너뛰기",
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlowingTargetWrapper(
                  targetId: 'line_next',
                  borderRadius: BorderRadius.circular(4),
                  guideLabel: "✨ 선로 선택",
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.arrow_forward, size: 13),
                    label: const Text("다음 (▶)", style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 7. Beginner Tip Note
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.tips_and_updates_outlined,
                  size: 14,
                  color: Color(0xFF2563EB),
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "정상 결선은 개별 승인하지 않습니다. 확인이 필요한 예외만 실제 경로와 함께 검토하세요.",
                    style: TextStyle(
                      color: Color(0xFF1E40AF),
                      fontSize: 10.5,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Agent Chat Side Panel ---

  // Kept for backwards compatibility with the legacy review implementation;
  // Lensy's global panel is the only visible assistant entry point now.
  // ignore: unused_element
  Widget _buildAgentChatSidePanel() {
    return Column(
      children: [
        // Mode Header Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFFF1F5F9),
            border: Border(
              bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xFF2563EB), size: 16),
              const SizedBox(width: 6),
              const Text(
                "AI 도면 검토 도우미 · Lensy",
                style: TextStyle(
                  color: Color(0xFF1D4ED8),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_selectedNode != null)
                Text(
                  "선택: ${_selectedNode!.effectiveDisplayLabel}",
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 10,
                  ),
                ),
              if (_selectedLine != null)
                Text(
                  "선택: ${_selectedLine!.effectiveDisplayLabel}",
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),

        // Chat Message List
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _chatHistory.length,
            itemBuilder: (context, idx) {
              final msg = _chatHistory[idx];
              final isUser = msg.role == "user";
              return Align(
                alignment: isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.32,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? const Color(0xFF2563EB)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isUser
                          ? const Color(0xFF2563EB)
                          : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isUser ? Icons.person : Icons.smart_toy,
                            size: 13,
                            color: isUser
                                ? Colors.white70
                                : const Color(0xFF2563EB),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isUser
                                ? "나"
                                : ((msg.providerMode ?? '')
                                          .toLowerCase()
                                          .startsWith('gemini')
                                      ? "Lensy AI · Gemini"
                                      : "Lensy AI · Local"),
                            style: TextStyle(
                              color: isUser
                                  ? Colors.white70
                                  : const Color(0xFF1D4ED8),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        msg.text,
                        style: TextStyle(
                          color: isUser
                              ? Colors.white
                              : const Color(0xFF0F172A),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Interactive Suggestion Chips
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 1)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPromptChip("📊 검토 필요한 부분 요약해줘"),
                _buildPromptChip("🧭 다음에 무엇을 해야 해?"),
                if (_selectedNode != null)
                  _buildPromptChip(
                    "🔍 왜 ${_selectedNode!.effectiveDisplayLabel}가 의심이야?",
                  ),
                if (_selectedNode != null)
                  _buildPromptChip(
                    "⚡ ${_selectedNode!.effectiveDisplayLabel} 클래스를 바꾸면 어떤 영향이 있어?",
                  ),
                if (_selectedLine != null)
                  _buildPromptChip(
                    "🔗 선택한 선로 ${_selectedLine!.effectiveDisplayLabel}가 왜 문제야?",
                  ),
                _buildPromptChip("⚠️ 누락된 설비 후보가 어디쯤 있어?"),
              ],
            ),
          ),
        ),

        // Chat Input Box
        Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatInputController,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    hintText: "도면, 선택 객체/선로에 대해 질문하세요...",
                    hintStyle: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                  ),
                  onSubmitted: _sendChatMessage,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isChatLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF2563EB),
                        ),
                      )
                    : const Icon(Icons.send, color: Color(0xFF2563EB)),
                onPressed: _isChatLoading
                    ? null
                    : () => _sendChatMessage(_chatInputController.text),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPromptChip(String prompt) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(
          prompt,
          style: const TextStyle(fontSize: 10, color: Color(0xFF334155)),
        ),
        backgroundColor: const Color(0xFFF1F5F9),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
        onPressed: () => _sendChatMessage(prompt),
      ),
    );
  }

  String _formatTopologyIssueKo(Map<String, dynamic> iss) {
    final code = iss['code']?.toString() ?? '';
    final rawMsg = iss['message']?.toString() ?? '';
    final compIds = iss['component_ids'];
    String compsStr = '';
    if (compIds is List && compIds.isNotEmpty) {
      compsStr = compIds
          .map((id) => _getDisplayLabelForId(id.toString()))
          .join(' ↔ ');
    }

    switch (code) {
      case 'invalid_terminal_degree':
        return compsStr.isNotEmpty
            ? "[단자 연결 오류] '$compsStr' 기기는 모선(Bus)에 정확히 1개의 선로로 연결되어야 합니다 (현재 연결 수 불일치)"
            : "[단자 연결 오류] 발전기/부하는 모선에 정확히 1개의 선로로 연결되어야 합니다.";
      case 'invalid_transformer_degree':
        return compsStr.isNotEmpty
            ? "[변압기 결선 이상] '$compsStr' 변압기의 1차측/2차측 결선이 불완전합니다."
            : "[변압기 결선 이상] 변압기 양단 포트 연결이 확인되지 않습니다.";
      case 'isolated_bus':
        return compsStr.isNotEmpty
            ? "[고립 모선] '$compsStr' 모선에 연결된 선로가 없습니다."
            : "[고립 모선] 모선에 연결된 선로가 없습니다.";
      case 'nested_bus_collision':
        return compsStr.isNotEmpty
            ? "[모선 중복/충돌] '$compsStr' 모선이 물리적으로 겹쳐 검출되었습니다 (도면상 동일 위치 중복 모선 오류)"
            : "[모선 중복/충돌] 물리적으로 겹치거나 포함된 모선이 검출되었습니다.";
      case 'isolated_subgraph':
        return "[망 분리/고립] 독립된 전력망 서브그래프가 감지되었습니다. 주 전력망과의 연계 선로를 확인하세요.";
      case 'duplicate_edge':
        return compsStr.isNotEmpty
            ? "[선로 중복] '$compsStr' 사이에 2개 이상의 선로가 연결됨 (병렬 2회선이 아니면 1개 제외 권장)"
            : "[선로 중복] 동일한 두 객체 사이에 선로가 중복 연결되었습니다.";
      case 'self_loop':
        return compsStr.isNotEmpty
            ? "[루프 오류] '$compsStr'에 시작과 끝이 모두 연결되어 있습니다."
            : "[루프 오류] 동일 부품에 루프로 연결된 선로입니다.";
      case 'unknown_endpoint':
        return "[미등록 객체] 선로 끝점이 인식되지 않은 객체를 가리키고 있습니다.";
      case 'invalid_device_pair':
        return compsStr.isNotEmpty
            ? "[기기 직결 오류] '$compsStr' 간에 모선(Bus) 없이 직접 연결되었습니다."
            : "[기기 직결 오류] 발전기/부하 간에 모선 없이 직접 연결되었습니다.";
      case 'dangling_connection':
        return "[단선/미연결] 선로 한쪽 끝이 어떤 부품에도 연결되지 않았습니다.";
      default:
        return compsStr.isNotEmpty
            ? "[$code] $rawMsg ($compsStr)"
            : "[$code] $rawMsg";
    }
  }

  String _getDisplayLabelForId(String id) {
    for (final n in _workingNodes) {
      if (n.id == id) return n.effectiveDisplayLabel;
    }
    return id;
  }

  String _agentEventTitleKo(String event) {
    switch (event) {
      case 'issue_detected':
        return 'Issue 감지';
      case 'plan_created':
        return '실행 계획 수립';
      case 'tool_selected':
        return '도구 선택';
      case 'tool_completed':
        return '도구 실행 완료';
      case 'result_evaluated':
        return '토폴로지 점수 평가';
      case 'retry_scheduled':
        return '대체 도구 재시도 결정';
      case 'final_decision':
        return '최종 판단';
      case 'patch_registered':
        return '수정안(Patch) 등록';
      case 'run_failed':
        return '실행 실패';
      default:
        return 'Agent 활동';
    }
  }

  IconData _agentEventIcon(String event) {
    switch (event) {
      case 'issue_detected':
        return Icons.search;
      case 'plan_created':
        return Icons.assignment_outlined;
      case 'tool_selected':
        return Icons.handyman_outlined;
      case 'tool_completed':
        return Icons.check_circle_outline;
      case 'result_evaluated':
        return Icons.analytics_outlined;
      case 'retry_scheduled':
        return Icons.replay;
      case 'final_decision':
        return Icons.gavel;
      case 'patch_registered':
        return Icons.bookmark_added_outlined;
      case 'run_failed':
        return Icons.error_outline;
      default:
        return Icons.info_outline;
    }
  }

  String _reviewToolNameKo(String? tool) {
    switch (tool) {
      case 'port_aware_retry':
        return '포트 기준 선로 재추적 (port_aware_retry)';
      case 'roi_reanalysis':
        return '선택 영역 국소 재분석 (roi_reanalysis)';
      case 'missing_object_scan':
        return '누락 객체 탐색 (missing_object_scan)';
      case 'validate_topology':
        return '토폴로지 무결성 검증 (validate_topology)';
      case 'auto':
        return '자동 검수 Supervisor (auto)';
      default:
        return tool ?? '자동 검수 도구';
    }
  }

  // Kept for backwards compatibility with existing review activity data.
  // ignore: unused_element
  Widget _buildAgentActivitySidePanel() {
    if (_isLoadingAgentRuns) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF2563EB)),
      );
    }

    if (_agentRuns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_edu, size: 48, color: Color(0xFF94A3B8)),
              const SizedBox(height: 12),
              const Text(
                '기록된 Agent 활동 이력이 없습니다.',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '이슈 자동 재분석 또는 도구 실행 시 이곳에 사고 과정이 기록됩니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _fetchAgentRuns,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('활동 기록 새로고침'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFF8FAFC),
                  foregroundColor: const Color(0xFF334155),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAgentRuns,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _agentRuns.length,
        itemBuilder: (context, runIdx) {
          final run = _agentRuns[runIdx];
          final runId = run['run_id']?.toString() ?? 'run_$runIdx';
          final status = run['status']?.toString() ?? 'COMPLETED';
          final patchId = run['selected_patch_id']?.toString() ?? '-';
          final activityLog = List<dynamic>.from(
            run['activity_log'] ?? const [],
          );

          final isAwaiting = status == 'AWAITING_APPROVAL';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isAwaiting
                    ? const Color(0xFF86EFAC)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: runIdx == 0,
                leading: Icon(
                  isAwaiting
                      ? Icons.check_circle_outline
                      : Icons.smart_toy_outlined,
                  color: isAwaiting
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF2563EB),
                ),
                title: Text(
                  'Agent 실행 #${_agentRuns.length - runIdx} (${run['issue_id'] ?? runId})',
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  '최종 판단: ${isAwaiting ? '수정안 승인 대기' : (status == 'NO_IMPROVEMENT' ? '개선 없음' : status)} · Patch: $patchId',
                  style: TextStyle(
                    color: isAwaiting
                        ? const Color(0xFF16A34A)
                        : const Color(0xFF64748B),
                    fontSize: 11,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const Divider(color: Color(0xFFE2E8F0)),
                  if (activityLog.isEmpty)
                    const Text(
                      '상세 활동 로그가 없습니다.',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    )
                  else
                    ...activityLog.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final item = Map<String, dynamic>.from(
                        entry.value as Map,
                      );
                      final event = item['event']?.toString() ?? '';
                      final msg = item['message']?.toString() ?? '';
                      final tool = item['tool_name']?.toString();
                      final reason = item['reason']?.toString();
                      final details = Map<String, dynamic>.from(
                        item['details'] ?? const {},
                      );

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 2, right: 8),
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFFBFDBFE),
                                ),
                              ),
                              child: Icon(
                                _agentEventIcon(event),
                                size: 12,
                                color: const Color(0xFF2563EB),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${idx + 1}. [${_agentEventTitleKo(event)}]',
                                    style: const TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                  if (msg.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        msg,
                                        style: const TextStyle(
                                          color: Color(0xFF334155),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  if (tool != null && tool.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        '• 도구: ${_reviewToolNameKo(tool)}${reason != null && reason.isNotEmpty ? ' (사유: $reason)' : ''}',
                                        style: const TextStyle(
                                          color: Color(0xFFB45309),
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  if (details.containsKey('before_score') &&
                                      details.containsKey('after_score'))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        '• 토폴로지 점수: ${details['before_score']}점 ➔ ${details['after_score']}점'
                                        ' (${details['improved'] == true ? '개선됨' : '유지'})',
                                        style: TextStyle(
                                          color: details['improved'] == true
                                              ? const Color(0xFF16A34A)
                                              : const Color(0xFF64748B),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Phase 2: Bus Number Mapping & Review ---

  bool _isLinkingBusNumbers = false;
  bool _isAutoVerifyingBusGate = false;
  String? _busModelUsed;
  bool _busFallbackUsed = false;
  int? _busHttpCode;

  Future<void> _triggerAiBusLinking() async {
    if (_document == null) return;
    var shouldAutoVerifyBusGate = false;
    setState(() {
      _isLinkingBusNumbers = true;
      _busMappingFeedback = BusMappingFeedback.processing(_busNodes.length);
      _stageGateMessage = _busMappingFeedback!.message;
    });
    _announceReviewStage();
    try {
      final res = await _apiService.linkBusNumbers(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
        workingLines: _workingLines,
      );
      if (res['status'] == 'success' && res['nodes'] is List) {
        final rawNodes = (res['nodes'] as List);
        final uncertainReasons = rawNodes
            .whereType<Map>()
            .where(
              (raw) =>
                  raw['bus_number_status']?.toString().toUpperCase() !=
                  'VERIFIED',
            )
            .expand(
              (raw) => raw['bus_number_reasons'] is List
                  ? (raw['bus_number_reasons'] as List).map(
                      (reason) => reason.toString(),
                    )
                  : const <String>[],
            );
        final report = res['bus_number_report'] is Map
            ? Map<String, dynamic>.from(res['bus_number_report'] as Map)
            : <String, dynamic>{};
        for (final key in const [
          'model_used',
          'primary_model',
          'fallback_model',
          'fallback_used',
          'http_code',
        ]) {
          if (!report.containsKey(key) && res.containsKey(key)) {
            report[key] = res[key];
          }
        }
        if (report.isEmpty) {
          final verifiedFallback = rawNodes
              .whereType<Map>()
              .where(
                (raw) =>
                    raw['bus_number_status']?.toString().toUpperCase() ==
                    'VERIFIED',
              )
              .length;
          report.addAll({
            'total_buses': _busNodes.length,
            'verified_count': verifiedFallback,
            'uncertain_count': math.max(0, _busNodes.length - verifiedFallback),
          });
        }
        final feedback = BusMappingFeedback.fromReport(
          report: report,
          totalFallback: _busNodes.length,
          uncertainReasons: uncertainReasons,
        );
        setState(() {
          _busModelUsed = feedback.modelUsed;
          _busFallbackUsed = feedback.fallbackUsed;
          _busHttpCode = feedback.httpCode;
          for (
            int i = 0;
            i < rawNodes.length && i < _workingNodes.length;
            i++
          ) {
            final raw = rawNodes[i];
            final node = _workingNodes[i];
            node.busNumber = (raw['bus_number'] as num?)?.toInt();
            node.busNumberStatus =
                raw['bus_number_status']?.toString() ?? 'UNCERTAIN';
            node.busNumberReasons = raw['bus_number_reasons'] is List
                ? (raw['bus_number_reasons'] as List)
                      .map((reason) => reason.toString())
                      .toList()
                : <String>[];
            node.displayLabel =
                raw['display_name']?.toString() ??
                raw['display_label']?.toString() ??
                node.displayLabel;
            node.connectedBusNumber = (raw['connected_bus_number'] as num?)
                ?.toInt();
            node.connectedBusId = raw['connected_bus_id']?.toString();
          }
          final buses = _filteredAndSortedBusNodes;
          _selectedNode = buses.isNotEmpty ? buses.first : null;
          if (_selectedNode != null && _selectedNode!.busNumber != null) {
            _busNumberEditController.text = _selectedNode!.busNumber.toString();
          } else {
            _busNumberEditController.clear();
          }
          _busMappingFeedback = feedback;
          _stageGateMessage = feedback.message;
        });
        shouldAutoVerifyBusGate = feedback.shouldAutoVerifyBusGate(
          gateReady: _canVerifyBusGate,
        );
        _announceReviewStage();
        _showBusMappingFeedback(feedback);
      } else {
        final code = int.tryParse(res['http_code']?.toString() ?? '');
        final feedback = BusMappingFeedback.failed(
          total: _busNodes.length,
          httpCode: code,
        );
        setState(() {
          _busMappingFeedback = feedback;
          _busHttpCode = code;
          _stageGateMessage = feedback.message;
        });
        _announceReviewStage();
        _showBusMappingFeedback(feedback);
      }
    } catch (_) {
      if (mounted) {
        final feedback = BusMappingFeedback.failed(total: _busNodes.length);
        setState(() {
          _busMappingFeedback = feedback;
          _stageGateMessage = feedback.message;
        });
        _announceReviewStage();
        _showBusMappingFeedback(feedback);
      }
    } finally {
      if (mounted) {
        setState(() => _isLinkingBusNumbers = false);
        _announceReviewStage();
      }
    }

    if (shouldAutoVerifyBusGate && mounted) {
      await _verifyBusGateAutomatically();
    }
  }

  Future<void> _verifyBusGateAutomatically() async {
    if (!mounted || _isLoading || _isAutoVerifyingBusGate) return;
    setState(() => _isAutoVerifyingBusGate = true);
    try {
      await _verifyBusGate();
    } finally {
      if (mounted) {
        setState(() => _isAutoVerifyingBusGate = false);
      }
    }
  }

  void _showBusMappingFeedback(BusMappingFeedback feedback) {
    if (!mounted) return;
    final color = switch (feedback.kind) {
      BusMappingFeedbackKind.complete => Colors.green,
      BusMappingFeedbackKind.partial => Colors.orange,
      BusMappingFeedbackKind.processing => const Color(0xFF2563EB),
      BusMappingFeedbackKind.unavailable ||
      BusMappingFeedbackKind.failed ||
      BusMappingFeedbackKind.noEvidence => const Color(0xFFB45309),
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(feedback.message), backgroundColor: color),
    );
  }

  void _proceedToBusMappingReview() {
    setState(() {
      _currentPhase = ReviewPhase.busMappingReview;
      _stageGateMessage = null;
      _selectedLine = null;
      _busFilterStatus = 'ALL';
      _busPage = 0;
      _busModelUsed = null;
      _busFallbackUsed = false;
      _busHttpCode = null;
      final buses = _filteredAndSortedBusNodes;
      _selectedNode = buses.isNotEmpty ? buses.first : null;
      if (_selectedNode != null && _selectedNode!.busNumber != null) {
        _busNumberEditController.text = _selectedNode!.busNumber.toString();
      } else {
        _busNumberEditController.clear();
      }
    });

    PowerLensAIService.instance.clearFocusTargets();
    _announceReviewStage();
    // Automatically run AI vision grounding on all working buses (including human-added ones)
    _triggerAiBusLinking();
  }

  void _propagateBusNumber(
    ReviewNodeItem busNode,
    int newBusNo, {
    bool isDuplicate = false,
  }) {
    // Internal IDs are evidence identifiers. Keep them stable and never derive
    // them from the human-entered Bus number.
    final busId = busNode.id;
    busNode.busNumber = newBusNo;
    busNode.busNumberStatus = isDuplicate ? 'UNCERTAIN' : 'VERIFIED';
    busNode.displayLabel = isDuplicate ? "Bus $newBusNo (중복)" : "Bus $newBusNo";

    // Propagate the number to directly connected generators and loads without
    // changing any node or line IDs.
    for (final line in _workingLines) {
      if (!line.connectedTo.contains(busId)) continue;

      final otherId = line.connectedTo.first == busId
          ? (line.connectedTo.length > 1 ? line.connectedTo[1] : null)
          : line.connectedTo.first;
      if (otherId == null) continue;

      ReviewNodeItem? otherNode;
      for (final node in _workingNodes) {
        if (node.id == otherId) {
          otherNode = node;
          break;
        }
      }
      if (otherNode == null || otherNode.id == busId) continue;

      final cls = otherNode.className.toLowerCase();
      if (cls.contains('gen') || cls.contains('load')) {
        otherNode.busNumber = newBusNo;
        otherNode.connectedBusNumber = newBusNo;
        otherNode.connectedBusId = busId;
        otherNode.displayLabel = cls.contains('gen')
            ? "G_$newBusNo"
            : "Load_$newBusNo";
      }
    }
  }

  Widget _buildBusMappingReviewSidePanel() {
    final buses = _filteredAndSortedBusNodes;
    final totalPages = math.max(1, (buses.length / _busPageSize).ceil());
    final currentPage = _busPage.clamp(0, totalPages - 1);
    final pageBuses = buses
        .skip(currentPage * _busPageSize)
        .take(_busPageSize)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Header with Stats & Filter Badges
        _buildBusMappingQueueHeader(),
        const SizedBox(height: 12),

        // 2. Selected Bus Detail Editor (Bus Inspector V2)
        if (_selectedNode != null &&
            _selectedNode!.className.toLowerCase() == 'bus')
          BusInspectorView(
            key: ValueKey('BusInspector_${_selectedNode!.id}'),
            node: _selectedNode!,
            allBuses: _busNodes,
            connectedGens: _getConnectedGensForBus(_selectedNode!),
            connectedLoads: _getConnectedLoadsForBus(_selectedNode!),
            onApplyNumber: (num) => _handleApplyBusNumber(_selectedNode!, num),
            validateNumber: (num) =>
                _validateBusNumberInput(_selectedNode!, num),
          )
        else if (buses.isNotEmpty)
          BusInspectorView(
            key: ValueKey('BusInspector_${buses.first.id}'),
            node: buses.first,
            allBuses: _busNodes,
            connectedGens: _getConnectedGensForBus(buses.first),
            connectedLoads: _getConnectedLoadsForBus(buses.first),
            onApplyNumber: (num) => _handleApplyBusNumber(buses.first, num),
            validateNumber: (num) => _validateBusNumberInput(buses.first, num),
          )
        else
          _buildNoSelectionPrompt("모선(Bus)"),

        const SizedBox(height: 14),

        // 3. Collapsible Full Bus Queue List
        InkWell(
          onTap: () => setState(() => _showAllBusesList = !_showAllBusesList),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "전체 모선 목록 (${buses.length}개) ${_showAllBusesList ? '접기 ▲' : '펼치기 ▼'}",
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Icon(
                  _showAllBusesList ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: const Color(0xFF64748B),
                ),
              ],
            ),
          ),
        ),
        if (_showAllBusesList) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "페이지: ${currentPage + 1}/$totalPages",
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
              ),
              if (totalPages > 1)
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 18),
                      onPressed: currentPage > 0
                          ? () => setState(() => _busPage--)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 18),
                      onPressed: currentPage < totalPages - 1
                          ? () => setState(() => _busPage++)
                          : null,
                    ),
                  ],
                ),
            ],
          ),
          ...pageBuses.map((bus) => _buildBusMappingListItem(bus)),
        ],
      ],
    );
  }

  Widget _buildBusMappingQueueHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.numbers, color: Color(0xFFD97706), size: 18),
                SizedBox(width: 6),
                Text(
                  "모선 번호 & 기기 매핑",
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _isLinkingBusNumbers ? null : _triggerAiBusLinking,
                  icon: _isLinkingBusNumbers
                      ? const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Color(0xFFD97706),
                          ),
                        )
                      : const Icon(
                          Icons.refresh,
                          size: 12,
                          color: Color(0xFFD97706),
                        ),
                  label: Text(
                    _isLinkingBusNumbers ? "판독 중..." : "AI 번호 판독",
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFFD97706),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    side: const BorderSide(
                      color: Color(0xFFCBD5E1),
                      width: 1.0,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildBusFilterBadge(
              "전체",
              _busNodes.length,
              const Color(0xFF475569),
              'ALL',
            ),
            const SizedBox(width: 6),
            _buildBusFilterBadge(
              "확인 필요",
              _busUncertainCount,
              const Color(0xFFD97706),
              'UNCERTAIN',
            ),
            const SizedBox(width: 6),
            _buildBusFilterBadge(
              "확인됨",
              _busVerifiedCount,
              const Color(0xFF16A34A),
              'VERIFIED',
            ),
          ],
        ),
        if (_busMappingFeedback case final feedback?) ...[
          const SizedBox(height: 8),
          _buildBusMappingFeedbackBanner(feedback),
        ],
      ],
    );
  }

  Widget _buildBusMappingFeedbackBanner(BusMappingFeedback feedback) {
    final color = switch (feedback.kind) {
      BusMappingFeedbackKind.complete => const Color(0xFF15803D),
      BusMappingFeedbackKind.partial => const Color(0xFFB45309),
      BusMappingFeedbackKind.processing => const Color(0xFF1D4ED8),
      BusMappingFeedbackKind.unavailable ||
      BusMappingFeedbackKind.failed ||
      BusMappingFeedbackKind.noEvidence => const Color(0xFFB91C1C),
    };
    final icon = switch (feedback.kind) {
      BusMappingFeedbackKind.complete => Icons.check_circle_outline,
      BusMappingFeedbackKind.partial => Icons.rule,
      BusMappingFeedbackKind.processing => Icons.visibility_outlined,
      BusMappingFeedbackKind.unavailable => Icons.cloud_off_outlined,
      BusMappingFeedbackKind.failed => Icons.error_outline,
      BusMappingFeedbackKind.noEvidence => Icons.search_off,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  feedback.message,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (feedback.kind != BusMappingFeedbackKind.processing &&
                  feedback.total > 0)
                Text(
                  '${feedback.verified}/${feedback.total}',
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          if (feedback.kind == BusMappingFeedbackKind.processing) ...[
            const SizedBox(height: 7),
            const LinearProgressIndicator(
              minHeight: 3,
              color: Color(0xFF2563EB),
              backgroundColor: Color(0xFFDBEAFE),
            ),
          ],
          if (feedback.modelUsed != null || feedback.httpCode != null) ...[
            const SizedBox(height: 5),
            Text(
              [
                if (feedback.modelUsed != null)
                  '실제 모델: ${feedback.modelUsed}${feedback.fallbackUsed ? ' (fallback)' : ''}',
                if (feedback.httpCode != null) 'HTTP ${feedback.httpCode}',
              ].join(' · '),
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 9.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBusFilterBadge(
    String label,
    int count,
    Color color,
    String filterKey,
  ) {
    final isSelected = _busFilterStatus == filterKey;
    return GestureDetector(
      onTap: () {
        setState(() {
          _busFilterStatus = filterKey;
          _busPage = 0;
          final matches = _filteredAndSortedBusNodes;
          _selectedNode = matches.isNotEmpty ? matches.first : null;
          if (_selectedNode != null && _selectedNode!.busNumber != null) {
            _busNumberEditController.text = _selectedNode!.busNumber.toString();
          } else {
            _busNumberEditController.clear();
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.12)
              : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFCBD5E1),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? color : const Color(0xFF475569),
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBusMappingListItem(ReviewNodeItem busNode) {
    final isSelected = _selectedNode?.id == busNode.id;
    final rowBadge = BusReviewUiState.rowBadgeText(
      node: busNode,
      workingNodes: _busNodes,
    );
    final isDuplicate = rowBadge == '중복 번호';
    final isVerified = rowBadge == '확인됨';

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedNode = busNode;
          if (busNode.busNumber != null) {
            _busNumberEditController.text = busNode.busNumber.toString();
          } else {
            _busNumberEditController.clear();
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFEF3C7) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFD97706)
                : (isDuplicate
                      ? const Color(0xFFEF4444)
                      : (isVerified
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFFCBD5E1))),
            width: isSelected || isDuplicate ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  isDuplicate
                      ? Icons.warning_amber_rounded
                      : (isVerified ? Icons.check_circle : Icons.help_outline),
                  color: isDuplicate
                      ? const Color(0xFFEF4444)
                      : (isVerified
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFD97706)),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  busNode.busNumber != null
                      ? "Bus #${busNode.busNumber}"
                      : "Bus ? (미인식)",
                  style: TextStyle(
                    color: const Color(0xFF0F172A),
                    fontSize: 12,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "(${busNode.id})",
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isDuplicate
                    ? const Color(0xFFFEE2E2)
                    : (isVerified
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFFFEF3C7)),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isDuplicate
                      ? const Color(0xFFFCA5A5)
                      : (isVerified
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFFFDE68A)),
                ),
              ),
              child: Text(
                isDuplicate ? "중복 번호" : (isVerified ? "확인됨" : "검토필요"),
                style: TextStyle(
                  color: isDuplicate
                      ? const Color(0xFFDC2626)
                      : (isVerified
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFB45309)),
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Excel Importer & Discrepancy Validation Methods ---

  List<Map<String, dynamic>> _collectCurrentReviewElements() {
    List<Map<String, dynamic>> collected = [];
    final nodes = (_verifiedSld != null && _verifiedSld!.nodes.isNotEmpty)
        ? _verifiedSld!.nodes
        : _workingNodes.where((n) => n.reviewStatus != 'REJECTED').toList();

    final lines = (_verifiedSld != null && _verifiedSld!.lines.isNotEmpty)
        ? _verifiedSld!.lines
        : _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();

    for (var node in nodes) {
      final cls = node.className.toLowerCase();
      final bool isSlack =
          node.metadata['is_slack'] == true ||
          node.metadata['isSlack'] == true ||
          (node.displayLabel?.toLowerCase().contains('slack') ?? false);
      collected.add({
        'id': node.id,
        'type': cls,
        'class': cls,
        'label': node.effectiveDisplayLabel,
        'bus_number': node.busNumber,
        'connected_bus_number': node.connectedBusNumber,
        'parentBusId': node.connectedBusId,
        'connected_bus_id': node.connectedBusId,
        'is_slack': isSlack,
        'isSlack': isSlack,
      });
    }

    for (var line in lines) {
      final isLead =
          line.traceMethod == 'equipment_lead' ||
          line.evidence['is_equipment_lead'] == true ||
          line.evidence['is_transformer_lead'] == true ||
          line.evidence['electricalBranch'] == false;
      collected.add({
        'id': line.lineId,
        'type': 'line',
        'connected_to': line.connectedTo,
        'startElementId': line.connectedTo.isNotEmpty
            ? line.connectedTo[0]
            : null,
        'endElementId': line.connectedTo.length > 1
            ? line.connectedTo[1]
            : null,
        'label': line.displayLabel ?? '',
        'endpoints_display': line.endpointsDisplay ?? '',
        'is_equipment_lead': isLead,
        'isEquipmentLead': isLead,
        'electricalBranch': !isLead,
        'evidence': line.evidence,
      });
    }

    return collected;
  }

  Future<void> _validateAndSetExcelData(Map<String, dynamic> excelData) async {
    Map<String, dynamic>? mismatchReport;
    try {
      final reviewElements = _collectCurrentReviewElements();
      final uri = Uri.parse(
        '${ReviewApiService.baseUrl}/apply_excel_to_elements',
      );
      final applyRes = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'elements': reviewElements,
          'excel_data': excelData,
          'verified_sld_review': true,
        }),
      );
      if (applyRes.statusCode == 200) {
        final resJson = jsonDecode(applyRes.body);
        mismatchReport =
            (resJson['mismatch_report'] ??
                    resJson['summary']?['mismatch_report'])
                as Map<String, dynamic>?;
      }
    } catch (e) {
      debugPrint("Review apply_excel_to_elements call error: $e");
    }

    if (!mounted) return;
    setState(() {
      _importedExcelData = excelData;
      _excelMismatchReport = mismatchReport;
      _isLoading = false;
    });

    PowerLensAIService.instance.refreshContextGuidance(
      _buildAssistantContext(),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    final matched = ReviewFinalContract.hasVerifiedExcelMatch(mismatchReport);
    final reportSummary = mismatchReport?['summary']?.toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          matched
              ? "Excel 계통 제원이 검증된 도면과 일치합니다. 이제 CAD로 전달할 수 있어요."
              : reportSummary == null || reportSummary.isEmpty
              ? "Excel은 불러왔지만 대조 결과를 확인하지 못했습니다. 확인 전까지 계산 준비 완료로 처리하지 않습니다."
              : "Excel 대조 결과: $reportSummary",
        ),
        backgroundColor: matched
            ? Colors.green.shade700
            : Colors.orange.shade900,
        duration: const Duration(seconds: 5),
        showCloseIcon: true,
        closeIconColor: Colors.white,
      ),
    );

    if (!matched && mismatchReport != null) {
      _showReviewMismatchDialog();
    }
  }

  Future<void> _applyEquipmentProposal(Map<String, dynamic> proposal) async {
    final busNum = (proposal['bus_number'] as num?)?.toInt();
    if (busNum == null) return;
    final category = proposal['category']?.toString() ?? 'generator';
    final isGen = category == 'generator';

    ReviewNodeItem? parentBus;
    if (_verifiedSld != null) {
      for (var n in _verifiedSld!.nodes) {
        if (n.className.toLowerCase() == 'bus' &&
            (n.busNumber == busNum || n.displayNumber == busNum)) {
          parentBus = n;
          break;
        }
      }
    }
    if (parentBus == null) {
      for (var n in _workingNodes) {
        if (n.className.toLowerCase() == 'bus' &&
            (n.busNumber == busNum || n.displayNumber == busNum)) {
          parentBus = n;
          break;
        }
      }
    }
    if (parentBus == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("연결할 Bus $busNum 모선을 찾지 못했습니다."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final targetBusId = parentBus.id;
    final cx = parentBus.bbox[0];
    final cy = parentBus.bbox[1];
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final equipId = "${category}_supp_${busNum}_$timestamp";

    final excelData = proposal['excel_data'] is Map
        ? Map<String, dynamic>.from(proposal['excel_data'] as Map)
        : <String, dynamic>{};
    final displayLabel =
        excelData['label']?.toString() ??
        (isGen ? "G_$busNum" : "Load_$busNum");

    final newNode = ReviewNodeItem(
      id: equipId,
      className: category,
      bbox: [cx + 20.0, cy - 60.0, 40.0, 40.0],
      confidence: 1.0,
      source: 'excel_repair_proposal',
      reviewStatus: 'CONFIRMED',
      busNumber: busNum,
      connectedBusNumber: busNum,
      connectedBusId: targetBusId,
      displayLabel: displayLabel,
      metadata: excelData,
    );

    final leadLineId = "lead_${equipId}_to_$targetBusId";
    final newLine = ReviewLineItem(
      lineId: leadLineId,
      connectedTo: [equipId, targetBusId],
      path: [
        [cx + 20.0, cy - 40.0],
        [cx, cy],
      ],
      traceMethod: 'equipment_lead',
      reviewStatus: 'CONFIRMED',
      source: 'excel_repair_proposal',
      displayLabel: 'Lead',
      endpointsDisplay: "$displayLabel ↔ Bus $busNum",
      evidence: {
        'is_equipment_lead': true,
        'electricalBranch': false,
        'repair_proposal': true,
      },
    );

    setState(() {
      _workingNodes.add(newNode);
      _workingLines.add(newLine);
      if (_verifiedSld != null) {
        _verifiedSld = VerifiedSLD(
          schemaVersion: _verifiedSld!.schemaVersion,
          documentId: _verifiedSld!.documentId,
          status: _verifiedSld!.status,
          image: _verifiedSld!.image,
          nodes: [..._verifiedSld!.nodes, newNode],
          lines: [..._verifiedSld!.lines, newLine],
          verification: _verifiedSld!.verification,
        );
      }
    });

    if (_importedExcelData != null) {
      await _validateAndSetExcelData(_importedExcelData!);
    }
  }

  void _showReviewMismatchDialog() {
    if (_excelMismatchReport == null || _importedExcelData == null) return;
    final proposals = List<Map<String, dynamic>>.from(
      _excelMismatchReport!['repair_proposals'] as List? ?? const [],
    );
    ScaffoldMessenger.of(context).clearSnackBars();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ExcelMismatchDialog(
        mismatchReport: _excelMismatchReport!,
        excelData: _importedExcelData!,
        elements: _collectCurrentReviewElements(),
        repairProposals: proposals,
        onApplyProposal: (proposal) async {
          Navigator.of(ctx).pop();
          await _applyEquipmentProposal(proposal);
        },
        onRejectProposal: (proposal) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "${proposal['category'] == 'generator' ? '발전기' : '부하'} 보완 제안이 거부되었습니다.",
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
        autoRecoverLabel: "불일치 확인 후 돌아가기",
        onResetToStart: () {
          Navigator.of(ctx).pop();
          _confirmResetToBeginning();
        },
        onCancel: () {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "⚠️ 도면과 엑셀 데이터가 일치하지 않습니다!\n• ${_excelMismatchReport!['summary'] ?? '모선/선로 구성 불일치'}",
              ),
              backgroundColor: Colors.orange.shade900,
              duration: const Duration(seconds: 4),
              showCloseIcon: true,
              closeIconColor: Colors.white,
              action: SnackBarAction(
                label: "AI 진단 보기",
                textColor: Colors.amberAccent,
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  _showReviewMismatchDialog();
                },
              ),
            ),
          );
        },
        onAutoRecover: () {
          Navigator.of(ctx).pop();
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _excelMismatchReport?['summary']?.toString() ??
                    "불일치 항목을 먼저 수정한 뒤 Excel을 다시 대조해주세요.",
              ),
              backgroundColor: Colors.orange.shade900,
              showCloseIcon: true,
              closeIconColor: Colors.white,
              duration: const Duration(seconds: 5),
            ),
          );
        },
      ),
    );
  }

  Future<void> _loadDefaultExcelInReview() async {
    if (!ReviewFinalContract.canImportExcel(
      isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
      verifiedSld: _verifiedSld,
    )) {
      return;
    }
    setState(() {
      _isLoading = true;
      _loadingMessage = "📊 기본 ac_case25 계통 데이터를 분석 및 매칭하는 중...";
    });
    try {
      final data = await _apiService.loadDefaultExcelCase();
      if (!mounted) return;
      await _validateAndSetExcelData(data);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("기본 엑셀 불러오기 실패: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _importExcelInReview() async {
    if (!ReviewFinalContract.canImportExcel(
      isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
      verifiedSld: _verifiedSld,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Excel 연결은 최종 검증을 통과한 뒤에 할 수 있습니다.")),
      );
      return;
    }
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls', 'csv'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      PlatformFile file = result.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("파일 데이터를 읽을 수 없습니다."),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      setState(() {
        _isLoading = true;
        _loadingMessage = "📊 엑셀 계통 데이터를 분석 및 매칭하는 중...";
      });

      final data = await _apiService.uploadExcelCase(bytes, file.name);
      if (!mounted) return;
      await _validateAndSetExcelData(data);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("엑셀 처리 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Bottom Gate Footer ---

  Widget _buildBottomGateFooter() {
    if (_currentPhase == ReviewPhase.objectReview) {
      // Step 1: Object Review V2
      final blockerCount = _objSuspiciousCount + _unresolvedCandidatesCount;
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Column(
          children: [
            if (blockerCount > 0)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  border: Border.all(color: const Color(0xFFFECACA)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Color(0xFFDC2626),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "검토가 필요한 객체 $blockerCount개가 남아 있습니다.",
                        style: const TextStyle(
                          color: Color(0xFF991B1B),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _focusNextReviewTask,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        "[검토 항목 보기]",
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  border: Border.all(color: const Color(0xFFBBF7D0)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: Color(0xFF16A34A),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _objectHumanCheckDone
                            ? '설비 종류별 확인과 전체 확인이 끝났어요. 아래 버튼으로 다음 단계로 이동할 수 있습니다.'
                            : _objectHumanCheckReady
                            ? '설비 종류별 확인이 끝났어요. 문제가 없다면 상단의 [전체 확인했어요]를 눌러주세요.'
                            : 'AI 1차 검수에서 의심 객체가 없습니다. 설비 종류별 탭을 눌러 각 유형을 확인해 주세요.',
                        style: const TextStyle(
                          color: Color(0xFF15803D),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_objectGateBlockers.isNotEmpty && blockerCount == 0)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '다음 단계로 가려면:\n• ${_objectGateBlockers.join('\n• ')}',
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: GlowingTargetWrapper(
                    targetId: 'object_gate',
                    borderRadius: BorderRadius.circular(8),
                    guideLabel: "✨ 객체 검수 완료",
                    child: ElevatedButton.icon(
                      key: const ValueKey('ObjectCompleteButton'),
                      onPressed: _objectGateReadyForUser
                          ? _completeObjectReview
                          : null,
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text(
                        "객체 검수 완료",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _objectGateReadyForUser
                            ? const Color(0xFF2563EB)
                            : const Color(0xFF94A3B8),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    } else if (_currentPhase == ReviewPhase.busMappingReview) {
      // Step 2: Bus Mapping Review -> Go to Step 3: Connection Review
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Column(
          children: [
            if (_busGateBlockers.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '선로 결선 단계로 가려면:\n• ${_busGateBlockers.join('\n• ')}',
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: _isAutoVerifyingBusGate
                      ? Container(
                          key: const ValueKey('AutoBusGateProgress'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFF93C5FD),
                            ),
                          ),
                          child: const Row(
                            children: [
                              SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  '모든 모선 번호를 확인했어요. 결선 검수로 이동합니다.',
                                  style: TextStyle(
                                    color: Color(0xFF1D4ED8),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : GlowingTargetWrapper(
                          targetId: 'bus_gate',
                          borderRadius: BorderRadius.circular(8),
                          guideLabel: "✨ 모선 검수 완료",
                          child: ElevatedButton.icon(
                            key: const ValueKey('BusCompleteButton'),
                            onPressed:
                                _isLinkingBusNumbers || _isLoading
                                ? null
                                : _completeBusReview,
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 16,
                            ),
                            label: const Text("모선 검수 완료"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _canVerifyBusGate
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFF2563EB),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      );
    } else if (_currentPhase == ReviewPhase.connectionReview) {
      // Step 3: Connection Review -> Go to Step 4: Final Verification & Excel
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          children: [
            Expanded(
              child: GlowingTargetWrapper(
                targetId: 'connection_gate',
                borderRadius: BorderRadius.circular(8),
                guideLabel: "✨ 결선 검수 완료",
                child: ElevatedButton.icon(
                  key: _connectionGateKey,
                  onPressed: _verifyFinalGate,
                  icon: const Icon(Icons.verified, size: 16),
                  label: const Text("결선 검수 완료"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _canVerifyFinalGate
                        ? const Color(0xFF16A34A)
                        : Colors.grey.shade400,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  // --- Step 4: Verified Final View & Excel Integration ---

  Widget _buildVerifiedFinalView() {
    final sld = _verifiedSld!;
    final hasExcel = _importedExcelData != null;
    final hasExcelMatch = ReviewFinalContract.hasVerifiedExcelMatch(
      _excelMismatchReport,
    );
    final mismatchReport = _excelMismatchReport ?? const <String, dynamic>{};
    final mismatchMessages = ReviewFinalContract.mismatchMessages(
      _excelMismatchReport,
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Container(
          width: 680,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF86EFAC), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.verified_user,
                color: Color(0xFF16A34A),
                size: 56,
              ),
              const SizedBox(height: 12),
              const Text(
                "도면 검수가 모두 끝났어요.",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                "이제 계산에 사용할 계통 제원을 연결해주세요.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF475569), fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                "문서 ID: ${sld.documentId}  |  상태: ${sld.status}",
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildFinalSummaryItem(
                      "확정 모선",
                      "${_busNodes.length}개",
                      const Color(0xFF2563EB),
                    ),
                    _buildFinalSummaryItem(
                      "확정 결선",
                      "${sld.lines.length}개",
                      const Color(0xFFEA580C),
                    ),
                    _buildFinalSummaryItem(
                      "발전기/부하",
                      "${_workingNodes.where((n) => n.className.contains('gen') || n.className.contains('load')).length}개",
                      const Color(0xFF0284C7),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Excel Case Importer Box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: hasExcel
                        ? (hasExcelMatch
                              ? const Color(0xFF86EFAC)
                              : const Color(0xFFF87171))
                        : const Color(0xFFCBD5E1),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.table_chart,
                              color: (hasExcel && !hasExcelMatch)
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFF0D9488),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              "계통 엑셀 데이터 (.xlsx) 매칭",
                              style: TextStyle(
                                color: Color(0xFF0F172A),
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            if (_importedExcelData == null) ...[
                              GlowingTargetWrapper(
                                targetId: 'default_excel_btn',
                                borderRadius: BorderRadius.circular(6),
                                guideLabel: "✨ 기본 25모선 예제 엑셀",
                                child: OutlinedButton.icon(
                                  onPressed: _loadDefaultExcelInReview,
                                  icon: const Icon(
                                    Icons.auto_stories,
                                    size: 14,
                                  ),
                                  label: const Text(
                                    "기본 25모선 엑셀",
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 6,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            GlowingTargetWrapper(
                              targetId: 'final_excel_upload',
                              borderRadius: BorderRadius.circular(8),
                              guideLabel: "✨ 엑셀 파일 선택",
                              child: ElevatedButton.icon(
                                key: _finalExcelUploadKey,
                                onPressed: _importExcelInReview,
                                icon: const Icon(Icons.file_upload, size: 14),
                                label: Text(
                                  _importedExcelData != null
                                      ? "다른 Excel 다시 가져오기"
                                      : "Excel 가져오기",
                                  style: const TextStyle(fontSize: 11),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0D9488),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_importedExcelData != null) ...[
                      if (!hasExcelMatch) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFFCA5A5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: Color(0xFFDC2626),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "⚠️ Excel 대조를 통과하지 못했어요.",
                                    style: TextStyle(
                                      color: Color(0xFF991B1B),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_excelMismatchReport != null) ...[
                                    const Spacer(),
                                    GlowingTargetWrapper(
                                      targetId: 'excel_mismatch_btn',
                                      borderRadius: BorderRadius.circular(6),
                                      guideLabel: "✨ AI 진단 & 세부비교",
                                      child: TextButton.icon(
                                        onPressed: _showReviewMismatchDialog,
                                        icon: const Icon(
                                          Icons.auto_awesome,
                                          size: 14,
                                          color: Color(0xFF4F46E5),
                                        ),
                                        label: const Text(
                                          "AI 진단 & 세부비교 보기",
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF4F46E5),
                                          ),
                                        ),
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          backgroundColor: const Color(
                                            0xFFEEF2FF,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "• ${mismatchReport['summary'] ?? '대조 결과를 확인하지 못했습니다. 파일을 다시 불러오거나 연결 상태를 확인해주세요.'}",
                                style: const TextStyle(
                                  color: Color(0xFFB91C1C),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (mismatchMessages.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                for (final message in mismatchMessages.take(8))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      "• $message",
                                      style: const TextStyle(
                                        color: Color(0xFF7F1D1D),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                "• 도면: 모선 ${_busNodes.length}개, 결선 ${sld.lines.length}개  |  Excel: 모선 ${_importedExcelData!['total_buses'] ?? 0}개, 선로 ${_importedExcelData!['total_branches'] ?? 0}개",
                                style: const TextStyle(
                                  color: Color(0xFF7F1D1D),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _confirmResetToBeginning,
                                    icon: const Icon(
                                      Icons.restart_alt,
                                      size: 14,
                                      color: Color(0xFFDC2626),
                                    ),
                                    label: const Text(
                                      "다시 검수 처음으로 돌아가기",
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFDC2626),
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      side: const BorderSide(
                                        color: Color(0xFFFCA5A5),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        _importedExcelData = null;
                                        _excelMismatchReport = null;
                                      });
                                      PowerLensAIService.instance
                                          .refreshContextGuidance(
                                            _buildAssistantContext(),
                                          );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).clearSnackBars();
                                    },
                                    icon: const Icon(
                                      Icons.link_off,
                                      size: 14,
                                      color: Color(0xFF64748B),
                                    ),
                                    label: const Text(
                                      "엑셀 연결 해제",
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF86EFAC)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle,
                                    color: Color(0xFF16A34A),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "Excel 제원이 검증된 도면과 일치합니다.",
                                    style: TextStyle(
                                      color: Color(0xFF15803D),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "• 슬랙 모선: #${_importedExcelData!['slack_bus_number'] ?? '자동'}  |  모선: ${_importedExcelData!['total_buses'] ?? 0}개  |  발전기: ${_importedExcelData!['total_generators'] ?? 0}개  |  선로/변압기: ${_importedExcelData!['total_branches'] ?? 0}개",
                                style: const TextStyle(
                                  color: Color(0xFF166534),
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ] else ...[
                      Text(
                        "💡 Excel의 기준 용량, 모선, 슬랙, 발전기·부하, 선로 R/X/B와 변압기 탭을 확인한 뒤 계산에 연결합니다.",
                        style: TextStyle(color: Colors.grey[600], fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),

              if (ReviewFinalContract.canHandoffToCanvas(
                isFinalPhase: _currentPhase == ReviewPhase.verifiedFinal,
                verifiedSld: _verifiedSld,
                excelData: _importedExcelData,
                mismatchReport: _excelMismatchReport,
              )) ...[
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GlowingTargetWrapper(
                      targetId: 'final_canvas_handoff',
                      borderRadius: BorderRadius.circular(8),
                      guideLabel: "✨ CAD로 이동",
                      child: ElevatedButton.icon(
                        key: _finalCanvasHandoffKey,
                        onPressed: _handoffToFlutterCanvas,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text(
                          "CAD로 이동",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFinalSummaryItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildNoSelectionPrompt(String type) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32.0),
        child: Text(
          "화면에서 $type을(를) 클릭하여 선택하세요.",
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildFilterableStatBadge(
    String label,
    int count,
    Color color,
    String filterKey,
  ) {
    final isSelected = _objFilterStatus == filterKey;
    return GestureDetector(
      onTap: () {
        setState(() {
          _objFilterStatus = filterKey;
          // Auto select first matching node
          final matches = _filteredAndSortedWorkingNodes;
          _selectedNode = matches.isEmpty ? null : matches.first;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFCBD5E1),
            width: isSelected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          "$label: $count",
          style: TextStyle(
            color: isSelected ? color : const Color(0xFF334155),
            fontSize: 9.2,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildObjectClassFilter(String label, String classKey) {
    final selected = _objFilterClass == classKey;
    final statusFiltered = _workingNodes.where((node) {
      if (_objFilterStatus == 'SUSPICIOUS') {
        return node.reviewStatus == 'SUSPICIOUS';
      }
      if (_objFilterStatus == 'AUTO_CONFIRMED') {
        return node.reviewStatus == 'CONFIRMED' &&
            !node.source.contains('human');
      }
      if (_objFilterStatus == 'HUMAN_CONFIRMED') {
        return node.reviewStatus == 'CONFIRMED' &&
            node.source.contains('human');
      }
      if (_objFilterStatus == 'DETECTED')
        return node.reviewStatus == 'DETECTED';
      if (_objFilterStatus == 'REJECTED')
        return node.reviewStatus == 'REJECTED';
      return true;
    });
    final count = classKey == 'ALL'
        ? statusFiltered.length
        : statusFiltered
              .where((node) => node.className.toLowerCase() == classKey)
              .length;
    final chipColor = classKey == 'ALL'
        ? const Color(0xFF2563EB)
        : _getClassColor(classKey);
    return GestureDetector(
      onTap: () {
        setState(() {
          _objFilterClass = classKey;
          final matches = _filteredAndSortedWorkingNodes;
          _selectedNode = matches.isEmpty ? null : matches.first;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
        decoration: BoxDecoration(
          color: selected
              ? chipColor.withValues(alpha: 0.15)
              : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? chipColor : const Color(0xFFCBD5E1),
            width: selected ? 1.4 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (classKey != 'ALL') ...[
              Icon(
                _getClassIcon(classKey),
                size: 9.5,
                color: selected ? chipColor : const Color(0xFF64748B),
              ),
              const SizedBox(width: 2.5),
            ],
            Text(
              '$label $count',
              style: TextStyle(
                color: selected ? chipColor : const Color(0xFF334155),
                fontSize: 9.2,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterableConnStatBadge(
    String label,
    int count,
    Color color,
    String filterKey,
  ) {
    final isSelected = _connFilterStatus == filterKey;
    return GestureDetector(
      onTap: () {
        setState(() {
          _connFilterStatus = filterKey;
          _linePage = 0;
          _selectedNode = null;
          _selectedTopologyIssue = null;
          // Select the first matching line, or clear stale inspector state
          // when the selected filter has no results.
          final matches = _filteredAndSortedWorkingLines;
          _selectedLine = matches.isNotEmpty ? matches.first : null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFCBD5E1),
            width: isSelected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          "$label: $count",
          style: TextStyle(
            color: isSelected ? color : const Color(0xFF334155),
            fontSize: 9.2,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildMissingCandidateBadge(String label, int count, Color color) {
    final hasCandidates = count > 0;
    return Tooltip(
      message: hasCandidates ? '누락 후보 확인 및 문제 없음 처리 (클릭)' : '누락 후보 없음',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (hasCandidates) {
              _showMissingCandidatesDialog();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("현재 미해결된 누락 후보가 없습니다. 정상입니다."),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hasCandidates
                  ? color.withValues(alpha: 0.15)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: hasCandidates ? color : const Color(0xFFCBD5E1),
                width: hasCandidates ? 1.4 : 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasCandidates) ...[
                  Icon(Icons.warning_amber_rounded, size: 11, color: color),
                  const SizedBox(width: 3),
                ],
                Text(
                  "$label: $count",
                  style: TextStyle(
                    color: hasCandidates ? color : const Color(0xFF64748B),
                    fontSize: 9.2,
                    fontWeight: hasCandidates
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMissingCandidatesAlertCard() {
    final openCands = _missingCandidates
        .where((c) => c.status == 'OPEN')
        .toList();
    if (openCands.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF5FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC084FC), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9333EA).withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Color(0xFF9333EA),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "도면 누락 의심 설비 (${openCands.length}건 확인 필요)",
                  style: const TextStyle(
                    color: Color(0xFF9333EA),
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              InkWell(
                onTap: _showMissingCandidatesDialog,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    "상세보기 ➔",
                    style: TextStyle(
                      color: Color(0xFF9333EA),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            "단선도에 원래 해당 부품이 없는 계통이면 [문제 없음]을 누르세요.",
            style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
          ),
          const SizedBox(height: 8),
          ...openCands.map(
            (c) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFE9D5FF)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF9333EA),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _classNameKo(c.suspectedClass),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.descriptionKo,
                          style: const TextStyle(
                            color: Color(0xFF1E293B),
                            fontSize: 10.5,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _isManualAddMode = true;
                              _manualAddClass = c.suspectedClass;
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  "도면에서 ${_classNameKo(c.suspectedClass)} 영역을 드래그하여 추가하세요.",
                                ),
                                backgroundColor: const Color(0xFF9333EA),
                              ),
                            );
                          },
                          icon: const Icon(Icons.edit, size: 12),
                          label: const Text(
                            "수동 추가",
                            style: TextStyle(fontSize: 10),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF9333EA),
                            side: const BorderSide(color: Color(0xFFD8B4FE)),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _dismissCandidate(c),
                          icon: const Icon(Icons.check, size: 12),
                          label: const Text(
                            "문제 없음",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showMissingCandidatesDialog({String? initialCandidateId}) {
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final openCands = _missingCandidates
              .where((c) => c.status == 'OPEN')
              .toList();
          if (initialCandidateId != null) {
            openCands.sort((a, b) {
              if (a.id == initialCandidateId) return -1;
              if (b.id == initialCandidateId) return 1;
              return 0;
            });
          }
          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3E8FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.help_outline_rounded,
                    color: Color(0xFF9333EA),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "도면 누락 후보 검토",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Text(
                        openCands.isNotEmpty
                            ? "검토 대기 ${openCands.length}건이 있습니다."
                            : "모든 누락 후보가 처리되었습니다.",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: openCands.isEmpty
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF16A34A),
                          size: 48,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "모든 누락 후보가 처리되었습니다!",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "이제 하단의 [객체 검수 완료] 버튼을 눌러 다음 단계로 진행하실 수 있습니다.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 16,
                                  color: Color(0xFF0284C7),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "AI가 단선도 분석 중 설비 누락 가능성을 감지한 항목입니다. 계통에 원래 해당 설비가 없는 경우 [문제 없음]을 누르시면 정상 통과됩니다.",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF334155),
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...openCands.map((c) {
                            final isInitial = c.id == initialCandidateId;
                            return Container(
                              key: ValueKey('MissingCandidateCard_${c.id}'),
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isInitial
                                    ? const Color(0xFFF3E8FF)
                                    : const Color(0xFFFAF5FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isInitial
                                      ? const Color(0xFF9333EA)
                                      : const Color(0xFFD8B4FE),
                                  width: isInitial ? 2.0 : 1.2,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF9333EA),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          _classNameKo(c.suspectedClass),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        "누락 의심",
                                        style: TextStyle(
                                          color: Color(0xFF9333EA),
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    c.descriptionKo,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF1E293B),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          Navigator.of(dialogCtx).pop();
                                          setState(() {
                                            _isManualAddMode = true;
                                            _manualAddClass = c.suspectedClass;
                                          });
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                "도면에서 ${_classNameKo(c.suspectedClass)} 영역을 드래그하여 추가하세요.",
                                              ),
                                              backgroundColor: const Color(
                                                0xFF9333EA,
                                              ),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.add, size: 14),
                                        label: const Text(
                                          "도면에서 직접 추가",
                                          style: TextStyle(fontSize: 11),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(
                                            0xFF9333EA,
                                          ),
                                          side: const BorderSide(
                                            color: Color(0xFFD8B4FE),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        onPressed: () {
                                          _dismissCandidate(c);
                                          setDialogState(() {});
                                          if (_unresolvedCandidatesCount == 0) {
                                            Navigator.of(dialogCtx).pop();
                                          }
                                        },
                                        icon: const Icon(Icons.check, size: 14),
                                        label: const Text(
                                          "문제 없음 (원래 없음)",
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF16A34A,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text("닫기"),
              ),
            ],
          );
        },
      ),
    );
  }
}
