import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import '../models/review_models.dart';
import '../services/review_api_service.dart';
import '../widgets/review_overlay.dart';

enum ReviewPhase {
  objectReview,
  connectionReview,
  verifiedFinal,
}

enum RightPanelTab {
  detailReview,
  agentChat,
}

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
  ProactiveSummaryItem? _proactiveSummary;

  // Selected Elements
  ReviewNodeItem? _selectedNode;
  ReviewLineItem? _selectedLine;

  // Filter & Sort
  String _objFilterStatus = 'ALL'; // ALL, SUSPICIOUS, AUTO_CONFIRMED, HUMAN_CONFIRMED, REJECTED, MISSING
  String _objSortOption = 'SEVERITY'; // SEVERITY, CONFIDENCE_ASC, ID_ASC

  String _connFilterStatus = 'ALL'; // ALL, AMBIGUOUS, AUTO_CONFIRMED, HUMAN_CONFIRMED, REJECTED, ERROR_ONLY
  String _connSortOption = 'SEVERITY'; // SEVERITY, ID_ASC

  // Loading & Modes
  bool _isLoading = false;
  String? _loadingMessage;

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
  int get _objSuspiciousCount => _workingNodes.where((n) => n.reviewStatus == 'SUSPICIOUS').length;
  int get _objDetectedCount => _workingNodes.where((n) => n.reviewStatus == 'DETECTED').length;
  int get _objRejectedCount => _workingNodes.where((n) => n.reviewStatus == 'REJECTED').length;
  int get _unresolvedCandidatesCount => _missingCandidates.where((c) => c.status == 'OPEN').length;

  bool get _canVerifyObjectGate =>
      _objSuspiciousCount == 0 &&
      _unresolvedCandidatesCount == 0 &&
      _humanCompletenessConfirmed &&
      _workingNodes.where((n) => n.reviewStatus != 'REJECTED').isNotEmpty;

  // Filtered & Sorted Working Nodes
  List<ReviewNodeItem> get _filteredAndSortedWorkingNodes {
    List<ReviewNodeItem> list = List.from(_workingNodes);

    if (_objFilterStatus == 'SUSPICIOUS') {
      list = list.where((n) => n.reviewStatus == 'SUSPICIOUS').toList();
    } else if (_objFilterStatus == 'AUTO_CONFIRMED') {
      list = list.where((n) => n.reviewStatus == 'CONFIRMED' && !n.source.contains('human')).toList();
    } else if (_objFilterStatus == 'HUMAN_CONFIRMED') {
      list = list.where((n) => n.reviewStatus == 'CONFIRMED' && n.source.contains('human')).toList();
    } else if (_objFilterStatus == 'DETECTED') {
      list = list.where((n) => n.reviewStatus == 'DETECTED').toList();
    } else if (_objFilterStatus == 'REJECTED') {
      list = list.where((n) => n.reviewStatus == 'REJECTED').toList();
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
  int get _lineAmbiguousCount => _workingLines.where((l) => l.reviewStatus == 'AMBIGUOUS').length;
  int get _lineDetectedCount => _workingLines.where((l) => l.reviewStatus == 'DETECTED').length;
  int get _lineRejectedCount => _workingLines.where((l) => l.reviewStatus == 'REJECTED').length;
  int get _criticalIssuesCount => _topologyIssues.where((i) => i['severity'] == 'error').length;

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
      list = list.where((l) => l.reviewStatus == 'CONFIRMED' && !l.source.contains('human')).toList();
    } else if (_connFilterStatus == 'HUMAN_CONFIRMED') {
      list = list.where((l) => l.reviewStatus == 'CONFIRMED' && l.source.contains('human')).toList();
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
        _proactiveSummary = doc.proactiveSummary;

        if (_workingNodes.isNotEmpty) {
          _selectedNode = _workingNodes.firstWhere(
            (n) => n.reviewStatus == 'SUSPICIOUS',
            orElse: () => _workingNodes.first,
          );
        }
        _isLoading = false;

        // Greeting and Proactive Summary in Chat
        final summaryMsg = doc.proactiveSummary?.summaryText ??
            "안녕하세요! VisionFlow 로컬 도면 어시스턴트입니다.\n도면 검수 상태, 선택 객체/선로의 판정 근거, 누락 후보 등을 로컬 분석 모드로 즉시 안내해 드립니다.";

        _chatHistory.add(ChatMessageItem(
          role: "assistant",
          text: summaryMsg,
          agentStatus: "LOCAL_READY",
        ));
      });

      // Auto run Global Completeness Review
      _triggerCompletenessReview();

      if (_selectedNode != null && _selectedNode!.reviewStatus == 'SUSPICIOUS') {
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

  // --- Step 2: Agent Node Review & Human Correction ---

  Future<void> _triggerAgentReviewNode(ReviewNodeItem node) async {
    if (_document == null) return;
    try {
      final res = await _apiService.agentReviewNode(_document!.documentId, node);
      setState(() {
        node.agentExplanation = res['explanation_ko']?.toString();
        node.recommendedAction = res['recommended_action']?.toString();
        if (res['suggested_classes'] is List) {
          node.suggestedClasses = (res['suggested_classes'] as List).map((e) => e.toString()).toList();
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
    setState(() {
      node.reviewStatus = 'REJECTED';
      node.source = '${node.source}_human_rejected';
    });
    _selectNextSuspiciousNode();
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
      const SnackBar(content: Text("정상 객체들이 일괄 승인되었습니다."), backgroundColor: Colors.teal),
    );
  }

  // Navigation Logic
  void _selectNextSuspiciousNode() {
    final suspicious = _workingNodes.where((n) => n.reviewStatus == 'SUSPICIOUS').toList();
    if (suspicious.isEmpty) return;

    int currentIdx = _selectedNode != null ? suspicious.indexOf(_selectedNode!) : -1;
    int nextIdx = (currentIdx + 1) % suspicious.length;
    setState(() {
      _selectedNode = suspicious[nextIdx];
    });
    if (_selectedNode!.agentExplanation == null) {
      _triggerAgentReviewNode(_selectedNode!);
    }
  }

  void _selectPreviousSuspiciousNode() {
    final suspicious = _workingNodes.where((n) => n.reviewStatus == 'SUSPICIOUS').toList();
    if (suspicious.isEmpty) return;

    int currentIdx = _selectedNode != null ? suspicious.indexOf(_selectedNode!) : 0;
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
    int currentIdx = _selectedNode != null ? _workingNodes.indexOf(_selectedNode!) : 0;
    int prevIdx = (currentIdx - 1 + _workingNodes.length) % _workingNodes.length;
    setState(() {
      _selectedNode = _workingNodes[prevIdx];
    });
  }

  void _selectNextNode() {
    if (_workingNodes.isEmpty) return;
    int currentIdx = _selectedNode != null ? _workingNodes.indexOf(_selectedNode!) : 0;
    int nextIdx = (currentIdx + 1) % _workingNodes.length;
    setState(() {
      _selectedNode = _workingNodes[nextIdx];
    });
  }

  void _jumpToPriorityItem(PriorityReviewItem item) {
    if (item.targetType == 'NODE') {
      final match = _workingNodes.firstWhere((n) => n.id == item.id, orElse: () => _workingNodes.first);
      setState(() {
        _selectedNode = match;
        _selectedLine = null;
        _activeRightTab = RightPanelTab.detailReview;
      });
      if (match.agentExplanation == null && match.reviewStatus == 'SUSPICIOUS') {
        _triggerAgentReviewNode(match);
      }
    } else if (item.targetType == 'LINE') {
      final match = _workingLines.firstWhere((l) => l.lineId == item.id, orElse: () => _workingLines.first);
      setState(() {
        _selectedLine = match;
        _selectedNode = null;
        _activeRightTab = RightPanelTab.detailReview;
      });
    }
  }

  void _editNodeDisplayLabel(ReviewNodeItem node) {
    final controller = TextEditingController(text: node.effectiveDisplayLabel);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252538),
        title: Text("${node.id} 표시명 / 번호 수정", style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("도면의 실제 번호와 일치하도록 표시명을 수정하세요:", style: TextStyle(color: Colors.grey, fontSize: 12)),
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
    final newId = "manual_${className}_${DateTime.now().millisecondsSinceEpoch % 10000}";
    final count = _workingNodes.where((n) => n.className == className).length + 1;
    final prefix = className == 'bus' ? 'BUS' : (className == 'generator' ? 'GEN' : (className == 'load' ? 'LOAD' : 'TRANS'));
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
      SnackBar(content: Text("$dispLabel ($className) 객체가 수동 추가되었습니다."), backgroundColor: Colors.purple),
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
            const SnackBar(content: Text("✓ 객체 검수 Gate 통과! 결선 단계로 진행할 수 있습니다."), backgroundColor: Colors.green),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_objectGateMessage ?? "객체 Gate 차단됨"), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Gate 검증 실패: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // --- Step 4: Connection Detection ---

  Future<void> _proceedToConnectionReview() async {
    if (!_isObjectVerified || _document == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("먼저 [객체 검수 완료 (Gate 통과)]를 완료해야 합니다."), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = "확정 객체 기반 결선 인식 중... 🔗";
      _currentPhase = ReviewPhase.connectionReview;
      _connFilterStatus = 'ALL';
    });

    try {
      final confirmedNodes = _workingNodes.where((n) => n.reviewStatus == 'CONFIRMED' || n.reviewStatus == 'DETECTED').toList();
      final res = await _apiService.detectConnections(_document!.documentId, confirmedNodes);
      final rawLines = res['lines'] as List? ?? [];
      final parsedLines = rawLines.map((l) => ReviewLineItem.fromJson(l as Map<String, dynamic>)).toList();

      ProactiveSummaryItem? proactiveSummary;
      if (res['proactive_summary'] is Map<String, dynamic>) {
        proactiveSummary = ProactiveSummaryItem.fromJson(res['proactive_summary']);
      }

      setState(() {
        _workingLines = parsedLines;
        _proactiveSummary = proactiveSummary;
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
      line.reviewStatus = 'REJECTED';
      line.source = '${line.source}_human_rejected';
    });
    _triggerTopologyValidation();
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
      const SnackBar(content: Text("정상 결선들이 일괄 승인되었습니다."), backgroundColor: Colors.teal),
    );
  }

  void _handleManualAddLineComplete(ReviewNodeItem startNode, ReviewNodeItem endNode) {
    final newLineId = "manual_line_${DateTime.now().millisecondsSinceEpoch % 10000}";
    final lineNum = _workingLines.length + 1;
    final dispLabel = "L$lineNum";
    final endpointsStr = "${startNode.effectiveDisplayLabel} ↔ ${endNode.effectiveDisplayLabel}";

    final newLine = ReviewLineItem(
      lineId: newLineId,
      connectedTo: [startNode.id, endNode.id],
      path: [
        [startNode.bbox[0], startNode.bbox[1]],
        [endNode.bbox[0], endNode.bbox[1]],
      ],
      sourcePort: 'manual',
      targetPort: 'manual',
      traceMethod: 'human_manual_connect',
      reviewStatus: 'CONFIRMED',
      source: 'human_manual_line',
      displayLabel: dispLabel,
      displayName: "$dispLabel ($endpointsStr)",
      endpointsDisplay: endpointsStr,
    );

    setState(() {
      _workingLines.add(newLine);
      _selectedLine = newLine;
      _isManualAddLineMode = false;
      _manualLineStartNode = null;
    });

    _triggerTopologyValidation();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("$dispLabel ($endpointsStr) 선로가 수동 추가되었습니다."), backgroundColor: Colors.purple),
    );
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
          _verifiedSld = VerifiedSLD.fromJson(res['verified_sld'] as Map<String, dynamic>);
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
        const SnackBar(content: Text("검증 완료된(VERIFIED) 회로도만 Canvas로 전달할 수 있습니다."), backgroundColor: Colors.red),
      );
      return;
    }

    widget.onProceedToCanvas?.call(_verifiedSld!.toJson());
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
          : (_currentPhase == ReviewPhase.connectionReview ? "CONNECTION_REVIEW" : "FINAL");

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
        _chatHistory.add(ChatMessageItem(
          role: "assistant",
          text: reply,
          agentStatus: agentStatus,
        ));
        _isChatLoading = false;
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(ChatMessageItem(
          role: "assistant",
          text: "오류가 발생했습니다: $e",
          agentStatus: "ERROR",
        ));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.bolt, color: Colors.blueAccent, size: 24),
            const SizedBox(width: 8),
            Text(
              _currentPhase == ReviewPhase.objectReview
                  ? "VisionFlow 단선도 검수: ① 객체 검수 (Object Review)"
                  : _currentPhase == ReviewPhase.connectionReview
                      ? "VisionFlow 단선도 검수: ② 결선 검수 (Connection Review)"
                      : "VisionFlow 단선도 검수: ③ 최종 회로도 검증 (Verified SLD)",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF181825),
        elevation: 1,
        actions: [
          // Step Badges
          _buildPhaseBadge("① 객체 검수", _currentPhase == ReviewPhase.objectReview, _isObjectVerified),
          const Icon(Icons.arrow_right, color: Colors.grey, size: 18),
          _buildPhaseBadge("② 결선 검수", _currentPhase == ReviewPhase.connectionReview, _isFinalVerified),
          const Icon(Icons.arrow_right, color: Colors.grey, size: 18),
          _buildPhaseBadge("③ 회로도 검증", _currentPhase == ReviewPhase.verifiedFinal, _isFinalVerified),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: _pickAndUploadImage,
            icon: const Icon(Icons.file_upload, size: 18),
            label: const Text("도면 이미지 업로드"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
          const SizedBox(width: 12),
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
                        const CircularProgressIndicator(color: Colors.blueAccent),
                        const SizedBox(height: 16),
                        Text(_loadingMessage ?? "처리 중...", style: const TextStyle(color: Colors.white, fontSize: 14)),
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
        style: TextStyle(color: text, fontSize: 11, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal),
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
            border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_upload_outlined, size: 72, color: Colors.blueAccent),
              const SizedBox(height: 16),
              const Text("전력계통 단선도(SLD) 이미지를 업로드하세요", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("객체 검수 ➔ 결선 인식 ➔ 토폴로지 검증 ➔ Verified SLD 생성", style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _pickAndUploadImage,
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text("도면 파일 선택 (Drag & Drop)"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Proactive AI Summary Top Banner ---

  Widget _buildProactiveSummaryBanner() {
    final summary = _proactiveSummary;
    if (summary == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2640),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Colors.blueAccent, size: 16),
              const SizedBox(width: 6),
              const Text("AI 검토 우선순위 브리핑", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  summary.displayMode,
                  style: const TextStyle(color: Colors.blueAccent, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
              const Spacer(),
              Text(
                "정상 ${summary.cleanCount}개 자동승인 대상 • 검토필요 ${summary.suspiciousCount}건",
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
          if (summary.priorityItems.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: summary.priorityItems.map((item) {
                final isWarning = item.severity == 'WARNING';
                final isAlert = item.severity == 'ALERT';
                final chipColor = isAlert ? Colors.purpleAccent : (isWarning ? Colors.orangeAccent : Colors.redAccent);

                return ActionChip(
                  avatar: Icon(
                    item.targetType == 'NODE' ? Icons.crop_square : (item.targetType == 'LINE' ? Icons.timeline : Icons.warning_amber),
                    size: 13,
                    color: chipColor,
                  ),
                  label: Text(
                    "${item.displayLabel} (${item.reason})",
                    style: TextStyle(color: chipColor, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: chipColor.withValues(alpha: 0.15),
                  side: BorderSide(color: chipColor.withValues(alpha: 0.5), width: 1),
                  onPressed: () => _jumpToPriorityItem(item),
                );
              }).toList(),
            ),
          ],
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
                flex: 6,
                child: Column(
                  children: [
                    // Top Tool Header
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      color: const Color(0xFF181825),
                      child: Row(
                        children: [
                          Text("도면 해상도: ${_document!.image.width} × ${_document!.image.height} px", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const Spacer(),
                          if (!isConnectionPhase) ...[
                            // Quick navigation & batch confirm
                            IconButton(
                              icon: const Icon(Icons.arrow_back, size: 16, color: Colors.grey),
                              tooltip: "이전 객체",
                              onPressed: _workingNodes.isEmpty ? null : _selectPreviousNode,
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
                              tooltip: "다음 객체",
                              onPressed: _workingNodes.isEmpty ? null : _selectNextNode,
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.history_toggle_off, size: 16, color: Colors.orangeAccent),
                              tooltip: "이전 의심 객체",
                              onPressed: _objSuspiciousCount == 0 ? null : _selectPreviousSuspiciousNode,
                            ),
                            IconButton(
                              icon: const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orangeAccent),
                              tooltip: "다음 의심 객체",
                              onPressed: _objSuspiciousCount == 0 ? null : _selectNextSuspiciousNode,
                            ),
                            const SizedBox(width: 8),
                            if (_objDetectedCount > 0)
                              ElevatedButton.icon(
                                onPressed: _batchConfirmCleanDetectedNodes,
                                icon: const Icon(Icons.done_all, size: 14),
                                label: Text("정상 객체 일괄 승인 ($_objDetectedCount)", style: const TextStyle(fontSize: 11)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.teal.shade800,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                ),
                              ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text("➕ 객체 수동 추가", style: TextStyle(fontSize: 12)),
                              selected: _isManualAddMode,
                              onSelected: (val) => setState(() => _isManualAddMode = val),
                              selectedColor: Colors.purpleAccent.withValues(alpha: 0.3),
                            ),
                            if (_isManualAddMode) ...[
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: _manualAddClass,
                                dropdownColor: const Color(0xFF252538),
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                                items: const [
                                  DropdownMenuItem(value: 'bus', child: Text('Bus')),
                                  DropdownMenuItem(value: 'generator', child: Text('Generator')),
                                  DropdownMenuItem(value: 'load', child: Text('Load')),
                                  DropdownMenuItem(value: 'transformer', child: Text('Transformer')),
                                ],
                                onChanged: (val) => setState(() => _manualAddClass = val ?? 'bus'),
                              ),
                            ],
                          ] else ...[
                            if (_lineDetectedCount > 0)
                              ElevatedButton.icon(
                                onPressed: _batchConfirmCleanDetectedLines,
                                icon: const Icon(Icons.done_all, size: 14),
                                label: Text("정상 결선 일괄 승인 ($_lineDetectedCount)", style: const TextStyle(fontSize: 11)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.teal.shade800,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                ),
                              ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: Text(
                                _isManualAddLineMode
                                    ? (_manualLineStartNode == null ? "시작 객체를 클릭하세요" : "끝 객체를 클릭하세요")
                                    : "➕ 선로 수동 추가",
                                style: const TextStyle(fontSize: 12),
                              ),
                              selected: _isManualAddLineMode,
                              onSelected: (val) {
                                setState(() {
                                  _isManualAddLineMode = val;
                                  _manualLineStartNode = null;
                                });
                              },
                              selectedColor: Colors.purpleAccent.withValues(alpha: 0.3),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Canvas View with Draggable Labels and Leader Lines
                    Expanded(
                      child: Container(
                        color: Colors.black,
                        child: ReviewOverlayView(
                          imageBytes: _document!.rawBytes,
                          imageUrl: _apiService.getOriginalImageUrl(_document!.documentId),
                          originalWidth: _document!.image.width,
                          originalHeight: _document!.image.height,
                          nodes: _workingNodes,
                          selectedNode: _selectedNode,
                          onSelectNode: (node) {
                            setState(() => _selectedNode = node);
                            if (node.reviewStatus == 'SUSPICIOUS' && node.agentExplanation == null) {
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
                          lines: isConnectionPhase ? _workingLines : const [],
                          selectedLine: isConnectionPhase ? _selectedLine : null,
                          onSelectLine: (line) {
                            setState(() => _selectedLine = line);
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
                    ),
                  ],
                ),
              ),

              const VerticalDivider(width: 1, color: Colors.black),

              // Right Column: Tabbed Panel (Detail Review vs Agent Chat)
              Expanded(
                flex: 4,
                child: Container(
                  color: const Color(0xFF181825),
                  child: Column(
                    children: [
                      // Panel Tab Header
                      _buildRightPanelHeader(),
                      Expanded(
                        child: _activeRightTab == RightPanelTab.detailReview
                            ? SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: isConnectionPhase
                                    ? _buildConnectionReviewSidePanel()
                                    : _buildObjectReviewSidePanel(),
                              )
                            : _buildAgentChatSidePanel(),
                      ),
                      // Bottom Gate Control Footer
                      _buildBottomGateFooter(),
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
                  label: Text("상세 검수 패널", style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.fact_check_outlined, size: 16),
                ),
                ButtonSegment(
                  value: RightPanelTab.agentChat,
                  label: Text("AI 질의응답 (Chat)", style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.chat_bubble_outline, size: 16),
                ),
              ],
              selected: {_activeRightTab},
              onSelectionChanged: (set) => setState(() => _activeRightTab = set.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: Colors.blueAccent.withValues(alpha: 0.3),
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
              const Text("객체 검수 큐 (Object Queue)", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              // Sort dropdown
              DropdownButton<String>(
                value: _objSortOption,
                dropdownColor: const Color(0xFF252538),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'SEVERITY', child: Text("정렬: 위험도순")),
                  DropdownMenuItem(value: 'CONFIDENCE_ASC', child: Text("정렬: 신뢰도낮은순")),
                  DropdownMenuItem(value: 'ID_ASC', child: Text("정렬: ID순")),
                ],
                onChanged: (val) => setState(() => _objSortOption = val ?? 'SEVERITY'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterableStatBadge("전체 보기", _workingNodes.length, Colors.white70, 'ALL'),
                const SizedBox(width: 6),
                _buildFilterableStatBadge("검토 필요", _objSuspiciousCount, Colors.orangeAccent, 'SUSPICIOUS'),
                const SizedBox(width: 6),
                _buildFilterableStatBadge("자동 승인", _workingNodes.where((n) => n.reviewStatus == 'CONFIRMED' && !n.source.contains('human')).length, Colors.tealAccent, 'AUTO_CONFIRMED'),
                const SizedBox(width: 6),
                _buildFilterableStatBadge("수동 승인", _workingNodes.where((n) => n.reviewStatus == 'CONFIRMED' && n.source.contains('human')).length, Colors.greenAccent, 'HUMAN_CONFIRMED'),
                const SizedBox(width: 6),
                _buildFilterableStatBadge("미검수", _objDetectedCount, Colors.lightBlueAccent, 'DETECTED'),
                const SizedBox(width: 6),
                _buildFilterableStatBadge("제외", _objRejectedCount, Colors.grey, 'REJECTED'),
                const SizedBox(width: 6),
                _buildStatBadge("누락 후보", _unresolvedCandidatesCount, _unresolvedCandidatesCount > 0 ? Colors.purpleAccent : Colors.grey),
              ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.list_alt, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text("객체 목록 (${list.length}개):", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, idx) {
              final n = list[idx];
              final isSelected = _selectedNode?.id == n.id;
              final isSuspicious = n.reviewStatus == 'SUSPICIOUS';
              final color = isSuspicious ? Colors.orangeAccent : (n.reviewStatus == 'CONFIRMED' ? Colors.greenAccent : Colors.lightBlueAccent);

              return GestureDetector(
                onTap: () {
                  setState(() => _selectedNode = n);
                  if (isSuspicious && n.agentExplanation == null) {
                    _triggerAgentReviewNode(n);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? color.withValues(alpha: 0.3) : const Color(0xFF252538),
                    border: Border.all(color: isSelected ? color : Colors.grey.withValues(alpha: 0.4), width: isSelected ? 1.8 : 1.0),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_getClassIcon(n.className), size: 12, color: color),
                      const SizedBox(width: 4),
                      Text(
                        n.effectiveDisplayLabel,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
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
          color: _unresolvedCandidatesCount > 0 ? Colors.purpleAccent.withValues(alpha: 0.6) : Colors.blueAccent.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _unresolvedCandidatesCount > 0 ? Icons.warning_amber : Icons.verified_outlined,
                size: 18,
                color: _unresolvedCandidatesCount > 0 ? Colors.purpleAccent : Colors.blueAccent,
              ),
              const SizedBox(width: 6),
              const Text("전체 도면 완결성 검사", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
              if (_completenessAssessment != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: _completenessAssessment == 'ALL_EXPECTED_PRESENT' ? Colors.green.withValues(alpha: 0.2) : Colors.purple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    _completenessAssessment!,
                    style: TextStyle(
                      color: _completenessAssessment == 'ALL_EXPECTED_PRESENT' ? Colors.greenAccent : Colors.purpleAccent,
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
            style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.3),
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
                  color: isOpen ? Colors.purple.withValues(alpha: 0.15) : const Color(0xFF181825),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isOpen ? Colors.purpleAccent.withValues(alpha: 0.5) : Colors.grey.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "⚠️ ${c.suspectedClass.toUpperCase()} 누락 후보",
                          style: TextStyle(
                            color: isOpen ? Colors.purpleAccent : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: isOpen ? Colors.purpleAccent : Colors.grey,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            c.status,
                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(c.descriptionKo, style: const TextStyle(color: Colors.white, fontSize: 11)),
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
                                  content: Text("도면에서 ${c.suspectedClass.toUpperCase()} 영역을 드래그하여 추가하세요."),
                                  backgroundColor: Colors.purple,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purpleAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: const Size(0, 26),
                            ),
                            child: const Text("객체 수동 추가", style: TextStyle(fontSize: 10)),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            onPressed: () => _dismissCandidate(c),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey.shade300,
                              side: const BorderSide(color: Colors.grey),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: const Size(0, 26),
                            ),
                            child: const Text("문제 없음 (Dismiss)", style: TextStyle(fontSize: 10)),
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
    final bboxStr = bbox.length >= 4 ? "중심 (${bbox[0].toInt()}, ${bbox[1].toInt()}) | 크기 ${bbox[2].toInt()} × ${bbox[3].toInt()} px" : "";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with Display Label and Edit Action
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(_getClassIcon(node.className), color: classColor, size: 20),
                const SizedBox(width: 6),
                Text(
                  node.effectiveDisplayLabel,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.edit, size: 14, color: Colors.blueAccent),
                  tooltip: "표시명 / 번호 수정",
                  onPressed: () => _editNodeDisplayLabel(node),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isSuspicious ? Colors.orangeAccent : (node.reviewStatus == 'CONFIRMED' ? Colors.green : Colors.blue),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(node.reviewStatus, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        Text("내부 ID: ${node.id}  |  클래스: ${node.className.toUpperCase()}  |  신뢰도: ${(node.confidence * 100).toInt()}%", style: const TextStyle(color: Colors.grey, fontSize: 11)),
        if (bboxStr.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(bboxStr, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
        const SizedBox(height: 12),

        if (node.reviewReasons.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orangeAccent, size: 14),
                    SizedBox(width: 4),
                    Text("검토 필요 사유:", style: TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                ...node.reviewReasons.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text("• $r", style: const TextStyle(color: Colors.white70, fontSize: 11)),
                )),
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
                  Icon(Icons.smart_toy_outlined, color: Colors.blueAccent, size: 16),
                  SizedBox(width: 6),
                  Text("AI 검수 의견", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                node.agentExplanation ?? (isSuspicious ? "의심 사유를 분석하고 있습니다..." : "정상 심볼로 인식되었습니다."),
                style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
              ),
              if (node.recommendedAction != null) ...[
                const SizedBox(height: 8),
                Text(
                  "추천 조치: ${node.recommendedAction}",
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Action Buttons
        const Text("사용자 검수 액션", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmNode(node),
                icon: const Icon(Icons.check, size: 16),
                label: const Text("승인 (Confirm)"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _rejectNode(node),
                icon: const Icon(Icons.close, size: 16),
                label: const Text("제외 (Reject)"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800, foregroundColor: Colors.white),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Class Change Chips
        const Text("클래스 변경:", style: TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: ['bus', 'generator', 'load', 'transformer'].map((cls) {
            final isCurrent = node.className.toLowerCase() == cls;
            return ChoiceChip(
              label: Text(cls.toUpperCase(), style: const TextStyle(fontSize: 11)),
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
              const Text("결선 검수 큐 (Connection Queue)", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              // Sort dropdown
              DropdownButton<String>(
                value: _connSortOption,
                dropdownColor: const Color(0xFF252538),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'SEVERITY', child: Text("정렬: 위험도순")),
                  DropdownMenuItem(value: 'ID_ASC', child: Text("정렬: Line ID순")),
                ],
                onChanged: (val) => setState(() => _connSortOption = val ?? 'SEVERITY'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterableConnStatBadge("전체 보기", _workingLines.length, Colors.white70, 'ALL'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("오류만 보기", _criticalIssuesCount, Colors.redAccent, 'ERROR_ONLY'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("검토 필요", _lineAmbiguousCount, Colors.orangeAccent, 'AMBIGUOUS'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("자동 승인", _workingLines.where((l) => l.reviewStatus == 'CONFIRMED' && !l.source.contains('human')).length, Colors.tealAccent, 'AUTO_CONFIRMED'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("수동 승인", _workingLines.where((l) => l.reviewStatus == 'CONFIRMED' && l.source.contains('human')).length, Colors.greenAccent, 'HUMAN_CONFIRMED'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("미검수", _lineDetectedCount, Colors.lightBlueAccent, 'DETECTED'),
                const SizedBox(width: 6),
                _buildFilterableConnStatBadge("제외", _lineRejectedCount, Colors.grey, 'REJECTED'),
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
          color: _criticalIssuesCount > 0 ? Colors.redAccent.withValues(alpha: 0.6) : Colors.green.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _criticalIssuesCount > 0 ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: _criticalIssuesCount > 0 ? Colors.redAccent : Colors.greenAccent,
              ),
              const SizedBox(width: 6),
              const Text("토폴로지 전기적 무결성 검증", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
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
              color: _criticalIssuesCount > 0 ? Colors.redAccent : Colors.greenAccent,
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
                  color: isError ? Colors.red.withValues(alpha: 0.15) : Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(isError ? Icons.cancel : Icons.warning, size: 12, color: isError ? Colors.redAccent : Colors.orangeAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        "[${iss['code']}] ${iss['message']}",
                        style: const TextStyle(color: Colors.white, fontSize: 10),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.timeline, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text("선로 목록 (${list.length}개):", style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, idx) {
              final l = list[idx];
              final isSelected = _selectedLine?.lineId == l.lineId;
              final isAmbiguous = l.reviewStatus == 'AMBIGUOUS';
              final color = isAmbiguous ? Colors.orangeAccent : (l.reviewStatus == 'CONFIRMED' ? Colors.greenAccent : Colors.cyanAccent);

              return GestureDetector(
                onTap: () => setState(() => _selectedLine = l),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? color.withValues(alpha: 0.3) : const Color(0xFF252538),
                    border: Border.all(color: isSelected ? color : Colors.grey.withValues(alpha: 0.4), width: isSelected ? 1.8 : 1.0),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l.effectiveDisplayLabel,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedLinePanel() {
    final line = _selectedLine!;
    final isAmbiguous = line.reviewStatus == 'AMBIGUOUS';
    final connStr = line.endpointsDisplay ?? (line.connectedTo.isNotEmpty ? line.connectedTo.join(" ↔ ") : "미연결");

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
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isAmbiguous ? Colors.orangeAccent : (line.reviewStatus == 'CONFIRMED' ? Colors.green : Colors.cyan),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(line.reviewStatus, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text("내부 ID: ${line.lineId}  |  연결: $connStr", style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
        Text("추적 방식: ${line.traceMethod}  |  단자: ${line.sourcePort} ➔ ${line.targetPort}", style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 12),

        // Action Buttons
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmLine(line),
                icon: const Icon(Icons.check, size: 16),
                label: const Text("선로 승인"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _rejectLine(line),
                icon: const Icon(Icons.close, size: 16),
                label: const Text("선로 제외"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800, foregroundColor: Colors.white),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Reconnect Candidate Chips
        if (line.candidateTargets.isNotEmpty) ...[
          const Text("연결 대상 Bus 재지정:", style: TextStyle(color: Colors.grey, fontSize: 11)),
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
                "로컬 분석 모드 (Local Analysis) • 무료 • 즉시 응답",
                style: TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_selectedNode != null)
                Text("선택: ${_selectedNode!.effectiveDisplayLabel}", style: const TextStyle(color: Colors.white70, fontSize: 10)),
              if (_selectedLine != null)
                Text("선택: ${_selectedLine!.effectiveDisplayLabel}", style: const TextStyle(color: Colors.white70, fontSize: 10)),
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
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.32),
                  decoration: BoxDecoration(
                    color: isUser ? Colors.blueAccent.withValues(alpha: 0.85) : const Color(0xFF252538),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isUser ? Colors.blueAccent : Colors.grey.withValues(alpha: 0.3),
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
                              color: isUser ? Colors.white70 : Colors.blueAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        msg.text,
                        style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
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
                if (_selectedNode != null) _buildPromptChip("🔍 왜 ${_selectedNode!.effectiveDisplayLabel}가 의심이야?"),
                if (_selectedNode != null) _buildPromptChip("⚡ ${_selectedNode!.effectiveDisplayLabel} 클래스를 바꾸면 어떤 영향이 있어?"),
                if (_selectedLine != null) _buildPromptChip("🔗 선택한 선로 ${_selectedLine!.effectiveDisplayLabel}가 왜 문제야?"),
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
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF252538),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                  ),
                  onSubmitted: _sendChatMessage,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isChatLoading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent))
                    : const Icon(Icons.send, color: Colors.blueAccent),
                onPressed: _isChatLoading ? null : () => _sendChatMessage(_chatInputController.text),
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
        label: Text(prompt, style: const TextStyle(fontSize: 10, color: Colors.white70)),
        backgroundColor: const Color(0xFF252538),
        onPressed: () => _sendChatMessage(prompt),
      ),
    );
  }

  // --- Bottom Gate Footer ---

  Widget _buildBottomGateFooter() {
    final isConnectionPhase = _currentPhase == ReviewPhase.connectionReview;

    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF181825),
      child: Column(
        children: [
          if (!isConnectionPhase) ...[
            // Human Completeness Confirmation Checkbox
            CheckboxListTile(
              value: _humanCompletenessConfirmed,
              onChanged: (val) => setState(() => _humanCompletenessConfirmed = val ?? false),
              title: const Text("원본 회로도 전체와의 대조 확인 완료 (Completeness Confirmed)", style: TextStyle(color: Colors.white, fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: Colors.blueAccent,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _canVerifyObjectGate ? _verifyObjectGate : null,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text("객체 검수 완료 (Gate 통과)"),
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
                    onPressed: _proceedToConnectionReview,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text("다음: 결선 인식 ➔"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _canVerifyFinalGate ? _verifyFinalGate : null,
                    icon: const Icon(Icons.verified, size: 16),
                    label: const Text("회로도 검증 완료 (Final Gate)"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // --- Verified Final View ---

  Widget _buildVerifiedFinalView() {
    final sld = _verifiedSld!;
    return Center(
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF252538),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.5), width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_user, color: Colors.greenAccent, size: 64),
            const SizedBox(height: 16),
            const Text("Verified SLD 생성 완료! 🎉", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text("문서 ID: ${sld.documentId}  |  상태: ${sld.status}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 16),
            Text("• 확정 객체 수: ${sld.nodes.length}개\n• 검증 결선 수: ${sld.lines.length}개", style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _handoffToFlutterCanvas,
              icon: const Icon(Icons.open_in_new),
              label: const Text("Flutter Canvas로 전달 (Proceed to Canvas)"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoSelectionPrompt(String type) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32.0),
        child: Text("화면에서 $type을(를) 클릭하여 선택하세요.", style: const TextStyle(color: Colors.grey, fontSize: 13)),
      ),
    );
  }

  Widget _buildFilterableStatBadge(String label, int count, Color color, String filterKey) {
    final isSelected = _objFilterStatus == filterKey;
    return GestureDetector(
      onTap: () {
        setState(() {
          _objFilterStatus = filterKey;
          // Auto select first matching node
          final matches = _filteredAndSortedWorkingNodes;
          if (matches.isNotEmpty) {
            _selectedNode = matches.first;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.3) : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSelected ? color : color.withValues(alpha: 0.4), width: isSelected ? 1.5 : 1.0),
        ),
        child: Text("$label: $count", style: TextStyle(color: color, fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  Widget _buildFilterableConnStatBadge(String label, int count, Color color, String filterKey) {
    final isSelected = _connFilterStatus == filterKey;
    return GestureDetector(
      onTap: () {
        setState(() {
          _connFilterStatus = filterKey;
          // Auto select first matching line
          final matches = _filteredAndSortedWorkingLines;
          if (matches.isNotEmpty) {
            _selectedLine = matches.first;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.3) : const Color(0xFF252538),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSelected ? color : color.withValues(alpha: 0.4), width: isSelected ? 1.5 : 1.0),
        ),
        child: Text("$label: $count", style: TextStyle(color: color, fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
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
      child: Text("$label: $count", style: TextStyle(color: color, fontSize: 10)),
    );
  }
}
