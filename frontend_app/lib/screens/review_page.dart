import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import '../models/review_models.dart';
import '../services/review_api_service.dart';
import '../widgets/review_overlay.dart';

enum ReviewPhase { objectReview, connectionReview, busMappingReview, verifiedFinal }

enum RightPanelTab { detailReview, agentActivity, agentChat }

class ObjectReviewPage extends StatefulWidget {
  final Function(Map<String, dynamic> verifiedSldData)? onProceedToCanvas;

  const ObjectReviewPage({super.key, this.onProceedToCanvas});

  @override
  State<ObjectReviewPage> createState() => _ObjectReviewPageState();
}

class _ObjectReviewPageState extends State<ObjectReviewPage> {
  final ReviewApiService _apiService = ReviewApiService();

  ReviewPhase _currentPhase = ReviewPhase.objectReview;
  RightPanelTab _activeRightTab = RightPanelTab.detailReview;

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
  static const int _nodePageSize = 12;
  int _nodePage = 0;
  static const int _linePageSize = 16;
  int _linePage = 0;

  // Bus Number Mapping Review (Phase 3)
  String _busFilterStatus = 'ALL'; // ALL, UNCERTAIN, VERIFIED
  int _busPage = 0;
  static const int _busPageSize = 12;
  final TextEditingController _busNumberEditController = TextEditingController();
  Map<String, dynamic>? _importedExcelData;

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

  bool get _canVerifyObjectGate =>
      _objSuspiciousCount == 0 &&
      _unresolvedCandidatesCount == 0 &&
      _humanCompletenessConfirmed &&
      _workingNodes.where((n) => n.reviewStatus != 'REJECTED').isNotEmpty;

  List<String> get _objectGateBlockers {
    final blockers = <String>[];
    if (_objSuspiciousCount > 0) {
      blockers.add('검토 필요 객체 $_objSuspiciousCount개 승인 또는 제외');
    }
    if (_unresolvedCandidatesCount > 0) {
      blockers.add('누락 후보 $_unresolvedCandidatesCount개 복구 또는 문제없음 처리');
    }
    if (!_humanCompletenessConfirmed) {
      blockers.add('원본 회로도 대조 확인 체크');
    }
    if (_workingNodes.where((n) => n.reviewStatus != 'REJECTED').isEmpty) {
      blockers.add('사용 가능한 객체가 없음');
    }
    return blockers;
  }

