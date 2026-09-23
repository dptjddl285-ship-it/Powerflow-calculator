import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/review_models.dart';
import '../models/powerlens_assistant_context.dart';
import '../services/powerlens_ai_service.dart';
import '../services/review_api_service.dart';
import '../widgets/review_overlay.dart';
import '../widgets/excel_mismatch_dialog.dart';
import '../widgets/powerlens_ai/powerlens_ai_button.dart';
import '../widgets/powerlens_ai/powerlens_ai_panel.dart';
import '../widgets/powerlens_ai/glowing_target_wrapper.dart';

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
      'ALL'; // ALL, AMBIGUOUS, AUTO_CONFIRMED, HUMAN_CONFIRMED, REJECTED, ERROR_ONLY
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
  bool _showTopologyDetails = false;
  final FocusNode _reviewKeyFocusNode = FocusNode();

  // Loading & Modes
  bool _isLoading = false;
  String? _loadingMessage;
  bool _showCanvasLabels = true;

  // Object Manual Add
  bool _isManualAddMode = false;
  String _manualAddClass = 'bus';

  // Line Manual Add
  bool _isManualAddLineMode = false;
  ReviewNodeItem? _manualLineStartNode;

  // Global Completeness & Missing Candidates
  List<MissingCandidateItem> _missingCandidates = [];
  String? _completenessAssessment;
  String? _completenessMessageKo;
  bool _humanCompletenessConfirmed = false;

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

  int get _unconfirmedNodesCount => _workingNodes
      .where((n) =>
          n.reviewStatus != 'CONFIRMED' && n.reviewStatus != 'REJECTED')
      .length;

  bool get _isCleanAuto =>
      _objSuspiciousCount == 0 &&
      _unresolvedCandidatesCount == 0 &&
      _unconfirmedNodesCount == 0 &&
      _workingNodes.where((n) => n.reviewStatus != 'REJECTED').isNotEmpty;

  bool get _canVerifyObjectGate =>
      _unconfirmedNodesCount == 0 &&
      _objSuspiciousCount == 0 &&
      _unresolvedCandidatesCount == 0 &&
      _workingNodes.where((n) => n.reviewStatus != 'REJECTED').isNotEmpty;

  List<String> get _objectGateBlockers {
    final blockers = <String>[];
    if (_objSuspiciousCount > 0) {
      blockers.add('검토 필요 객체 $_objSuspiciousCount개 승인 또는 제외');
    }
    if (_unresolvedCandidatesCount > 0) {
      blockers.add('누락 후보 $_unresolvedCandidatesCount개 복구 또는 문제없음 처리');
    }
    if (_unconfirmedNodesCount > 0) {
      blockers.add('대기 중인 정상 객체 $_unconfirmedNodesCount개 승인 (우측 [정상 객체 일괄 승인] 클릭)');
    }
    if (_workingNodes.where((n) => n.reviewStatus != 'REJECTED').isEmpty) {
      blockers.add('사용 가능한 객체가 없음');
    }
    return blockers;
  }

  // Statistics (Bus Number Mapping)
  List<ReviewNodeItem> get _busNodes => _workingNodes
      .where(
        (n) =>
            n.className.toLowerCase() == 'bus' && n.reviewStatus != 'REJECTED',
      )
      .toList();
  List<int> get _duplicateBusNumbers {
    final counts = <int, int>{};
    for (final b in _busNodes) {
      if (b.busNumber != null) {
        counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
      }
    }
    return counts.entries.where((e) => e.value > 1).map((e) => e.key).toList();
  }

  int get _busUncertainCount {
    final dups = _duplicateBusNumbers;
    return _busNodes
        .where(
          (n) =>
              n.busNumberStatus != 'VERIFIED' ||
              n.busNumber == null ||
              dups.contains(n.busNumber),
        )
        .length;
  }

  int get _busVerifiedCount {
    final dups = _duplicateBusNumbers;
    return _busNodes
        .where(
          (n) =>
              n.busNumberStatus == 'VERIFIED' &&
              n.busNumber != null &&
              !dups.contains(n.busNumber),
        )
        .length;
  }

  bool get _canVerifyBusGate =>
      _busUncertainCount == 0 &&
      _busNodes.isNotEmpty &&
      _duplicateBusNumbers.isEmpty;

  List<String> get _busGateBlockers {
    final blockers = <String>[];
    final dups = _duplicateBusNumbers;
    if (dups.isNotEmpty) {
      blockers.add(
        '중복된 모선 번호(${dups.map((n) => "#$n").join(", ")})가 존재합니다. 각각 고유한 번호로 수정해 주세요.',
      );
    }
    final missingCount = _busNodes.where((n) => n.busNumber == null).length;
    if (missingCount > 0) {
      blockers.add('미지정 모선 $missingCount개 번호 입력 필요');
    }
    if (_busNodes.isEmpty) {
      blockers.add('도면에 유효한 모선(Bus)이 없음');
    }
    return blockers;
  }

  List<ReviewNodeItem> get _filteredAndSortedBusNodes {
    final dups = _duplicateBusNumbers;
    List<ReviewNodeItem> list = List.from(_busNodes);
    if (_busFilterStatus == 'UNCERTAIN') {
      list = list
          .where(
            (n) =>
                n.busNumberStatus != 'VERIFIED' ||
                n.busNumber == null ||
                dups.contains(n.busNumber),
          )
          .toList();
    } else if (_busFilterStatus == 'VERIFIED') {
      list = list
          .where(
            (n) =>
                n.busNumberStatus == 'VERIFIED' &&
                n.busNumber != null &&
                !dups.contains(n.busNumber),
          )
          .toList();
    }
    list.sort((a, b) {
      final aIsUncertain =
          a.busNumberStatus != 'VERIFIED' ||
          a.busNumber == null ||
          dups.contains(a.busNumber);
      final bIsUncertain =
          b.busNumberStatus != 'VERIFIED' ||
          b.busNumber == null ||
          dups.contains(b.busNumber);
      if (aIsUncertain && !bIsUncertain) return -1;
      if (!aIsUncertain && bIsUncertain) return 1;
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
      _workingLines.where((l) => l.reviewStatus == 'AMBIGUOUS').length;
  int get _lineDetectedCount =>
      _workingLines.where((l) => l.reviewStatus == 'DETECTED').length;
  int get _lineRejectedCount =>
      _workingLines.where((l) => l.reviewStatus == 'REJECTED').length;
  int get _criticalIssuesCount =>
      _topologyIssues.where((i) => i['severity'] == 'error').length;

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

  bool get _canVerifyFinalGate =>
      _lineAmbiguousCount == 0 &&
      _criticalIssuesCount == 0 &&
      _connectionMissionComplete &&
      _workingLines.where((l) => l.reviewStatus != 'REJECTED').isNotEmpty;

  // Filtered & Sorted Working Lines
  List<ReviewLineItem> get _filteredAndSortedWorkingLines {
    List<ReviewLineItem> list = List.from(_workingLines);

    if (_connFilterStatus == 'AMBIGUOUS') {
      list = list.where((l) => l.reviewStatus == 'AMBIGUOUS').toList();
    } else if (_connFilterStatus == 'AUTO_CONFIRMED') {
      list = list
          .where(
            (l) => l.reviewStatus == 'CONFIRMED' && !l.source.contains('human'),
          )
          .toList();
    } else if (_connFilterStatus == 'HUMAN_CONFIRMED') {
      list = list
          .where(
            (l) => l.reviewStatus == 'CONFIRMED' && l.source.contains('human'),
          )
          .toList();
    } else if (_connFilterStatus == 'DETECTED') {
      list = list.where((l) => l.reviewStatus == 'DETECTED').toList();
    } else if (_connFilterStatus == 'REJECTED') {
      list = list.where((l) => l.reviewStatus == 'REJECTED').toList();
    } else if (_connFilterStatus == 'ERROR_ONLY') {
      list = list.where((l) => l.validationIssues.isNotEmpty).toList();
    }

    if (_connSortOption == 'SEVERITY') {
      list.sort((a, b) {
        int rank(ReviewLineItem l) {
          if (l.validationIssues.isNotEmpty) return 0;
          if (l.reviewStatus == 'AMBIGUOUS') return 1;
          if (l.reviewStatus == 'DETECTED') return 2;
          return 3;
        }

        return rank(a).compareTo(rank(b));
      });
    } else if (_connSortOption == 'ID_ASC') {
      list.sort((a, b) => a.lineId.compareTo(b.lineId));
    }

    if (_currentPhase == ReviewPhase.connectionReview &&
        !_connectionFastMode &&
        _connSortOption == 'SEVERITY' &&
        _connFilterStatus == 'ALL') {
      final priorityIds = _connectionPriorityMissionLines
          .map((line) => line.lineId)
          .toSet();
      list.sort((a, b) {
        final aPriority = priorityIds.contains(a.lineId);
        final bPriority = priorityIds.contains(b.lineId);
        if (aPriority != bPriority) return aPriority ? -1 : 1;
        return a.lineId.compareTo(b.lineId);
      });
    }

    return list;
  }

  bool _isAiPanelOpen = false;
  bool _busCompletionPromptVisible = false;
  bool _connectionFastMode = false;
  bool _connectionFullOverview = false;
  bool _connectionLinesOnlyMode = false;
  final GlobalKey _reviewStackKey = GlobalKey();
  final GlobalKey _reviewFocusTargetKey = GlobalKey();
  final GlobalKey _objectFilterKey = GlobalKey();
  final GlobalKey _objectPrimaryActionKey = GlobalKey();
  final GlobalKey _busPrimaryActionKey = GlobalKey();
  final GlobalKey _busWholeApproveKey = GlobalKey();
  final GlobalKey _connectionMissionKey = GlobalKey();
  final GlobalKey _connectionPrimaryActionKey = GlobalKey();
  final GlobalKey _connectionGateKey = GlobalKey();
  final GlobalKey _finalExcelUploadKey = GlobalKey();
  final GlobalKey _finalCanvasHandoffKey = GlobalKey();
  Alignment? _manualLensyAlignment;
  String? _stageGateMessage;

  String get _reviewLensyPresenceState {
    if (_stageGateMessage != null || _isLoading) return 'thinking';
    if (_isFinalVerified) return 'success';
    return 'idle';
  }

  String get _lensyCoachTarget {
    if (_document == null) return 'home_upload';
    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        return _objSuspiciousCount > 0 && _selectedNode != null
            ? 'object_bbox'
            : 'object_approve';
      case ReviewPhase.busMappingReview:
        return 'bus_input';
      case ReviewPhase.connectionReview:
        return _connectionMissionComplete
            ? 'connection_gate'
            : 'connection_priority';
      case ReviewPhase.verifiedFinal:
        return _importedExcelData == null
            ? 'final_excel_upload'
            : 'final_canvas_handoff';
    }
  }

  void _scheduleReviewLensyTargetSync() {
    // Lensy remains cleanly anchored at bottom-right without jumping across controls
  }

  Alignment _effectiveReviewLensyAlignment(
    String target, {
    required bool isMobile,
  }) {
    if (_manualLensyAlignment != null) {
      return _manualLensyAlignment!;
    }
    return const Alignment(0.86, 0.86);
  }

  void _handleReviewLensyDrag(
    Offset delta,
    String target, {
    required bool isMobile,
  }) {
    final size = MediaQuery.of(context).size;
    final current = _effectiveReviewLensyAlignment(
      target,
      isMobile: isMobile,
    );
    double clampAlignment(double value) =>
        value.clamp(-0.94, 0.94).toDouble();
    setState(() {
      _manualLensyAlignment = Alignment(
        clampAlignment(current.x + delta.dx / math.max(size.width / 2, 1)),
        clampAlignment(current.y + delta.dy / math.max(size.height / 2, 1)),
      );
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
        if (_isLoading || _currentPhase != ReviewPhase.verifiedFinal) {
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
        if (_currentPhase != ReviewPhase.objectReview) return false;
        _confirmAllCleanNodes();
        return true;
      case PowerLensAppAction.connectionFullReview:
        return _showConnectionFullReviewForAgent();
      case PowerLensAppAction.connectionLinesOnly:
        return _showConnectionLinesOnlyForAgent();
      case PowerLensAppAction.connectionNextLine:
        return _showConnectionNextLineForAgent();
      case PowerLensAppAction.handoffToCanvas:
        if (_currentPhase != ReviewPhase.verifiedFinal ||
            _verifiedSld == null) {
          return false;
        }
        _handoffToFlutterCanvas();
        return true;
      case PowerLensAppAction.goToNextStage:
        return _advanceReviewStageForAgent();
      case PowerLensAppAction.goToPreviousStage:
        return _returnToPreviousReviewStageForAgent();
      case PowerLensAppAction.runPowerFlow:
        if (_currentPhase == ReviewPhase.verifiedFinal &&
            _verifiedSld != null) {
          _handoffToFlutterCanvas();
          return true;
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
        final hasIssues = _busUncertainCount > 0 || _duplicateBusNumbers.isNotEmpty;
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
        _connectionFullOverview = false;
        _connectionLinesOnlyMode = false;
        _connectionFastMode = false;
        _lineFocusOnly = true;
        _linePage = 0;
        _showAllLinesList = false;
        _showTopologyDetails = _topologyIssues.isNotEmpty;
        if (_lineAmbiguousCount > 0 || _topologyIssues.isNotEmpty) {
          _connFilterStatus = _lineAmbiguousCount > 0
              ? 'AMBIGUOUS'
              : 'ERROR_ONLY';
          final issues = _filteredAndSortedWorkingLines;
          _selectedLine = issues.isNotEmpty ? issues.first : _selectedLine;
        } else {
          _connFilterStatus = 'ALL';
          final allLines = _filteredAndSortedWorkingLines;
          _selectedLine = allLines.isNotEmpty ? allLines.first : _selectedLine;
        }
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
    if (_currentPhase != ReviewPhase.connectionReview ||
        _workingLines.isEmpty) {
      return false;
    }
    setState(() {
      _connectionFullOverview = true;
      _connectionLinesOnlyMode = false;
      _connectionFastMode = true;
      _lineFocusOnly = false;
      _connFilterStatus = 'ALL';
      _connSortOption = 'ID_ASC';
      _showAllLinesList = true;
      _selectedLine = null;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _linePage = 0;
    });
    return true;
  }

  bool _showConnectionLinesOnlyForAgent() {
    if (_currentPhase != ReviewPhase.connectionReview ||
        _workingLines.isEmpty) {
      return false;
    }
    setState(() {
      _connectionFullOverview = false;
      _connectionLinesOnlyMode = true;
      _connectionFastMode = true;
      _lineFocusOnly = false;
      _connFilterStatus = 'ALL';
      _connSortOption = 'ID_ASC';
      _showAllLinesList = true;
      _selectedLine = null;
      _selectedNode = null;
      _selectedTopologyIssue = null;
      _linePage = 0;
    });
    return true;
  }

  bool _showConnectionNextLineForAgent() {
    if (_currentPhase != ReviewPhase.connectionReview ||
        _workingLines.isEmpty) {
      return false;
    }
    setState(() {
      _connectionFullOverview = false;
      _connectionLinesOnlyMode = false;
      _connectionFastMode = false;
      _lineFocusOnly = true;
      _connFilterStatus = 'ALL';
      _connSortOption = 'SEVERITY';
      _showAllLinesList = false;
    });
    _selectNextLine();
    return true;
  }

  bool _approveCurrentAndNextForAgent() {
    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        if (_selectedNode == null) return false;
        _confirmNodeAndNext(_selectedNode!);
        return true;
      case ReviewPhase.busMappingReview:
        if (_selectedNode == null) return false;
        _approveAndNextBus(_selectedNode!);
        return true;
      case ReviewPhase.connectionReview:
        if (_selectedLine == null) return false;
        _confirmLineAndNext(_selectedLine!);
        return true;
      case ReviewPhase.verifiedFinal:
        return false;
    }
  }

  Future<bool> _advanceReviewStageForAgent() async {
    if (_isLoading) return false;

    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        await _verifyObjectGate();
        return _currentPhase == ReviewPhase.busMappingReview;
      case ReviewPhase.busMappingReview:
        await _proceedToConnectionReview();
        return _currentPhase == ReviewPhase.connectionReview;
      case ReviewPhase.connectionReview:
        await _verifyFinalGate();
        return _currentPhase == ReviewPhase.verifiedFinal;
      case ReviewPhase.verifiedFinal:
        if (_verifiedSld?.status != 'VERIFIED') return false;
        _handoffToFlutterCanvas();
        return true;
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
          _lineFocusOnly = true;
          _selectedNode = null;
          _connFilterStatus = 'ALL';
          var lines = _filteredAndSortedWorkingLines;
          if (lines.isEmpty) {
            lines = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
            if (lines.isEmpty) lines = _workingLines;
          }
          _selectedLine = lines.isNotEmpty ? lines.first : null;
        });
        FocusManager.instance.primaryFocus?.unfocus();
        return true;
    }
  }

  PowerLensAssistantContext _buildAssistantContext() {
    final connectionBlockers = <String>[
      if (_lineAmbiguousCount > 0) '검토가 필요한 결선 $_lineAmbiguousCount개',
      ..._topologyIssues.map(
        (issue) => issue['message']?.toString() ?? '연결 구조 오류',
      ),
    ];

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
      totalConnections: _workingLines.length,
      ambiguousConnections: _lineAmbiguousCount,
      topologyIssueCount: _topologyIssues.length,
      finalVerified: _verifiedSld != null,
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
    PowerLensAIService.instance.onStageChanged(
      stage,
      _buildAssistantContext(),
    );
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
        _objFilterStatus = 'ALL';
        _objFilterClass = 'ALL';
        _nodePage = 0;
        _chatHistory.clear();
      });

      final doc = await _apiService.detectObjects(bytes, filename);
      PowerLensAIService.instance.setProviderMode(
        doc.proactiveSummary?.providerMode,
      );

      setState(() {
        _document = doc;
        _workingNodes = List.from(doc.nodes);
        final suspiciousNodes = _workingNodes
            .where((n) => n.reviewStatus == 'SUSPICIOUS')
            .toList();
        _objFilterStatus = suspiciousNodes.isNotEmpty ? 'SUSPICIOUS' : 'ALL';

        _selectedNode = suspiciousNodes.isNotEmpty
            ? suspiciousNodes.first
            : (_workingNodes.isNotEmpty ? _workingNodes.first : null);
        _isLoading = false;

        // Greeting and Proactive Summary in Chat
        final summaryMsg =
            doc.proactiveSummary?.summaryText ??
            "안녕하세요! PowerLens AI 도면 어시스턴트입니다.\n도면 검수 상태, 선택 객체/선로의 판정 근거, 누락 후보 등을 즉시 안내해 드립니다.";

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
        content: Text("✓ '${_classNameKo(cand.suspectedClass)}' 누락 후보를 [문제 없음]으로 처리했습니다."),
        backgroundColor: const Color(0xFF16A34A),
        duration: const Duration(seconds: 2),
      ),
    );
    if (_canVerifyObjectGate) {
      PowerLensAIService.instance.triggerHighlight('object_gate');
    }
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
    setState(() {
      node.className = newClass;
      node.reviewStatus = 'CONFIRMED';
      node.source = 'human_class_changed';
    });
  }

  void _batchConfirmCleanDetectedNodes() {
    _confirmAllCleanNodes();
  }

  void _batchConfirmVisibleNodes() {
    final visibleIds = _filteredAndSortedWorkingNodes
        .where((node) => node.reviewStatus != 'REJECTED')
        .map((node) => node.id)
        .toSet();
    if (visibleIds.isEmpty) return;
    setState(() {
      for (final node in _workingNodes) {
        if (!visibleIds.contains(node.id)) continue;
        node.reviewStatus = 'CONFIRMED';
        if (!node.source.contains('human')) {
          node.source = '${node.source}_human_batch_confirmed';
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('현재 목록의 객체 ${visibleIds.length}개를 승인했습니다.'),
        backgroundColor: Colors.green,
      ),
    );
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

  void _selectPreviousNode() {
    var list = _filteredAndSortedWorkingNodes;
    if (list.isEmpty || (_selectedNode != null && !list.any((n) => n.id == _selectedNode!.id))) {
      _objFilterStatus = 'ALL';
      _objFilterClass = 'ALL';
      list = _filteredAndSortedWorkingNodes;
      if (list.isEmpty) {
        list = _workingNodes.where((n) => n.reviewStatus != 'REJECTED').toList();
      }
    }
    if (list.isEmpty) list = _workingNodes;
    if (list.isEmpty) return;

    int currentIdx = _selectedNode != null
        ? list.indexWhere((n) => n.id == _selectedNode!.id)
        : 0;
    if (currentIdx < 0) currentIdx = 0;
    int prevIdx = (currentIdx - 1 + list.length) % list.length;
    setState(() {
      _selectedNode = list[prevIdx];
      _nodePage = prevIdx ~/ _nodePageSize;
    });
    if (_selectedNode!.agentExplanation == null &&
        _selectedNode!.reviewStatus == 'SUSPICIOUS') {
      _triggerAgentReviewNode(_selectedNode!);
    }
  }

  void _selectNextNode() {
    var list = _filteredAndSortedWorkingNodes;
    if (list.isEmpty || (_selectedNode != null && !list.any((n) => n.id == _selectedNode!.id))) {
      _objFilterStatus = 'ALL';
      _objFilterClass = 'ALL';
      list = _filteredAndSortedWorkingNodes;
      if (list.isEmpty) {
        list = _workingNodes.where((n) => n.reviewStatus != 'REJECTED').toList();
      }
    }
    if (list.isEmpty) list = _workingNodes;
    if (list.isEmpty) return;

    int currentIdx = _selectedNode != null
        ? list.indexWhere((n) => n.id == _selectedNode!.id)
        : -1;
    int nextIdx = (currentIdx + 1) % list.length;
    setState(() {
      _selectedNode = list[nextIdx];
      _nodePage = nextIdx ~/ _nodePageSize;
    });
    if (_selectedNode!.agentExplanation == null &&
        _selectedNode!.reviewStatus == 'SUSPICIOUS') {
      _triggerAgentReviewNode(_selectedNode!);
    }
  }

  void _confirmNodeAndNext(ReviewNodeItem node) {
    setState(() {
      node.reviewStatus = 'CONFIRMED';
      node.source = '${node.source}_human_confirmed';
    });
    if (_objFilterStatus == 'SUSPICIOUS') {
      _selectNextSuspiciousNode();
    } else {
      _selectNextNode();
    }
  }

  void _confirmAllCleanNodes() {
    int count = 0;
    setState(() {
      for (final node in _workingNodes) {
        if (node.reviewStatus != 'CONFIRMED' &&
            node.reviewStatus != 'REJECTED' &&
            node.reviewStatus != 'SUSPICIOUS') {
          node.reviewStatus = 'CONFIRMED';
          node.source = '${node.source}_batch_confirmed';
          count++;
        }
      }
      if (_selectedNode != null && _selectedNode!.reviewStatus == 'CONFIRMED') {
        if (_objSuspiciousCount > 0) {
          _selectNextSuspiciousNode();
        }
      }
    });

    if (mounted) {
      if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✓ 정상 객체 $count개를 일괄 승인했습니다! "
              "${_objSuspiciousCount == 0 ? '하단의 [객체 검수 완료]를 눌러 다음 단계로 이동하세요.' : '남은 의심 객체 $_objSuspiciousCount개를 확인해주세요.'}",
            ),
            backgroundColor: const Color(0xFF16A34A),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("일괄 승인할 정상 대기 객체가 없습니다. 이미 승인되었거나 의심 항목만 남아있습니다."),
            backgroundColor: Color(0xFF475569),
          ),
        );
      }
    }

    if (_canVerifyObjectGate) {
      PowerLensAIService.instance.triggerHighlight('object_gate');
    }
  }

  // --- Sequential Line Review Methods ---
  void _selectPreviousLine() {
    var lines = _filteredAndSortedWorkingLines;
    if (lines.isEmpty || (_selectedLine != null && !lines.any((l) => l.lineId == _selectedLine!.lineId))) {
      _connFilterStatus = 'ALL';
      lines = _filteredAndSortedWorkingLines;
      if (lines.isEmpty) {
        lines = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
      }
    }
    if (lines.isEmpty) lines = _workingLines;
    if (lines.isEmpty) return;

    int currentIdx = _selectedLine != null
        ? lines.indexWhere((l) => l.lineId == _selectedLine!.lineId)
        : 0;
    if (currentIdx < 0) currentIdx = 0;
    int prevIdx = (currentIdx - 1 + lines.length) % lines.length;
    setState(() {
      _selectedLine = lines[prevIdx];
      _linePage = prevIdx ~/ _linePageSize;
      _selectedNode = null;
      _selectedTopologyIssue = null;
    });
  }

  void _selectNextLine() {
    var lines = _filteredAndSortedWorkingLines;
    if (lines.isEmpty || (_selectedLine != null && !lines.any((l) => l.lineId == _selectedLine!.lineId))) {
      _connFilterStatus = 'ALL';
      lines = _filteredAndSortedWorkingLines;
      if (lines.isEmpty) {
        lines = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
      }
    }
    if (lines.isEmpty) lines = _workingLines;
    if (lines.isEmpty) return;

    int currentIdx = _selectedLine != null
        ? lines.indexWhere((l) => l.lineId == _selectedLine!.lineId)
        : -1;
    int nextIdx = currentIdx + 1;
    if (nextIdx >= lines.length) {
      nextIdx = 0;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✓ 모든 선로를 한 바퀴 검토했습니다."),
          duration: Duration(seconds: 2),
        ),
      );
    }
    setState(() {
      _selectedLine = lines[nextIdx];
      _linePage = nextIdx ~/ _linePageSize;
      _selectedNode = null;
      _selectedTopologyIssue = null;
    });
  }

  void _confirmLineAndNext(ReviewLineItem line) {
    setState(() {
      line.reviewStatus = 'CONFIRMED';
      line.source = '${line.source}_human_confirmed';
      if (_connFilterStatus == 'AMBIGUOUS' && _lineAmbiguousCount == 0) {
        _connFilterStatus = 'ALL';
      } else if (_connFilterStatus == 'ERROR_ONLY' && _criticalIssuesCount == 0) {
        _connFilterStatus = 'ALL';
      }
    });
    _triggerTopologyValidation();
    _selectNextLine();
  }

  void _rejectLineAndNext(ReviewLineItem line) {
    final lines = _filteredAndSortedWorkingLines;
    int currentIdx = lines.indexWhere((item) => item.lineId == line.lineId);
    setState(() {
      _workingLines.removeWhere((item) => item.lineId == line.lineId);
      if (_connFilterStatus == 'AMBIGUOUS' && _lineAmbiguousCount == 0) {
        _connFilterStatus = 'ALL';
      } else if (_connFilterStatus == 'ERROR_ONLY' && _criticalIssuesCount == 0) {
        _connFilterStatus = 'ALL';
      }
      var remaining = _filteredAndSortedWorkingLines;
      if (remaining.isEmpty) {
        _connFilterStatus = 'ALL';
        remaining = _filteredAndSortedWorkingLines;
        if (remaining.isEmpty) {
          remaining = _workingLines.where((l) => l.reviewStatus != 'REJECTED').toList();
        }
      }
      if (remaining.isNotEmpty) {
        int nextIdx = currentIdx.clamp(0, remaining.length - 1);
        _selectedLine = remaining[nextIdx];
        _linePage = nextIdx ~/ _linePageSize;
      } else {
        _selectedLine = null;
      }
      _isFinalVerified = false;
      _selectedNode = null;
      _selectedTopologyIssue = null;
    });
    _triggerTopologyValidation();
  }

  // --- Sequential Bus Review Methods ---
  void _selectPreviousBus() {
    var buses = _filteredAndSortedBusNodes;
    if (buses.isEmpty || (_selectedNode != null && !buses.any((b) => b.id == _selectedNode!.id))) {
      _busFilterStatus = 'ALL';
      buses = _filteredAndSortedBusNodes;
      if (buses.isEmpty) {
        buses = _busNodes;
      }
    }
    if (buses.isEmpty) return;

    int currentIdx = _selectedNode != null
        ? buses.indexWhere((b) => b.id == _selectedNode!.id)
        : 0;
    if (currentIdx < 0) currentIdx = 0;
    int prevIdx = (currentIdx - 1 + buses.length) % buses.length;
    setState(() {
      _selectedNode = buses[prevIdx];
      if (_selectedNode!.busNumber != null) {
        _busNumberEditController.text = _selectedNode!.busNumber.toString();
      } else {
        _busNumberEditController.clear();
      }
      _busPage = prevIdx ~/ _busPageSize;
    });
  }

  void _selectNextBus() {
    var buses = _filteredAndSortedBusNodes;
    if (buses.isEmpty || (_selectedNode != null && !buses.any((b) => b.id == _selectedNode!.id))) {
      _busFilterStatus = 'ALL';
      buses = _filteredAndSortedBusNodes;
      if (buses.isEmpty) {
        buses = _busNodes;
      }
    }
    if (buses.isEmpty) return;

    int currentIdx = _selectedNode != null
        ? buses.indexWhere((b) => b.id == _selectedNode!.id)
        : -1;
    int nextIdx = currentIdx + 1;
    if (nextIdx >= buses.length) {
      nextIdx = 0;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✓ 모든 모선을 한 바퀴 확인했습니다."),
          duration: Duration(seconds: 2),
        ),
      );
    }
    setState(() {
      _selectedNode = buses[nextIdx];
      if (_selectedNode!.busNumber != null) {
        _busNumberEditController.text = _selectedNode!.busNumber.toString();
      } else {
        _busNumberEditController.clear();
      }
      _busPage = nextIdx ~/ _busPageSize;
    });
  }

  void _skipAndNextBus() {
    _selectNextBus();
  }

  void _approveAndNextBus(ReviewNodeItem busNode) {
    final text = _busNumberEditController.text.trim();
    int? num = int.tryParse(text);
    if (num == null || num <= 0) {
      num = busNode.busNumber;
    }
    if (num == null || num <= 0) {
      final match = RegExp(r'\d+').firstMatch(busNode.id);
      if (match != null) num = int.tryParse(match.group(0)!);
    }

    if (num != null && num > 0) {
      final conflictBuses = _busNodes
          .where((b) => b != busNode && b.busNumber == num)
          .toList();
      if (conflictBuses.isNotEmpty) {
        for (final cb in conflictBuses) {
          cb.busNumberStatus = 'UNCERTAIN';
          cb.displayLabel = "Bus $num (중복)";
          if (!cb.busNumberReasons.contains('DUPLICATE_BUS_NUMBER_$num')) {
            cb.busNumberReasons.add('DUPLICATE_BUS_NUMBER_$num');
          }
        }
        busNode.busNumberStatus = 'UNCERTAIN';
        if (!busNode.busNumberReasons.contains('DUPLICATE_BUS_NUMBER_$num')) {
          busNode.busNumberReasons.add('DUPLICATE_BUS_NUMBER_$num');
        }
        _propagateBusNumber(busNode, num, isDuplicate: true);
      } else {
        busNode.busNumberStatus = 'VERIFIED';
        busNode.busNumberReasons.removeWhere(
          (r) => r.startsWith('DUPLICATE_BUS_NUMBER_'),
        );
        _propagateBusNumber(busNode, num, isDuplicate: false);
      }
    } else {
      busNode.busNumberStatus = 'VERIFIED';
    }

    final completedAllBuses = _canVerifyBusGate;
    _selectNextBus();
    if (completedAllBuses) _showBusCompletionPrompt();
  }

  void _showBusCompletionPrompt() {
    if (!mounted || _busCompletionPromptVisible) return;
    _busCompletionPromptVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 24),
              SizedBox(width: 8),
              Text(
                '모선 번호 매핑 완료',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          content: const Text(
            '모든 모선 번호가 고유하게 확인되었습니다.\n이제 선로 결선을 우선순위대로 검수할까요?',
            style: TextStyle(
              color: Color(0xFF475569),
              fontSize: 13,
              height: 1.45,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('한 번 더 보기'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
              ),
              child: const Text('다음 단계로 이동'),
            ),
          ],
        ),
      ).then((goNext) {
        if (!mounted) return;
        _busCompletionPromptVisible = false;
        if (goNext == true && _currentPhase == ReviewPhase.busMappingReview) {
          _proceedToConnectionReview();
        }
      });
    });
  }

  String _getReviewStageSpeechBubbleText() {
    if (_stageGateMessage != null && _stageGateMessage!.isNotEmpty) {
      return _stageGateMessage!;
    }
    switch (_currentPhase) {
      case ReviewPhase.objectReview:
        final suspCount = _objSuspiciousCount;
        if (suspCount > 0) {
          final selectedLabel =
              _selectedNode?.effectiveDisplayLabel ?? '첫 번째 검토 항목';
          return "객체를 확인해봤어요. 대부분 괜찮고, 제가 다시 봤으면 하는 것부터 보여드릴게요.\n"
              "$selectedLabel의 검토 이유를 확인한 뒤 [승인하고 다음] 또는 [제외]를 선택해주세요.";
        }
        if (_unresolvedCandidatesCount > 0) {
          return "의심 객체는 모두 확인되었으나, 누락 후보 $_unresolvedCandidatesCount건이 남아 있어요.\n"
              "목록에서 복구하거나 문제없음 처리 후 [객체 검수 완료]를 눌러주세요.";
        }
        return "도면 내 모든 객체 인식이 정상적으로 완료되었어요!\n"
            "검토가 필요한 항목이 없으니 아래의 [객체 검수 완료]를 눌러 다음 단계로 가면 돼요.";
      case ReviewPhase.busMappingReview:
        final hasBusIssues = _busUncertainCount > 0 || _duplicateBusNumbers.isNotEmpty;
        if (!hasBusIssues) {
          return "모든 모선에 고유 번호가 정상적으로 지정되었습니다!\n"
              "오른쪽 하단의 [모선 번호 승인]을 눌러 결선 검수로 넘어가시면 돼요.";
        }
        return "이번에는 모선 번호만 확인하면 돼요. 전체 승인하거나, 하나씩 넘겨보면서 확인할 수 있어요.\n"
            "추천하는 방법은 오른쪽의 번호 입력 후 [승인하고 다음 모선으로]를 누르는 거예요.";
      case ReviewPhase.connectionReview:
        if (_connectionMissionComplete || (_lineAmbiguousCount == 0 && _topologyIssues.isEmpty)) {
          return "모든 선로와 결선 연결이 정상적으로 검증되었습니다!\n"
              "아래 [결선 검수 완료]를 눌러 마지막 확인을 시작해주세요.";
        }
        return "전체 연결을 먼저 확인해봤어요. 제가 다시 보는 게 좋다고 판단한 선부터 같이 볼게요.\n"
            "[핵심 검토]에서 [선로 승인하고 다음]을 누르거나, 전체 선로·한 선씩 보기로 바꿀 수 있어요.";
      case ReviewPhase.verifiedFinal:
        return _importedExcelData == null
            ? "검증이 끝났어요. 이제 엑셀 값을 연결하면 실제 조류계산을 할 수 있어요.\n"
                "상단 또는 가운데의 [엑셀 파일 선택]을 눌러 계통 제원을 연결해주세요."
            : "엑셀 값이 연결됐어요. 이제 캔버스로 이동하면 실제 조류계산을 실행할 수 있어요.";
    }
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
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (_currentPhase == ReviewPhase.busMappingReview &&
            _selectedNode != null) {
          _approveAndNextBus(_selectedNode!);
          return true;
        }
      }
      return false;
    }

    // Arrow Right or Down: Navigate to Next
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_currentPhase == ReviewPhase.objectReview) {
        _selectNextNode();
        return true;
      } else if (_currentPhase == ReviewPhase.busMappingReview) {
        _selectNextBus();
        return true;
      } else if (_currentPhase == ReviewPhase.connectionReview) {
        _selectNextLine();
        return true;
      }
    }

    // Arrow Left or Up: Navigate to Previous
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_currentPhase == ReviewPhase.objectReview) {
        _selectPreviousNode();
        return true;
      } else if (_currentPhase == ReviewPhase.busMappingReview) {
        _selectPreviousBus();
        return true;
      } else if (_currentPhase == ReviewPhase.connectionReview) {
        _selectPreviousLine();
        return true;
      }
    }

    // Enter: Confirm and Next
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_currentPhase == ReviewPhase.objectReview && _selectedNode != null) {
        _confirmNodeAndNext(_selectedNode!);
        return true;
      } else if (_currentPhase == ReviewPhase.busMappingReview &&
          _selectedNode != null) {
        _approveAndNextBus(_selectedNode!);
        return true;
      } else if (_currentPhase == ReviewPhase.connectionReview &&
          _selectedLine != null) {
        _confirmLineAndNext(_selectedLine!);
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
        _rejectLineAndNext(_selectedLine!);
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

  // --- Step 3: Object Gate Verification ---

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
      _connectionFullOverview = false;
      _connectionLinesOnlyMode = false;
      _connectionFastMode = false;
      _lineFocusOnly = true;
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
        _selectedLine = _workingLines.isNotEmpty ? _workingLines.first : null;
        _selectedNode = null;
        _isLoading = false;
        _stageGateMessage = null;
        _connectionFullOverview = false;
        _connectionLinesOnlyMode = false;
        _connectionFastMode = false;
        _lineFocusOnly = true;
      });

      FocusManager.instance.primaryFocus?.unfocus();
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

      setState(() {
        _topologyIssues = List<Map<String, dynamic>>.from(res['issues'] ?? []);
      });
    } catch (e) {
      print("토폴로지 검증 오류: $e");
    }
  }

  void _batchConfirmCleanDetectedLines() {
    setState(() {
      for (var line in _workingLines) {
        if (line.reviewStatus == 'DETECTED' && line.validationIssues.isEmpty) {
          line.reviewStatus = 'CONFIRMED';
          line.source = '${line.source}_auto_confirmed';
        }
      }
    });
    _triggerTopologyValidation();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("정상 결선들이 일괄 승인되었습니다."),
        backgroundColor: Colors.teal,
      ),
    );
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
      blockers: () => [
        if (_lineAmbiguousCount > 0) '검토가 필요한 결선 $_lineAmbiguousCount개 승인 또는 제외',
        if (_criticalIssuesCount > 0) '연결 구조 오류 $_criticalIssuesCount건 해결',
        if (!_connectionMissionComplete) 'Lensy 핵심 선로 검토 미션 완료',
        if (_workingLines.where((l) => l.reviewStatus != 'REJECTED').isEmpty)
          '사용 가능한 선로가 없음',
      ],
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
        _stageGateMessage = _isFinalVerified
            ? null
            : '최종 확인에서 다시 검토할 선로가 있어요.';
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

  void _handoffToFlutterCanvas() {
    if (_verifiedSld == null || _verifiedSld!.status != 'VERIFIED') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("최종 검증을 통과한 회로도만 편집 화면으로 전달할 수 있습니다."),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final data = _verifiedSld!.toJson();
    if (_importedExcelData != null) {
      data['excel_data'] = _importedExcelData;
      if (_excelMismatchReport != null) {
        data['mismatch_report'] = _excelMismatchReport;
      }
    }
    widget.onProceedToCanvas?.call(data);
    if (Navigator.canPop(context)) {
      Navigator.pop(context, data);
    }
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
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF0F172A)),
            ),
          ],
        ),
        content: const Text(
          "검수를 처음 단계(① 객체 검수)로 되돌리시겠습니까?\n\n"
          "• 적용된 엑셀 데이터 및 불일치 알림이 초기화됩니다.\n"
          "• 선로 결선 및 최종 검증 상태가 리셋되며, 최초 도면 AI 인식 객체 목록으로 복원됩니다.",
          style: TextStyle(fontSize: 13.5, height: 1.5, color: Color(0xFF334155)),
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
      _isObjectVerified = false;
      _isFinalVerified = false;
      _objectGateMessage = null;
      _humanCompletenessConfirmed = false;
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
        _workingNodes = _document!.nodes.map((n) => ReviewNodeItem.fromJson(n.toJson())).toList();
        _selectedNode = _workingNodes.isNotEmpty ? _workingNodes.first : null;
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
                  _selectedNode = _workingNodes.isNotEmpty ? _workingNodes.first : null;
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
              _canVerifyBusGate,
              onTap: _workingNodes.isNotEmpty
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
              _workingLines.isNotEmpty && _lineAmbiguousCount == 0,
              onTap: _workingLines.isNotEmpty
                  ? () {
                      setState(() {
                        _currentPhase = ReviewPhase.connectionReview;
                        _selectedNode = null;
                        _selectedLine = _workingLines.first;
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
                icon: const Icon(Icons.restart_alt, size: 14, color: Color(0xFFDC2626)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          ElevatedButton.icon(
            onPressed: _importExcelInReview,
            icon: Icon(
              Icons.table_chart,
              size: 14,
              color: (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF0D9488),
            ),
            label: Text(
              _importedExcelData != null
                  ? ((_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
                      ? "⚠️ 엑셀 불일치 (#${_importedExcelData!['slack_bus_number'] ?? '?'})"
                      : "엑셀 적용됨 (#${_importedExcelData!['slack_bus_number']})")
                  : "엑셀 불러오기",
              style: TextStyle(
                fontSize: 11,
                color: (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
                  ? const Color(0xFFFEF2F2)
                  : const Color(0xFFF1F5F9),
              foregroundColor: const Color(0xFF0F172A),
              elevation: 0,
              side: BorderSide(
                color: (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
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
              child: Builder(
                builder: (context) {
                  final isMobile = MediaQuery.of(context).size.width < 768;
                  final coachTarget = _lensyCoachTarget;
                  return AnimatedAlign(
                    alignment: _effectiveReviewLensyAlignment(
                      coachTarget,
                      isMobile: isMobile,
                    ),
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.easeInOutCubic,
                    child: PowerLensAIFloatingButton(
                      coachTarget: coachTarget,
                      onDragDelta: (delta) => _handleReviewLensyDrag(
                        delta,
                        coachTarget,
                        isMobile: isMobile,
                      ),
                      onPressed: () {
                        if (isMobile) {
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
                        } else {
                          setState(() => _isAiPanelOpen = !_isAiPanelOpen);
                        }
                      },
                      isOpen: _isAiPanelOpen,
                      isMobile: isMobile,
                      presenceState: _reviewLensyPresenceState,
                      alertCount: _objSuspiciousCount > 0
                          ? _objSuspiciousCount
                          : null,
                      speechBubbleText: _getReviewStageSpeechBubbleText(),
                      coachMessage: _getReviewStageSpeechBubbleText(),
                    ),
                  );
                },
              ),
            ),
            if (_isAiPanelOpen && MediaQuery.of(context).size.width >= 768)
              Positioned(
                right: 20,
                bottom: 130,
                child: PowerLensAIPanel(
                  assistantContext: _buildAssistantContext(),
                  onClose: () => setState(() => _isAiPanelOpen = false),
                  isMobile: false,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseBadge(String label, bool isCurrent, bool isCompleted, {VoidCallback? onTap}) {
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
      if (!_humanCompletenessConfirmed && !_isCleanAuto) {
        return '원본 도면과 객체 목록이 일치하는지 확인해 주세요.';
      }
      return '객체 확인이 완료되었습니다. 모선 번호 매핑으로 이동할 수 있습니다.';
    }
    if (_lineAmbiguousCount > 0) {
      return '검토가 필요한 결선 $_lineAmbiguousCount개를 확인하세요.';
    }
    if (_criticalIssuesCount > 0) {
      return '연결 구조 오류 $_criticalIssuesCount건을 먼저 해결하세요.';
    }
    return '결선 확인이 완료되었습니다. 최종 검증을 진행할 수 있습니다.';
  }

  void _focusNextReviewTask() {
    final needsCompletenessCheck =
        _currentPhase == ReviewPhase.objectReview &&
        _objSuspiciousCount == 0 &&
        _unresolvedCandidatesCount == 0 &&
        !_humanCompletenessConfirmed;
    setState(() {
      if (_currentPhase == ReviewPhase.objectReview) {
        final suspicious = _workingNodes
            .where((node) => node.reviewStatus == 'SUSPICIOUS')
            .toList();
        if (suspicious.isNotEmpty) {
          _objFilterStatus = 'SUSPICIOUS';
          _objFilterClass = 'ALL';
          _selectedNode = suspicious.first;
        }
      } else if (_currentPhase == ReviewPhase.busMappingReview) {
        _busFilterStatus = 'UNCERTAIN';
        _busPage = 0;
        final buses = _filteredAndSortedBusNodes;
        _selectedNode = buses.isNotEmpty ? buses.first : null;
        _selectedLine = null;
      } else if (_currentPhase == ReviewPhase.connectionReview) {
        _connFilterStatus = _lineAmbiguousCount > 0
            ? 'AMBIGUOUS'
            : 'ERROR_ONLY';
        _showAllLinesList = false;
        _showTopologyDetails = _topologyIssues.isNotEmpty;
        final lines = _filteredAndSortedWorkingLines;
        final nextIndex = lines.indexWhere(
          (line) =>
              line.reviewStatus == 'AMBIGUOUS' ||
              line.validationIssues.isNotEmpty,
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
          content: Text('오른쪽 아래의 원본 도면 대조 확인 항목을 체크해 주세요.'),
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
    final hasNextTask = isObjectPhase
        ? (_objSuspiciousCount > 0 ||
              _unresolvedCandidatesCount > 0 ||
              !_humanCompletenessConfirmed)
        : (_lineAmbiguousCount > 0 || _criticalIssuesCount > 0);
    final autoConfirmedCount = isObjectPhase
        ? _workingNodes
              .where(
                (node) =>
                    node.reviewStatus == 'CONFIRMED' &&
                    !node.source.contains('human'),
              )
              .length
        : _workingLines
              .where(
                (line) =>
                    line.reviewStatus == 'CONFIRMED' &&
                    !line.source.contains('human'),
              )
              .length;
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
                  isObjectPhase ? '객체 인식 검수' : '결선 및 전기 검수',
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
          _buildAiMetric('자동 승인', autoConfirmedCount, const Color(0xFF16A34A)),
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
            onPressed: hasNextTask ? _focusNextReviewTask : null,
            icon: Icon(
              hasNextTask ? Icons.arrow_forward_rounded : Icons.check_rounded,
              size: 13,
            ),
            label: Text(
              hasNextTask ? '다음 검토' : '정리 완료',
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
                              // Quick navigation & batch confirm
                              IconButton(
                                icon: const Icon(
                                  Icons.arrow_back,
                                  size: 15,
                                  color: Color(0xFF64748B),
                                ),
                                tooltip: "이전 객체",
                                visualDensity: VisualDensity.compact,
                                onPressed: _workingNodes.isEmpty
                                    ? null
                                    : _selectPreviousNode,
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.arrow_forward,
                                  size: 15,
                                  color: Color(0xFF64748B),
                                ),
                                tooltip: "다음 객체",
                                visualDensity: VisualDensity.compact,
                                onPressed: _workingNodes.isEmpty
                                    ? null
                                    : _selectNextNode,
                              ),
                              const SizedBox(width: 2),
                              IconButton(
                                icon: const Icon(
                                  Icons.history_toggle_off,
                                  size: 15,
                                  color: Color(0xFFD97706),
                                ),
                                tooltip: "이전 의심 객체",
                                visualDensity: VisualDensity.compact,
                                onPressed: _objSuspiciousCount == 0
                                    ? null
                                    : _selectPreviousSuspiciousNode,
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.warning_amber_rounded,
                                  size: 15,
                                  color: Color(0xFFD97706),
                                ),
                                tooltip: "다음 의심 객체",
                                visualDensity: VisualDensity.compact,
                                onPressed: _objSuspiciousCount == 0
                                    ? null
                                    : _selectNextSuspiciousNode,
                              ),
                              const SizedBox(width: 6),
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
                              if (_lineDetectedCount > 0)
                                ElevatedButton.icon(
                                  onPressed: _batchConfirmCleanDetectedLines,
                                  icon: const Icon(Icons.done_all, size: 13),
                                  label: Text(
                                    "정상 결선 승인 ($_lineDetectedCount)",
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0D9488),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    visualDensity: VisualDensity.compact,
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
                              child: ReviewOverlayView(
                                focusTargetKey: _reviewFocusTargetKey,
                                imageBytes: _document!.rawBytes,
                                imageUrl: _apiService.getOriginalImageUrl(
                                  _document!.documentId,
                                ),
                                originalWidth: _document!.image.width,
                                originalHeight: _document!.image.height,
                                nodes:
                                    (_currentPhase == ReviewPhase.objectReview)
                                    ? _filteredAndSortedWorkingNodes
                                    : _workingNodes,
                                selectedNode: _selectedNode,
                                onSelectNode: (node) {
                                  setState(() {
                                    _selectedNode = node;
                                    if (_isManualAddLineMode &&
                                        _manualLineStartNode == null) {
                                      _manualLineStartNode = node;
                                    }
                                    if (_currentPhase ==
                                        ReviewPhase.connectionReview) {
                                      final matchedIssue = _topologyIssues
                                          .firstWhere(
                                            (i) =>
                                                (i['component_ids'] as List? ??
                                                        [])
                                                    .map((e) => e.toString())
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
                                    (_currentPhase == ReviewPhase.objectReview)
                                    ? const []
                                    : _workingLines,
                                selectedLine: _selectedLine,
                                onSelectLine: (line) {
                                  setState(() {
                                    _selectedLine = line;
                                    if (_currentPhase ==
                                        ReviewPhase.connectionReview) {
                                      _selectedNode = null;
                                      _selectedTopologyIssue = null;
                                      if (!_filteredAndSortedWorkingLines.any((l) => l.lineId == line.lineId)) {
                                        _connFilterStatus = 'ALL';
                                      }
                                    }
                                    final index = _filteredAndSortedWorkingLines
                                        .indexWhere(
                                          (item) => item.lineId == line.lineId,
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
                                onManualAddComplete: _handleManualAddComplete,
                                isManualAddLineMode: _isManualAddLineMode,
                                manualLineStartNode: _manualLineStartNode,
                                onManualAddLineComplete:
                                    _handleManualAddLineComplete,
                                violationNodeIds: _topologyIssues
                                    .where((i) => i['severity'] == 'error')
                                    .expand(
                                      (i) => (i['component_ids'] as List? ?? [])
                                          .map((e) => e.toString()),
                                    )
                                    .toSet(),
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
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => setState(
                                          () =>
                                              _lineFocusOnly = !_lineFocusOnly,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
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
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
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
                                                      ? const Color(0xFF0284C7)
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
                                    ? _buildConnectionReviewSidePanel()
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
            child: Wrap(
              spacing: 3.5,
              runSpacing: 4.0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  "도면 표시:",
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 9.5),
                ),
                _buildObjectClassFilter("전체", 'ALL'),
                _buildObjectClassFilter("Bus", 'bus'),
                _buildObjectClassFilter("Load", 'load'),
                _buildObjectClassFilter("Gen", 'generator'),
                _buildObjectClassFilter("Trans", 'transformer'),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: const Text(
              "고급: 필터·정렬·일괄 작업",
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
              const SizedBox(height: 8),
              GlowingTargetWrapper(
                targetId: 'object_batch_approve',
                borderRadius: BorderRadius.circular(8),
                guideLabel: "✨ 정상 객체 일괄 승인",
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _unconfirmedNodesCount > 0
                        ? _confirmAllCleanNodes
                        : null,
                    icon: const Icon(Icons.done_all, size: 16),
                    label: Text(
                      _unconfirmedNodesCount > 0
                          ? (_objSuspiciousCount > 0
                              ? "정상 객체 일괄 승인 (의심 제외 $_unconfirmedNodesCount건)"
                              : "정상 객체 일괄 승인 ($_unconfirmedNodesCount건 한 번에 확정)")
                          : "모든 정상 객체 승인 완료됨 ✓",
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFF1F5F9),
                      disabledForegroundColor: const Color(0xFF94A3B8),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      elevation: _unconfirmedNodesCount > 0 ? 1 : 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),
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
            final isSuspicious = n.reviewStatus == 'SUSPICIOUS';
            final isConfirmed = n.reviewStatus == 'CONFIRMED';
            final isRejected = n.reviewStatus == 'REJECTED';
            final classColor = _getClassColor(n.className);

            return GestureDetector(
              onTap: () {
                setState(() {
                  _selectedNode = n;
                  _nodePage = currentPage;
                });
                if (isSuspicious && n.agentExplanation == null) {
                  _triggerAgentReviewNode(n);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? classColor.withValues(alpha: 0.22)
                      : const Color(0xFFF8FAFC),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFFF59E0B)
                        : (isSuspicious
                              ? const Color(0xFFF97316)
                              : classColor.withValues(alpha: 0.6)),
                    width: isSelected ? 1.8 : 1.2,
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
    final isSuspicious = node.reviewStatus == 'SUSPICIOUS';
    final classColor = _getClassColor(node.className);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with Display Label and Edit Action
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  _getClassIcon(node.className),
                  color: classColor,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  node.effectiveDisplayLabel,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(
                    Icons.edit,
                    size: 14,
                    color: Color(0xFF2563EB),
                  ),
                  tooltip: "표시명 / 번호 수정",
                  onPressed: () => _editNodeDisplayLabel(node),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isSuspicious
                    ? const Color(0xFFD97706)
                    : (node.reviewStatus == 'CONFIRMED'
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF2563EB)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                node.reviewStatus,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        Text(
          "객체 종류: ${_classNameKo(node.className)}  ·  신뢰도: ${(node.confidence * 100).toInt()}%",
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
        const SizedBox(height: 12),

        if (node.reviewReasons.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Color(0xFFD97706),
                      size: 14,
                    ),
                    SizedBox(width: 4),
                    Text(
                      "검토 필요 사유:",
                      style: TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ...node.reviewReasons.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      "• $r",
                      style: const TextStyle(
                        color: Color(0xFF78350F),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Agent Card
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    color: Color(0xFF2563EB),
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    "AI 검수 의견",
                    style: TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                node.agentExplanation ??
                    (isSuspicious ? "의심 사유를 분석하고 있습니다..." : "정상 심볼로 인식되었습니다."),
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (node.recommendedAction != null) ...[
                const SizedBox(height: 8),
                Text(
                  "추천 조치: ${_recommendedActionKo(node.recommendedAction)}",
                  style: const TextStyle(
                    color: Color(0xFF15803D),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Action Buttons
        const Text(
          "사용자 검수 액션",
          style: TextStyle(
            color: Color(0xFF475569),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        GlowingTargetWrapper(
          targetId: 'object_approve',
          borderRadius: BorderRadius.circular(8),
          guideLabel: "✨ 승인하고 다음 (Enter)",
          child: ElevatedButton.icon(
            key: _objectPrimaryActionKey,
            onPressed: () => _confirmNodeAndNext(node),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text(
              "승인하고 다음 (Enter ➔)",
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        GlowingTargetWrapper(
          targetId: 'object_batch_approve',
          borderRadius: BorderRadius.circular(8),
          guideLabel: "✨ 정상 객체 일괄 승인",
          child: OutlinedButton.icon(
            onPressed: _unconfirmedNodesCount > 0 ? _confirmAllCleanNodes : null,
            icon: const Icon(Icons.done_all, size: 16),
            label: Text(
              _unconfirmedNodesCount > 0
                  ? (_objSuspiciousCount > 0
                      ? "정상 객체 일괄 승인 (의심 제외)"
                      : "정상 객체 전체 승인 (한 번에 확인)")
                  : "모든 정상 객체 승인 완료됨 ✓",
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0D9488),
              side: const BorderSide(color: Color(0xFF14B8A6), width: 1.2),
              backgroundColor: const Color(0xFFF0FDFA),
              disabledForegroundColor: const Color(0xFF94A3B8),
              minimumSize: const Size(double.infinity, 38),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        Row(
          children: [
            Expanded(
              child: GlowingTargetWrapper(
                targetId: 'node_prev',
                borderRadius: BorderRadius.circular(4),
                guideLabel: "✨ 이전 객체 (◀)",
                child: OutlinedButton.icon(
                  onPressed: _selectPreviousNode,
                  icon: const Icon(Icons.arrow_back, size: 13),
                  label: const Text("이전 (◀)", style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GlowingTargetWrapper(
                targetId: 'node_reject',
                borderRadius: BorderRadius.circular(4),
                guideLabel: "✨ 객체 제외/삭제",
                child: OutlinedButton(
                  onPressed: () => _rejectNode(node),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    side: const BorderSide(color: Color(0xFFFCA5A5)),
                  ),
                  child: const Text(
                    "제외/삭제",
                    style: TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GlowingTargetWrapper(
                targetId: 'node_next',
                borderRadius: BorderRadius.circular(4),
                guideLabel: "✨ 다음 객체 (▶)",
                child: OutlinedButton.icon(
                  onPressed: _selectNextNode,
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
        const SizedBox(height: 6),

        // Class changes remain available for Human-in-the-Loop corrections,
        // but are intentionally kept out of the beginner default view.
        GlowingTargetWrapper(
          targetId: 'node_class_tile',
          borderRadius: BorderRadius.circular(4),
          guideLabel: "✨ 객체 종류 수정",
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: const Text(
              "고급: 객체 종류 수정",
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
            ),
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ['bus', 'generator', 'load', 'transformer'].map((cls) {
                final isCurrent = node.className.toLowerCase() == cls;
                return ChoiceChip(
                  label: Text(
                    cls.toUpperCase(),
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: isCurrent,
                  onSelected: (selected) {
                    if (selected) _changeNodeClass(node, cls);
                  },
                  selectedColor: _getClassColor(cls).withValues(alpha: 0.25),
                  backgroundColor: const Color(0xFFF1F5F9),
                  side: BorderSide(
                    color: isCurrent
                        ? _getClassColor(cls)
                        : const Color(0xFFCBD5E1),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    ],
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
                  '핵심 검토 $completed/$total',
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
            color: linesOnly ? const Color(0xFF0F766E) : const Color(0xFFB45309),
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
            child: const Text('한 선씩 보기', style: TextStyle(fontSize: 10)),
          ),
        ],
      ),
    );
  }

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
            if (_connFilterStatus != 'ALL' && _filteredAndSortedWorkingLines.isEmpty) {
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
                "⚡ 선로 결선 확인 (순차 집중 모드)",
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
          GlowingTargetWrapper(
            targetId: 'connection_priority',
            borderRadius: BorderRadius.circular(8),
            guideLabel: "✨ 선로 승인하고 다음",
            child: ElevatedButton.icon(
              key: _connectionPrimaryActionKey,
              onPressed: () => _confirmLineAndNext(line),
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text(
                "선로 승인하고 다음 (Enter ➔)",
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
                    onPressed: _selectPreviousLine,
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
                    onPressed: () => _rejectLineAndNext(line),
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
                    onPressed: _selectNextLine,
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
                  guideLabel: "✨ 다음 선로 (▶)",
                  child: OutlinedButton.icon(
                    onPressed: _selectNextLine,
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
                    "두 부품 간 선로가 올바르면 [선로 승인하고 다음]을 누르세요. 키보드 [Enter] 또는 [➔] 키로 연속 검토할 수 있습니다.",
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

  String _recommendedActionKo(String? action) {
    switch (action?.toUpperCase()) {
      case 'CONFIRM':
        return '승인 권장';
      case 'ASK_USER':
        return '사용자 확인 필요';
      case 'CHANGE_CLASS':
        return '클래스 변경 검토';
      case 'REJECT':
        return '제외·삭제 권장';
      default:
        return action ?? '확인 필요';
    }
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

  Future<void> _triggerAiBusLinking() async {
    if (_document == null) return;
    setState(() => _isLinkingBusNumbers = true);
    try {
      final res = await _apiService.linkBusNumbers(
        documentId: _document!.documentId,
        workingNodes: _workingNodes,
        workingLines: _workingLines,
      );
      if (res['status'] == 'success' && res['nodes'] is List) {
        final rawNodes = (res['nodes'] as List);
        setState(() {
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
            node.displayLabel =
                raw['display_name']?.toString() ??
                raw['display_label']?.toString() ??
                node.displayLabel;
            node.connectedBusNumber = (raw['connected_bus_number'] as num?)
                ?.toInt();
            node.connectedBusId = raw['connected_bus_id']?.toString();
            if (raw['id'] != null) {
              node.id = raw['id'].toString();
            }
          }
          final buses = _filteredAndSortedBusNodes;
          _selectedNode = buses.isNotEmpty ? buses.first : null;
          if (_selectedNode != null && _selectedNode!.busNumber != null) {
            _busNumberEditController.text = _selectedNode!.busNumber.toString();
          } else {
            _busNumberEditController.clear();
          }
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✓ AI가 추가/수정된 모선을 포함한 모든 모선 번호를 도면에서 판독했습니다!"),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("모선 번호 AI 판독 중 알림: $e"),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLinkingBusNumbers = false);
    }
  }

  void _proceedToBusMappingReview() {
    setState(() {
      _currentPhase = ReviewPhase.busMappingReview;
      _stageGateMessage = null;
      _selectedLine = null;
      _busFilterStatus = 'ALL';
      _busPage = 0;
      final buses = _filteredAndSortedBusNodes;
      _selectedNode = buses.isNotEmpty ? buses.first : null;
      if (_selectedNode != null && _selectedNode!.busNumber != null) {
        _busNumberEditController.text = _selectedNode!.busNumber.toString();
      } else {
        _busNumberEditController.clear();
      }
    });

    _announceReviewStage();
    // Automatically run AI vision grounding on all working buses (including human-added ones)
    _triggerAiBusLinking();
  }

  void _propagateBusNumber(
    ReviewNodeItem busNode,
    int newBusNo, {
    bool isDuplicate = false,
  }) {
    setState(() {
      final oldBusId = busNode.id;
      final existingWithSameId = _workingNodes.where(
        (n) => n.id == "bus_$newBusNo" && n != busNode,
      );
      final newBusId = existingWithSameId.isNotEmpty
          ? "bus_${newBusNo}_${busNode.displayNumber ?? (busNode.hashCode.abs() % 1000)}"
          : "bus_$newBusNo";

      busNode.id = newBusId;
      busNode.busNumber = newBusNo;
      busNode.busNumberStatus = isDuplicate ? 'UNCERTAIN' : 'VERIFIED';
      busNode.displayLabel = isDuplicate
          ? "Bus $newBusNo (중복)"
          : "Bus $newBusNo";

      // 1. Update line connections referencing the old bus ID
      for (final line in _workingLines) {
        for (int i = 0; i < line.connectedTo.length; i++) {
          if (line.connectedTo[i] == oldBusId) {
            line.connectedTo[i] = newBusId;
          }
        }
      }

      // 2. Propagate to all connected generators and loads via workingLines
      for (final line in _workingLines) {
        if (line.connectedTo.contains(newBusId)) {
          final otherId = line.connectedTo.first == newBusId
              ? (line.connectedTo.length > 1 ? line.connectedTo[1] : null)
              : line.connectedTo.first;
          if (otherId != null) {
            final otherNode = _workingNodes.firstWhere(
              (n) => n.id == otherId,
              orElse: () => busNode,
            );
            if (otherNode.id != busNode.id) {
              final cls = otherNode.className.toLowerCase();
              final oldOtherId = otherNode.id;
              if (cls.contains('gen')) {
                final newGenId = "gen_$newBusNo";
                otherNode.id = newGenId;
                otherNode.busNumber = newBusNo;
                otherNode.connectedBusNumber = newBusNo;
                otherNode.connectedBusId = newBusId;
                otherNode.displayLabel = "G_$newBusNo";

                for (final l in _workingLines) {
                  for (int i = 0; i < l.connectedTo.length; i++) {
                    if (l.connectedTo[i] == oldOtherId)
                      l.connectedTo[i] = newGenId;
                  }
                  if (l.connectedTo.contains(newBusId) &&
                      l.connectedTo.contains(newGenId)) {
                    l.lineId = "lead_${newBusId}_$newGenId";
                    l.displayLabel = "Line Bus $newBusNo ↔ G_$newBusNo";
                  }
                }
              } else if (cls.contains('load')) {
                final newLoadId = "load_$newBusNo";
                otherNode.id = newLoadId;
                otherNode.busNumber = newBusNo;
                otherNode.connectedBusNumber = newBusNo;
                otherNode.connectedBusId = newBusId;
                otherNode.displayLabel = "Load_$newBusNo";

                for (final l in _workingLines) {
                  for (int i = 0; i < l.connectedTo.length; i++) {
                    if (l.connectedTo[i] == oldOtherId)
                      l.connectedTo[i] = newLoadId;
                  }
                  if (l.connectedTo.contains(newBusId) &&
                      l.connectedTo.contains(newLoadId)) {
                    l.lineId = "lead_${newBusId}_$newLoadId";
                    l.displayLabel = "Line Bus $newBusNo ↔ Load_$newBusNo";
                  }
                }
              }
            }
          }
        }
      }
    });
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

        // 2. Selected Bus Detail Editor (Sequential 1-by-1 Focus Card)
        if (_selectedNode != null &&
            _selectedNode!.className.toLowerCase() == 'bus')
          _buildSelectedBusMappingCard(_selectedNode!)
        else if (buses.isNotEmpty)
          _buildSelectedBusMappingCard(buses.first)
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
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  key: _busWholeApproveKey,
                  onPressed: () {
                    setState(() {
                      final counts = <int, int>{};
                      for (var b in _busNodes) {
                        if (b.busNumber != null) {
                          counts[b.busNumber!] =
                              (counts[b.busNumber!] ?? 0) + 1;
                        }
                      }
                      int approvedCount = 0;
                      int skippedDups = 0;
                      for (var b in _busNodes) {
                        if (b.busNumber != null) {
                          if ((counts[b.busNumber!] ?? 0) == 1) {
                            b.busNumberStatus = 'VERIFIED';
                            _propagateBusNumber(b, b.busNumber!);
                            approvedCount++;
                          } else {
                            b.busNumberStatus = 'UNCERTAIN';
                            skippedDups++;
                          }
                        }
                      }
                      if (skippedDups > 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "중복 번호($skippedDups개)는 일괄 승인에서 제외되었습니다. 각각 고유 번호로 지정해 주세요.",
                            ),
                            backgroundColor: Colors.orange,
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "✓ $approvedCount개 모선 번호가 모두 승인되었습니다.",
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    });
                  },
                  icon: const Icon(Icons.done_all, size: 12),
                  label: const Text("전체 승인", style: TextStyle(fontSize: 10)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    side: const BorderSide(color: Color(0xFF93C5FD)),
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
              "검토 필요",
              _busUncertainCount,
              const Color(0xFFD97706),
              'UNCERTAIN',
            ),
            const SizedBox(width: 6),
            _buildBusFilterBadge(
              "승인 완료",
              _busVerifiedCount,
              const Color(0xFF16A34A),
              'VERIFIED',
            ),
          ],
        ),
      ],
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

  Widget _buildSelectedBusMappingCard(ReviewNodeItem busNode) {
    final isVerified = busNode.busNumberStatus == 'VERIFIED';
    final buses = _filteredAndSortedBusNodes;
    final currentIndex = buses.indexOf(busNode);
    final totalCount = buses.length;

    final connectedGens = <ReviewNodeItem>[];
    final connectedLoads = <ReviewNodeItem>[];

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
          if (other.id != busNode.id) {
            if (other.className.toLowerCase().contains('gen'))
              connectedGens.add(other);
            if (other.className.toLowerCase().contains('load'))
              connectedLoads.add(other);
          }
        }
      }
    }

    final candidates = <int>{};
    if (busNode.suggestedBusNumber != null)
      candidates.add(busNode.suggestedBusNumber!);
    if (busNode.busNumber != null) candidates.add(busNode.busNumber!);
    if (busNode.displayNumber != null) candidates.add(busNode.displayNumber!);
    final idDigits = RegExp(r'\d+')
        .allMatches(busNode.id)
        .map((m) => int.tryParse(m.group(0)!))
        .whereType<int>();
    candidates.addAll(idDigits);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isVerified ? const Color(0xFF86EFAC) : const Color(0xFFBFDBFE),
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
                "⚡ 모선 번호 확인 (순차 집중 모드)",
                style: TextStyle(
                  color: Color(0xFF334155),
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                totalCount > 0 ? "$totalCount개 중 ${currentIndex + 1}번째" : "",
                style: const TextStyle(
                  color: Color(0xFF2563EB),
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
                  ? ((currentIndex + 1) / totalCount).clamp(0.0, 1.0)
                  : 1.0,
              minHeight: 5,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF2563EB)),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Hero Bus Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isVerified
                    ? const Color(0xFF86EFAC)
                    : const Color(0xFFBFDBFE),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      (isVerified
                              ? const Color(0xFF16A34A)
                              : const Color(0xFF2563EB))
                          .withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isVerified
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.numbers_rounded,
                    color: isVerified
                        ? const Color(0xFF16A34A)
                        : const Color(0xFF2563EB),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        busNode.busNumber != null
                            ? "Bus #${busNode.busNumber}"
                            : "Bus 번호 미지정",
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        "도면 객체 ID: ${busNode.id} · ${isVerified ? '✓ 승인 완료' : '⚠️ 확인 필요'}",
                        style: TextStyle(
                          color: isVerified
                              ? const Color(0xFF16A34A)
                              : const Color(0xFFD97706),
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. OCR Candidates Chips
          if (candidates.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  "추천 번호: ",
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ...candidates.map(
                  (cand) => ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      "#$cand",
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    backgroundColor: const Color(0xFFEFF6FF),
                    side: const BorderSide(color: Color(0xFF93C5FD)),
                    onPressed: () {
                      _busNumberEditController.text = cand.toString();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],

          // 4. Bus Number Input Field
          SizedBox(
            height: 38,
            child: TextField(
              controller: _busNumberEditController,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                labelText: "모선 번호 (Bus Number)",
                labelStyle: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 11,
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: Color(0xFF2563EB),
                    width: 1.5,
                  ),
                ),
              ),
              onSubmitted: (_) => _approveAndNextBus(busNode),
            ),
          ),
          const SizedBox(height: 10),

          // 5. Big Primary Action CTA
          GlowingTargetWrapper(
            targetId: 'bus_input',
            borderRadius: BorderRadius.circular(8),
            guideLabel: "✨ 승인하고 다음 모선으로",
            child: ElevatedButton.icon(
              key: _busPrimaryActionKey,
              onPressed: () => _approveAndNextBus(busNode),
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text(
                "승인하고 다음 모선으로 (Enter ➔)",
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 6. Secondary Navigation Row
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectPreviousBus,
                  icon: const Icon(Icons.arrow_back, size: 13),
                  label: const Text("이전 (◀)", style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: _skipAndNextBus,
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
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectNextBus,
                  icon: const Icon(Icons.arrow_forward, size: 13),
                  label: const Text("다음 (▶)", style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 7. Connected Devices Summary
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "⚡ 직결된 발전기/부하 명명 현황:",
                  style: TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                if (connectedGens.isEmpty && connectedLoads.isEmpty)
                  const Text(
                    "• 직결된 발전기/부하 없음 (단독 모선)",
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                  )
                else ...[
                  if (connectedGens.isNotEmpty)
                    Text(
                      "• 발전기: ${connectedGens.map((g) => g.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(
                        color: Color(0xFF16A34A),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (connectedLoads.isNotEmpty)
                    Text(
                      "• 부하: ${connectedLoads.map((l) => l.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(
                        color: Color(0xFF0284C7),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBusMappingListItem(ReviewNodeItem busNode) {
    final isSelected = _selectedNode?.id == busNode.id;
    final isDuplicate =
        busNode.busNumber != null &&
        _duplicateBusNumbers.contains(busNode.busNumber);
    final isVerified =
        busNode.busNumberStatus == 'VERIFIED' &&
        busNode.busNumber != null &&
        !isDuplicate;

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
                isDuplicate ? "중복 번호" : (isVerified ? "승인됨" : "검토필요"),
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
      final bool isSlack = node.metadata['is_slack'] == true ||
          node.metadata['isSlack'] == true ||
          (node.displayLabel?.toLowerCase().contains('slack') ?? false);
      collected.add({
        'id': node.id,
        'type': cls,
        'class': cls,
        'label': node.effectiveDisplayLabel,
        'bus_number': node.connectedBusNumber ?? node.busNumber ?? node.displayNumber,
        'connected_bus_number': node.connectedBusNumber ?? node.busNumber,
        'parentBusId': node.connectedBusId,
        'is_slack': isSlack,
        'isSlack': isSlack,
      });
    }

    for (var line in lines) {
      collected.add({
        'id': line.lineId,
        'type': 'line',
        'connected_to': line.connectedTo,
        'startElementId': line.connectedTo.isNotEmpty ? line.connectedTo[0] : null,
        'endElementId': line.connectedTo.length > 1 ? line.connectedTo[1] : null,
        'label': line.displayLabel ?? '',
        'endpoints_display': line.endpointsDisplay ?? '',
      });
    }

    return collected;
  }

  Future<void> _validateAndSetExcelData(Map<String, dynamic> excelData) async {
    Map<String, dynamic>? mismatchReport;
    try {
      final reviewElements = _collectCurrentReviewElements();
      final uri = Uri.parse('http://127.0.0.1:8000/apply_excel_to_elements');
      final applyRes = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'elements': reviewElements,
          'excel_data': excelData,
        }),
      );
      if (applyRes.statusCode == 200) {
        final resJson = jsonDecode(applyRes.body);
        mismatchReport = (resJson['mismatch_report'] ?? resJson['summary']?['mismatch_report']) as Map<String, dynamic>?;
      }
    } catch (e) {
      debugPrint("Review apply_excel_to_elements call error: $e");
    }

    setState(() {
      _importedExcelData = excelData;
      _excelMismatchReport = mismatchReport;
      _isLoading = false;
    });

    if (!mounted) return;

    if (mismatchReport != null && mismatchReport['is_matched'] == false) {
      ScaffoldMessenger.of(context).clearSnackBars();
      _showReviewMismatchDialog();
    } else {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ 엑셀 데이터 매칭 성공 (도면과 완벽 일치)!\n• 슬랙 모선: #${excelData['slack_bus_number'] ?? '자동'}\n• 모선: ${excelData['total_buses'] ?? 0}개, 발전기: ${excelData['total_generators'] ?? 0}개, 선로: ${excelData['total_branches'] ?? 0}개",
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
          showCloseIcon: true,
          closeIconColor: Colors.white,
        ),
      );
    }
  }

  void _showReviewMismatchDialog() {
    if (_excelMismatchReport == null || _importedExcelData == null) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ExcelMismatchDialog(
        mismatchReport: _excelMismatchReport!,
        excelData: _importedExcelData!,
        elements: _collectCurrentReviewElements(),
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
            const SnackBar(
              content: Text("캔버스 편집 화면으로 이동하여 누락 요소를 자동 동기화합니다."),
              backgroundColor: Colors.teal,
              showCloseIcon: true,
              closeIconColor: Colors.white,
              duration: Duration(seconds: 3),
            ),
          );
          _handoffToFlutterCanvas();
        },
      ),
    );
  }

  Future<void> _loadDefaultExcelInReview() async {
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
          SnackBar(content: Text("기본 엑셀 불러오기 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _importExcelInReview() async {
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
      // Step 1: Object Review
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Column(
          children: [
            CheckboxListTile(
              value: _canVerifyObjectGate,
              onChanged: null,
              title: Text(
                _canVerifyObjectGate
                    ? "✓ 전체 도면 대조 및 모든 객체 승인 완료 (Gate 통과 가능)"
                    : (_unconfirmedNodesCount > 0
                        ? "대기 중인 정상 객체 ${_unconfirmedNodesCount}개 승인 필요 (우측 일괄 승인)"
                        : "원본 회로도 대조 확인 대기 중"),
                style: TextStyle(
                  color: _canVerifyObjectGate
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF0F172A),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: const Color(0xFF2563EB),
            ),
            if (_objSuspiciousCount > 0)
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
                        "검토가 필요한 객체 $_objSuspiciousCount개가 남아 있습니다.",
                        style: const TextStyle(
                          color: Color(0xFF991B1B),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _objFilterStatus = 'SUSPICIOUS';
                          _selectedNode = _workingNodes.firstWhere(
                            (n) => n.reviewStatus == 'SUSPICIOUS',
                            orElse: () => _workingNodes.first,
                          );
                        });
                      },
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
              ),
            if (_objectGateBlockers.isNotEmpty && _objSuspiciousCount == 0)
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
            const SizedBox(height: 6),
            Row(
              children: [
                if (_objSuspiciousCount > 0)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFED7AA)),
                      ),
                      child: const Text(
                        'Lensy가 검토 필요 객체를 먼저 보여드리고 있어요.\n'
                        '모든 항목을 승인하거나 제외하면 다음 단계 버튼이 나타납니다.',
                        style: TextStyle(
                          color: Color(0xFF9A3412),
                          fontSize: 11,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: GlowingTargetWrapper(
                      targetId: 'object_gate',
                      borderRadius: BorderRadius.circular(8),
                      guideLabel: "✨ 객체 검수 완료",
                      child: ElevatedButton.icon(
                        onPressed: _canVerifyObjectGate
                            ? _verifyObjectGate
                            : () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '아직 완료할 항목: ${_objectGateBlockers.join(', ')}',
                                    ),
                                    backgroundColor: Colors.orange,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.check_circle_outline, size: 16),
                        label: const Text("객체 검수 완료"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _canVerifyObjectGate
                              ? const Color(0xFF2563EB)
                              : const Color(0xFF94A3B8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                if (_isObjectVerified) ...[
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _proceedToBusMappingReview,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text("다음: 모선 번호 매핑 ➔"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
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
                  child: GlowingTargetWrapper(
                    targetId: 'bus_gate',
                    borderRadius: BorderRadius.circular(8),
                    guideLabel: "✨ 모선 번호 승인",
                    child: ElevatedButton.icon(
                      onPressed: _canVerifyBusGate ? _proceedToConnectionReview : null,
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text("모선 번호 승인 ➔ 다음: 선로 결선 인식 및 검수"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
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
                  label: const Text("결선 검수 완료 ➔ 다음: 최종 확인 & 엑셀"),
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
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Container(
          width: 680,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF86EFAC),
              width: 2,
            ),
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
                "Verified SLD 회로도 검증 완료! 🎉",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
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
                    _buildFinalSummaryItem("확정 모선", "${_busNodes.length}개", const Color(0xFF2563EB)),
                    _buildFinalSummaryItem("확정 결선", "${sld.lines.length}개", const Color(0xFFEA580C)),
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
                    color: _importedExcelData != null
                        ? ((_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
                            ? const Color(0xFFF87171)
                            : const Color(0xFF86EFAC))
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
                              color: (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false)
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
                                  icon: const Icon(Icons.auto_stories, size: 14),
                                  label: const Text("기본 25모선 엑셀", style: TextStyle(fontSize: 11)),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                                      ? "다른 엑셀 다시 불러오기"
                                      : "엑셀 파일 선택",
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
                      if (_excelMismatchReport != null && _excelMismatchReport!['is_matched'] == false) ...[
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
                                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 20),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "⚠️ 도면과 엑셀 데이터가 일치하지 않습니다!",
                                    style: TextStyle(color: Color(0xFF991B1B), fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const Spacer(),
                                  GlowingTargetWrapper(
                                    targetId: 'excel_mismatch_btn',
                                    borderRadius: BorderRadius.circular(6),
                                    guideLabel: "✨ AI 진단 & 세부비교",
                                    child: TextButton.icon(
                                      onPressed: _showReviewMismatchDialog,
                                      icon: const Icon(Icons.auto_awesome, size: 14, color: Color(0xFF4F46E5)),
                                      label: const Text(
                                        "AI 진단 & 세부비교 보기",
                                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5)),
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        backgroundColor: const Color(0xFFEEF2FF),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "• ${_excelMismatchReport!['summary'] ?? '도면과 엑셀 사양이 일치하지 않습니다.'}",
                                style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 11.5, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "• 도면: 모선 ${_busNodes.length}개, 결선 ${sld.lines.length}개  |  엑셀: 모선 ${_importedExcelData!['total_buses'] ?? 0}개, 선로 ${_importedExcelData!['total_branches'] ?? 0}개",
                                style: const TextStyle(color: Color(0xFF7F1D1D), fontSize: 11),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _confirmResetToBeginning,
                                    icon: const Icon(Icons.restart_alt, size: 14, color: Color(0xFFDC2626)),
                                    label: const Text(
                                      "다시 검수 처음으로 돌아가기",
                                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFFDC2626)),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      side: const BorderSide(color: Color(0xFFFCA5A5)),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                                      ScaffoldMessenger.of(context).clearSnackBars();
                                    },
                                    icon: const Icon(Icons.link_off, size: 14, color: Color(0xFF64748B)),
                                    label: const Text(
                                      "엑셀 연결 해제",
                                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                    ),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                                  const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 18),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "계통 엑셀 데이터 매칭 완료 (도면과 완벽 일치)",
                                    style: TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                "• 슬랙 모선: #${_importedExcelData!['slack_bus_number'] ?? '자동'}  |  모선: ${_importedExcelData!['total_buses'] ?? 0}개  |  발전기: ${_importedExcelData!['total_generators'] ?? 0}개  |  선로/변압기: ${_importedExcelData!['total_branches'] ?? 0}개",
                                style: const TextStyle(color: Color(0xFF166534), fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ] else ...[
                      Text(
                        "💡 계통 제원 엑셀(.xlsx) 파일을 불러오면 슬랙 모선과 발전기/부하/선로 파라미터가 캔버스에 자동 반영됩니다.",
                        style: TextStyle(color: Colors.grey[600], fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlowingTargetWrapper(
                    targetId: 'final_canvas_handoff',
                    borderRadius: BorderRadius.circular(8),
                    guideLabel: "✨ 캔버스로 이동",
                    child: ElevatedButton.icon(
                      key: _finalCanvasHandoffKey,
                      onPressed: _handoffToFlutterCanvas,
                      icon: const Icon(Icons.open_in_new),
                      label: Text(
                        _importedExcelData != null
                            ? "엑셀 데이터 적용하여 캔버스로 이동"
                            : "캔버스 편집 화면으로 이동",
                        style: const TextStyle(
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
          // Auto select first matching line
          final matches = _filteredAndSortedWorkingLines;
          if (matches.isNotEmpty) {
            _selectedLine = matches.first;
          }
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

  Widget _buildStatBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.0),
      ),
      child: Text(
        "$label: $count",
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
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
                    fontWeight: hasCandidates ? FontWeight.bold : FontWeight.normal,
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
    final openCands = _missingCandidates.where((c) => c.status == 'OPEN').toList();
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
              const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFF9333EA)),
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

  void _showMissingCandidatesDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final openCands = _missingCandidates
              .where((c) => c.status == 'OPEN')
              .toList();
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
                          ...openCands.map(
                            (c) => Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFAF5FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFD8B4FE),
                                  width: 1.2,
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
                                            PowerLensAIService.instance
                                                .triggerHighlight(
                                                  'object_gate',
                                                );
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
                            ),
                          ),
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