  // Statistics (Bus Number Mapping)
  List<ReviewNodeItem> get _busNodes => _workingNodes
      .where((n) => n.className.toLowerCase() == 'bus' && n.reviewStatus != 'REJECTED')
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
        .where((n) => n.busNumberStatus != 'VERIFIED' || n.busNumber == null || dups.contains(n.busNumber))
        .length;
  }

  int get _busVerifiedCount {
    final dups = _duplicateBusNumbers;
    return _busNodes
        .where((n) => n.busNumberStatus == 'VERIFIED' && n.busNumber != null && !dups.contains(n.busNumber))
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
      blockers.add('중복된 모선 번호(${dups.map((n) => "#$n").join(", ")})가 존재합니다. 각각 고유한 번호로 수정해 주세요.');
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
      list = list.where((n) => n.busNumberStatus != 'VERIFIED' || n.busNumber == null || dups.contains(n.busNumber)).toList();
    } else if (_busFilterStatus == 'VERIFIED') {
      list = list.where((n) => n.busNumberStatus == 'VERIFIED' && n.busNumber != null && !dups.contains(n.busNumber)).toList();
    }
    list.sort((a, b) {
      final aIsUncertain = a.busNumberStatus != 'VERIFIED' || a.busNumber == null || dups.contains(a.busNumber);
      final bIsUncertain = b.busNumberStatus != 'VERIFIED' || b.busNumber == null || dups.contains(b.busNumber);
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

  bool get _canVerifyFinalGate =>
      _lineAmbiguousCount == 0 &&
      _criticalIssuesCount == 0 &&
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

    return list;
  }

  @override
  void dispose() {
    _chatInputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  // --- Step 1: Upload & Object Detection ---

  Future<void> _pickAndUploadImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;

      final Uint8List bytes = await file.readAsBytes();
      final String filename = file.name;

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
        _chatHistory.clear();
      });

      final doc = await _apiService.detectObjects(bytes, filename);

      setState(() {
        _document = doc;
        _workingNodes = List.from(doc.nodes);

        if (_workingNodes.isNotEmpty) {
          _selectedNode = _workingNodes.firstWhere(
            (n) => n.reviewStatus == 'SUSPICIOUS',
            orElse: () => _workingNodes.first,
          );
        }
        _isLoading = false;

        // Greeting and Proactive Summary in Chat
        final summaryMsg =
            doc.proactiveSummary?.summaryText ??
            "안녕하세요! VisionFlow 로컬 도면 어시스턴트입니다.\n도면 검수 상태, 선택 객체/선로의 판정 근거, 누락 후보 등을 로컬 분석 모드로 즉시 안내해 드립니다.";

        _chatHistory.add(
          ChatMessageItem(
            role: "assistant",
            text: summaryMsg,
            agentStatus: "LOCAL_READY",
          ),
        );
      });

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
          SnackBar(content: Text("업로드 실패: $e"), backgroundColor: Colors.red),
        );
      }
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
        node.agentExplanation =
            (res['explanation_ko'] ?? res['message_ko'])?.toString();
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

  void _confirmNode(ReviewNodeItem node) {
    setState(() {
      node.reviewStatus = 'CONFIRMED';
      node.source = '${node.source}_human_confirmed';
    });
    _selectNextSuspiciousNode();
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
    setState(() {
      for (var node in _workingNodes) {
        if (node.reviewStatus == 'DETECTED') {
          node.reviewStatus = 'CONFIRMED';
          node.source = '${node.source}_auto_confirmed';
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("정상 객체들이 일괄 승인되었습니다."),
        backgroundColor: Colors.teal,
      ),
    );
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
    if (suspicious.isEmpty) return;

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
    if (suspicious.isEmpty) return;

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
    if (_workingNodes.isEmpty) return;
    int currentIdx = _selectedNode != null
        ? _workingNodes.indexOf(_selectedNode!)
        : 0;
    int prevIdx =
        (currentIdx - 1 + _workingNodes.length) % _workingNodes.length;
    setState(() {
      _selectedNode = _workingNodes[prevIdx];
    });
  }

  void _selectNextNode() {
    if (_workingNodes.isEmpty) return;
    int currentIdx = _selectedNode != null
        ? _workingNodes.indexOf(_selectedNode!)
        : 0;
    int nextIdx = (currentIdx + 1) % _workingNodes.length;
    setState(() {
      _selectedNode = _workingNodes[nextIdx];
    });
  }

  void _editNodeDisplayLabel(ReviewNodeItem node) {
    final controller = TextEditingController(text: node.effectiveDisplayLabel);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252538),
        title: Text(
          "${node.id} 표시명 / 번호 수정",
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "도면의 실제 번호와 일치하도록 표시명을 수정하세요:",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "표시 이름 (예: BUS 4, LOAD 2)",
                labelStyle: TextStyle(color: Colors.blueAccent),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            child: const Text("저장", style: TextStyle(color: Colors.white)),
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

  // --- Step 3: Object Gate Verification ---

  Future<void> _verifyObjectGate() async {
    if (_document == null) return;

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
        humanCompletenessConfirmed: _humanCompletenessConfirmed,
      );

      setState(() {
        _isLoading = false;
        _isObjectVerified = res['gate_status'] == 'OBJECT_VERIFIED';
        _objectGateMessage = res['message']?.toString();
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
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("단계 검증 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Step 4: Connection Detection ---

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

    setState(() {
      _isLoading = true;
      _loadingMessage = "확정 객체 기반 결선 인식 중... 🔗";
      _connFilterStatus = 'ALL';
      _linePage = 0;
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

      setState(() {
        _currentPhase = ReviewPhase.connectionReview;
        _workingLines = parsedLines;
        _selectedLine = _workingLines.isNotEmpty ? _workingLines.first : null;
        _selectedNode = null;
        _isLoading = false;
      });

      _triggerTopologyValidation();
    } catch (e) {
      setState(() => _isLoading = false);
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

  void _confirmLine(ReviewLineItem line) {
    setState(() {
      line.reviewStatus = 'CONFIRMED';
      line.source = '${line.source}_human_confirmed';
    });
    _triggerTopologyValidation();
  }

  void _rejectLine(ReviewLineItem line) {
    setState(() {
      _workingLines.removeWhere((item) => item.lineId == line.lineId);
      final remainingVisible = _filteredAndSortedWorkingLines;
      final pageCount = remainingVisible.isEmpty
          ? 1
          : (remainingVisible.length / _linePageSize).ceil();
      if (_linePage >= pageCount) _linePage = pageCount - 1;
      _selectedLine = remainingVisible.isNotEmpty
          ? remainingVisible.first
          : null;
      _isFinalVerified = false;
    });
    _triggerTopologyValidation();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${line.effectiveDisplayLabel} 선로를 삭제했습니다.'),
        backgroundColor: Colors.red.shade700,
      ),
    );
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

    setState(() {
      _isLoading = true;
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
        if (res['verified_sld'] != null) {
          _verifiedSld = VerifiedSLD.fromJson(
            res['verified_sld'] as Map<String, dynamic>,
          );
          _currentPhase = ReviewPhase.verifiedFinal;
        }
      });
    } catch (e) {
      setState(() => _isLoading = false);
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
    }
    widget.onProceedToCanvas?.call(data);
    if (Navigator.canPop(context)) {
      Navigator.pop(context, data);
    }
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
          : (_currentPhase == ReviewPhase.connectionReview
                ? "CONNECTION_REVIEW"
                : "FINAL");

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

      setState(() {
        _chatHistory.add(
          ChatMessageItem(
            role: "assistant",
            text: reply,
            agentStatus: agentStatus,
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
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        toolbarHeight: 42,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt, color: Colors.blueAccent, size: 20),
              const SizedBox(width: 6),
              Text(
                _currentPhase == ReviewPhase.objectReview
                    ? "PowerLens AI 도면 검수 · ① 객체 검수"
                    : _currentPhase == ReviewPhase.busMappingReview
                    ? "PowerLens AI 도면 검수 · ② 모선 번호 매핑"
                    : _currentPhase == ReviewPhase.connectionReview
                    ? "PowerLens AI 도면 검수 · ③ 선로 결선 검수"
                    : "PowerLens AI 도면 검수 · ④ 최종 확인 & 엑셀",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              ),
            ],
          ),
        ),
        backgroundColor: const Color(0xFF181825),
        foregroundColor: Colors.white,
        elevation: 1,
        actions: [
          // Step Badges
          _buildPhaseBadge(
            "① 객체 검수",
            _currentPhase == ReviewPhase.objectReview,
            _isObjectVerified,
          ),
          const Icon(Icons.arrow_right, color: Colors.grey, size: 14),
          _buildPhaseBadge(
            "② 모선 매핑",
            _currentPhase == ReviewPhase.busMappingReview,
            _canVerifyBusGate,
          ),
          const Icon(Icons.arrow_right, color: Colors.grey, size: 14),
          _buildPhaseBadge(
            "③ 결선 검수",
            _currentPhase == ReviewPhase.connectionReview,
            _workingLines.isNotEmpty && _lineAmbiguousCount == 0,
          ),
          const Icon(Icons.arrow_right, color: Colors.grey, size: 14),
          _buildPhaseBadge(
            "④ 최종 & 엑셀",
            _currentPhase == ReviewPhase.verifiedFinal,
            _isFinalVerified,
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _importExcelInReview,
            icon: const Icon(Icons.table_chart, size: 14, color: Colors.greenAccent),
            label: Text(
              _importedExcelData != null ? "엑셀 적용됨 (#${_importedExcelData!['slack_bus_number']})" : "엑셀 불러오기",
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal[800],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: _pickAndUploadImage,
            icon: const Icon(Icons.file_upload, size: 15),
            label: const Text("도면 이미지 업로드", style: TextStyle(fontSize: 11)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          _document == null
              ? _buildEmptyUploadArea()
              : _currentPhase == ReviewPhase.verifiedFinal
              ? _buildVerifiedFinalView()
              : _buildMainReviewView(),
          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.65),
              child: Center(
                child: Card(
                  color: const Color(0xFF252538),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: Colors.blueAccent,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _loadingMessage ?? "처리 중...",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPhaseBadge(String label, bool isCurrent, bool isCompleted) {
    Color bg = const Color(0xFF252538);
    Color text = Colors.grey;
    if (isCompleted) {
      bg = Colors.green.withValues(alpha: 0.2);
      text = Colors.greenAccent;
    } else if (isCurrent) {
      bg = Colors.blueAccent.withValues(alpha: 0.25);
      text = Colors.blueAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
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
  }

  Widget _buildEmptyUploadArea() {
    return Center(
      child: GestureDetector(
        onTap: _pickAndUploadImage,
        child: Container(
          width: 550,
          height: 320,
          decoration: BoxDecoration(
            color: const Color(0xFF252538),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.blueAccent.withValues(alpha: 0.5),
              width: 2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                size: 72,
                color: Colors.blueAccent,
              ),
              const SizedBox(height: 16),
              const Text(
                "전력계통 단선도(SLD) 이미지를 업로드하세요",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "객체 확인 → 결선 확인 → 전기 검증 → 회로도 생성",
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _pickAndUploadImage,
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text("도면 파일 선택"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Proactive AI Summary Top Banner ---

  String get _nextReviewActionText {
    if (_currentPhase == ReviewPhase.objectReview) {
      if (_objSuspiciousCount > 0) {
        return '신뢰도가 낮은 객체 $_objSuspiciousCount개를 승인하거나 제외하세요.';
      }
      if (_unresolvedCandidatesCount > 0) {
        return '누락 후보 $_unresolvedCandidatesCount개를 복구하거나 문제없음 처리하세요.';
      }
      if (!_humanCompletenessConfirmed) {
        return '원본 도면과 객체 목록이 일치하는지 확인해 주세요.';
      }
      return '객체 검수가 끝났습니다. 결선 검수로 이동할 수 있습니다.';
    }
    if (_lineAmbiguousCount > 0) {
      return '판단이 필요한 결선 $_lineAmbiguousCount개를 확인하세요.';
    }
    if (_criticalIssuesCount > 0) {
      return '전기적 오류 $_criticalIssuesCount건을 먼저 해결하세요.';
    }
    return '결선 검수가 끝났습니다. 최종 회로도를 생성할 수 있습니다.';
  }

  void _focusNextReviewTask() {
    final needsCompletenessCheck =
        _currentPhase == ReviewPhase.objectReview &&
        _objSuspiciousCount == 0 &&
        _unresolvedCandidatesCount == 0 &&
        !_humanCompletenessConfirmed;
    setState(() {
      _activeRightTab = RightPanelTab.detailReview;
      if (_currentPhase == ReviewPhase.objectReview) {
        final suspicious = _workingNodes
            .where((node) => node.reviewStatus == 'SUSPICIOUS')
            .toList();
        if (suspicious.isNotEmpty) {
          _objFilterStatus = 'SUSPICIOUS';
          _objFilterClass = 'ALL';
          _selectedNode = suspicious.first;
        }
      } else {
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

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF202437),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.blueAccent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.blueAccent,
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
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  isObjectPhase ? '객체 인식 검수' : '결선 및 전기 검수',
                  style: const TextStyle(color: Colors.white54, fontSize: 8.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _buildAiMetric('자동 승인', autoConfirmedCount, Colors.greenAccent),
          const SizedBox(width: 4),
          _buildAiMetric(
            '검토 필요',
            isObjectPhase ? _objSuspiciousCount : _lineAmbiguousCount,
            Colors.orangeAccent,
            icon: Icons.warning_amber_rounded,
          ),
          const SizedBox(width: 4),
          _buildAiMetric(
            isObjectPhase ? '누락 후보' : '전기 오류',
            isObjectPhase ? _unresolvedCandidatesCount : _criticalIssuesCount,
            isObjectPhase ? Colors.purpleAccent : Colors.redAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _nextReviewActionText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 10.5),
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: hasNextTask ? _focusNextReviewTask : null,
            icon: Icon(
              hasNextTask ? Icons.arrow_forward_rounded : Icons.check_rounded,
              size: 13,
            ),
            label: Text(hasNextTask ? '다음 검토' : '정리 완료', style: const TextStyle(fontSize: 10.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.blueAccent,
              side: BorderSide(color: Colors.blueAccent.withValues(alpha: 0.5)),
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
                      color: const Color(0xFF181825),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text(
                              "도면 해상도: ${_document!.image.width} × ${_document!.image.height} px",
                              style: const TextStyle(
                                color: Colors.grey,
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
                                    ? Colors.white
                                    : Colors.grey,
                              ),
                              label: Text(
                                _showCanvasLabels ? "라벨 표시" : "라벨 숨김",
                                style: TextStyle(
                                  color: _showCanvasLabels
                                      ? Colors.white
                                      : Colors.grey,
                                  fontSize: 10.5,
                                ),
                              ),
                              selected: _showCanvasLabels,
                              onSelected: (val) =>
                                  setState(() => _showCanvasLabels = val),
                              selectedColor: Colors.blueAccent.withValues(
                                alpha: 0.35,
                              ),
                              backgroundColor: const Color(0xFF252538),
                              side: BorderSide(
                                color: _showCanvasLabels
                                    ? Colors.blueAccent
                                    : Colors.grey.withValues(alpha: 0.4),
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
                                  color: Colors.grey,
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
                                  color: Colors.grey,
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
                                  color: Colors.orangeAccent,
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
                                  color: Colors.orangeAccent,
                                ),
                                tooltip: "다음 의심 객체",
                                visualDensity: VisualDensity.compact,
                                onPressed: _objSuspiciousCount == 0
                                    ? null
                                    : _selectNextSuspiciousNode,
                              ),
                              const SizedBox(width: 6),
                              if (_objDetectedCount > 0)
                                ElevatedButton.icon(
                                  onPressed: _batchConfirmCleanDetectedNodes,
                                  icon: const Icon(Icons.done_all, size: 13),
                                  label: Text(
                                    "정상 객체 승인 ($_objDetectedCount)",
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.teal.shade800,
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
                                  _isManualAddMode
                                      ? "객체 드래그 추가 중..."
                                      : "➕ 객체 추가",
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                selected: _isManualAddMode,
                                onSelected: (val) =>
                                    setState(() => _isManualAddMode = val),
                                selectedColor: Colors.purpleAccent.withValues(
                                  alpha: 0.35,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              if (_isManualAddMode) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF252538),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                                  ),
                                  child: DropdownButton<String>(
                                    value: _manualAddClass,
                                    dropdownColor: const Color(0xFF252538),
                                    isDense: true,
                                    underline: const SizedBox.shrink(),
                                    style: const TextStyle(
                                      color: Colors.white,
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
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.teal.shade800,
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
                                selectedColor: Colors.purpleAccent.withValues(
                                  alpha: 0.35,
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
                        color: Colors.black,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ReviewOverlayView(
                                imageBytes: _document!.rawBytes,
                                imageUrl: _apiService.getOriginalImageUrl(
                                  _document!.documentId,
                                ),
                                originalWidth: _document!.image.width,
                                originalHeight: _document!.image.height,
                                nodes: (_currentPhase == ReviewPhase.objectReview)
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
                                lines: (_currentPhase == ReviewPhase.objectReview)
                                    ? const []
                                    : _workingLines,
                                selectedLine: _selectedLine,
                                onSelectLine: (line) {
                                  setState(() {
                                    _selectedLine = line;
                                    final index = _filteredAndSortedWorkingLines
                                        .indexWhere(
                                          (item) => item.lineId == line.lineId,
                                        );
                                    if (index >= 0)
                                      _linePage = index ~/ _linePageSize;
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
                                onManualAddLineComplete: _handleManualAddLineComplete,
                              ),
                            ),
                            // Floating HUD on Canvas: Direct Label Toggle
                            Positioned(
                              top: 10,
                              right: 12,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => setState(() => _showCanvasLabels = !_showCanvasLabels),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E1E2E).withValues(alpha: 0.9),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: _showCanvasLabels ? Colors.blueAccent : Colors.orangeAccent,
                                        width: 1.2,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black54,
                                          blurRadius: 4,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _showCanvasLabels ? Icons.visibility : Icons.visibility_off,
                                          size: 14,
                                          color: _showCanvasLabels ? Colors.blueAccent : Colors.orangeAccent,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          _showCanvasLabels ? "라벨 숨기기" : "라벨 보이기",
                                          style: TextStyle(
                                            color: _showCanvasLabels ? Colors.white : Colors.orangeAccent,
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
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const VerticalDivider(width: 1, color: Colors.black),

              // Right Column: Tabbed Panel (Detail Review vs Agent Chat)
              Expanded(
                flex: 35,
                child: Container(
                  color: const Color(0xFF181825),
                  child: Column(
                    children: [
                      // Panel Tab Header
                      _buildRightPanelHeader(),
                      Expanded(
                        child: _activeRightTab == RightPanelTab.detailReview
                            ? SingleChildScrollView(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    _currentPhase == ReviewPhase.busMappingReview
                                        ? _buildBusMappingReviewSidePanel()
                                        : isConnectionPhase
                                        ? _buildConnectionReviewSidePanel()
                                        : _buildObjectReviewSidePanel(),
                                    const SizedBox(height: 12),
                                    const Divider(color: Colors.white24, height: 1),
                                    _buildBottomGateFooter(),
                                  ],
                                ),
                              )
                            : (_activeRightTab == RightPanelTab.agentActivity
                                ? _buildAgentActivitySidePanel()
                                : _buildAgentChatSidePanel()),
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
      color: const Color(0xFF1E1E2E),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<RightPanelTab>(
              segments: const [
                ButtonSegment(
                  value: RightPanelTab.detailReview,
                  label: Text("검수", style: TextStyle(fontSize: 11)),
                  icon: Icon(Icons.fact_check_outlined, size: 14),
                ),
                ButtonSegment(
                  value: RightPanelTab.agentActivity,
                  label: Text("활동기록", style: TextStyle(fontSize: 11)),
                  icon: Icon(Icons.history_edu, size: 14),
                ),
                ButtonSegment(
                  value: RightPanelTab.agentChat,
                  label: Text("AI도우미", style: TextStyle(fontSize: 11)),
                  icon: Icon(Icons.chat_bubble_outline, size: 14),
                ),
              ],
              selected: {_activeRightTab},
              onSelectionChanged: (set) {
                final selectedTab = set.first;
                setState(() => _activeRightTab = selectedTab);
                if (selectedTab == RightPanelTab.agentActivity) {
                  _fetchAgentRuns();
                }
              },
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: Colors.blueAccent.withValues(
                  alpha: 0.3,
                ),
                selectedForegroundColor: Colors.white,
                foregroundColor: Colors.grey,
              ),
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
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              // Sort dropdown
              DropdownButton<String>(
                value: _objSortOption,
                dropdownColor: const Color(0xFF252538),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'SEVERITY', child: Text("정렬: 위험도순")),
                  DropdownMenuItem(
                    value: 'CONFIDENCE_ASC',
                    child: Text("정렬: 신뢰도낮은순"),
                  ),
                  DropdownMenuItem(value: 'ID_ASC', child: Text("정렬: ID순")),
                ],
                onChanged: (val) =>
                    setState(() => _objSortOption = val ?? 'SEVERITY'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterableStatBadge(
                  "전체 보기",
                  _workingNodes.length,
                  Colors.white70,
                  'ALL',
                ),
                const SizedBox(width: 4),
                _buildFilterableStatBadge(
                  "검토 필요",
                  _objSuspiciousCount,
                  Colors.orangeAccent,
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
                  Colors.tealAccent,
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
                  Colors.greenAccent,
                  'HUMAN_CONFIRMED',
                ),
                const SizedBox(width: 4),
                _buildFilterableStatBadge(
                  "미검수",
                  _objDetectedCount,
                  Colors.lightBlueAccent,
                  'DETECTED',
                ),
                const SizedBox(width: 4),
                _buildFilterableStatBadge(
                  "제외",
                  _objRejectedCount,
                  Colors.grey,
                  'REJECTED',
                ),
                const SizedBox(width: 4),
                _buildStatBadge(
                  "누락 후보",
                  _unresolvedCandidatesCount,
                  _unresolvedCandidatesCount > 0
                      ? Colors.purpleAccent
                      : Colors.grey,
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 3.5,
            runSpacing: 4.0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                "도면 표시:",
                style: TextStyle(color: Colors.grey, fontSize: 9.5),
              ),
              _buildObjectClassFilter("전체", 'ALL'),
              _buildObjectClassFilter("Bus", 'bus'),
              _buildObjectClassFilter("Load", 'load'),
              _buildObjectClassFilter("Gen", 'generator'),
              _buildObjectClassFilter("Trans", 'transformer'),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  _filteredAndSortedWorkingNodes.any(
                    (node) =>
                        node.reviewStatus == 'DETECTED' ||
                        node.reviewStatus == 'SUSPICIOUS',
                  )
                  ? _batchConfirmVisibleNodes
                  : null,
              icon: const Icon(Icons.done_all, size: 14),
              label: Text(
                '현재 표시된 객체 전체 승인 (${_filteredAndSortedWorkingNodes.where((node) => node.reviewStatus != 'REJECTED').length})',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildObjectReviewSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildObjectQueueHeader(),
        const Divider(color: Colors.grey, height: 1),
        const SizedBox(height: 12),

        // 1. Global Completeness Review Section
        _buildGlobalCompletenessSection(),
        const SizedBox(height: 14),

        // 2. Quick Node Selection Carousel / Chip Row
        _buildNodeSelectionChips(),
        const SizedBox(height: 14),
        const Divider(color: Colors.grey, height: 1),
        const SizedBox(height: 14),

        // 3. Selected Node Details Panel
        if (_selectedNode == null)
          _buildNoSelectionPrompt("객체")
        else
          _buildSelectedNodePanel(),
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
                const Icon(Icons.list_alt, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  "객체 목록 (${list.length}개) · ${currentPage + 1}/$pageCount 페이지",
                  style: const TextStyle(
                    color: Colors.grey,
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
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    onPressed: currentPage > 0
                        ? () => setState(() => _nodePage = currentPage - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left, size: 18),
                  ),
                  Text(
                    '${currentPage + 1}/$pageCount',
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  IconButton(
                    tooltip: '다음 페이지',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
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
                      ? classColor.withValues(alpha: 0.35)
                      : const Color(0xFF252538),
                  border: Border.all(
                    color: isSelected
                        ? Colors.yellowAccent
                        : (isSuspicious
                            ? Colors.orangeAccent
                            : classColor.withValues(alpha: 0.85)),
                    width: isSelected ? 1.8 : 1.2,
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_getClassIcon(n.className), size: 11, color: classColor),
                    const SizedBox(width: 3.5),
                    Text(
                      n.effectiveDisplayLabel,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontSize: 10.5,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        decoration: isRejected ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (isSuspicious) ...[
                      const SizedBox(width: 2.5),
                      const Text("⚠️", style: TextStyle(fontSize: 8)),
                    ] else if (isConfirmed) ...[
                      const SizedBox(width: 2.5),
                      const Icon(Icons.check, size: 10, color: Colors.greenAccent),
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
        color: const Color(0xFF252538),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _unresolvedCandidatesCount > 0
              ? Colors.purpleAccent.withValues(alpha: 0.6)
              : Colors.blueAccent.withValues(alpha: 0.3),
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
                    ? Colors.purpleAccent
                    : Colors.blueAccent,
              ),
              const SizedBox(width: 6),
              const Text(
                "전체 도면 완결성 검사",
                style: TextStyle(
                  color: Colors.white,
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
                        ? Colors.green.withValues(alpha: 0.2)
                        : Colors.purple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    _completenessAssessmentKo(_completenessAssessment!),
                    style: TextStyle(
                      color: _completenessAssessment == 'ALL_EXPECTED_PRESENT'
                          ? Colors.greenAccent
                          : Colors.purpleAccent,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: Colors.grey),
                tooltip: "완결성 재검사",
                onPressed: _triggerCompletenessReview,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _completenessMessageKo ?? "전체 도면 내 미검출 설비 누락 가능성을 점검 중입니다...",
            style: const TextStyle(
              color: Colors.white70,
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
                      ? Colors.purple.withValues(alpha: 0.15)
                      : const Color(0xFF181825),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isOpen
                        ? Colors.purpleAccent.withValues(alpha: 0.5)
                        : Colors.grey.withValues(alpha: 0.3),
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
                            color: isOpen ? Colors.purpleAccent : Colors.grey,
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
                            color: isOpen ? Colors.purpleAccent : Colors.grey,
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
                      style: const TextStyle(color: Colors.white, fontSize: 11),
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
                                  backgroundColor: Colors.purple,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purpleAccent,
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
                              foregroundColor: Colors.grey.shade300,
                              side: const BorderSide(color: Colors.grey),
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
    final bbox = node.bbox;
    final bboxStr = bbox.length >= 4
        ? "중심 (${bbox[0].toInt()}, ${bbox[1].toInt()}) | 크기 ${bbox[2].toInt()} × ${bbox[3].toInt()} px"
        : "";

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
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(
                    Icons.edit,
                    size: 14,
                    color: Colors.blueAccent,
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
                    ? Colors.orangeAccent
                    : (node.reviewStatus == 'CONFIRMED'
                          ? Colors.green
                          : Colors.blue),
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
          "내부 ID: ${node.id}  |  클래스: ${node.className.toUpperCase()}  |  신뢰도: ${(node.confidence * 100).toInt()}%",
          style: const TextStyle(color: Colors.grey, fontSize: 11),
        ),
        if (bboxStr.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            bboxStr,
            style: const TextStyle(color: Colors.grey, fontSize: 10),
          ),
        ],
        const SizedBox(height: 12),

        if (node.reviewReasons.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.orangeAccent.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.orangeAccent,
                      size: 14,
                    ),
                    SizedBox(width: 4),
                    Text(
                      "검토 필요 사유:",
                      style: TextStyle(
                        color: Colors.orangeAccent,
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
                        color: Colors.white70,
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
            color: const Color(0xFF252538),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    color: Colors.blueAccent,
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    "AI 검수 의견",
                    style: TextStyle(
                      color: Colors.blueAccent,
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
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (node.recommendedAction != null) ...[
                const SizedBox(height: 8),
                Text(
                  "추천 조치: ${_recommendedActionKo(node.recommendedAction)}",
                  style: const TextStyle(
                    color: Colors.greenAccent,
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
            color: Colors.grey,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmNode(node),
                icon: const Icon(Icons.check, size: 16),
                label: const Text("승인"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _rejectNode(node),
                icon: const Icon(Icons.close, size: 16),
                label: const Text("제외·삭제"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade800,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Class Change Chips
        const Text(
          "클래스 변경:",
          style: TextStyle(color: Colors.grey, fontSize: 11),
        ),
        const SizedBox(height: 6),
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
              selectedColor: _getClassColor(cls).withValues(alpha: 0.35),
            );
          }).toList(),
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
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              // Sort dropdown
              DropdownButton<String>(
                value: _connSortOption,
                dropdownColor: const Color(0xFF252538),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
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
                  Colors.white70,
                  'ALL',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "오류만 보기",
                  _criticalIssuesCount,
                  Colors.redAccent,
                  'ERROR_ONLY',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "검토 필요",
                  _lineAmbiguousCount,
                  Colors.orangeAccent,
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
                  Colors.tealAccent,
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
                  Colors.greenAccent,
                  'HUMAN_CONFIRMED',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "미검수",
                  _lineDetectedCount,
                  Colors.lightBlueAccent,
                  'DETECTED',
                ),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge(
                  "제외",
                  _lineRejectedCount,
                  Colors.grey,
                  'REJECTED',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionReviewSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildConnectionQueueHeader(),
        const Divider(color: Colors.grey, height: 1),
        const SizedBox(height: 12),

        // 1. Topology Validation Issues Summary
        _buildTopologyIssuesSection(),
        const SizedBox(height: 14),

        // 2. Line Selection Chips
        _buildLineSelectionChips(),
        const SizedBox(height: 14),
        const Divider(color: Colors.grey, height: 1),
        const SizedBox(height: 14),

        // 3. Selected Line Panel
        if (_selectedLine == null)
          _buildNoSelectionPrompt("선로")
        else
          _buildSelectedLinePanel(),
      ],
    );
  }

  Widget _buildTopologyIssuesSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF252538),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _criticalIssuesCount > 0
              ? Colors.redAccent.withValues(alpha: 0.6)
              : Colors.green.withValues(alpha: 0.3),
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
                    ? Colors.redAccent
                    : Colors.greenAccent,
              ),
              const SizedBox(width: 6),
              const Text(
                "토폴로지 전기적 무결성 검증",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: Colors.grey),
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
                  ? Colors.redAccent
                  : Colors.greenAccent,
              fontSize: 11,
            ),
          ),
          if (_topologyIssues.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._topologyIssues.map((iss) {
              final isError = iss['severity'] == 'error';
              return Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isError
                      ? Colors.red.withValues(alpha: 0.15)
                      : Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      isError ? Icons.cancel : Icons.warning,
                      size: 12,
                      color: isError ? Colors.redAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _formatTopologyIssueKo(iss),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
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
            const Icon(Icons.timeline, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              "선로 목록 (${list.length}개) · ${currentPage + 1}/$pageCount 페이지",
              style: const TextStyle(
                color: Colors.grey,
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
                ? Colors.orangeAccent
                : (l.reviewStatus == 'CONFIRMED'
                      ? Colors.greenAccent
                      : Colors.cyanAccent);

            return GestureDetector(
              onTap: () => setState(() {
                _selectedLine = l;
                _linePage = currentPage;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? color.withValues(alpha: 0.3)
                      : const Color(0xFF252538),
                  border: Border.all(
                    color: isSelected
                        ? color
                        : Colors.grey.withValues(alpha: 0.4),
                    width: isSelected ? 1.8 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  l.effectiveDisplayLabel,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
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
    final isAmbiguous = line.reviewStatus == 'AMBIGUOUS';
    final connStr =
        line.endpointsDisplay ??
        (line.connectedTo.isNotEmpty ? line.connectedTo.join(" ↔ ") : "미연결");

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline, color: Colors.cyanAccent, size: 20),
                const SizedBox(width: 6),
                Text(
                  line.effectiveDisplayLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isAmbiguous
                    ? Colors.orangeAccent
                    : (line.reviewStatus == 'CONFIRMED'
                          ? Colors.green
                          : Colors.cyan),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                line.reviewStatus,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          "내부 ID: ${line.lineId}  |  연결: $connStr",
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          "추적 방식: ${line.traceMethod}  |  단자: ${line.sourcePort} ➔ ${line.targetPort}",
          style: const TextStyle(color: Colors.grey, fontSize: 11),
        ),
        const SizedBox(height: 12),

        // Action Buttons
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmLine(line),
                icon: const Icon(Icons.check, size: 16),
                label: const Text("선로 승인"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _rejectLine(line),
                icon: const Icon(Icons.close, size: 16),
                label: const Text("선로 제외·삭제"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade800,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Reconnect Candidate Chips
        if (line.candidateTargets.isNotEmpty) ...[
          const Text(
            "연결 대상 Bus 재지정:",
            style: TextStyle(color: Colors.grey, fontSize: 11),
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
        ],
      ],
    );
  }

  // --- Agent Chat Side Panel ---

  Widget _buildAgentChatSidePanel() {
    return Column(
      children: [
        // Mode Header Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: const Color(0xFF1E2640),
          child: Row(
            children: [
              const Icon(Icons.bolt, color: Colors.blueAccent, size: 16),
              const SizedBox(width: 6),
              const Text(
                "AI 도면 검토 도우미 · 로컬 분석",
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_selectedNode != null)
                Text(
                  "선택: ${_selectedNode!.effectiveDisplayLabel}",
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              if (_selectedLine != null)
                Text(
                  "선택: ${_selectedLine!.effectiveDisplayLabel}",
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
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
                        ? Colors.blueAccent.withValues(alpha: 0.85)
                        : const Color(0xFF252538),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isUser
                          ? Colors.blueAccent
                          : Colors.grey.withValues(alpha: 0.3),
                    ),
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
                            color: isUser ? Colors.white70 : Colors.blueAccent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isUser ? "나" : "Local Assistant",
                            style: TextStyle(
                              color: isUser
                                  ? Colors.white70
                                  : Colors.blueAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        msg.text,
                        style: const TextStyle(
                          color: Colors.white,
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
          color: const Color(0xFF1E1E2E),
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
          color: const Color(0xFF181825),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatInputController,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: "도면, 선택 객체/선로에 대해 질문하세요...",
                    hintStyle: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF252538),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
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
                          color: Colors.blueAccent,
                        ),
                      )
                    : const Icon(Icons.send, color: Colors.blueAccent),
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
          style: const TextStyle(fontSize: 10, color: Colors.white70),
        ),
        backgroundColor: const Color(0xFF252538),
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
      compsStr = compIds.map((id) => _getDisplayLabelForId(id.toString())).join(' ↔ ');
    }

    switch (code) {
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

  Widget _buildAgentActivitySidePanel() {
    if (_isLoadingAgentRuns) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.blueAccent),
      );
    }

    if (_agentRuns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_edu, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                '기록된 Agent 활동 이력이 없습니다.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              const Text(
                '이슈 자동 재분석 또는 도구 실행 시 이곳에 사고 과정이 기록됩니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetchAgentRuns,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('활동 기록 새로고침'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF252538),
                  foregroundColor: Colors.white,
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
          final activityLog = List<dynamic>.from(run['activity_log'] ?? const []);

          final isAwaiting = status == 'AWAITING_APPROVAL';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF252538),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isAwaiting
                    ? Colors.green.withValues(alpha: 0.5)
                    : Colors.blueGrey.withValues(alpha: 0.3),
              ),
            ),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                initiallyExpanded: runIdx == 0,
                leading: Icon(
                  isAwaiting
                      ? Icons.check_circle_outline
                      : Icons.smart_toy_outlined,
                  color: isAwaiting ? Colors.greenAccent : Colors.blueAccent,
                ),
                title: Text(
                  'Agent 실행 #${_agentRuns.length - runIdx} (${run['issue_id'] ?? runId})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  '최종 판단: ${isAwaiting ? '수정안 승인 대기' : (status == 'NO_IMPROVEMENT' ? '개선 없음' : status)} · Patch: $patchId',
                  style: TextStyle(
                    color: isAwaiting ? Colors.greenAccent : Colors.white70,
                    fontSize: 11,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const Divider(color: Colors.black26),
                  if (activityLog.isEmpty)
                    const Text(
                      '상세 활동 로그가 없습니다.',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
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
                                color: Colors.blueAccent.withValues(
                                  alpha: 0.2,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _agentEventIcon(event),
                                size: 12,
                                color: Colors.blueAccent,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${idx + 1}. [${_agentEventTitleKo(event)}]',
                                    style: const TextStyle(
                                      color: Colors.white,
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
                                          color: Colors.white70,
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
                                          color: Colors.amberAccent,
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
                                              ? Colors.greenAccent
                                              : Colors.grey,
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

  // --- Step 6: Bus Number Mapping & Review (Phase 3) ---

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
          for (int i = 0; i < rawNodes.length && i < _workingNodes.length; i++) {
            final raw = rawNodes[i];
            final node = _workingNodes[i];
            node.busNumber = (raw['bus_number'] as num?)?.toInt();
            node.busNumberStatus = raw['bus_number_status']?.toString() ?? 'UNCERTAIN';
            node.displayLabel = raw['display_name']?.toString() ?? raw['display_label']?.toString() ?? node.displayLabel;
            node.connectedBusNumber = (raw['connected_bus_number'] as num?)?.toInt();
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
          SnackBar(content: Text("모선 번호 AI 판독 중 알림: $e"), backgroundColor: Colors.orange),
        );
      }
    } finally {
      if (mounted) setState(() => _isLinkingBusNumbers = false);
    }
  }

  void _proceedToBusMappingReview() {
    setState(() {
      _currentPhase = ReviewPhase.busMappingReview;
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

    // Automatically run AI vision grounding on all working buses (including human-added ones)
    _triggerAiBusLinking();
  }

  void _propagateBusNumber(ReviewNodeItem busNode, int newBusNo, {bool isDuplicate = false}) {
    setState(() {
      final oldBusId = busNode.id;
      final existingWithSameId = _workingNodes.where((n) => n.id == "bus_$newBusNo" && n != busNode);
      final newBusId = existingWithSameId.isNotEmpty
          ? "bus_${newBusNo}_${busNode.displayNumber ?? (busNode.hashCode.abs() % 1000)}"
          : "bus_$newBusNo";

      busNode.id = newBusId;
      busNode.busNumber = newBusNo;
      busNode.busNumberStatus = isDuplicate ? 'UNCERTAIN' : 'VERIFIED';
      busNode.displayLabel = isDuplicate ? "Bus $newBusNo (중복)" : "Bus $newBusNo";

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
                    if (l.connectedTo[i] == oldOtherId) l.connectedTo[i] = newGenId;
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
                    if (l.connectedTo[i] == oldOtherId) l.connectedTo[i] = newLoadId;
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
    final pageBuses = buses.skip(currentPage * _busPageSize).take(_busPageSize).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Header with Stats & Filter Badges
        _buildBusMappingQueueHeader(),
        const SizedBox(height: 12),

        // 2. Selected Bus Detail Editor
        if (_selectedNode != null && _selectedNode!.className.toLowerCase() == 'bus')
          _buildSelectedBusMappingCard(_selectedNode!)
        else
          _buildNoSelectionPrompt("모선(Bus)"),

        const SizedBox(height: 14),
        const Divider(color: Colors.white24, height: 1),
        const SizedBox(height: 10),

        // 3. Bus Queue List
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "모선 목록 (${buses.length}개) · ${currentPage + 1}/$totalPages 페이지",
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (totalPages > 1)
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 18, color: Colors.white70),
                    onPressed: currentPage > 0
                        ? () => setState(() => _busPage--)
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right, size: 18, color: Colors.white70),
                    onPressed: currentPage < totalPages - 1
                        ? () => setState(() => _busPage++)
                        : null,
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        ...pageBuses.map((bus) => _buildBusMappingListItem(bus)),
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
                Icon(Icons.numbers, color: Colors.amberAccent, size: 18),
                SizedBox(width: 6),
                Text(
                  "모선 번호 & 기기 매핑",
                  style: TextStyle(
                    color: Colors.white,
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
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.amberAccent),
                        )
                      : const Icon(Icons.refresh, size: 12, color: Colors.amberAccent),
                  label: Text(
                    _isLinkingBusNumbers ? "판독 중..." : "AI 번호 판독",
                    style: const TextStyle(fontSize: 10, color: Colors.amberAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.amberAccent, width: 0.8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      final counts = <int, int>{};
                      for (var b in _busNodes) {
                        if (b.busNumber != null) {
                          counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
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
                            content: Text("중복 번호($skippedDups개)는 일괄 승인에서 제외되었습니다. 각각 고유 번호로 지정해 주세요."),
                            backgroundColor: Colors.orange,
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("✓ 고유한 모선 번호가 모두 승인되었습니다."),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    });
                  },
                  icon: const Icon(Icons.done_all, size: 12),
                  label: const Text("전체 승인", style: TextStyle(fontSize: 10)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
            _buildBusFilterBadge("전체", _busNodes.length, Colors.blueGrey, 'ALL'),
            const SizedBox(width: 6),
            _buildBusFilterBadge("검토 필요", _busUncertainCount, Colors.orangeAccent, 'UNCERTAIN'),
            const SizedBox(width: 6),
            _buildBusFilterBadge("승인 완료", _busVerifiedCount, Colors.greenAccent, 'VERIFIED'),
          ],
        ),
      ],
    );
  }

  Widget _buildBusFilterBadge(String label, int count, Color color, String filterKey) {
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
          color: isSelected ? color.withValues(alpha: 0.3) : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? color : Colors.white12,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.3),
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
    final connectedGens = <ReviewNodeItem>[];
    final connectedLoads = <ReviewNodeItem>[];

    for (final line in _workingLines) {
      if (line.connectedTo.contains(busNode.id)) {
        final otherId = line.connectedTo.first == busNode.id
            ? (line.connectedTo.length > 1 ? line.connectedTo[1] : null)
            : line.connectedTo.first;
        if (otherId != null) {
          final other = _workingNodes.firstWhere((n) => n.id == otherId, orElse: () => busNode);
          if (other.id != busNode.id) {
            if (other.className.toLowerCase().contains('gen')) connectedGens.add(other);
            if (other.className.toLowerCase().contains('load')) connectedLoads.add(other);
          }
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF252538),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isVerified ? Colors.greenAccent.withValues(alpha: 0.6) : Colors.orangeAccent,
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      busNode.id,
                      style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    busNode.busNumber != null ? "Bus #${busNode.busNumber}" : "Bus (미지정)",
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isVerified ? Colors.green.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isVerified ? "✓ 검증 완료" : "⚠️ 확인 필요",
                  style: TextStyle(
                    color: isVerified ? Colors.greenAccent : Colors.orangeAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Bus Number Input & Apply
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _busNumberEditController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: "모선 번호 지정 (Bus Number)",
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 10),
                      filled: true,
                      fillColor: const Color(0xFF181825),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () {
                    final num = int.tryParse(_busNumberEditController.text.trim());
                    if (num != null && num > 0) {
                      final conflictBuses = _busNodes.where((b) => b != busNode && b.busNumber == num).toList();
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("⚠️ 중복 감지: #$num번이 이미 다른 모선(${conflictBuses.map((b) => b.id).join(', ')})에 할당되어 있습니다! 중복된 모선들이 모두 [검토 필요] 탭으로 이동되었습니다."),
                            backgroundColor: Colors.orange[800],
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      } else {
                        // Clear any old duplicate reason on this bus
                        busNode.busNumberReasons.removeWhere((r) => r.startsWith('DUPLICATE_BUS_NUMBER_'));
                        _propagateBusNumber(busNode, num, isDuplicate: false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("✓ Bus $num 설정 및 연결 기기(발전기/부하) 자동 갱신 완료!"),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("올바른 양의 정수 번호를 입력해 주세요."), backgroundColor: Colors.red),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: const Text("적용 및 동기화", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Connected Devices Summary
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2E),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("⚡ 연결된 기기 자동 명명 현황:", style: TextStyle(color: Colors.white70, fontSize: 10.5)),
                const SizedBox(height: 4),
                if (connectedGens.isEmpty && connectedLoads.isEmpty)
                  const Text("• 직결된 발전기/부하 없음 (단독 모선)", style: TextStyle(color: Colors.grey, fontSize: 10))
                else ...[
                  if (connectedGens.isNotEmpty)
                    Text(
                      "• 발전기: ${connectedGens.map((g) => g.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 10.5, fontWeight: FontWeight.bold),
                    ),
                  if (connectedLoads.isNotEmpty)
                    Text(
                      "• 부하: ${connectedLoads.map((l) => l.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(color: Colors.cyanAccent, fontSize: 10.5, fontWeight: FontWeight.bold),
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
    final isDuplicate = busNode.busNumber != null && _duplicateBusNumbers.contains(busNode.busNumber);
    final isVerified = busNode.busNumberStatus == 'VERIFIED' && busNode.busNumber != null && !isDuplicate;

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
          color: isSelected
              ? Colors.amber.withValues(alpha: 0.15)
              : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? Colors.amberAccent
                : (isDuplicate
                    ? Colors.redAccent.withValues(alpha: 0.8)
                    : (isVerified ? Colors.green.withValues(alpha: 0.3) : Colors.orangeAccent.withValues(alpha: 0.5))),
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
                      ? Colors.redAccent
                      : (isVerified ? Colors.greenAccent : Colors.orangeAccent),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  busNode.busNumber != null ? "Bus #${busNode.busNumber}" : "Bus ? (미인식)",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "(${busNode.id})",
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isDuplicate
                    ? Colors.redAccent.withValues(alpha: 0.25)
                    : (isVerified ? Colors.green.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isDuplicate ? "중복 번호" : (isVerified ? "승인됨" : "검토필요"),
                style: TextStyle(
                  color: isDuplicate
                      ? Colors.redAccent
                      : (isVerified ? Colors.greenAccent : Colors.orangeAccent),
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

  // --- Excel Importer Method ---

  Future<void> _loadDefaultExcelInReview() async {
    setState(() {
      _isLoading = true;
      _loadingMessage = "📊 기본 ac_case25 계통 데이터를 분석 및 매칭하는 중...";
    });
    try {
      final data = await _apiService.loadDefaultExcelCase();
      if (!mounted) return;
      setState(() {
        _importedExcelData = data;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ ac_case25 데이터 매칭 성공!\n• 슬랙 모선: #${_importedExcelData!['slack_bus_number']}\n• 모선: ${_importedExcelData!['total_buses']}개, 발전기: ${_importedExcelData!['total_generators']}개, 선로: ${_importedExcelData!['total_branches']}개",
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
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
            const SnackBar(content: Text("파일 데이터를 읽을 수 없습니다."), backgroundColor: Colors.red),
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
      setState(() {
        _importedExcelData = data;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ 엑셀 데이터 매칭 성공!\n• 슬랙 모선: #${_importedExcelData!['slack_bus_number']}\n• 모선: ${_importedExcelData!['total_buses']}개, 발전기: ${_importedExcelData!['total_generators']}개, 선로: ${_importedExcelData!['total_branches']}개",
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
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
        color: const Color(0xFF181825),
        child: Column(
          children: [
            CheckboxListTile(
              value: _humanCompletenessConfirmed,
              onChanged: (val) =>
                  setState(() => _humanCompletenessConfirmed = val ?? false),
              title: const Text(
                "원본 회로도 전체와의 대조 확인 완료 (Completeness Confirmed)",
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: Colors.blueAccent,
            ),
            if (_objectGateBlockers.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  border: Border.all(color: Colors.orangeAccent),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '결선 단계로 가려면:\n• ${_objectGateBlockers.join('\n• ')}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
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
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
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
                      backgroundColor: Colors.green,
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
        color: const Color(0xFF181825),
        child: Column(
          children: [
            if (_busGateBlockers.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  border: Border.all(color: Colors.orangeAccent),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '선로 결선 단계로 가려면:\n• ${_busGateBlockers.join('\n• ')}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _canVerifyBusGate ? _proceedToConnectionReview : null,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text("모선 번호 승인 ➔ 다음: 선로 결선 인식 및 검수"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigoAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
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
        color: const Color(0xFF181825),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _verifyFinalGate,
                icon: const Icon(Icons.verified, size: 16),
                label: const Text("결선 검수 완료 ➔ 다음: 최종 확인 & 엑셀"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
            color: const Color(0xFF252538),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.greenAccent.withValues(alpha: 0.5),
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.verified_user,
                color: Colors.greenAccent,
                size: 56,
              ),
              const SizedBox(height: 12),
              const Text(
                "Verified SLD 회로도 검증 완료! 🎉",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "문서 ID: ${sld.documentId}  |  상태: ${sld.status}",
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildFinalSummaryItem("확정 모선", "${_busNodes.length}개", Colors.blueAccent),
                    _buildFinalSummaryItem("확정 결선", "${sld.lines.length}개", Colors.orangeAccent),
                    _buildFinalSummaryItem(
                      "발전기/부하",
                      "${_workingNodes.where((n) => n.className.contains('gen') || n.className.contains('load')).length}개",
                      Colors.cyanAccent,
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
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _importedExcelData != null ? Colors.greenAccent : Colors.tealAccent.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.table_chart, color: Colors.tealAccent, size: 20),
                            SizedBox(width: 8),
                            Text(
                              "계통 엑셀 데이터 (.xlsx) 매칭",
                              style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _loadDefaultExcelInReview,
                              icon: const Icon(Icons.bolt, size: 14, color: Colors.amberAccent),
                              label: const Text(
                                "⚡ ac_case25 기본값 바로 적용",
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.amber[900]?.withValues(alpha: 0.7),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: _importExcelInReview,
                              icon: const Icon(Icons.file_upload, size: 14),
                              label: Text(
                                _importedExcelData != null ? "다른 엑셀 다시 불러오기" : "엑셀 파일 선택",
                                style: const TextStyle(fontSize: 11),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal[700],
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_importedExcelData != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.stars, color: Colors.amberAccent, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  "⭐️ 슬랙 모선: #${_importedExcelData!['slack_bus_number']} (Swing Bus 자동 지정)",
                                  style: const TextStyle(color: Colors.amberAccent, fontSize: 12.5, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "• 발전기 ${_importedExcelData!['total_generators']}개 파라미터 (PG, 목표전압 Vset)\n• 부하 ${_importedExcelData!['total_buses']}개 모선 유효/무효전력 (Pload, Qload)\n• 선로 ${_importedExcelData!['total_branches']}개 임피던스 (R, X, B, Tap) 자동 바인딩 완료!",
                              style: const TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      const Text(
                        "💡 'ac_case25 - 복사본.xlsx' 등의 엑셀 파일을 불러오면 13번 슬랙 모선과 발전기/부하/선로 파라미터가 캔버스에 자동 반영됩니다.",
                        style: TextStyle(color: Colors.white60, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _handoffToFlutterCanvas,
                    icon: const Icon(Icons.open_in_new),
                    label: Text(
                      _importedExcelData != null ? "엑셀 데이터 적용하여 캔버스로 이동" : "캔버스 편집 화면으로 이동",
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
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
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
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
              ? color.withValues(alpha: 0.3)
              : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isSelected ? color : color.withValues(alpha: 0.4),
            width: isSelected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          "$label: $count",
          style: TextStyle(
            color: color,
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
    final chipColor = classKey == 'ALL' ? Colors.blueAccent : _getClassColor(classKey);
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
              ? chipColor.withValues(alpha: 0.35)
              : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? chipColor : chipColor.withValues(alpha: 0.4),
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
                color: selected ? Colors.white : chipColor,
              ),
              const SizedBox(width: 2.5),
            ],
            Text(
              '$label $count',
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
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
              ? color.withValues(alpha: 0.3)
              : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isSelected ? color : color.withValues(alpha: 0.4),
            width: isSelected ? 1.4 : 0.8,
          ),
        ),
        child: Text(
          "$label: $count",
          style: TextStyle(
            color: color,
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
        color: const Color(0xFF252538),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.0),
      ),
      child: Text(
        "$label: $count",
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }
}
