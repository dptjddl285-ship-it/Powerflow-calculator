import 'widgets/excel_mismatch_dialog.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'screens/review_page.dart';
import 'models/drawing_element.dart';
import 'models/powerlens_assistant_context.dart';
import 'services/powerlens_ai_service.dart';
import 'services/review_api_service.dart';
import 'widgets/inspector_panel.dart';
import 'widgets/home/powerlens_home_empty_state.dart';
import 'widgets/powerlens_ai/powerlens_ai_button.dart';
import 'widgets/powerlens_ai/powerlens_ai_panel.dart';

// 절대 끊기지 않는 무한 캔버스의 크기 (10만 픽셀)
const double CANVAS_SIZE = 100000.0;
const double CANVAS_CENTER = 50000.0;

void main() => runApp(const PowerDesignerApp());

class PowerDesignerApp extends StatelessWidget {
  const PowerDesignerApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'Power Designer Pro',
    home: PowerCanvasPage(),
    debugShowCheckedModeBanner: false,
  );
}

class PowerCanvasPage extends StatefulWidget {
  const PowerCanvasPage({super.key});
  @override
  State<PowerCanvasPage> createState() => PowerCanvasPageState();
}

class PowerCanvasPageState extends State<PowerCanvasPage>
    with TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();
  final FocusNode _canvasFocusNode = FocusNode();

  late AnimationController _flowAnimController;

  List<DrawingElement> elements = [];
  List<List<DrawingElement>> historyStack = [];
  List<List<DrawingElement>> redoStack = [];

  Tool selectedTool = Tool.move;
  DrawingElement? selectedElement;
  Offset? lineStart;
  Offset? lineMid;
  Offset? currentMousePos;
  String? pendingStartId;
  Offset? pendingStartAnchor;
  DrawingElement? snapTarget;

  Map<String, dynamic>? lastSimulationResult;
  int? excelBranchCount;
  bool showResultOverlay = false;
  bool showFlowDirection = true;
  bool showValueLabels = false;
  bool isInspectorOpen = false;
  bool isSimulating = false;
  bool _isAiPanelOpen = false;
  final GlobalKey _canvasStackKey = GlobalKey();
  final GlobalKey _powerFlowButtonKey = GlobalKey();
  final GlobalKey _resultButtonKey = GlobalKey();
  Alignment? _manualLensyAlignment;
  String? _manualLensyTarget;
  Alignment? _measuredLensyAlignment;
  String? _measuredLensyTarget;
  String? _lastLensySyncTarget;
  final ReviewApiService _apiService = ReviewApiService();

  @override
  void initState() {
    super.initState();
    _flowAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _flowAnimController.addListener(() {
      if (showResultOverlay &&
          showFlowDirection &&
          lastSimulationResult != null) {
        setState(() {});
      }
    });

    PowerLensAIService.instance.registerActionHandler(_handleAppAction);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetCamera();
      _canvasFocusNode.requestFocus();
      PowerLensAIService.instance.onStageChanged('HOME');
    });
  }

  @override
  void dispose() {
    _flowAnimController.dispose();
    PowerLensAIService.instance.unregisterActionHandler(_handleAppAction);
    _canvasFocusNode.dispose();
    super.dispose();
  }

  Future<bool> _handleAppAction(
    PowerLensAppAction action,
    Map<String, dynamic>? params,
  ) async {
    if (!mounted) return false;
    // ReviewPage owns the global bridge while it is visible. Do not reopen a
    // second review route or run a canvas action underneath that page.
    // ReviewPage calls goHome directly for the explicit home handoff.
    if (action != PowerLensAppAction.goHome &&
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    switch (action) {
      case PowerLensAppAction.goHome:
        setState(() {
          elements.clear();
          selectedElement = null;
          lastSimulationResult = null;
          showResultOverlay = false;
          isInspectorOpen = false;
          _flowAnimController.stop();
          _resetCamera();
        });
        PowerLensAIService.instance.onStageChanged('HOME');
        return true;
      case PowerLensAppAction.triggerPhotoUpload:
        await _uploadImageToAI();
        return true;
      case PowerLensAppAction.triggerExcelUpload:
        await _importExcelCase();
        return true;
      case PowerLensAppAction.loadSampleDiagram:
        await _loadSampleDiagram();
        return true;
      case PowerLensAppAction.showReviewIssues:
      case PowerLensAppAction.approveCurrentAndNext:
      case PowerLensAppAction.connectionFullReview:
      case PowerLensAppAction.connectionLinesOnly:
      case PowerLensAppAction.connectionNextLine:
      case PowerLensAppAction.handoffToCanvas:
        // ReviewPage owns review evidence and its gate state. Returning false
        // lets the visible ReviewPage handler consume these actions while the
        // canvas remains a safe no-op for review-only commands.
        return false;
      case PowerLensAppAction.goToNextStage:
        if (elements.isEmpty) {
          await _openReviewPage();
          return true;
        }
        if (lastSimulationResult == null) {
          await _sendDataToServer();
          return true;
        }
        return false;
      case PowerLensAppAction.goToPreviousStage:
        if (historyStack.isNotEmpty) {
          _undo();
          return true;
        }
        return false;
      case PowerLensAppAction.runPowerFlow:
        if (elements.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("먼저 도면을 분석하거나 샘플을 불러와주세요.")),
            );
          }
          return false;
        }
        await _sendDataToServer();
        return true;
      case PowerLensAppAction.showPowerFlowResults:
        if (lastSimulationResult == null) return false;
        if (mounted) {
          setState(() => showResultOverlay = true);
          _showPowerFlowResultDialog(lastSimulationResult!);
        }
        return true;
      case PowerLensAppAction.toggleFlowDirection:
        setState(() {
          showFlowDirection = !showFlowDirection;
          showResultOverlay = true;
          if (showFlowDirection && lastSimulationResult != null) {
            _flowAnimController.repeat();
          } else {
            _flowAnimController.stop();
          }
        });
        return true;
      case PowerLensAppAction.showFlowDirection:
        if (lastSimulationResult == null) return false;
        setState(() {
          showFlowDirection = true;
          showResultOverlay = true;
          _flowAnimController.repeat();
        });
        return true;
      case PowerLensAppAction.hideFlowDirection:
        setState(() {
          showFlowDirection = false;
          _flowAnimController.stop();
        });
        return true;
      case PowerLensAppAction.toggleValueLabels:
        setState(() {
          showValueLabels = !showValueLabels;
        });
        return true;
      case PowerLensAppAction.showValueLabels:
        if (lastSimulationResult == null) return false;
        setState(() => showValueLabels = true);
        return true;
      case PowerLensAppAction.hideValueLabels:
        setState(() => showValueLabels = false);
        return true;
      case PowerLensAppAction.explainCurrentStage:
        return true;
    }
  }

  void _resetCamera() {
    final size = MediaQuery.of(context).size;
    if (size.width == 0) return;
    _transformationController.value = Matrix4.identity()
      ..translate(
        -(CANVAS_CENTER - size.width / 2),
        -(CANVAS_CENTER - size.height / 2),
        0.0,
      );
  }

  Rect? _getContentBounds() {
    if (elements.isEmpty) return null;
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;

    for (var e in elements) {
      minX = math.min(minX, e.position.dx - e.width / 2);
      minY = math.min(minY, e.position.dy - e.height / 2);
      maxX = math.max(maxX, e.position.dx + e.width / 2);
      maxY = math.max(maxY, e.position.dy + e.height / 2);

      if (e.endPosition != null) {
        minX = math.min(minX, e.endPosition!.dx);
        minY = math.min(minY, e.endPosition!.dy);
        maxX = math.max(maxX, e.endPosition!.dx);
        maxY = math.max(maxY, e.endPosition!.dy);
      }
      if (e.midPosition != null) {
        minX = math.min(minX, e.midPosition!.dx);
        minY = math.min(minY, e.midPosition!.dy);
        maxX = math.max(maxX, e.midPosition!.dx);
        maxY = math.max(maxY, e.midPosition!.dy);
      }
    }

    if (minX == double.infinity) return null;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  void _zoomToFit() {
    final bounds = _getContentBounds();
    if (bounds == null) return;

    final mediaQuery = MediaQuery.of(context);
    final double availWidth =
        mediaQuery.size.width - 64 - (isInspectorOpen ? 320 : 0);
    final double availHeight = mediaQuery.size.height - kToolbarHeight;

    if (availWidth <= 100 || availHeight <= 100) return;

    const double margin = 100.0;
    final double contentWidth = bounds.width + margin * 2;
    final double contentHeight = bounds.height + margin * 2;

    final double scaleX = availWidth / contentWidth;
    final double scaleY = availHeight / contentHeight;
    double targetScale = math.min(scaleX, scaleY).clamp(0.2, 2.0);

    final double centerX = bounds.center.dx;
    final double centerY = bounds.center.dy;

    final double screenCenterX = availWidth / 2;
    final double screenCenterY = availHeight / 2;

    final double tx = screenCenterX - (centerX * targetScale);
    final double ty = screenCenterY - (centerY * targetScale);

    setState(() {
      _transformationController.value = Matrix4.identity()
        ..translate(tx, ty)
        ..scale(targetScale);
    });
  }

  void _zoom(double factor) {
    final size = MediaQuery.of(context).size;
    final center = Offset(size.width / 2, size.height / 2);
    final matrix = _transformationController.value.clone();
    matrix.translate(center.dx, center.dy);
    matrix.scale(factor, factor);
    matrix.translate(-center.dx, -center.dy);
    _transformationController.value = matrix;
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    final focusedWidget = FocusManager.instance.primaryFocus;
    // Any focus outside canvas on an editable text field means the user is typing
    final isEditingInput = focusedWidget != null && focusedWidget != _canvasFocusNode && (
      focusedWidget.context?.widget is EditableText ||
      focusedWidget.toString().contains('EditableText') ||
      focusedWidget.toString().contains('TextField')
    );

    if (isEditingInput) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        FocusManager.instance.primaryFocus?.unfocus();
        _canvasFocusNode.requestFocus();
      }
      // CRITICAL: Return immediately so Backspace, Delete, and shortcuts NEVER delete elements or trigger actions while typing!
      return;
    }

    // Zoom to fit: Ctrl + Space, Ctrl + F, or Ctrl + 0 (Prevents accidental trigger when typing 'F' or Space in labels)
    if (isCtrl && (event.logicalKey == LogicalKeyboardKey.space ||
                   event.logicalKey == LogicalKeyboardKey.keyF ||
                   event.logicalKey == LogicalKeyboardKey.digit0)) {
      _zoomToFit();
      return;
    }

    // Only allow element deletion when Delete key is pressed on canvas
    if (event.logicalKey == LogicalKeyboardKey.delete && selectedElement != null && _canvasFocusNode.hasFocus) {
      _deleteSelectedElement();
      return;
    } else if (selectedElement != null && _canvasFocusNode.hasFocus && (
        event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      final double step = isShift ? 10.0 : 1.0;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _moveElement(selectedElement!, Offset(-step, 0));
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _moveElement(selectedElement!, Offset(step, 0));
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _moveElement(selectedElement!, Offset(0, -step));
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _moveElement(selectedElement!, Offset(0, step));
      }
      return;
    } else if (selectedElement != null && (isCtrl || isAlt) && event.logicalKey == LogicalKeyboardKey.keyR) {
      // Rotation now strictly requires Ctrl+R (or Alt+R) combination, preventing single 'R' collisions during label input
      _rotateElement(selectedElement!);
      return;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        selectedTool = Tool.move;
        selectedElement = null;
        lineStart = null;
        lineMid = null;
        pendingStartId = null;
      });
    } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (isShift) {
        _redo();
      } else {
        _undo();
      }
    } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyY) {
      _redo();
    } else if (isAlt || (isCtrl && isShift)) {
      // Tool switching requires Alt+Key (or Ctrl+Shift+Key) to prevent single B/G/L/T/W collisions during label typing
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        setState(() => selectedTool = Tool.move);
      } else if (event.logicalKey == LogicalKeyboardKey.keyB) {
        setState(() {
          selectedTool = Tool.bus;
          selectedElement = null;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
        setState(() {
          selectedTool = Tool.generator;
          selectedElement = null;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.keyL) {
        setState(() {
          selectedTool = Tool.load;
          selectedElement = null;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.keyT) {
        setState(() {
          selectedTool = Tool.transformer;
          selectedElement = null;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.keyW) {
        setState(() {
          selectedTool = Tool.line;
          selectedElement = null;
        });
      }
    }
  }

  void _rotateElement(DrawingElement e) {
    _saveState();
    setState(() {
      if (e.type == Tool.bus && e.width < e.height) {
        double temp = e.width;
        e.width = e.height;
        e.height = temp;
      }
      e.angle = (e.angle + math.pi / 2) % (math.pi * 2);
    });
  }

  void _deleteSelectedElement() {
    if (selectedElement == null) return;
    _saveState();
    final target = selectedElement!;
    setState(() {
      if (target.type == Tool.bus) {
        elements.removeWhere(
          (el) =>
              el.id == target.id ||
              el.parentBusId == target.id ||
              el.startElementId == target.id ||
              el.endElementId == target.id,
        );
      } else {
        elements.remove(target);
      }
      selectedElement = null;
    });
  }

  void _handleBusRenamed(DrawingElement e) {
    if (e.type == Tool.bus && e.label.isNotEmpty) {
      String oldId = e.id;
      String newBusNum = _getBusNum(e.label);
      String newId = "bus_$newBusNum";

      if (oldId != newId) {
        e.id = newId;
        for (var el in elements) {
          if (el.parentBusId == oldId) el.parentBusId = newId;
          if (el.startElementId == oldId) el.startElementId = newId;
          if (el.endElementId == oldId) el.endElementId = newId;
        }
      }
      _updateConnectedElementsId(e);
    }
  }

  void _confirmClearCanvas() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("도면 초기화"),
        content: const Text("도면의 모든 요소를 지우시겠습니까? (Ctrl+Z로 되돌릴 수 있습니다)"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _saveState();
              setState(() {
                elements.clear();
                selectedElement = null;
                lineStart = null;
                lineMid = null;
                pendingStartId = null;
                lastSimulationResult = null;
                _resetCamera();
              });
            },
            child: const Text("초기화", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showUserGuideDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 750, maxHeight: 680),
          child: DefaultTabController(
            length: 4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  color: const Color(0xFF0F172A),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.purpleAccent, width: 1.5),
                        ),
                        child: const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 22),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "PowerLens Pro 가이드 · AI 도면 검수실 (메인)",
                              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 2),
                            Text(
                              "AI 멀티에이전트 도면 검수 & AC 조류계산 완벽 가이드",
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        tooltip: "닫기",
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                // TabBar
                Container(
                  color: const Color(0xFF1E293B),
                  child: const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    indicatorColor: Colors.purpleAccent,
                    indicatorWeight: 3,
                    labelColor: Colors.purpleAccent,
                    unselectedLabelColor: Colors.white60,
                    labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    tabs: [
                      Tab(icon: Icon(Icons.auto_awesome, size: 18), text: "AI 도면 검수실 (메인)"),
                      Tab(icon: Icon(Icons.account_tree_outlined, size: 18), text: "계통 해석 순서"),
                      Tab(icon: Icon(Icons.keyboard, size: 18), text: "키보드 단축키 (Ctrl+R)"),
                      Tab(icon: Icon(Icons.mouse, size: 18), text: "마우스 & 캔버스 조작"),
                    ],
                  ),
                ),
                // Tab Content
                Expanded(
                  child: Container(
                    color: Colors.white,
                    child: TabBarView(
                      children: [
                        _buildAiReviewTab(ctx),
                        _buildWorkflowTab(),
                        _buildShortcutsTab(),
                        _buildCanvasControlsTab(),
                      ],
                    ),
                  ),
                ),
                // Footer
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(top: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome, size: 16, color: Colors.purpleAccent),
                          const SizedBox(width: 6),
                          Text(
                            "💡 Tip: 상단 [AI 도면 검수실] 버튼을 누르면 즉시 검수실로 이동합니다.",
                            style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade800, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F172A),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text("닫기", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiReviewTab(BuildContext ctx) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.purple.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 3)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 28),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "AI 도면 검수실이란?",
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "손그림/CAD 단선도 이미지와 계통 엑셀 데이터 사이의 불일치(부품 누락, 잘못된 선로 연결, 모선 번호 오류)를 멀티에이전트 AI가 스스로 발견하고 정밀 교정해주는 핵심 기능입니다.",
                        style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Action Button to directly enter
          Center(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C3AED),
                foregroundColor: Colors.white,
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                _openReviewPage();
              },
              icon: const Icon(Icons.open_in_new, size: 18, color: Colors.amberAccent),
              label: const Text("✨ 지금 AI 도면 검수실 열기", style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 20),

          _buildShortcutSectionTitle("🔍 4단계 체계적 검수 프로세스 (Workflow)"),
          const SizedBox(height: 10),
          _buildReviewPhaseCard(
            phaseNum: "Phase 1",
            title: "객체 검수 (Object Review)",
            desc: "도면 이미지에서 추출된 모선(Bus), 발전기(Gen), 부하(Load), 변압기(Tr)의 바운딩 박스와 AI 신뢰도(Confidence)를 확인합니다. 미인식된 부품은 추가하고 오인식된 부품은 수정/제외합니다.",
            color: Colors.blue,
            icon: Icons.filter_center_focus,
          ),
          const SizedBox(height: 12),
          _buildReviewPhaseCard(
            phaseNum: "Phase 2",
            title: "모선 번호 매핑 (Bus Mapping Review)",
            desc: "도면 텍스트 OCR 및 기하학적 공간 근접도를 기반으로 각 모선에 고유 번호(Bus Number)를 자동/수동 부여하고 인접 발전기/부하로 번호를 전파합니다. 중복 번호 및 미부여 문제를 해결합니다.",
            color: Colors.amber.shade900,
            icon: Icons.swap_horiz,
          ),
          const SizedBox(height: 12),
          _buildReviewPhaseCard(
            phaseNum: "Phase 3",
            title: "선로 결선 검수 (Connection Review)",
            desc: "확정된 모선 노드를 기반으로 픽셀 스켈레톤화 및 선로 추적을 실행하여 송전선로(Branch), 변압기, 인입선 결선을 검수합니다. 모호한 선로(Ambiguous) 수동 교정 및 단선/고립 모선 토폴로지 결함을 해결합니다.",
            color: Colors.teal,
            icon: Icons.polyline,
          ),
          const SizedBox(height: 12),
          _buildReviewPhaseCard(
            phaseNum: "Phase 4",
            title: "최종 확인 & 엑셀 대조 (Verified Final & Excel)",
            desc: "검증이 완료된 단선도(VerifiedSLD)를 확정하고, 전력계통 엑셀 파일(.xlsx)을 업로드하여 도면과 엑셀 간 설비 사양(모선/선로/발전기/부하)을 교차 대조(Cross-check)합니다. 불일치 발생 시 AI 진단 및 자동 보정 후 캔버스로 전송합니다.",
            color: Colors.green,
            icon: Icons.verified,
          ),
          const SizedBox(height: 20),

          _buildShortcutSectionTitle("🤖 검수실 전용 Agentic AI 협업 기능 (우측 패널)"),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.purple.shade200),
            ),
            child: const Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.history_edu, color: Colors.purple, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("활동기록 (Agent Activity - 추론 과정 및 감사 로그)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                          SizedBox(height: 2),
                          Text("AI가 왜 특정 설비를 의심(Suspicious)으로 판정했는지, 어떤 규칙과 근거로 문제를 탐지했는지 단계별 사고 과정(Reasoning Steps)과 도구 실행 이력을 실시간으로 투명하게 확인합니다.", style: TextStyle(fontSize: 12, color: Colors.black87)),
                        ],
                      ),
                    ),
                  ],
                ),
                Divider(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.chat_bubble_outline, color: Colors.purple, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("AI도우미 (Review Assistant - 상황 맞춤 진단 및 검수 가이드)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                          SizedBox(height: 2),
                          Text("도면의 객체나 선로를 선택한 후 원클릭 추천 칩(우선순위 요약, 다음 단계 가이드, 의심 판정 근거, 클래스 변경 시 계통 영향 분석)을 눌러 실시간 진단 조언을 확인할 수 있습니다. (자연어로 도면을 자동 수정하는 봇이 아니며, 실제 객체 승인·수정·제외는 검수 패널의 전용 조작 버튼으로 안전하게 진행합니다.)", style: TextStyle(fontSize: 12, color: Colors.black87)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewPhaseCard({
    required String phaseNum,
    required String title,
    required String desc,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              phaseNum,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 6),
                    Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(desc, style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildShortcutSectionTitle("🎯 부품 회전 및 편집 조작 (Ctrl 조합키)"),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.indigo.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.indigo.shade200),
            ),
            child: Column(
              children: [
                _buildShortcutItem("Ctrl + R", "선택한 부품 90° 회전 (모선 가로/세로 전환, 발전기/부하/변압기 각도 회전, Alt+R 지원)", isHighlight: true),
                const Divider(height: 14),
                _buildShortcutItem("Del", "선택한 부품 즉시 삭제 (텍스트 입력 중 오동작 방지)"),
                const Divider(height: 14),
                _buildShortcutItem("방향키 (↑ ↓ ← →)", "선택 부품 1px 미세 이동 (Shift 누르면 10px씩 고속 이동)"),
                const Divider(height: 14),
                _buildShortcutItem("Ctrl + Z  /  Ctrl + Y", "실행 취소 (Undo)  /  다시 실행 (Redo)"),
                const Divider(height: 14),
                _buildShortcutItem("Ctrl + Space  /  Ctrl + F", "도면 전체 화면 맞춤 (Zoom to Fit, Ctrl+0 지원)"),
                const Divider(height: 14),
                _buildShortcutItem("Esc", "선택 해제 또는 현재 도구 취소"),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _buildShortcutSectionTitle("🛠️ 도구 빠른 선택 (Alt + 조합키)"),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                _buildShortcutItem("Alt + V (또는 Ctrl+Shift+V)", "선택 및 이동 도구 (Move Tool)"),
                const Divider(height: 14),
                _buildShortcutItem("Alt + B (또는 Ctrl+Shift+B)", "모선 (Bus) 그리기 도구"),
                const Divider(height: 14),
                _buildShortcutItem("Alt + G (또는 Ctrl+Shift+G)", "발전기 (Generator) 배치 도구"),
                const Divider(height: 14),
                _buildShortcutItem("Alt + L (또는 Ctrl+Shift+L)", "부하 (Load) 배치 도구"),
                const Divider(height: 14),
                _buildShortcutItem("Alt + T (또는 Ctrl+Shift+T)", "변압기 (Transformer) 배치 도구"),
                const Divider(height: 14),
                _buildShortcutItem("Alt + W (또는 Ctrl+Shift+W)", "송전선로 연결 도구 (Wire / Line)"),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
    );
  }

  Widget _buildShortcutItem(String keys, String desc, {bool isHighlight = false}) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isHighlight ? const Color(0xFF4F46E5) : Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isHighlight ? const Color(0xFF4338CA) : Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Text(
            keys,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
              color: isHighlight ? Colors.white : const Color(0xFF0F172A),
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            desc,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.w500,
              color: isHighlight ? const Color(0xFF3730A3) : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCanvasControlsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGuideCard(
            icon: Icons.mouse,
            iconColor: Colors.blueAccent,
            title: "마우스 조작 및 캔버스 탐색",
            items: const [
              "마우스 휠 스크롤: 캔버스 확대(+) 및 축소(-)가 마우스 커서 위치를 중심으로 부드럽게 동작합니다.",
              "우클릭 드래그 or 휠 클릭 드래그: 캔버스 무한 공간을 상하좌우로 자유롭게 이동(Pan)합니다.",
              "좌클릭: 부품을 클릭하면 선택되며 우측에 속성 패널(Inspector)이 자동으로 열립니다.",
              "드래그 이동: 선택한 부품을 원하는 위치로 끌어서 직관적으로 재배치할 수 있습니다.",
            ],
          ),
          const SizedBox(height: 16),
          _buildGuideCard(
            icon: Icons.timeline,
            iconColor: Colors.teal,
            title: "선로 연결 및 형태 정형화 (Smart Routing)",
            items: const [
              "선로 도구(W)를 선택한 뒤 연결할 첫 번째 모선을 클릭하고, 대상 모선을 클릭하면 자동으로 연결선이 생성됩니다.",
              "상단 마술봉(선로 정형화) 메뉴에서 '자연스러운 직선화' 또는 '90° 직각(맨해튼) 정형화'를 클릭하면 손그림 배선이 깔끔하게 정돈됩니다.",
            ],
          ),
          const SizedBox(height: 16),
          _buildGuideCard(
            icon: Icons.tune,
            iconColor: Colors.purple,
            title: "부품 속성 편집 (Inspector Panel)",
            items: const [
              "우측 패널에서 모선 종류(Slack, PV, PQ), 기준 전압, 목표 전압을 설정할 수 있습니다.",
              "발전기 및 부하의 발전량(MW/MVAR)과 송전선로 직렬 임피던스(R, X, B)를 즉시 수정 가능합니다.",
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWorkflowTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStepCard(
            step: "1",
            title: "계통 구성 (직접 그리기 또는 엑셀 가져오기)",
            desc: "좌측 도구(B: 모선, W: 선로, G: 발전기, L: 부하)로 계통을 직접 설계하거나, 상단 [엑셀 가져오기]를 눌러 IEEE 24모선(case24_psse.xlsx) 등 표준 케이스를 즉시 로드할 수 있습니다.",
            color: Colors.blue,
          ),
          const SizedBox(height: 14),
          _buildStepCard(
            step: "2",
            title: "기준 모선(Slack) 및 파라미터 확인",
            desc: "계통 내 최소 1개의 모선은 슬랙 모선(Slack Bus, V=1.0 pu, θ=0°)으로 지정되어야 합니다. 각 발전기의 유효전력(PG)과 부하량(PD, QD)을 우측 속성 패널에서 확인합니다.",
            color: Colors.amber.shade800,
          ),
          const SizedBox(height: 14),
          _buildStepCard(
            step: "3",
            title: "조류계산 실행 (AC Newton-Raphson)",
            desc: "상단 우측의 파란색 [조류계산 실행] 버튼을 클릭합니다. 백엔드 전력 조류 해석 엔진이 4블록 야코비 행렬과 극좌표계 전력방정식을 풀어 1초 내에 수렴 결과를 도출합니다.",
            color: Colors.green,
          ),
          const SizedBox(height: 14),
          _buildStepCard(
            step: "4",
            title: "결과 확인 및 엑셀 보고서 다운로드",
            desc: "캔버스 위에 각 선로를 흐르는 유효전력/무효전력(MW/MVAR)과 방향 화살표가 표시됩니다. 상단 [수치 결과표] 버튼을 누르면 모선별 전압 크기/위상각 및 총 계통 손실을 확인하고 엑셀로 내려받을 수 있습니다.",
            color: Colors.purple,
          ),
        ],
      ),
    );
  }

  Widget _buildGuideCard({required IconData icon, required Color iconColor, required String title, required List<String> items}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 10),
          ...items.map((it) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("• ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                Expanded(child: Text(it, style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4))),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildStepCard({required String step, required String title, required String desc, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: color,
            child: Text(step, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 4),
                Text(desc, style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _saveState() {
    historyStack.add(elements.map((e) => e.copy()).toList());
    redoStack.clear();
    if (historyStack.length > 30) historyStack.removeAt(0);
  }

  void _undo() {
    if (historyStack.isEmpty) return;
    setState(() {
      redoStack.add(elements.map((e) => e.copy()).toList());
      elements = historyStack.removeLast();
      selectedElement = null;
    });
  }

  void _redo() {
    if (redoStack.isEmpty) return;
    setState(() {
      historyStack.add(elements.map((e) => e.copy()).toList());
      elements = redoStack.removeLast();
      selectedElement = null;
    });
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    double l2 = (a - b).distanceSquared;
    if (l2 == 0.0) return (p - a).distance;
    double t =
        ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy)))
        .distance;
  }

  Offset _getSnapPoint(DrawingElement e, Offset touchPos) {
    if (e.type == Tool.bus) {
      double cosA = math.cos(-e.angle); double sinA = math.sin(-e.angle);
      Offset rel = touchPos - e.position;
      double localX = (rel.dx * cosA - rel.dy * sinA).clamp(-e.width/2, e.width/2);
      double localY = (rel.dx * sinA + rel.dy * cosA).clamp(-e.height/2, e.height/2);
      cosA = math.cos(e.angle); sinA = math.sin(e.angle);
      return e.position + Offset(localX * cosA - localY * sinA, localX * sinA + localY * cosA);
    } else if (e.type == Tool.generator || e.type == Tool.load || e.type == Tool.transformer) {
      Offset delta = touchPos - e.position;
      double dist = delta.distance;
      double r = math.max(e.width, e.height) / 2;
      if (dist > 0) return e.position + (delta / dist) * r;
      return e.position;
    }
    return e.position;
  }

  List<Offset> _truncateSpursAtBus(List<Offset> points, DrawingElement? bus) {
    if (bus == null || bus.type != Tool.bus || points.length < 3) return points;
    final double x1 = bus.position.dx - bus.width / 2 - 10;
    final double x2 = bus.position.dx + bus.width / 2 + 10;
    final double y1 = bus.position.dy - bus.height / 2 - 10;
    final double y2 = bus.position.dy + bus.height / 2 + 10;

    for (int i = points.length - 1; i > 0; i--) {
      final pt = points[i];
      if (pt.dx >= x1 && pt.dx <= x2 && pt.dy >= y1 && pt.dy <= y2) {
        final prev = points[i - 1];
        if (!(prev.dx >= x1 && prev.dx <= x2 && prev.dy >= y1 && prev.dy <= y2)) {
          return points.sublist(0, i + 1);
        }
      }
    }
    return points;
  }

  List<Offset> _pruneBusTerminalHooks(
    List<Offset> points,
    DrawingElement? startEl,
    DrawingElement? endEl,
  ) {
    if (points.length < 3) return points;
    List<Offset> pts = List.from(points);

    // 1. Prune contour hook at END (when endEl is a Bus)
    if (endEl != null && endEl.type == Tool.bus) {
      final int qTurns = ((endEl.angle / (math.pi / 2)).round() % 4 + 4) % 4;
      final bool isVert = (qTurns % 2 == 0) ? (endEl.height > endEl.width) : (endEl.width > endEl.height);
      final double busHalfW = (qTurns % 2 == 0) ? endEl.width / 2 : endEl.height / 2;
      final double busHalfH = (qTurns % 2 == 0) ? endEl.height / 2 : endEl.width / 2;

      while (pts.length >= 3) {
        final Offset pLast = pts.last;
        final Offset pPen = pts[pts.length - 2];
        final Offset pAnte = pts[pts.length - 3];

        final double dxLast = (pLast.dx - pPen.dx).abs();
        final double dyLast = (pLast.dy - pPen.dy).abs();
        final double dxAnte = (pPen.dx - pAnte.dx).abs();
        final double dyAnte = (pPen.dy - pAnte.dy).abs();

        final double distToCenterX = (pPen.dx - endEl.position.dx).abs();
        final double distToCenterY = (pPen.dy - endEl.position.dy).abs();

        if (isVert) {
          // Vertical bus: spurious contour hook runs vertically parallel to bus (|dx| <= 10px, |dy| >= 6px)
          // immediately adjacent to bus, while approaching segment had horizontal movement (dxAnte >= 8px)
          final bool isParallelSpur = dxLast <= 10.0 && dyLast >= 6.0;
          final bool isAdjacentToBus = distToCenterX <= busHalfW + 35.0 && distToCenterY <= busHalfH + 35.0;
          final bool isApproachingFromSide = dxAnte >= 8.0 || dxAnte >= dyAnte;

          if (isParallelSpur && isAdjacentToBus && isApproachingFromSide) {
            pts.removeLast();
            continue;
          }
        } else {
          // Horizontal bus: spurious contour hook runs horizontally parallel to bus (|dy| <= 10px, |dx| >= 6px)
          // immediately adjacent to bus, while approaching segment had vertical movement (dyAnte >= 8px)
          final bool isParallelSpur = dyLast <= 10.0 && dxLast >= 6.0;
          final bool isAdjacentToBus = distToCenterY <= busHalfH + 35.0 && distToCenterX <= busHalfW + 35.0;
          final bool isApproachingVertically = dyAnte >= 8.0 || dyAnte >= dxAnte;

          if (isParallelSpur && isAdjacentToBus && isApproachingVertically) {
            pts.removeLast();
            continue;
          }
        }
        break;
      }
    }

    // 2. Prune contour hook at START (when startEl is a Bus)
    if (startEl != null && startEl.type == Tool.bus) {
      final int qTurns = ((startEl.angle / (math.pi / 2)).round() % 4 + 4) % 4;
      final bool isVert = (qTurns % 2 == 0) ? (startEl.height > startEl.width) : (startEl.width > startEl.height);
      final double busHalfW = (qTurns % 2 == 0) ? startEl.width / 2 : startEl.height / 2;
      final double busHalfH = (qTurns % 2 == 0) ? startEl.height / 2 : startEl.width / 2;

      while (pts.length >= 3) {
        final Offset pFirst = pts[0];
        final Offset pSec = pts[1];
        final Offset pThird = pts[2];

        final double dxFirst = (pSec.dx - pFirst.dx).abs();
        final double dyFirst = (pSec.dy - pFirst.dy).abs();
        final double dxSec = (pThird.dx - pSec.dx).abs();
        final double dySec = (pThird.dy - pSec.dy).abs();

        final double distToCenterX = (pSec.dx - startEl.position.dx).abs();
        final double distToCenterY = (pSec.dy - startEl.position.dy).abs();

        if (isVert) {
          final bool isParallelSpur = dxFirst <= 10.0 && dyFirst >= 6.0;
          final bool isAdjacentToBus = distToCenterX <= busHalfW + 35.0 && distToCenterY <= busHalfH + 35.0;
          final bool isLeavingFromSide = dxSec >= 8.0 || dxSec >= dySec;

          if (isParallelSpur && isAdjacentToBus && isLeavingFromSide) {
            pts.removeAt(0);
            continue;
          }
        } else {
          final bool isParallelSpur = dyFirst <= 10.0 && dxFirst >= 6.0;
          final bool isAdjacentToBus = distToCenterY <= busHalfH + 35.0 && distToCenterX <= busHalfW + 35.0;
          final bool isLeavingVertically = dySec >= 8.0 || dySec >= dxSec;

          if (isParallelSpur && isAdjacentToBus && isLeavingVertically) {
            pts.removeAt(0);
            continue;
          }
        }
        break;
      }
    }

    return pts;
  }

  List<Offset> _ramerDouglasPeucker(List<Offset> points, double epsilon) {
    if (points.length < 3) return points;

    double dmax = 0.0;
    int index = 0;
    final int end = points.length - 1;

    for (int i = 1; i < end; i++) {
      final double d = _distToSegment(points[i], points[0], points[end]);
      if (d > dmax) {
        index = i;
        dmax = d;
      }
    }

    if (dmax > epsilon) {
      final rec1 = _ramerDouglasPeucker(points.sublist(0, index + 1), epsilon);
      final rec2 = _ramerDouglasPeucker(points.sublist(index), epsilon);
      return [...rec1.sublist(0, rec1.length - 1), ...rec2];
    } else {
      return [points.first, points.last];
    }
  }

  List<Offset> _vectorizeAndOrthogonalizeLine({
    required List<Offset> rawPoints,
    DrawingElement? startEl,
    DrawingElement? endEl,
  }) {
    if (rawPoints.length < 2) return rawPoints;

    // Truncate spurs penetrating deep into bus body
    List<Offset> pts = _truncateSpursAtBus(rawPoints, endEl);
    if (startEl != null && startEl.type == Tool.bus) {
      pts = _truncateSpursAtBus(pts.reversed.toList(), startEl).reversed.toList();
    }
    if (pts.length < 2) pts = List.from(rawPoints);

    // Reorient startEl and endEl so startEl is closer to pts.first
    if (startEl != null && endEl != null) {
      final double d1 = (pts.first - startEl.position).distance;
      final double d2 = (pts.first - endEl.position).distance;
      if (d1 > d2) {
        final tmp = startEl;
        startEl = endEl;
        endEl = tmp;
      }
    }

    // Special case: Generator or Load feeder lead to Bus
    if (startEl != null && endEl != null) {
      final bool isStartDev = (startEl.type == Tool.generator || startEl.type == Tool.load);
      final bool isEndDev = (endEl.type == Tool.generator || endEl.type == Tool.load);
      final bool isStartBus = startEl.type == Tool.bus;
      final bool isEndBus = endEl.type == Tool.bus;

      if ((isStartDev && isEndBus) || (isEndDev && isStartBus)) {
        final dev = isStartDev ? startEl : endEl;
        final bus = isStartDev ? endEl : startEl;
        final double dx = dev.position.dx - bus.position.dx;
        final double dy = dev.position.dy - bus.position.dy;

        if (dx.abs() >= dy.abs()) {
          // Horizontal lead: snap Y to dev.position.dy clamped to bus height
          final double yCon = dev.position.dy.clamp(
            bus.position.dy - bus.height / 2,
            bus.position.dy + bus.height / 2,
          );
          final Offset devSnap = Offset(
            dev.position.dx + (dx < 0 ? dev.width / 2 : -dev.width / 2),
            yCon,
          );
          final Offset busSnap = Offset(
            bus.position.dx + (dx < 0 ? -bus.width / 2 : bus.width / 2),
            yCon,
          );
          return isStartDev ? [devSnap, busSnap] : [busSnap, devSnap];
        } else {
          // Vertical lead: snap X to dev.position.dx clamped to bus width
          final double xCon = dev.position.dx.clamp(
            bus.position.dx - bus.width / 2,
            bus.position.dx + bus.width / 2,
          );
          final Offset devSnap = Offset(
            xCon,
            dev.position.dy + (dy < 0 ? dev.height / 2 : -dev.height / 2),
          );
          final Offset busSnap = Offset(
            xCon,
            bus.position.dy + (dy < 0 ? -bus.height / 2 : bus.height / 2),
          );
          return isStartDev ? [devSnap, busSnap] : [busSnap, devSnap];
        }
      }
    }

    // 1. Simplify via Ramer-Douglas-Peucker
    var simplified = _ramerDouglasPeucker(pts, 14.0);
    simplified = _pruneBusTerminalHooks(simplified, startEl, endEl);

    // 2. Snap endpoints to component boundaries
    Offset pStart = startEl != null ? _getSnapPoint(startEl, simplified.first) : simplified.first;
    Offset pEnd = endEl != null ? _getSnapPoint(endEl, simplified.last) : simplified.last;

    // Case A: 2 points -> Straight line
    if (simplified.length <= 2) {
      final double dx = (pEnd.dx - pStart.dx).abs();
      final double dy = (pEnd.dy - pStart.dy).abs();
      if (dy < 30.0 || (dx > 0 && dy / dx < 0.25)) {
        // Snap horizontal
        final double yAvg = (pStart.dy + pEnd.dy) / 2;
        if (startEl != null) pStart = _getSnapPoint(startEl, Offset(pStart.dx, yAvg));
        if (endEl != null) pEnd = _getSnapPoint(endEl, Offset(pEnd.dx, yAvg));
        return [pStart, Offset(pEnd.dx, pStart.dy)];
      } else if (dx < 30.0 || (dy > 0 && dx / dy < 0.25)) {
        // Snap vertical
        final double xAvg = (pStart.dx + pEnd.dx) / 2;
        if (startEl != null) pStart = _getSnapPoint(startEl, Offset(xAvg, pStart.dy));
        if (endEl != null) pEnd = _getSnapPoint(endEl, Offset(xAvg, pEnd.dy));
        return [pStart, Offset(pStart.dx, pEnd.dy)];
      } else {
        return [pStart, pEnd];
      }
    }

    // Case B: 3 points -> L-bend
    if (simplified.length == 3) {
      final Offset pMid = simplified[1];
      final double dx1 = (pMid.dx - pStart.dx).abs();
      final double dy1 = (pMid.dy - pStart.dy).abs();

      if (dx1 >= dy1) {
        // Segment 1 Horizontal, Segment 2 Vertical
        Offset corner = Offset(pEnd.dx, pStart.dy);
        if (startEl != null) pStart = _getSnapPoint(startEl, corner);
        if (endEl != null) pEnd = _getSnapPoint(endEl, corner);
        corner = Offset(pEnd.dx, pStart.dy);
        return [pStart, corner, pEnd];
      } else {
        // Segment 1 Vertical, Segment 2 Horizontal
        Offset corner = Offset(pStart.dx, pEnd.dy);
        if (startEl != null) pStart = _getSnapPoint(startEl, corner);
        if (endEl != null) pEnd = _getSnapPoint(endEl, corner);
        corner = Offset(pStart.dx, pEnd.dy);
        return [pStart, corner, pEnd];
      }
    }

    // Case C: 4+ points -> multi-segment orthogonalization
    final List<Offset> result = [pStart];
    for (int i = 1; i < simplified.length - 1; i++) {
      final prev = result.last;
      final curr = simplified[i];
      final double dx = (curr.dx - prev.dx).abs();
      final double dy = (curr.dy - prev.dy).abs();
      if (dx >= dy) {
        result.add(Offset(curr.dx, prev.dy));
      } else {
        result.add(Offset(prev.dx, curr.dy));
      }
    }
    result.add(pEnd);
    return result;
  }

  List<Offset> _smoothNaturalLine({
    required List<Offset> rawPoints,
    DrawingElement? startEl,
    DrawingElement? endEl,
    double epsilon = 7.0,
  }) {
    if (rawPoints.length < 2) return rawPoints;

    // 0. Reorient startEl and endEl so startEl is closer to rawPoints.first
    if (startEl != null && endEl != null) {
      final double d1 = (rawPoints.first - startEl.position).distance;
      final double d2 = (rawPoints.first - endEl.position).distance;
      if (d1 > d2) {
        final tmp = startEl;
        startEl = endEl;
        endEl = tmp;
      }
    }

    // 1. Ramer-Douglas-Peucker: eliminates pixel tremor / noise while preserving true vertices & corners!
    List<Offset> simplified = _ramerDouglasPeucker(rawPoints, epsilon);
    if (simplified.length < 2) simplified = [rawPoints.first, rawPoints.last];

    // 2. Safely prune spurious bus contour hooks at terminals
    simplified = _pruneBusTerminalHooks(simplified, startEl, endEl);

    // 3. Snap endpoints to component boundaries (if available)
    Offset pStart = startEl != null ? _getSnapPoint(startEl, simplified.first) : simplified.first;
    Offset pEnd = endEl != null ? _getSnapPoint(endEl, simplified.last) : simplified.last;

    List<Offset> pts = [pStart, ...simplified.sublist(1, simplified.length - 1), pEnd];

    // 4. Level out segments that are ALREADY nearly horizontal or vertical (within 4 degrees or 5px)
    // IMPORTANT: Diagonal lines (angle > 5 deg) are preserved 100% naturally!
    List<Offset> result = [pts.first];
    for (int i = 1; i < pts.length; i++) {
      Offset prev = result.last;
      Offset curr = pts[i];
      double dx = curr.dx - prev.dx;
      double dy = curr.dy - prev.dy;
      double angle = math.atan2(dy.abs(), dx.abs()); // 0 ~ pi/2

      if (dy.abs() <= 5.0 || angle < 0.07) {
        // Nearly horizontal -> level to flat
        result.add(Offset(curr.dx, prev.dy));
      } else if (dx.abs() <= 5.0 || (math.pi / 2 - angle).abs() < 0.07) {
        // Nearly vertical -> align to straight vertical
        result.add(Offset(prev.dx, curr.dy));
      } else {
        // Natural diagonal or intentional angle -> KEEP IT!
        result.add(curr);
      }
    }

    // 5. Ensure terminal points remain firmly snapped to component boundaries
    if (startEl != null && result.isNotEmpty) {
      result[0] = _getSnapPoint(startEl, result.first);
    }
    if (endEl != null && result.length > 1) {
      result[result.length - 1] = _getSnapPoint(endEl, result.last);
    }

    // 6. Remove redundant collinear points
    if (result.length > 2) {
      List<Offset> cleaned = [result.first];
      for (int i = 1; i < result.length - 1; i++) {
        Offset p0 = cleaned.last;
        Offset p1 = result[i];
        Offset p2 = result[i + 1];
        double d = _distToSegment(p1, p0, p2);
        if (d > 2.5) {
          cleaned.add(p1);
        }
      }
      cleaned.add(result.last);
      return cleaned;
    }

    return result;
  }

  void _smoothAllLinesNaturally() {
    _saveState();
    setState(() {
      for (var line in elements.where((e) => e.type == Tool.line)) {
        DrawingElement? startEl;
        DrawingElement? endEl;
        try { startEl = elements.firstWhere((e) => e.id == line.startElementId); } catch (_) {}
        try { endEl = elements.firstWhere((e) => e.id == line.endElementId); } catch (_) {}

        List<Offset> sourcePts = [];
        if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
          sourcePts = List.from(line.rawAiPath!);
        } else if (line.aiPath != null && line.aiPath!.length >= 2) {
          sourcePts = List.from(line.aiPath!);
        } else if (line.endPosition != null) {
          sourcePts.add(line.position);
          if (line.midPosition != null) sourcePts.add(line.midPosition!);
          sourcePts.add(line.endPosition!);
        }

        if (sourcePts.length >= 2) {
          if (startEl == null) {
            for (var b in elements.where((e) => e.type == Tool.bus)) {
              if ((sourcePts.first.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                  (sourcePts.first.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
                startEl = b;
                line.startElementId = b.id;
                break;
              }
            }
          }
          if (endEl == null) {
            for (var b in elements.where((e) => e.type == Tool.bus)) {
              if ((sourcePts.last.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                  (sourcePts.last.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
                endEl = b;
                line.endElementId = b.id;
                break;
              }
            }
          }

          final clean = _smoothNaturalLine(
            rawPoints: sourcePts,
            startEl: startEl,
            endEl: endEl,
          );
          line.position = clean.first;
          line.endPosition = clean.last;
          line.midPosition = clean.length == 3 ? clean[1] : (clean.length > 3 ? clean[1] : null);
          line.aiPath = clean.length > 2 ? clean : null;
          if (startEl != null) line.startAnchor = line.position - startEl.position;
          if (endEl != null) line.endAnchor = line.endPosition! - endEl.position;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✨ 원본 경로와 각도를 보존하며 선로를 매끄러운 직선으로 보정했습니다."),
        backgroundColor: Color(0xFF2563EB),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _smoothSelectedLine() {
    if (selectedElement == null || selectedElement!.type != Tool.line) return;
    _saveState();
    setState(() {
      final line = selectedElement!;
      DrawingElement? startEl;
      DrawingElement? endEl;
      try { startEl = elements.firstWhere((e) => e.id == line.startElementId); } catch (_) {}
      try { endEl = elements.firstWhere((e) => e.id == line.endElementId); } catch (_) {}

      List<Offset> sourcePts = [];
      if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
        sourcePts = List.from(line.rawAiPath!);
      } else if (line.aiPath != null && line.aiPath!.length >= 2) {
        sourcePts = List.from(line.aiPath!);
      } else if (line.endPosition != null) {
        sourcePts.add(line.position);
        if (line.midPosition != null) sourcePts.add(line.midPosition!);
        sourcePts.add(line.endPosition!);
      }

      if (sourcePts.length >= 2) {
        if (startEl == null) {
          for (var b in elements.where((e) => e.type == Tool.bus)) {
            if ((sourcePts.first.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                (sourcePts.first.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
              startEl = b;
              line.startElementId = b.id;
              break;
            }
          }
        }
        if (endEl == null) {
          for (var b in elements.where((e) => e.type == Tool.bus)) {
            if ((sourcePts.last.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                (sourcePts.last.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
              endEl = b;
              line.endElementId = b.id;
              break;
            }
          }
        }

        final clean = _smoothNaturalLine(
          rawPoints: sourcePts,
          startEl: startEl,
          endEl: endEl,
        );
        line.position = clean.first;
        line.endPosition = clean.last;
        line.midPosition = clean.length == 3 ? clean[1] : (clean.length > 3 ? clean[1] : null);
        line.aiPath = clean.length > 2 ? clean : null;
        if (startEl != null) line.startAnchor = line.position - startEl.position;
        if (endEl != null) line.endAnchor = line.endPosition! - endEl.position;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✨ 선택한 선로를 자연스러운 직선으로 보정했습니다."),
        backgroundColor: Color(0xFF2563EB),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _straightenAllLines() {
    _saveState();
    setState(() {
      for (var line in elements.where((e) => e.type == Tool.line)) {
        DrawingElement? startEl;
        DrawingElement? endEl;
        try { startEl = elements.firstWhere((e) => e.id == line.startElementId); } catch (_) {}
        try { endEl = elements.firstWhere((e) => e.id == line.endElementId); } catch (_) {}

        List<Offset> sourcePts = [];
        if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
          sourcePts = List.from(line.rawAiPath!);
        } else if (line.aiPath != null && line.aiPath!.length >= 2) {
          sourcePts = List.from(line.aiPath!);
        } else if (line.endPosition != null) {
          sourcePts.add(line.position);
          if (line.midPosition != null) sourcePts.add(line.midPosition!);
          sourcePts.add(line.endPosition!);
        }

        if (sourcePts.length >= 2) {
          final clean = _vectorizeAndOrthogonalizeLine(
            rawPoints: sourcePts,
            startEl: startEl,
            endEl: endEl,
          );
          line.position = clean.first;
          line.endPosition = clean.last;
          line.midPosition = clean.length == 3 ? clean[1] : (clean.length > 3 ? clean[1] : null);
          line.aiPath = clean.length > 2 ? clean : null;
          if (startEl != null) line.startAnchor = line.position - startEl.position;
          if (endEl != null) line.endAnchor = line.endPosition! - endEl.position;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("📐 모든 선로를 90° 직각(맨해튼)으로 정형화했습니다."),
        backgroundColor: Color(0xFFD97706),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _straightenSelectedLine() {
    if (selectedElement == null || selectedElement!.type != Tool.line) return;
    _saveState();
    setState(() {
      final line = selectedElement!;
      DrawingElement? startEl;
      DrawingElement? endEl;
      try { startEl = elements.firstWhere((e) => e.id == line.startElementId); } catch (_) {}
      try { endEl = elements.firstWhere((e) => e.id == line.endElementId); } catch (_) {}

      List<Offset> sourcePts = [];
      if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
        sourcePts = List.from(line.rawAiPath!);
      } else if (line.aiPath != null && line.aiPath!.length >= 2) {
        sourcePts = List.from(line.aiPath!);
      } else if (line.endPosition != null) {
        sourcePts.add(line.position);
        if (line.midPosition != null) sourcePts.add(line.midPosition!);
        sourcePts.add(line.endPosition!);
      }

      if (sourcePts.length >= 2) {
        final clean = _vectorizeAndOrthogonalizeLine(
          rawPoints: sourcePts,
          startEl: startEl,
          endEl: endEl,
        );
        line.position = clean.first;
        line.endPosition = clean.last;
        line.midPosition = clean.length == 3 ? clean[1] : (clean.length > 3 ? clean[1] : null);
        line.aiPath = clean.length > 2 ? clean : null;
        if (startEl != null) line.startAnchor = line.position - startEl.position;
        if (endEl != null) line.endAnchor = line.endPosition! - endEl.position;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("📐 선택한 선로를 90° 직각으로 정형화했습니다."),
        backgroundColor: Color(0xFFD97706),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _restoreSelectedRawLine() {
    if (selectedElement == null || selectedElement!.type != Tool.line) return;
    _saveState();
    setState(() {
      final line = selectedElement!;
      if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
        line.aiPath = List.from(line.rawAiPath!);
        line.position = line.rawAiPath!.first;
        line.endPosition = line.rawAiPath!.last;
        line.midPosition = line.rawAiPath!.length > 2
            ? line.rawAiPath![line.rawAiPath!.length ~/ 2]
            : null;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("↩️ 원본 손그림 경로로 복원했습니다."),
        backgroundColor: Colors.blueGrey,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _restoreAllRawLines() {
    _saveState();
    setState(() {
      for (var line in elements.where((e) => e.type == Tool.line)) {
        if (line.rawAiPath != null && line.rawAiPath!.length >= 2) {
          line.aiPath = List.from(line.rawAiPath!);
          line.position = line.rawAiPath!.first;
          line.endPosition = line.rawAiPath!.last;
          line.midPosition = line.rawAiPath!.length > 2
              ? line.rawAiPath![line.rawAiPath!.length ~/ 2]
              : null;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("↩️ 모든 선로를 원본 인식 경로로 복원했습니다."),
        backgroundColor: Colors.blueGrey,
        duration: Duration(seconds: 2),
      ),
    );
  }

  DrawingElement? _findElementAt(Offset pos) {
    for (var e in elements.reversed) {
      if (e.type == Tool.line) continue;

      if (e.type == Tool.bus) {
        double cosA = math.cos(-e.angle);
        double sinA = math.sin(-e.angle);
        Offset rel = pos - e.position;
        double localX = rel.dx * cosA - rel.dy * sinA;
        double localY = rel.dx * sinA + rel.dy * cosA;

        if (localX.abs() <= (e.width / 2) + 10 &&
            localY.abs() <= (e.height / 2) + 10)
          return e;
      } else if (e.type == Tool.text) {
        if ((pos - e.position).distance < 30) return e;
      } else {
        double radius = math.max(e.width, e.height) / 2 + 10;
        if ((pos - e.position).distance <= radius) return e;
      }
    }

    for (var e in elements.reversed) {
      if (e.type == Tool.line) {
        double hitPadding = 15.0;
        if (e.aiPath != null && e.aiPath!.isNotEmpty) {
          for (int i = 0; i < e.aiPath!.length - 1; i++) {
            if (_distToSegment(pos, e.aiPath![i], e.aiPath![i + 1]) <
                hitPadding)
              return e;
          }
        } else if (e.endPosition != null) {
          if (e.midPosition != null) {
            double d1 = _distToSegment(pos, e.position, e.midPosition!);
            double d2 = _distToSegment(pos, e.midPosition!, e.endPosition!);
            if (d1 < hitPadding || d2 < hitPadding) return e;
          } else {
            double d = _distToSegment(pos, e.position, e.endPosition!);
            if (d < hitPadding) return e;
          }
        }
      }
    }
    return null;
  }

  String _getBusNum(String text) {
    final RegExp digitRegExp = RegExp(r'\d+');
    final match = digitRegExp.firstMatch(text);
    return match != null ? match.group(0)! : text;
  }

  void _updateConnectedElementsId(DrawingElement bus) {
    String busNum = _getBusNum(bus.label.isNotEmpty ? bus.label : bus.id);
    int genCount = 1, loadCount = 1, transCount = 1;

    // 1. 버스와 '직접 붙인 부품' + '단순 연결선으로 이어진 부품' 모두 찾아내기
    for (var el in elements) {
      if (el.type == Tool.generator ||
          el.type == Tool.load ||
          el.type == Tool.transformer) {
        bool isConnected = false;

        if (el.parentBusId == bus.id) {
          isConnected = true; // 모선 위에 직접 찰칵(스냅) 붙인 경우
        } else {
          // 단순 연결선(Line)을 길게 그려서 연결한 경우인지 스캔
          isConnected = elements.any(
            (line) =>
                line.type == Tool.line &&
                ((line.startElementId == bus.id &&
                        line.endElementId == el.id) ||
                    (line.startElementId == el.id &&
                        line.endElementId == bus.id)),
          );
        }

        // 연결이 확인되면 즉시 모선의 번호를 가져와서 이름 수정
        if (isConnected) {
          if (el.type == Tool.generator) {
            el.id = 'G_${busNum}_${genCount++}';
          } else if (el.type == Tool.load) {
            el.id = 'Load_${busNum}_${loadCount++}';
          } else if (el.type == Tool.transformer) {
            el.id = 'T_${busNum}_${transCount++}';
          }
        }
      }
    }

    // 2. 부품 이름이 싹 바뀌었으니, 그 부품에 매달려 있던 선로(Line) 이름들도 재갱신!
    for (var el in elements) {
      if (el.type == Tool.line) {
        DrawingElement? startEl;
        DrawingElement? endEl;
        try {
          startEl = elements.firstWhere((e) => e.id == el.startElementId);
        } catch (_) {}
        try {
          endEl = elements.firstWhere((e) => e.id == el.endElementId);
        } catch (_) {}

        // Null Safety 수정: startEl과 endEl의 Null 체크를 명확히 함
        if (startEl != null &&
            endEl != null &&
            startEl.type == Tool.bus &&
            endEl.type == Tool.bus) {
          String startNum = _getBusNum(
            startEl.label.isNotEmpty ? startEl.label : startEl.id,
          );
          String endNum = _getBusNum(
            endEl.label.isNotEmpty ? endEl.label : endEl.id,
          );
          el.id = 'L_${startNum}_$endNum';
        } else if (startEl != null && endEl != null) {
          el.id = 'Conn_${startEl.id}_${endEl.id}';
        }
      }
    }
  }

  Future<void> _sendDataToServer() async {
    final url = Uri.parse('http://127.0.0.1:8000/run_simulation');
    final payload = jsonEncode({
      'elements': elements.map((e) => e.toJson()).toList(),
    });

    setState(() => isSimulating = true);

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: payload,
      );
      if (!mounted) return;
      setState(() => isSimulating = false);

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result['data'] != null &&
            (result['status'] == 'success' || result['status'] == 'warning')) {
          setState(() {
            lastSimulationResult = result['data'];
            showResultOverlay = true;
            showFlowDirection = true;
            _flowAnimController.repeat();
            if (result['data']['total_branches'] is num) {
              excelBranchCount = (result['data']['total_branches'] as num)
                  .toInt();
            }
            final busResults =
                result['data']['bus_results'] as List<dynamic>? ?? [];
            for (var br in busResults) {
              int bNum = (br['bus'] as num).toInt();
              double pgenPu = (br['pgen_pu'] as num?)?.toDouble() ?? 0.0;
              double qgenPu = (br['qgen_pu'] as num?)?.toDouble() ?? 0.0;
              double vPu = (br['volt_pu'] as num?)?.toDouble() ?? 1.0;
              double angleDeg = (br['angle_deg'] as num?)?.toDouble() ?? 0.0;

              for (var el in elements) {
                if (el.type == Tool.bus &&
                    (el.label == "$bNum" ||
                        el.label.startsWith("$bNum ") ||
                        el.id == "bus_$bNum")) {
                  el.vPu = vPu;
                  el.thetaDeg = angleDeg;
                } else if (el.type == Tool.generator &&
                    (el.label == "G_$bNum" ||
                        el.label.startsWith("G_$bNum ") ||
                        el.label.startsWith("SC_$bNum") ||
                        el.id == "gen_$bNum" ||
                        el.parentBusId == "bus_$bNum")) {
                  el.pPu = pgenPu;
                  el.qPu = qgenPu;
                  el.vPu = vPu;
                }
              }
            }
          });

          if (result['status'] == 'warning') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result['message'] ?? "조류 계산 미수렴 (발산)"),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 4),
              ),
            );
          } else {
            PowerLensAIService.instance.onStageChanged('POWERFLOW_CONVERGED');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.greenAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "조류계산 수렴 완료 (${result['data']['iterations']}회 반복) · 수치 표 또는 요소를 클릭해 확인하세요.",
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF0F172A),
                duration: const Duration(seconds: 4),
                action: SnackBarAction(
                  label: "수치 표 보기",
                  textColor: Colors.cyanAccent,
                  onPressed: () => _showPowerFlowResultDialog(result['data']),
                ),
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['message'] ?? "조류 계산 실패"),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("서버 응답 오류가 발생했습니다."),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => isSimulating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("서버 접속 실패!\n$e"), backgroundColor: Colors.red),
      );
    }
  }

  void _showPowerFlowResultDialog(Map<String, dynamic> data) {
    bool isConverged = data['converged'] == true;
    int iterations = data['iterations'] ?? 0;
    double maxMismatch = (data['max_mismatch'] as num?)?.toDouble() ?? 0.0;
    int? slackBus = data['slack_bus'];
    var summary = data['summary'] as Map<String, dynamic>? ?? {};
    List<dynamic> busResults = data['bus_results'] ?? [];
    List<dynamic> lineResults = data['line_results'] ?? [];
    String csvText = data['csv_text'] ?? "";

    bool showPu = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Container(
              width: 1000,
              height: 720,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isConverged ? Icons.check_circle : Icons.warning,
                        color: isConverged ? Colors.green : Colors.orange,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isConverged
                                  ? "조류 계산 수렴 완료 ($iterations회 반복)"
                                  : "조류 계산 미수렴",
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "슬랙 모선: #${slackBus ?? '자동'} | 최대 불평형량 오차: ${maxMismatch.toStringAsExponential(3)}",
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Row(
                          children: [
                            Text(
                              showPu ? "단위: pu" : "단위: MW / MVAR",
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Switch(
                              value: showPu,
                              activeColor: Colors.blueAccent,
                              onChanged: (v) => setDlgState(() => showPu = v),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.blue[200]!),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildKpiItem(
                          "총 발전 (P / Q)",
                          "${summary['total_gen_p_mw'] ?? 0} MW / ${summary['total_gen_q_mvar'] ?? 0} MVAR",
                          Colors.blue[900]!,
                        ),
                        _buildKpiItem(
                          "총 부하 (P / Q)",
                          "${summary['total_load_p_mw'] ?? 0} MW / ${summary['total_load_q_mvar'] ?? 0} MVAR",
                          Colors.teal[900]!,
                        ),
                        _buildKpiItem(
                          "총 송전 손실 (Loss)",
                          "${summary['total_loss_p_mw'] ?? 0} MW / ${summary['total_loss_q_mvar'] ?? 0} MVAR",
                          Colors.red[900]!,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          TabBar(
                            labelColor: Colors.blue[800],
                            unselectedLabelColor: Colors.grey[600],
                            indicatorColor: Colors.blue[800],
                            tabs: [
                              Tab(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.grid_on, size: 18),
                                    const SizedBox(width: 8),
                                    Text("모선 결과 (${busResults.length}개)"),
                                  ],
                                ),
                              ),
                              Tab(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.timeline, size: 18),
                                    const SizedBox(width: 8),
                                    Text("선로 조류 (${lineResults.length}개)"),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildBusResultsTable(busResults, showPu),
                                _buildLineResultsTable(lineResults, showPu),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          _applyPowerFlowResultsToCanvas(busResults);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "✅ 계산된 전압 및 위상각이 캔버스 모선에 실시간 반영되었습니다!",
                              ),
                              backgroundColor: Colors.indigo,
                            ),
                          );
                        },
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text("캔버스에 전압/위상각 반영"),
                      ),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: csvText));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "📋 CSV 데이터가 클립보드에 복사되었습니다! 엑셀(Ctrl+V)에 바로 붙여넣을 수 있습니다.",
                                  ),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.copy,
                              size: 18,
                              color: Colors.white,
                            ),
                            label: const Text(
                              "CSV 텍스트 복사 (엑셀용)",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal[700],
                            ),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text("닫기"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildKpiItem(String title, String val, Color color) {
    return Column(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[700],
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          val,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildBusResultsTable(List<dynamic> busResults, bool showPu) {
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: MaterialStateProperty.all(Colors.grey[100]),
            columnSpacing: 22,
            columns: [
              const DataColumn(
                label: Text(
                  "Bus",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Volt (pu)" : "Volt",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Angle (deg)" : "Angle",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Pgen (pu)" : "Pgen",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Qgen (pu)" : "Qgen",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Pload (pu)" : "Pload",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Qload (pu)" : "Qload",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const DataColumn(
                label: Text(
                  "Type",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
            rows: busResults.map((r) {
              String type = r['type'] ?? 'PQ';
              Color rowColor = type == 'SLACK'
                  ? Colors.amber[50]!
                  : (type == 'PV' ? Colors.blue[50]! : Colors.transparent);

              double volt = showPu
                  ? (r['volt_pu'] as num).toDouble()
                  : (r['volt'] as num).toDouble();
              double angle = (r['angle'] as num).toDouble();
              double pgen = showPu
                  ? (r['pgen_pu'] as num).toDouble()
                  : (r['pgen'] as num).toDouble();
              double qgen = showPu
                  ? (r['qgen_pu'] as num).toDouble()
                  : (r['qgen'] as num).toDouble();
              double pload = showPu
                  ? (r['pload_pu'] as num).toDouble()
                  : (r['pload'] as num).toDouble();
              double qload = showPu
                  ? (r['qload_pu'] as num).toDouble()
                  : (r['qload'] as num).toDouble();

              return DataRow(
                color: MaterialStateProperty.all(rowColor),
                cells: [
                  DataCell(
                    Text(
                      "${r['bus']}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataCell(Text(volt.toStringAsFixed(4))),
                  DataCell(Text(angle.toStringAsFixed(4))),
                  DataCell(Text(pgen.toStringAsFixed(4))),
                  DataCell(Text(qgen.toStringAsFixed(4))),
                  DataCell(Text(pload.toStringAsFixed(4))),
                  DataCell(Text(qload.toStringAsFixed(4))),
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: type == 'SLACK'
                            ? Colors.red[100]
                            : (type == 'PV'
                                  ? Colors.blue[100]
                                  : Colors.grey[200]),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: type == 'SLACK'
                              ? Colors.red[900]
                              : (type == 'PV'
                                    ? Colors.blue[900]
                                    : Colors.grey[800]),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildLineResultsTable(List<dynamic> lineResults, bool showPu) {
    if (lineResults.isEmpty) {
      return const Center(child: Text("선로 조류 데이터가 없습니다."));
    }

    final sortedLines = List<dynamic>.from(lineResults)
      ..sort((a, b) {
        int fa = (a['from_bus'] as num?)?.toInt() ?? 0;
        int fb = (b['from_bus'] as num?)?.toInt() ?? 0;
        if (fa != fb) return fa.compareTo(fb);
        int ta = (a['to_bus'] as num?)?.toInt() ?? 0;
        int tb = (b['to_bus'] as num?)?.toInt() ?? 0;
        return ta.compareTo(tb);
      });

    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: MaterialStateProperty.all(Colors.grey[100]),
            columnSpacing: 18,
            columns: [
              const DataColumn(
                label: Text(
                  "No.",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const DataColumn(
                label: Text(
                  "선로",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const DataColumn(
                label: Text(
                  "From",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const DataColumn(
                label: Text(
                  "To",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "P From (pu)" : "P From (MW)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Q From (pu)" : "Q From (MVAR)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "P To (pu)" : "P To (MW)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Q To (pu)" : "Q To (MVAR)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              DataColumn(
                label: Text(
                  showPu ? "Loss P (pu)" : "Loss P (MW)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
            rows: List.generate(sortedLines.length, (idx) {
              final r = sortedLines[idx];
              return DataRow(
                cells: [
                  DataCell(
                    Text(
                      "${idx + 1}",
                      style: const TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      "${r['label'] ?? ''}",
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  DataCell(Text("${r['from_bus']}")),
                  DataCell(Text("${r['to_bus']}")),
                  DataCell(
                    Text(showPu ? "${r['p_from_pu']}" : "${r['p_from_mw']}"),
                  ),
                  DataCell(
                    Text(showPu ? "${r['q_from_pu']}" : "${r['q_from_mvar']}"),
                  ),
                  DataCell(Text(showPu ? "-" : "${r['p_to_mw']}")),
                  DataCell(Text(showPu ? "-" : "${r['q_to_mvar']}")),
                  DataCell(
                    Text(
                      showPu ? "${r['loss_p_pu']}" : "${r['loss_p_mw']}",
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  void _applyPowerFlowResultsToCanvas(List<dynamic> busResults) {
    setState(() {
      for (var r in busResults) {
        int bNum = r['bus'];
        double v = (r['volt'] as num).toDouble();
        double ang = (r['angle'] as num).toDouble();
        double pg = (r['pgen_pu'] as num).toDouble();
        double qg = (r['qgen_pu'] as num).toDouble();

        for (var el in elements.where((e) => e.type == Tool.bus)) {
          int? elBNum;
          if (el.label.isNotEmpty) {
            String digits = el.label.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) elBNum = int.tryParse(digits);
          }
          if (elBNum == null) {
            String digits = el.id.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) elBNum = int.tryParse(digits);
          }
          if (elBNum == bNum) {
            el.vPu = v;
            el.thetaDeg = ang;
            el.showInfo = true;
          }
        }

        for (var el in elements.where((e) => e.type == Tool.generator)) {
          int? elBNum;
          if (el.parentBusId != null) {
            String digits = el.parentBusId!.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) elBNum = int.tryParse(digits);
          }
          if (elBNum == null && el.label.isNotEmpty) {
            String digits = el.label.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) elBNum = int.tryParse(digits);
          }
          if (elBNum == bNum) {
            el.vPu = v;
            el.thetaDeg = ang;
            if (el.isSlack) {
              el.pPu = pg;
              el.qPu = qg;
            } else {
              el.qPu = qg;
            }
            el.showInfo = true;
          }
        }
      }
    });
  }

  Future<void> _openReviewPage({
    Uint8List? initialImageBytes,
    String? initialFilename,
  }) async {
    bool hasApplied = false;
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => ObjectReviewPage(
          initialImageBytes: initialImageBytes,
          initialFilename: initialFilename,
          onRequestHome: () =>
              _handleAppAction(PowerLensAppAction.goHome, null),
          onProceedToCanvas: (verifiedData) {
            if (!hasApplied) {
              hasApplied = true;
              _applyAiDataToCanvas(verifiedData);
            }
          },
        ),
      ),
    );
    if (result != null && !hasApplied) {
      hasApplied = true;
      _applyAiDataToCanvas(result);
    }
  }

  Future<void> _loadSampleDiagram() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("IEEE-24 샘플 도면을 불러오는 중... ⚡"),
          duration: Duration(seconds: 2),
        ),
      );
      final bytes = await _apiService.fetchSampleDiagramBytes();
      await _openReviewPage(
        initialImageBytes: bytes,
        initialFilename: 'sample_diagram_ieee24.jpg',
      );
    } catch (e) {
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

  Future<void> _uploadImageToAI() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    Uint8List imageBytes = await image.readAsBytes();
    await _openReviewPage(
      initialImageBytes: imageBytes,
      initialFilename: image.name,
    );
  }

  Future<void> _importExcelCase() async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("파일 데이터를 읽을 수 없습니다."),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("📊 엑셀 계통 데이터를 분석하고 있습니다...")),
      );

      var uri = Uri.parse('http://127.0.0.1:8000/upload_excel');
      var request = http.MultipartRequest('POST', uri);
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );

      var response = await request.send();
      if (!mounted) return;
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var res = jsonDecode(responseData);

        if (res['status'] == 'success') {
          var excelData = res['data'];
          _applyExcelDataToCanvas(excelData);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("엑셀 처리 실패: ${res['message']}"),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("엑셀 업로드 서버 오류 (코드: ${response.statusCode})"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("엑셀 파일 선택/업로드 오류: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _applyExcelDataToCanvas(Map<String, dynamic> excelData) async {
    _saveState();
    PowerLensAIService.instance.onStageChanged('EXCEL_LOADED');

    var buses = excelData['buses'] as Map<String, dynamic>? ?? {};
    var gens = excelData['generators'] as Map<String, dynamic>? ?? {};
    var branches = excelData['branches'] as Map<String, dynamic>? ?? {};
    var transformers = excelData['transformers'] as Map<String, dynamic>? ?? {};

    if (excelData['total_branches'] is num) {
      setState(() {
        excelBranchCount = (excelData['total_branches'] as num).toInt();
      });
    }

    // 0. If canvas is empty, auto-generate single-line diagram in circle layout
    if (elements.isEmpty && buses.isNotEmpty) {
      setState(() {
        final sortedBusKeys = buses.keys.toList()
          ..sort(
            (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
          );
        final int n = sortedBusKeys.length;
        const double centerX = CANVAS_CENTER;
        const double centerY = CANVAS_CENTER;
        final double radius = math.max(350.0, n * 45.0);

        Map<int, DrawingElement> busElMap = {};

        for (int i = 0; i < n; i++) {
          final bKey = sortedBusKeys[i];
          final bNum = int.tryParse(bKey) ?? (i + 1);
          final bInfo = buses[bKey] ?? {};
          final angle = (2 * math.pi * i) / n - (math.pi / 2);
          final bPos = Offset(
            centerX + radius * math.cos(angle),
            centerY + radius * math.sin(angle),
          );

          final busEl =
              DrawingElement(
                  id: "bus_$bNum",
                  type: Tool.bus,
                  position: bPos,
                  width: 120,
                  height: 10,
                  label: "$bNum",
                )
                ..isSlack = (bInfo['is_slack'] == true)
                ..vPu = (bInfo['vm_pu'] as num?)?.toDouble() ?? 1.0
                ..thetaDeg = (bInfo['va_deg'] as num?)?.toDouble() ?? 0.0
                ..pPu = (bInfo['pload_pu'] as num?)?.toDouble() ?? 0.0
                ..qPu = (bInfo['qload_pu'] as num?)?.toDouble() ?? 0.0;

          if (busEl.isSlack) busEl.label = "$bNum (Slack)";
          elements.add(busEl);
          busElMap[bNum] = busEl;

          if (gens.containsKey(bKey)) {
            final gInfo = gens[bKey] ?? {};
            final gPos = Offset(bPos.dx, bPos.dy - 60);
            final bool isSC = (gInfo['is_slack'] != true) && 
                ((gInfo['isSynchronousCondenser'] == true) || 
                 (gInfo['is_synchronous_condenser'] == true) ||
                 (gInfo['label']?.toString().contains("SC") == true));
            final genEl = DrawingElement(
              id: isSC ? "sc_$bNum" : "gen_$bNum",
              type: Tool.generator,
              position: gPos,
              width: 44,
              height: 44,
              parentBusId: busEl.id,
              label: isSC ? "SC_$bNum (동기조상기)" : ("G_$bNum" + (gInfo['is_slack'] == true ? " (Slack)" : "")),
            )
              ..isSlack = (gInfo['is_slack'] == true)
              ..isSynchronousCondenser = isSC
              ..vPu = (gInfo['voltage_setpoint'] as num?)?.toDouble() ?? 1.0
              ..pPu = (gInfo['is_slack'] == true) ? 0.0 : ((gInfo['pg_pu'] as num?)?.toDouble() ?? (isSC ? 0.0 : 1.0))
              ..qPu = (gInfo['is_slack'] == true) ? 0.0 : ((gInfo['qg_pu'] as num?)?.toDouble() ?? 0.0);
            elements.add(genEl);
          }

          if (busEl.pPu > 0 || busEl.qPu > 0) {
            final lPos = Offset(bPos.dx, bPos.dy + 60);
            final loadEl =
                DrawingElement(
                    id: "load_$bNum",
                    type: Tool.load,
                    position: lPos,
                    width: 36,
                    height: 40,
                    parentBusId: busEl.id,
                    label: "Load_$bNum",
                  )
                  ..pPu = busEl.pPu
                  ..qPu = busEl.qPu;
            elements.add(loadEl);
          }
        }

        void addLine(int fb, int tb, dynamic info, bool isTr) {
          final startB = busElMap[fb];
          final endB = busElMap[tb];
          if (startB == null || endB == null) return;
          final lineEl =
              DrawingElement(
                  id: "line_${fb}_$tb",
                  type: Tool.line,
                  position: startB.position,
                  endPosition: endB.position,
                  startElementId: startB.id,
                  endElementId: endB.id,
                  label: isTr
                      ? "Line $fb-$tb (T: ${info['tap'] ?? 1.0})"
                      : "Line $fb-$tb",
                )
                ..rPu = (info['r_pu'] as num?)?.toDouble() ?? 0.01
                ..xPu = (info['x_pu'] as num?)?.toDouble() ?? 0.05
                ..bPu = (info['b_pu'] as num?)?.toDouble() ?? 0.0
                ..tapRatio = (info['tap'] as num?)?.toDouble() ?? 1.0;
          elements.add(lineEl);
        }

        branches.forEach((k, v) {
          final m = RegExp(r'(\d+)\D+(\d+)').firstMatch(k);
          if (m != null)
            addLine(int.parse(m.group(1)!), int.parse(m.group(2)!), v, false);
        });
        transformers.forEach((k, v) {
          final m = RegExp(r'(\d+)\D+(\d+)').firstMatch(k);
          if (m != null)
            addLine(int.parse(m.group(1)!), int.parse(m.group(2)!), v, true);
        });

        WidgetsBinding.instance.addPostFrameCallback((_) => _zoomToFit());
      });
    }

    // 1. Authoritative Backend Binding: Call backend /apply_excel_to_elements
    try {
      final uri = Uri.parse('http://127.0.0.1:8000/apply_excel_to_elements');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'elements': elements.map((e) => e.toJson()).toList(),
          'excel_data': excelData,
        }),
      );

      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        if (res['status'] == 'success' && res['elements'] is List) {
          final updatedList = res['elements'] as List;
          setState(() {
            for (var updated in updatedList) {
              if (updated is! Map<String, dynamic>) continue;
              final id = updated['id']?.toString();
              for (var e in elements) {
                if (e.id == id) {
                  e.updateFromJson(updated);
                  break;
                }
              }
            }
          });
          final summary = res['summary'] as Map<String, dynamic>? ?? {};
          final mismatchReport = (res['mismatch_report'] ?? summary['mismatch_report']) as Map<String, dynamic>?;

          if (mounted) {
            if (mismatchReport != null && mismatchReport['is_matched'] == false) {
              _showMismatchDialog(mismatchReport, excelData);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "✅ 엑셀 데이터와 도면이 완벽히 일치합니다!\n"
                    "• 모선: ${summary['applied_counts']?['bus'] ?? summary['bus'] ?? 0}개, 발전기: ${summary['applied_counts']?['generator'] ?? summary['generator'] ?? 0}개, "
                    "부하: ${summary['applied_counts']?['load'] ?? summary['load'] ?? 0}개, 선로: ${summary['applied_counts']?['line'] ?? summary['line'] ?? 0}개, 변압기: ${summary['applied_counts']?['transformer'] ?? summary['transformer'] ?? 0}개",
                  ),
                  backgroundColor: Colors.green.shade700,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
          return;
        }
      }
    } catch (e) {
      debugPrint("Backend apply_excel_to_elements call error: $e");
    }
  }

  void _showMismatchDialog(Map<String, dynamic> mismatchReport, Map<String, dynamic> excelData) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ExcelMismatchDialog(
        mismatchReport: mismatchReport,
        excelData: excelData,
        elements: elements,
        onAutoRecover: () {
          Navigator.of(ctx).pop();
          _autoRecoverMissingElements(mismatchReport, excelData);
        },
      ),
    );
  }

  void _autoRecoverMissingElements(Map<String, dynamic> mismatchReport, Map<String, dynamic> excelData) {
    _saveState();
    final details = (mismatchReport['details'] as Map<String, dynamic>?) ?? {};
    final missingBuses = (details['missing_buses'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [];
    final missingBranches = (details['missing_branches'] as List?) ?? [];
    final missingGens = (details['missing_generators'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [];
    final missingLoads = (details['missing_loads'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [];

    setState(() {
      double avgX = CANVAS_CENTER;
      double avgY = CANVAS_CENTER;
      int busCount = 0;
      for (var el in elements) {
        if (el.type == Tool.bus) {
          avgX += el.position.dx;
          avgY += el.position.dy;
          busCount++;
        }
      }
      if (busCount > 0) {
        avgX /= (busCount + 1);
        avgY /= (busCount + 1);
      }

      int offsetIdx = 0;
      for (var bNum in missingBuses) {
        final newBus = DrawingElement(
          id: "bus_$bNum",
          type: Tool.bus,
          position: Offset(avgX + (offsetIdx * 140) - 200, avgY + 180),
          width: 120,
          height: 10,
          label: "$bNum",
        );
        elements.add(newBus);
        offsetIdx++;
      }

      Map<int, DrawingElement> busMap = {};
      for (var el in elements) {
        if (el.type == Tool.bus) {
          final bNum = int.tryParse(RegExp(r'\d+').firstMatch(el.label)?.group(0) ?? '') ??
                       int.tryParse(RegExp(r'\d+').firstMatch(el.id)?.group(0) ?? '');
          if (bNum != null) busMap[bNum] = el;
        }
      }

      for (var bNum in missingGens) {
        final bus = busMap[bNum];
        if (bus != null) {
          final genEl = DrawingElement(
            id: "gen_$bNum",
            type: Tool.generator,
            position: Offset(bus.position.dx + 20, bus.position.dy - 60),
            width: 44,
            height: 44,
            parentBusId: bus.id,
            label: "G_$bNum",
          );
          elements.add(genEl);
        }
      }

      for (var bNum in missingLoads) {
        final bus = busMap[bNum];
        if (bus != null) {
          final loadEl = DrawingElement(
            id: "load_$bNum",
            type: Tool.load,
            position: Offset(bus.position.dx + 20, bus.position.dy + 60),
            width: 44,
            height: 44,
            parentBusId: bus.id,
            label: "Load_$bNum",
          );
          elements.add(loadEl);
        }
      }

      for (var br in missingBranches) {
        if (br is List && br.length >= 2) {
          final fb = (br[0] as num).toInt();
          final tb = (br[1] as num).toInt();
          final b1 = busMap[fb];
          final b2 = busMap[tb];
          if (b1 != null && b2 != null) {
            final lineEl = DrawingElement(
              id: "line_${fb}_$tb",
              type: Tool.line,
              position: Offset((b1.position.dx + b2.position.dx) / 2, (b1.position.dy + b2.position.dy) / 2),
              startElementId: b1.id,
              endElementId: b2.id,
              label: "Line $fb-$tb",
            );
            elements.add(lineEl);
          }
        }
      }
    });

    _applyExcelDataToCanvas(excelData);
  }

  void _applyAiDataToCanvas(Map<String, dynamic> aiData) {
    _saveState();
    setState(() {
      elements.clear();

      final rawNodes = aiData['nodes'] ?? aiData['verified_nodes'] ?? [];
      final rawLines = aiData['lines'] ?? aiData['verified_lines'] ?? [];

      if (rawNodes.isEmpty) return;

      // 1. Calculate centroid of all raw nodes to apply a single uniform shift to center
      double sumX = 0, sumY = 0;
      int nodeCount = 0;
      for (var node in rawNodes) {
        final rawBbox = node['bbox'] ?? [100, 100, 40, 40];
        sumX += (rawBbox[0] as num).toDouble();
        sumY += (rawBbox[1] as num).toDouble();
        nodeCount++;
      }
      final double origCenterX = nodeCount > 0 ? sumX / nodeCount : 0;
      final double origCenterY = nodeCount > 0 ? sumY / nodeCount : 0;

      final double shiftX = CANVAS_CENTER - origCenterX;
      final double shiftY = CANVAS_CENTER - origCenterY;

      // 2. Parse nodes preserving original bbox width/height
      final Set<String> elementsWithExplicitOrientation = {};
      for (var node in rawNodes) {
        String id = (node['id'] ?? node['node_id'] ?? '').toString();
        String aiClass = (node['class'] ?? node['className'] ?? 'bus')
            .toString()
            .toLowerCase();
        final rawBbox = node['bbox'] ?? [100, 100, 40, 40];
        double cx = ((rawBbox[0] as num).toDouble()) + shiftX;
        double cy = ((rawBbox[1] as num).toDouble()) + shiftY;
        double w = (rawBbox[2] as num).toDouble();
        double h = (rawBbox[3] as num).toDouble();

        Tool type = Tool.bus;
        if (aiClass.contains('gen'))
          type = Tool.generator;
        else if (aiClass.contains('load'))
          type = Tool.load;
        else if (aiClass.contains('trans'))
          type = Tool.transformer;
        else if (aiClass.contains('bus'))
          type = Tool.bus;

        // Preserve bbox aspect ratio and dimensions without forced 34-52px square
        if (type == Tool.bus) {
          if (w > h) {
            h = math.max(h, 8.0);
            w = math.max(w, 40.0);
          } else {
            w = math.max(w, 8.0);
            h = math.max(h, 40.0);
          }
        } else if (type == Tool.load) {
          w = 18.0;
          h = 26.0;
        } else if (type == Tool.generator) {
          double size = math.max(math.max(w, h), 26.0);
          w = size;
          h = size;
        } else if (type == Tool.transformer) {
          w = math.max(w, 24.0);
          h = math.max(h, 24.0);
        }

        // Calculate 90-degree snapped rotation angle from metadata orientation if available
        double angle = 0.0;
        final orientationMeta = node['orientation'] ?? 
            (node['metadata'] is Map ? node['metadata']['orientation'] : null) ??
            (node['parameters'] is Map ? node['parameters']['orientation'] : null);
        final directionMeta = node['direction'] ?? 
            (node['metadata'] is Map ? node['metadata']['direction'] : null) ??
            (node['parameters'] is Map ? node['parameters']['direction'] : null);

        if (orientationMeta != null) {
          String orient = orientationMeta.toString().toLowerCase();
          if (orient == 'down' || orient == 'south' || orient == '90') {
            angle = 0.0;
          } else if (orient == 'up' || orient == 'north' || orient == '270') {
            angle = math.pi;
          } else if (orient == 'left' || orient == 'west' || orient == '180') {
            angle = math.pi / 2;
          } else if (orient == 'right' || orient == 'east' || orient == '0') {
            angle = -math.pi / 2;
          }
          elementsWithExplicitOrientation.add(id);
        } else if (directionMeta is List && directionMeta.length >= 2) {
          num dx = directionMeta[0] as num;
          num dy = directionMeta[1] as num;
          if (dy > 0) {
            angle = 0.0;
          } else if (dy < 0) {
            angle = math.pi;
          } else if (dx > 0) {
            angle = -math.pi / 2;
          } else if (dx < 0) {
            angle = math.pi / 2;
          }
          elementsWithExplicitOrientation.add(id);
        }

        String label = (node['display_label'] ?? '').toString();
        if (label.isEmpty && id.isNotEmpty) {
          label = id;
        }

        // Determine parentBusId from node metadata if available
        String? parentBusId = node['connected_bus_id']?.toString();
        int? devBusNum =
            (node['connected_bus_number'] as num?)?.toInt() ??
            (node['bus_number'] as num?)?.toInt();
        if (parentBusId == null && devBusNum != null && type != Tool.bus) {
          parentBusId = "bus_$devBusNum";
        }

        final newEl = DrawingElement(
          id: id,
          type: type,
          position: Offset(cx, cy),
          width: w,
          height: h,
          angle: angle,
          label: label,
          parentBusId: parentBusId,
        );
        if (type == Tool.bus) {
          if (node['is_slack'] == true || node['isSlack'] == true) {
            newEl.isSlack = true;
          }
        }
        elements.add(newEl);
      }

      // 3. Parse lines and vectorize to clean CAD standards (orthogonal / straight)
      for (var line in rawLines) {
        String lineId = (line['line_id'] ?? line['id'] ?? '').toString();
        String lineLabel = (line['display_label'] ?? line['display_name'] ?? '')
            .toString();
        List<dynamic> rawPath = line['path'] ?? [];
        List<dynamic> connectedTo = line['connected_to'] ?? [];
        
        DrawingElement? startEl;
        DrawingElement? endEl;
        if (connectedTo.isNotEmpty) {
          try { startEl = elements.firstWhere((e) => e.id == connectedTo[0].toString()); } catch (_) {}
        }
        if (connectedTo.length > 1) {
          try { endEl = elements.firstWhere((e) => e.id == connectedTo[1].toString()); } catch (_) {}
        }

        if (lineLabel.isEmpty && connectedTo.length >= 2) {
          String id1 = connectedTo[0].toString();
          String id2 = connectedTo[1].toString();
          bool isBus1 = id1.startsWith('bus_');
          bool isBus2 = id2.startsWith('bus_');
          String num1 = id1.split('_').last;
          String num2 = id2.split('_').last;
          if (isBus1 && isBus2) {
            lineLabel = "Line $num1-$num2";
          } else if (isBus1) {
            lineLabel = "Line Bus $num1 ↔ $id2";
          } else if (isBus2) {
            lineLabel = "Line Bus $num2 ↔ $id1";
          } else {
            lineLabel = "Line $num1-$num2";
          }
        }

        if (rawPath.length >= 2) {
          List<Offset> parsedPath = [];
          for (var pt in rawPath) {
            parsedPath.add(
              Offset(
                (pt[0] as num).toDouble() + shiftX,
                (pt[1] as num).toDouble() + shiftY,
              ),
            );
          }

          if (parsedPath.isNotEmpty) {
            if (startEl == null) {
              for (var b in elements.where((e) => e.type == Tool.bus)) {
                if ((parsedPath.first.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                    (parsedPath.first.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
                  startEl = b;
                  break;
                }
              }
            }
            if (endEl == null) {
              for (var b in elements.where((e) => e.type == Tool.bus)) {
                if ((parsedPath.last.dx - b.position.dx).abs() <= b.width / 2 + 35.0 &&
                    (parsedPath.last.dy - b.position.dy).abs() <= b.height / 2 + 35.0) {
                  endEl = b;
                  break;
                }
              }
            }
          }

          final cleanPath = _smoothNaturalLine(
            rawPoints: parsedPath,
            startEl: startEl,
            endEl: endEl,
          );

          Offset startPos = cleanPath.first;
          Offset endPos = cleanPath.last;
          Offset? midPos = cleanPath.length == 3 ? cleanPath[1] : (cleanPath.length > 3 ? cleanPath[1] : null);

          elements.add(DrawingElement(
            id: lineId,
            type: Tool.line, 
            position: startPos,
            midPosition: midPos,
            endPosition: endPos,
            aiPath: cleanPath.length > 2 ? cleanPath : null,
            rawAiPath: parsedPath,
            label: lineLabel.isNotEmpty ? lineLabel : lineId,
            startElementId: startEl != null ? startEl.id : (connectedTo.isNotEmpty ? connectedTo[0].toString() : null),
            endElementId: endEl != null ? endEl.id : (connectedTo.length > 1 ? connectedTo[1].toString() : null),
            startAnchor: startEl != null ? (startPos - startEl.position) : null,
            endAnchor: endEl != null ? (endPos - endEl.position) : null,
          ));
        }
      }

      // 4. Connect every Generator & Load to its parent Bus (via bus number, line, or spatial proximity)
      for (var dev in elements.where((e) => e.type == Tool.generator || e.type == Tool.load)) {
        if (dev.parentBusId == null || dev.parentBusId!.isEmpty) {
          int? bNum;
          final mId = RegExp(
            r'^(?:gen|load|g|l)[-_ ]*(\d+)',
            caseSensitive: false,
          ).firstMatch(dev.id);
          if (mId != null) bNum = int.tryParse(mId.group(1)!);
          if (bNum == null && dev.label.isNotEmpty) {
            final mLbl = RegExp(
              r'^(?:gen|load|g|l)[-_ ]*(\d+)',
              caseSensitive: false,
            ).firstMatch(dev.label);
            if (mLbl != null) bNum = int.tryParse(mLbl.group(1)!);
          }
          if (bNum != null) {
            final targetBus = elements
                .where(
                  (e) =>
                      e.type == Tool.bus &&
                      (e.id == "bus_$bNum" ||
                          e.id == "$bNum" ||
                          e.label == "$bNum" ||
                          e.label.startsWith("$bNum ")),
                )
                .firstOrNull;
            if (targetBus != null) {
              dev.parentBusId = targetBus.id;
            }
          }
        }
        if (dev.parentBusId == null || dev.parentBusId!.isEmpty) {
          for (var l in elements.where((e) => e.type == Tool.line)) {
            if (l.startElementId == dev.id && l.endElementId != null) {
              var other = elements
                  .where((e) => e.id == l.endElementId)
                  .firstOrNull;
              if (other != null && other.type == Tool.bus) {
                dev.parentBusId = other.id;
                break;
              }
            } else if (l.endElementId == dev.id && l.startElementId != null) {
              var other = elements
                  .where((e) => e.id == l.startElementId)
                  .firstOrNull;
              if (other != null && other.type == Tool.bus) {
                dev.parentBusId = other.id;
                break;
              }
            }
          }
        }
        if (dev.parentBusId == null || dev.parentBusId!.isEmpty) {
          DrawingElement? nearestBus;
          double minDist = double.infinity;
          for (var b in elements.where((e) => e.type == Tool.bus)) {
            double d = (dev.position - b.position).distance;
            if (d < minDist) {
              minDist = d;
              nearestBus = b;
            }
          }
          if (nearestBus != null && minDist < 200.0) {
            dev.parentBusId = nearestBus.id;
          }
        }
      }

      // 5. For Loads without explicit orientation metadata from AI, compute orientation pointing away from parent Bus
      for (var el in elements.where((e) => e.type == Tool.load)) {
        if (!elementsWithExplicitOrientation.contains(el.id)) {
          DrawingElement? parentBus = elements.where((e) => e.type == Tool.bus && e.id == el.parentBusId).firstOrNull;
          if (parentBus == null && elements.any((e) => e.type == Tool.bus)) {
            double minDist = double.infinity;
            for (var b in elements.where((e) => e.type == Tool.bus)) {
              double d = (el.position - b.position).distance;
              if (d < minDist) {
                minDist = d;
                parentBus = b;
              }
            }
          }
          if (parentBus != null) {
            double dx = el.position.dx - parentBus.position.dx;
            double dy = el.position.dy - parentBus.position.dy;
            if (parentBus.width >= parentBus.height) {
              // Horizontal bus: loads above point UP, loads below point DOWN
              if (dy < -6) {
                el.angle = math.pi; // Pointing UP
              } else if (dy > 6) {
                el.angle = 0.0; // Pointing DOWN
              } else if (dx.abs() > 6) {
                el.angle = dx > 0 ? -math.pi / 2 : math.pi / 2; // Right vs Left
              }
            } else {
              // Vertical bus: loads to right point RIGHT, loads to left point LEFT
              if (dx > 6) {
                el.angle = -math.pi / 2; // Pointing RIGHT
              } else if (dx < -6) {
                el.angle = math.pi / 2; // Pointing LEFT
              } else if (dy.abs() > 6) {
                el.angle = dy > 0 ? 0.0 : math.pi; // Down vs Up
              }
            }
          }
        }
      }

      _resetCamera();
    });

    if (aiData['excel_data'] != null) {
      _applyExcelDataToCanvas(aiData['excel_data']);
    }
    isInspectorOpen = true;
    PowerLensAIService.instance.onStageChanged('FINAL_CAD');
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && lastSimulationResult == null) {
        _showPostCircuitCreationProposal();
      }
    });
  }

  void _showPostCircuitCreationProposal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.bolt,
                color: Colors.amberAccent,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                "🎉 회로도 생성 완료!",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "AI 검수를 통과한 24모선 단선도가 무한 캔버스에 배치되었습니다.\n"
              "이제 뉴턴-랩슨 전력조류계산을 실행하여 송전선로의 유효전력 흐름 방향과 전압을 분석할까요?",
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF38BDF8), width: 1),
              ),
              child: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Colors.cyanAccent, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "조류계산이 끝나면 선로 위로 전력 조류 흐름 애니메이션이 시작됩니다.",
                      style: TextStyle(
                        color: Color(0xFFBAE6FD),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "도면 먼저 보기",
              style: TextStyle(color: Colors.white60),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _sendDataToServer();
            },
            icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
            label: const Text(
              "⚡ 지금 조류계산 실행하기",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _canvasFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: _buildTopAppBar(),
        body: Row(
          children: [
            // 1. Left CAD Tool Palette (64px)
            _buildLeftToolPalette(),

            // 2. Center Infinite Canvas (Expanded)
            Expanded(
                child: Stack(
                  key: _canvasStackKey,
                  children: [
                  _buildCanvas(),
                  _buildCanvasViewControls(),
                  _buildFlowDirectionLegend(),
                  if (!isInspectorOpen)
                    Positioned(
                      right: 0,
                      top: 16,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => setState(() => isInspectorOpen = true),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(8),
                            bottomLeft: Radius.circular(8),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(8),
                                bottomLeft: Radius.circular(8),
                              ),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6, offset: const Offset(-2, 2)),
                              ],
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.chevron_left, size: 18, color: Colors.cyanAccent),
                                SizedBox(width: 4),
                                Text(
                                  "속성 패널 열기",
                                  style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (elements.isEmpty)
                    PowerLensHomeEmptyState(
                      onStartAnalysis: _openReviewPage,
                      onPickImage: _uploadImageToAI,
                      onLoadSample: _loadSampleDiagram,
                      onDrawManually: () {
                        setState(() {
                          isInspectorOpen = true;
                          elements.add(
                            DrawingElement(
                              id: 'bus_1',
                              type: Tool.bus,
                              position: const Offset(
                                CANVAS_CENTER,
                                CANVAS_CENTER,
                              ),
                              label: 'Bus 1',
                            ),
                          );
                          historyStack.add(List.from(elements));
                        });
                      },
                    ),
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: PowerLensAIService.instance,
                      builder: (context, _) {
                        final isMobile =
                            MediaQuery.of(context).size.width < 768;
                        final coachTarget = elements.isEmpty
                            ? 'home_upload'
                            : (lastSimulationResult == null
                                  ? 'final_powerflow'
                                  : 'result_flow');
                        _scheduleLensyTargetSync(coachTarget);
                        return AnimatedAlign(
                          alignment: _effectiveLensyAlignment(
                            coachTarget,
                            isMobile: isMobile,
                          ),
                          duration: const Duration(milliseconds: 650),
                          curve: Curves.easeInOutCubic,
                          child: PowerLensAIFloatingButton(
                            coachTarget: coachTarget,
                            onDragDelta: (delta) => _handleLensyDrag(
                              delta,
                              coachTarget,
                              isMobile: isMobile,
                            ),
                            speechBubbleText: elements.isEmpty
                                ? "도면 사진 업로드 버튼을 눌러 시작해볼까요? ⚡"
                                : (lastSimulationResult == null
                                      ? "회로도가 완성됐어요. 조류계산 버튼을 가리킬게요. ⚡"
                                      : "계산이 끝났어요. 결과를 보여드릴게요! 🌊"),
                            coachMessage: elements.isEmpty
                                ? "도면 사진 업로드 버튼을 눌러 시작해볼까요? ⚡"
                                : (lastSimulationResult == null
                                      ? "회로도가 완성됐어요. 조류계산 버튼을 가리킬게요. ⚡"
                                      : "계산이 끝났어요. 결과를 보여드릴게요! 🌊"),
                            presenceState:
                                PowerLensAIService.instance.mascotState,
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
                                setState(
                                  () => _isAiPanelOpen = !_isAiPanelOpen,
                                );
                              }
                            },
                            isOpen: _isAiPanelOpen,
                            isMobile: isMobile,
                          ),
                        );
                      },
                    ),
                  ),
                  if (_isAiPanelOpen &&
                      MediaQuery.of(context).size.width >= 768)
                    Positioned(
                      right: 20,
                      bottom: 70,
                      child: PowerLensAIPanel(
                        assistantContext: _buildAssistantContext(),
                        onClose: () => setState(() => _isAiPanelOpen = false),
                        isMobile: false,
                      ),
                    ),
                ],
              ),
            ),

            // 3. Right Property Inspector (320px) - Hidden on empty home state
            if (isInspectorOpen && elements.isNotEmpty)
              SizedBox(
                width: 320,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      left: BorderSide(color: Colors.grey.shade300, width: 1),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 6,
                        offset: const Offset(-2, 0),
                      ),
                    ],
                  ),
                  child: InspectorPanel(
                    selectedElement: selectedElement,
                    elements: elements,
                    simulationResult: lastSimulationResult,
                    sBase: 100.0,
                    onStateChanged: () {
                      _saveState();
                      setState(() {});
                    },
                    onDeleteSelected: _deleteSelectedElement,
                    onRotateSelected: () {
                      if (selectedElement != null) {
                        _rotateElement(selectedElement!);
                      }
                    },
                    onStraightenLine: _straightenSelectedLine,
                    onSmoothLine: _smoothSelectedLine,
                    onRestoreRawLine: _restoreSelectedRawLine,
                    onClose: () => setState(() => selectedElement = null),
                    onCollapse: () => setState(() => isInspectorOpen = false),
                    onBusRenamed: _handleBusRenamed,
                    onClearAll: _confirmClearCanvas,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isActualTransmissionOrTransformerLine(DrawingElement el) {
    if (el.type != Tool.line) return false;
    DrawingElement? startEl;
    DrawingElement? endEl;
    try {
      startEl = elements.firstWhere((e) => e.id == el.startElementId);
    } catch (_) {}
    try {
      endEl = elements.firstWhere((e) => e.id == el.endElementId);
    } catch (_) {}

    // Exclude generator feeder leads
    final bool isGenLead =
        startEl?.type == Tool.generator ||
        endEl?.type == Tool.generator ||
        el.label.contains("↔ G_") ||
        el.label.contains("G_") ||
        (el.id.startsWith("lead_") && el.id.contains("gen"));
    if (isGenLead) return false;

    // Exclude load feeder leads
    final bool isLoadLead =
        startEl?.type == Tool.load ||
        endEl?.type == Tool.load ||
        el.label.contains("↔ Load_") ||
        el.label.contains("Load_") ||
        (el.id.startsWith("lead_") && el.id.contains("load"));
    if (isLoadLead) return false;

    if (el.id.startsWith("lead_") ||
        el.label.contains("↔ Load_") ||
        el.label.contains("↔ G_"))
      return false;

    // Transformer branches and AC transmission lines are both included
    return true;
  }

  Map<String, dynamic> _assistantElementPayload(DrawingElement element) {
    final payload = Map<String, dynamic>.from(element.toJson());
    payload['position'] = {
      'dx': element.position.dx,
      'dy': element.position.dy,
    };
    if (element.midPosition != null) {
      payload['mid_position'] = {
        'dx': element.midPosition!.dx,
        'dy': element.midPosition!.dy,
      };
    }
    if (element.endPosition != null) {
      payload['end_position'] = {
        'dx': element.endPosition!.dx,
        'dy': element.endPosition!.dy,
      };
    }
    if (element.aiPath != null) {
      payload['ai_path'] = element.aiPath!
          .map((point) => {'x': point.dx, 'y': point.dy})
          .toList();
    }
    return payload;
  }

  PowerLensAssistantContext _buildAssistantContext() {
    final busCount = elements.where((e) => e.type == Tool.bus).length;
    final lineCount =
        excelBranchCount ??
        (lastSimulationResult != null
            ? (lastSimulationResult!['total_branches'] as num?)?.toInt() ?? 0
            : elements.where(_isActualTransmissionOrTransformerLine).length);
    final bool hasElements = elements.isNotEmpty;
    final bool hasResults = lastSimulationResult != null;
    final bool converged = lastSimulationResult?['converged'] == true;
    final workingNodes = elements
        .where((element) => element.type != Tool.line)
        .map(_assistantElementPayload)
        .toList();
    final workingLines = elements
        .where((element) => element.type == Tool.line)
        .map(_assistantElementPayload)
        .toList();
    final selectedNode =
        selectedElement != null && selectedElement!.type != Tool.line
        ? _assistantElementPayload(selectedElement!)
        : null;
    final selectedLine =
        selectedElement != null && selectedElement!.type == Tool.line
        ? _assistantElementPayload(selectedElement!)
        : null;

    return PowerLensAssistantContext(
      currentScreen: hasElements ? 'CAD_CANVAS' : 'HOME',
      workflowStage: !hasElements
          ? 'HOME'
          : !hasResults
          ? (excelBranchCount != null && excelBranchCount! > 0
                ? 'EXCEL'
                : 'FINAL_CAD')
          : 'POWERFLOW',
      documentId: '',
      hasDiagram: hasElements,
      totalObjects: elements.length,
      totalBuses: busCount,
      totalConnections: lineCount,
      excelLoaded: excelBranchCount != null && excelBranchCount! > 0,
      powerflowReady: busCount > 0 && lineCount > 0,
      powerflowRunning: isSimulating,
      powerflowConverged: hasResults ? converged : null,
      selectedElement: selectedElement?.label,
      selectedNode: selectedNode,
      selectedLine: selectedLine,
      workingNodes: workingNodes,
      workingLines: workingLines,
      currentBlockers: !hasElements
          ? ['단선도 도면 불러오기 또는 AI 분석']
          : (excelBranchCount == null || excelBranchCount == 0)
          ? ['엑셀 계통 제원(임피던스, P, Q, V) 연결']
          : [],
    );
  }

  Widget _workflowBadge(String label, bool isCurrent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isCurrent ? const Color(0xFF2563EB) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isCurrent ? Colors.white : Colors.white60,
          fontSize: 10.5,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
        ),
      ),
    );
  }

  Alignment _lensyCoachAlignment(String target, {required bool isMobile}) {
    if (isMobile) return const Alignment(0.92, 0.88);
    switch (target) {
      case 'home_upload':
        return const Alignment(0.52, 0.02);
      case 'final_powerflow':
        return const Alignment(0.42, 0.48);
      case 'result_flow':
        return const Alignment(0.48, 0.72);
      default:
        return const Alignment(0.82, 0.82);
    }
  }

  Alignment? _measureLensyCoachTarget(
    String target, {
    required bool isMobile,
  }) {
    if (isMobile) return null;
    final targetKey = target == 'final_powerflow'
        ? _powerFlowButtonKey
        : (target == 'result_flow' ? _resultButtonKey : null);
    final targetBox = targetKey?.currentContext?.findRenderObject() as RenderBox?;
    final stackBox =
        _canvasStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (targetBox == null || stackBox == null || !targetBox.hasSize) {
      return null;
    }
    final stackSize = stackBox.size;
    if (stackSize.width <= 1 || stackSize.height <= 1) return null;
    final targetOrigin = targetBox.localToGlobal(Offset.zero);
    final stackOrigin = stackBox.localToGlobal(Offset.zero);
    final targetCenter = targetOrigin - stackOrigin +
        Offset(targetBox.size.width / 2, targetBox.size.height / 2);
    final companionPosition = targetCenter + const Offset(-118, -48);
    return Alignment(
      (((companionPosition.dx / stackSize.width) * 2) - 1)
          .clamp(-0.94, 0.94)
          .toDouble(),
      (((companionPosition.dy / stackSize.height) * 2) - 1)
          .clamp(-0.94, 0.94)
          .toDouble(),
    );
  }

  void _scheduleLensyTargetSync(String target) {
    if (_lastLensySyncTarget == target && _measuredLensyTarget == target) {
      return;
    }
    _lastLensySyncTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final isMobile = MediaQuery.of(context).size.width < 768;
      final measured = _measureLensyCoachTarget(target, isMobile: isMobile);
      if (measured == null || _manualLensyTarget == target) return;
      setState(() {
        _measuredLensyTarget = target;
        _measuredLensyAlignment = measured;
      });
    });
  }

  Alignment _effectiveLensyAlignment(String target, {required bool isMobile}) {
    if (_manualLensyTarget == target && _manualLensyAlignment != null) {
      return _manualLensyAlignment!;
    }
    if (_measuredLensyTarget == target && _measuredLensyAlignment != null) {
      return _measuredLensyAlignment!;
    }
    final measured = _measureLensyCoachTarget(target, isMobile: isMobile);
    if (measured != null) return measured;
    return _lensyCoachAlignment(target, isMobile: isMobile);
  }

  void _handleLensyDrag(
    Offset delta,
    String target, {
    required bool isMobile,
  }) {
    final size = MediaQuery.of(context).size;
    final current = _effectiveLensyAlignment(target, isMobile: isMobile);
    double clampAlignment(double value) =>
        value.clamp(-0.94, 0.94).toDouble();
    setState(() {
      _manualLensyTarget = target;
      _manualLensyAlignment = Alignment(
        clampAlignment(current.x + delta.dx / math.max(size.width / 2, 1)),
        clampAlignment(current.y + delta.dy / math.max(size.height / 2, 1)),
      );
    });
  }

  PreferredSizeWidget _buildTopAppBar() {
    final int busCount = elements.where((e) => e.type == Tool.bus).length;
    int lineCount = excelBranchCount ?? 0;
    if (lineCount == 0 && lastSimulationResult != null) {
      if (lastSimulationResult!['total_branches'] is num) {
        lineCount = (lastSimulationResult!['total_branches'] as num).toInt();
      } else if (lastSimulationResult!['line_results'] is List &&
          (lastSimulationResult!['line_results'] as List).isNotEmpty) {
        lineCount = (lastSimulationResult!['line_results'] as List).length;
      }
    }
    if (lineCount == 0) {
      lineCount = elements.where(_isActualTransmissionOrTransformerLine).length;
    }
    final bool hasResults = lastSimulationResult != null;

    return AppBar(
      elevation: 0.5,
      backgroundColor: const Color(0xFF0F172A), // Modern dark slate 900
      title: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.blue.shade600,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.bolt,
                color: Colors.amberAccent,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              "Power Designer Pro",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 15,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (MediaQuery.of(context).size.width >= 1180)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _workflowBadge("1. 도면", elements.isEmpty),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white30,
                  size: 14,
                ),
                _workflowBadge(
                  "2. AI 검수",
                  elements.isNotEmpty &&
                      (excelBranchCount == null || excelBranchCount == 0),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white30,
                  size: 14,
                ),
                _workflowBadge(
                  "3. 제원 연결",
                  excelBranchCount != null &&
                      excelBranchCount! > 0 &&
                      !hasResults,
                ),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white30,
                  size: 14,
                ),
                _workflowBadge("4. 조류계산", hasResults),
              ],
            ),
          ),
        if (MediaQuery.of(context).size.width >= 850)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.hub_outlined,
                  color: Colors.cyanAccent,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  "모선 $busCount · 선로 $lineCount",
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                if (hasResults) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    "수렴됨",
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.undo, color: Colors.white, size: 18),
          tooltip: "되돌리기 (Ctrl+Z)",
          onPressed: historyStack.isNotEmpty ? _undo : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo, color: Colors.white, size: 18),
          tooltip: "다시실행 (Ctrl+Y)",
          onPressed: redoStack.isNotEmpty ? _redo : null,
        ),
        PopupMenuButton<String>(
          tooltip: "선로 형태 보정 및 정형화",
          icon: const Icon(Icons.auto_fix_high, color: Colors.cyanAccent, size: 20),
          enabled: elements.any((e) => e.type == Tool.line),
          onSelected: (mode) {
            if (mode == 'natural') {
              _smoothAllLinesNaturally();
            } else if (mode == 'orthogonal') {
              _straightenAllLines();
            } else if (mode == 'raw') {
              _restoreAllRawLines();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'natural',
              child: Row(
                children: [
                  Icon(Icons.timeline, color: Color(0xFF2563EB), size: 18),
                  SizedBox(width: 8),
                  Text("자연스러운 직선화 (대각선/각도 보존, 추천)"),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'orthogonal',
              child: Row(
                children: [
                  Icon(Icons.alt_route, color: Color(0xFFD97706), size: 18),
                  SizedBox(width: 8),
                  Text("90° 직각 정형화 (맨해튼 직교)"),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'raw',
              child: Row(
                children: [
                  Icon(Icons.gesture, color: Colors.grey, size: 18),
                  SizedBox(width: 8),
                  Text("원본 손그림 복원"),
                ],
              ),
            ),
          ],
        ),
        if (elements.isNotEmpty) ...[
          Container(height: 20, width: 1, color: Colors.white24),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 10.0,
              horizontal: 2.0,
            ),
            child: OutlinedButton.icon(
              onPressed: _importExcelCase,
              icon: const Icon(
                Icons.table_chart,
                color: Colors.tealAccent,
                size: 15,
              ),
              label: const Text(
                "엑셀 가져오기",
                style: TextStyle(
                  color: Colors.tealAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.tealAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 10.0,
              horizontal: 2.0,
            ),
            child: OutlinedButton.icon(
              onPressed: _openReviewPage,
              icon: const Icon(
                Icons.auto_awesome,
                color: Colors.purpleAccent,
                size: 15,
              ),
              label: const Text(
                "AI로 사진 검사하기",
                style: TextStyle(
                  color: Colors.purpleAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.purpleAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
          if (hasResults)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 10.0,
                horizontal: 2.0,
              ),
              child: OutlinedButton.icon(
                key: _resultButtonKey,
                onPressed: () =>
                    _showPowerFlowResultDialog(lastSimulationResult!),
                icon: const Icon(
                  Icons.assessment_outlined,
                  color: Colors.amberAccent,
                  size: 15,
                ),
                label: const Text(
                  "수치 결과표",
                  style: TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.amberAccent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
            ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: ElevatedButton.icon(
              key: _powerFlowButtonKey,
              onPressed: isSimulating ? null : _sendDataToServer,
              icon: isSimulating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
              label: Text(
                isSimulating ? "해석 중..." : "조류계산 (파이썬 전송)",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: busCount > 0
                    ? Colors.blueAccent.shade700
                    : const Color(0xFF334155),
                elevation: busCount > 0 ? 2 : 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildLeftToolPalette() {
    return Container(
      width: 64,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(1, 0),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    _paletteItem(Tool.move, Icons.near_me, "선택", "V"),
                    _paletteItem(Tool.bus, Icons.horizontal_rule, "모선", "B"),
                    _paletteItem(Tool.generator, Icons.motion_photos_on, "발전기", "G"),
                    _paletteItem(Tool.load, Icons.arrow_downward, "부하", "L"),
                    _paletteItem(Tool.transformer, Icons.crop_square, "변압기", "T"),
                    _paletteItem(Tool.line, Icons.polyline, "선로", "W"),
                    _paletteItem(Tool.text, Icons.text_fields, "라벨", ""),
                    _actionPaletteItem(
                      Icons.menu_book_rounded,
                      "설명서",
                      const Color(0xFF4F46E5),
                      _showUserGuideDialog,
                    ),
                    const Divider(indent: 8, endIndent: 8, height: 16),
                    _actionPaletteItem(
                      Icons.auto_awesome,
                      "AI 도면",
                      Colors.purple,
                      _uploadImageToAI,
                    ),
                    const Spacer(),
                    _actionPaletteItem(
                      Icons.delete_sweep_outlined,
                      "초기화",
                      Colors.redAccent,
                      _confirmClearCanvas,
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _paletteItem(Tool tool, IconData icon, String label, String shortcut) {
    final bool isSel = selectedTool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Tooltip(
        message: shortcut.isNotEmpty ? "$label ($shortcut)" : label,
        waitDuration: const Duration(milliseconds: 300),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() {
              selectedTool = tool;
              if (tool != Tool.move) selectedElement = null;
              lineStart = null;
              lineMid = null;
              pendingStartId = null;
            });
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isSel ? Colors.blue.shade600 : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: isSel
                  ? Border.all(color: Colors.blue.shade800, width: 1.5)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSel ? Colors.white : Colors.blueGrey.shade800,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                    color: isSel ? Colors.white : Colors.blueGrey.shade700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionPaletteItem(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasViewControls() {
    if (elements.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      bottom: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: "화면 확대 (+)",
              onPressed: () => _zoom(1.2),
            ),
            IconButton(
              icon: const Icon(Icons.remove, size: 20),
              tooltip: "화면 축소 (-)",
              onPressed: () => _zoom(1.0 / 1.2),
            ),
            IconButton(
              icon: const Icon(Icons.fit_screen, size: 20, color: Colors.blue),
              tooltip: "도면 전체 화면 맞춤 (F / Space)",
              onPressed: _zoomToFit,
            ),
            Container(
              height: 20,
              width: 1,
              color: Colors.grey.shade300,
              margin: const EdgeInsets.symmetric(horizontal: 4),
            ),
            IconButton(
              icon: Icon(
                showResultOverlay ? Icons.visibility : Icons.visibility_off,
                size: 20,
                color: showResultOverlay ? Colors.blueAccent : Colors.grey,
              ),
              tooltip: showResultOverlay ? "조류계산 결과 숨기기" : "조류계산 결과 도면 표시",
              onPressed: () => setState(() {
                showResultOverlay = !showResultOverlay;
                if (showResultOverlay &&
                    showFlowDirection &&
                    lastSimulationResult != null) {
                  _flowAnimController.repeat();
                } else {
                  _flowAnimController.stop();
                }
              }),
            ),
            if (lastSimulationResult != null) ...[
              IconButton(
                icon: Icon(
                  showFlowDirection
                      ? Icons.navigation
                      : Icons.navigation_outlined,
                  size: 19,
                  color: showFlowDirection
                      ? const Color(0xFF0284C7)
                      : Colors.grey,
                ),
                tooltip: showFlowDirection
                    ? "선로 조류 흐름 애니메이션 숨기기"
                    : "선로 조류 흐름 애니메이션 보기",
                onPressed: () => setState(() {
                  showFlowDirection = !showFlowDirection;
                  if (showFlowDirection && showResultOverlay) {
                    _flowAnimController.repeat();
                  } else {
                    _flowAnimController.stop();
                  }
                }),
              ),
              IconButton(
                icon: Icon(
                  showValueLabels ? Icons.label : Icons.label_outline,
                  size: 19,
                  color: showValueLabels
                      ? const Color(0xFF10B981)
                      : Colors.grey,
                ),
                tooltip: showValueLabels ? "수치 상세 라벨 숨기기" : "수치 상세 라벨 보기",
                onPressed: () =>
                    setState(() => showValueLabels = !showValueLabels),
              ),
            ],
            IconButton(
              icon: Icon(
                isInspectorOpen
                    ? Icons.dock
                    : Icons.chrome_reader_mode_outlined,
                size: 20,
                color: isInspectorOpen ? Colors.blueAccent : Colors.grey,
              ),
              tooltip: isInspectorOpen ? "속성 패널 접기" : "속성 패널 열기",
              onPressed: () =>
                  setState(() => isInspectorOpen = !isInspectorOpen),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlowDirectionLegend() {
    if (elements.isEmpty ||
        !showResultOverlay ||
        !showFlowDirection ||
        lastSimulationResult == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 16,
      bottom: 66,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xE60F172A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF38BDF8), width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, color: Colors.amberAccent, size: 14),
            SizedBox(width: 5),
            Text(
              "⚡ 범례: 흐르는 네온 펄스 (➔) = 유효전력(P) 전송 방향 (수치 라벨 토글 가능)",
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return Stack(
      children: [
        AnimatedBuilder(
          animation: _transformationController,
          builder: (context, child) {
            return CustomPaint(
              painter: InfiniteGridPainter(_transformationController.value),
              size: Size.infinite,
            );
          },
        ),
        InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: selectedTool == Tool.move,
          boundaryMargin: const EdgeInsets.all(10000),
          minScale: 0.1,
          maxScale: 3.0,
          constrained: false,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () {
              if (selectedElement != null) {
                setState(() => isInspectorOpen = true);
              }
            },
            onTapDown: (details) {
              setState(() => currentMousePos = details.localPosition);
              if (selectedTool == Tool.move) {
                _checkSelection(details.localPosition);
              } else {
                _handleDrawingTap(details.localPosition);
              }
            },
            child: MouseRegion(
              onHover: (e) {
                if (selectedTool == Tool.line && lineStart != null) {
                  setState(() {
                    currentMousePos = e.localPosition;
                    snapTarget = _findElementAt(e.localPosition);
                  });
                }
              },
              child: Container(
                width: CANVAS_SIZE,
                height: CANVAS_SIZE,
                color: Colors.transparent,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ...elements
                        .where((e) => e.type == Tool.line)
                        .map((e) => _buildLineWidget(e)),
                    ...elements
                        .where((e) => e.type != Tool.line)
                        .map((e) => _buildBusGenLoadWidget(e)),
                    ...elements
                        .where((e) => e.type != Tool.text)
                        .map((e) => _buildMovableInfoBox(e)),
                    ..._buildResultOverlays(),
                    _buildSnapTargetIndicator(),

                    if (lineStart != null && currentMousePos != null)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: PreviewLinePainter(
                            lineStart!,
                            lineMid,
                            snapTarget != null
                                ? _getSnapPoint(snapTarget!, currentMousePos!)
                                : currentMousePos!,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Offset> _lineGeometry(DrawingElement line) {
    final source = line.aiPath != null && line.aiPath!.length >= 2
        ? line.aiPath!
        : <Offset>[
            line.position,
            if (line.midPosition != null) line.midPosition!,
            if (line.endPosition != null) line.endPosition!,
          ];
    final points = <Offset>[];
    for (final point in source) {
      if (points.isEmpty || (point - points.last).distance > 0.1) {
        points.add(point);
      }
    }
    return points;
  }

  double _linePathLength(List<Offset> points) {
    var length = 0.0;
    for (var i = 1; i < points.length; i++) {
      length += (points[i] - points[i - 1]).distance;
    }
    return length;
  }

  _FlowPathSample? _sampleLinePath(List<Offset> points, double progress) {
    if (points.length < 2) return null;
    final target = _linePathLength(points) * progress.clamp(0.0, 1.0);
    var traversed = 0.0;
    for (var i = 1; i < points.length; i++) {
      final from = points[i - 1];
      final to = points[i];
      final segment = (to - from).distance;
      if (segment <= 0.1) continue;
      if (target <= traversed + segment || i == points.length - 1) {
        final localT = ((target - traversed) / segment).clamp(0.0, 1.0);
        final point = Offset.lerp(from, to, localT) ?? from;
        return _FlowPathSample(
          point: point,
          angle: math.atan2(to.dy - from.dy, to.dx - from.dx),
        );
      }
      traversed += segment;
    }
    return _FlowPathSample(
      point: points.last,
      angle: math.atan2(
        points.last.dy - points[points.length - 2].dy,
        points.last.dx - points[points.length - 2].dx,
      ),
    );
  }

  List<Widget> _buildResultOverlays() {
    if (!showResultOverlay || lastSimulationResult == null) return [];
    final busResults =
        lastSimulationResult!['bus_results'] as List<dynamic>? ?? [];
    final lineResults =
        lastSimulationResult!['line_results'] as List<dynamic>? ?? [];

    List<Widget> overlays = [];

    // 1. Bus Result Badges
    for (var el in elements.where((e) => e.type == Tool.bus)) {
      final busNum = _getBusNum(el.label.isNotEmpty ? el.label : el.id);
      final bRes = busResults.firstWhere(
        (b) => b['bus'].toString() == busNum,
        orElse: () => null,
      );

      if (bRes != null) {
        final double v = (bRes['volt'] as num?)?.toDouble() ?? 1.0;
        final double ang = (bRes['angle'] as num?)?.toDouble() ?? 0.0;
        final double pgen = (bRes['pgen'] as num?)?.toDouble() ?? 0.0;
        final double qgen = (bRes['qgen'] as num?)?.toDouble() ?? 0.0;
        final double pload = (bRes['pload'] as num?)?.toDouble() ?? 0.0;
        final double qload = (bRes['qload'] as num?)?.toDouble() ?? 0.0;

        Color voltColor = (v >= 0.95 && v <= 1.05)
            ? Colors.greenAccent.shade700
            : Colors.deepOrangeAccent;

        if (showValueLabels || selectedElement?.id == el.id) {
          // Detailed voltage and gen/load card. Numeric labels are intentionally
          // absent from the default result canvas; selecting a bus remains an
          // explicit, useful way to inspect its values.
          overlays.add(
            Positioned(
              left: el.position.dx - 80,
              top: el.position.dy + (el.height / 2) + 14,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE60F172A), // Dark slate
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: voltColor.withOpacity(0.7),
                      width: 1.2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "V: ${v.toStringAsFixed(4)} pu",
                            style: TextStyle(
                              color: voltColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "∠${ang >= 0 ? '+' : ''}${ang.toStringAsFixed(2)}°",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      if (pgen.abs() > 0.01 || qgen.abs() > 0.01)
                        Text(
                          "Gen: ${pgen.toStringAsFixed(1)} MW / ${qgen.toStringAsFixed(1)} MVAR",
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 9.5,
                          ),
                        ),
                      if (pload.abs() > 0.01 || qload.abs() > 0.01)
                        Text(
                          "Load: ${pload.toStringAsFixed(1)} MW / ${qload.toStringAsFixed(1)} MVAR",
                          style: const TextStyle(
                            color: Colors.amberAccent,
                            fontSize: 9.5,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    // 2. Line Flow Badges & Animated Pulses
    for (var el in elements.where(
      (e) => e.type == Tool.line && e.endPosition != null,
    )) {
      DrawingElement? startEl;
      DrawingElement? endEl;
      try {
        startEl = elements.firstWhere((e) => e.id == el.startElementId);
      } catch (_) {}
      try {
        endEl = elements.firstWhere((e) => e.id == el.endElementId);
      } catch (_) {}
      final String? sBusStr = (startEl != null)
          ? _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id)
          : (el.startElementId != null ? _getBusNum(el.startElementId!) : null);
      final String? eBusStr = (endEl != null)
          ? _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id)
          : (el.endElementId != null ? _getBusNum(el.endElementId!) : null);
      final bool isBothBuses =
          (startEl?.type == Tool.bus && endEl?.type == Tool.bus) ||
          (sBusStr != null &&
              eBusStr != null &&
              int.tryParse(sBusStr) != null &&
              int.tryParse(eBusStr) != null &&
              startEl?.type != Tool.generator &&
              endEl?.type != Tool.generator &&
              startEl?.type != Tool.load &&
              endEl?.type != Tool.load &&
              startEl?.type != Tool.transformer &&
              endEl?.type != Tool.transformer &&
              !el.id.contains('trans') &&
              !el.id.contains('load') &&
              !el.id.contains('gen')) ||
          (RegExp(r'^line_\d+_\d+$').hasMatch(el.id)) ||
          (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(el.label));
      final bool isGenLead =
          !isBothBuses &&
          (startEl?.type == Tool.generator ||
              endEl?.type == Tool.generator ||
              el.label.contains("↔ G_") ||
              el.label.contains("G_") ||
              (el.id.startsWith("lead_") && el.id.contains("gen")));
      final bool isLoadLead =
          !isBothBuses &&
          !isGenLead &&
          (startEl?.type == Tool.load ||
              endEl?.type == Tool.load ||
              el.label.contains("↔ Load_") ||
              el.label.contains("Load_") ||
              (el.id.startsWith("lead_") && el.id.contains("load")));
      final mid = el.midPosition ?? (el.position + el.endPosition!) / 2;

      if (isGenLead && (el.pPu.abs() > 0.001 || el.qPu.abs() > 0.001)) {
        if (showValueLabels || selectedElement?.id == el.id) {
          final double pMw = el.pPu * 100.0;
          overlays.add(
            Positioned(
              left: mid.dx - 45,
              top: mid.dy - 12,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE61E293B),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.6),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    "${pMw.abs().toStringAsFixed(1)} MW (발전)",
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        continue;
      }

      if (isLoadLead && (el.pPu.abs() > 0.001 || el.qPu.abs() > 0.001)) {
        if (showValueLabels || selectedElement?.id == el.id) {
          final double pMw = el.pPu * 100.0;
          overlays.add(
            Positioned(
              left: mid.dx - 45,
              top: mid.dy - 12,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE61E293B),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Colors.orangeAccent.withOpacity(0.6),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    "${pMw.abs().toStringAsFixed(1)} MW (부하)",
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        continue;
      }

      if (startEl == null || endEl == null) continue;

      final fb = _getBusNum(
        startEl.label.isNotEmpty ? startEl.label : startEl.id,
      );
      final tb = _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id);

      final lRes = lineResults.firstWhere(
        (l) =>
            (l['from_bus'].toString() == fb && l['to_bus'].toString() == tb) ||
            (l['from_bus'].toString() == tb && l['to_bus'].toString() == fb),
        orElse: () => null,
      );

      if (lRes != null) {
        final double pFrom = (lRes['p_from_mw'] as num?)?.toDouble() ?? 0.0;
        final double lossP = (lRes['loss_p_mw'] as num?)?.toDouble() ?? 0.0;
        final bool isForward = (lRes['from_bus'].toString() == fb)
            ? (pFrom >= 0)
            : (pFrom < 0);
        final String fromLabel = isForward
            ? (startEl.label.isNotEmpty ? startEl.label : "Bus $fb")
            : (endEl.label.isNotEmpty ? endEl.label : "Bus $tb");
        final String toLabel = isForward
            ? (endEl.label.isNotEmpty ? endEl.label : "Bus $tb")
            : (startEl.label.isNotEmpty ? startEl.label : "Bus $fb");

        // Use the authoritative routed polyline when available. Reversing
        // this same geometry for a negative P value keeps the animation on
        // the actual drawn line, including elbows and AI pixel traces.
        final basePath = _lineGeometry(el);
        final flowPath = isForward
            ? basePath
            : basePath.reversed.toList(growable: false);

        // Animated arrowheads moving along the routed line. A short line gets
        // one arrow, longer lines get two or three; there are no circular
        // markers, so the direction remains visually unambiguous.
        if (showFlowDirection && pFrom.abs() > 0.01) {
          final double t = _flowAnimController.value;
          final pathLength = _linePathLength(flowPath);
          final arrowCount = pathLength > 700 ? 3 : (pathLength > 260 ? 2 : 1);
          for (int i = 0; i < arrowCount; i++) {
            final double phase = (t + (i / arrowCount)) % 1.0;
            if (phase > 0.10 && phase < 0.90) {
              final sample = _sampleLinePath(flowPath, phase);
              if (sample != null) {
                overlays.add(
                  Positioned(
                    left: sample.point.dx - 10,
                    top: sample.point.dy - 10,
                    child: IgnorePointer(
                      child: Transform.rotate(
                        angle: sample.angle,
                        child: CustomPaint(
                          size: const Size(20, 20),
                          painter: const FlowArrowPainter(),
                        ),
                      ),
                    ),
                  ),
                );
              }
            }
          }
        }

        // Numerical MW text badge: Only shown if showValueLabels is ON or line is selected
        if (showValueLabels || selectedElement?.id == el.id) {
          overlays.add(
            Positioned(
              left: mid.dx - 65,
              top: mid.dy - 15,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE61E293B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.cyanAccent.withOpacity(0.7),
                      width: 1.2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showFlowDirection && pFrom.abs() > 0.01) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.bolt,
                              color: Colors.amberAccent,
                              size: 10,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              "$fromLabel ➔ $toLabel",
                              style: const TextStyle(
                                color: Color(0xFF38BDF8),
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        "${pFrom.abs().toStringAsFixed(1)} MW (손실: ${lossP.toStringAsFixed(1)})",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    return overlays;
  }

  Widget _buildSnapTargetIndicator() {
    if (snapTarget == null || currentMousePos == null || lineStart == null)
      return const SizedBox.shrink();
    final pt = _getSnapPoint(snapTarget!, currentMousePos!);
    return Positioned(
      left: pt.dx - 8,
      top: pt.dy - 8,
      child: IgnorePointer(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withOpacity(0.4),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.cyanAccent, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.cyanAccent, blurRadius: 6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMovableInfoBox(DrawingElement e) {
    if (!e.showInfo || e.type == Tool.bus) return const SizedBox.shrink();

    String name = e.label.isNotEmpty ? e.label : e.id;
    String info = "[$name]\n";
    if (e.type == Tool.generator) {
      info += e.isSlack
          ? "V:${e.vPu}∠${e.thetaDeg}° (Slack)\nP:${e.pPu} Q:${e.qPu}"
          : "P:${e.pPu} Q:${e.qPu}\nV:${e.vPu}";
    } else if (e.type == Tool.load) {
      info += "P:${e.pPu}\nQ:${e.qPu}";
    } else if (e.type == Tool.line) {
      DrawingElement? startEl;
      DrawingElement? endEl;
      try {
        startEl = elements.firstWhere((el) => el.id == e.startElementId);
      } catch (_) {}
      try {
        endEl = elements.firstWhere((el) => el.id == e.endElementId);
      } catch (_) {}
      final String? sBusStr = (startEl != null)
          ? _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id)
          : (e.startElementId != null ? _getBusNum(e.startElementId!) : null);
      final String? eBusStr = (endEl != null)
          ? _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id)
          : (e.endElementId != null ? _getBusNum(e.endElementId!) : null);
      final bool isBothBuses =
          (startEl?.type == Tool.bus && endEl?.type == Tool.bus) ||
          (sBusStr != null &&
              eBusStr != null &&
              int.tryParse(sBusStr) != null &&
              int.tryParse(eBusStr) != null &&
              startEl?.type != Tool.generator &&
              endEl?.type != Tool.generator &&
              startEl?.type != Tool.load &&
              endEl?.type != Tool.load &&
              startEl?.type != Tool.transformer &&
              endEl?.type != Tool.transformer &&
              !e.id.contains('trans') &&
              !e.id.contains('load') &&
              !e.id.contains('gen')) ||
          (RegExp(r'^line_\d+_\d+$').hasMatch(e.id)) ||
          (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(e.label));
      final bool isGenLead =
          !isBothBuses &&
          (startEl?.type == Tool.generator ||
              endEl?.type == Tool.generator ||
              e.label.contains("↔ G_") ||
              e.label.contains("G_") ||
              (e.id.startsWith("lead_") && e.id.contains("gen")));
      final bool isLoadLead =
          !isBothBuses &&
          !isGenLead &&
          (startEl?.type == Tool.load ||
              endEl?.type == Tool.load ||
              e.label.contains("↔ Load_") ||
              e.label.contains("Load_") ||
              (e.id.startsWith("lead_") && e.id.contains("load")));
      if (isGenLead) {
        info +=
            "발전: ${(e.pPu * 100.0).toStringAsFixed(1)} MW\n무효: ${(e.qPu * 100.0).toStringAsFixed(1)} MVAR";
      } else if (isLoadLead) {
        info +=
            "부하: ${(e.pPu * 100.0).toStringAsFixed(1)} MW\n무효: ${(e.qPu * 100.0).toStringAsFixed(1)} MVAR";
      } else {
        info +=
            "${e.rPu}+j${e.xPu}" +
            (e.bPu != 0 ? "\nB:${e.bPu}" : "") +
            (e.tapRatio != 1.0 ? "\nTap:${e.tapRatio}" : "");
      }
    } else if (e.type == Tool.transformer) {
      info += "Tap: ${e.tapRatio} pu";
    } else {
      return const SizedBox.shrink();
    }

    Offset basePos = (e.type == Tool.line)
        ? (e.midPosition ?? (e.position + (e.endPosition ?? e.position)) / 2)
        : e.position;

    return Positioned(
      left: basePos.dx + e.infoOffset.dx,
      top: basePos.dy + e.infoOffset.dy,
      child: GestureDetector(
        onPanStart: (_) => _saveState(),
        onPanUpdate: (d) => setState(() => e.infoOffset += d.delta),
        onTap: () => setState(() => selectedElement = e),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            border: Border.all(
              color: selectedElement == e ? Colors.blue : Colors.grey,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              if (selectedElement == e)
                const BoxShadow(color: Colors.black12, blurRadius: 4),
            ],
          ),
          child: Text(
            info,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }

  void _handleDrawingTap(Offset pos) {
    setState(() {
      DrawingElement? target = _findElementAt(pos);

      String newId =
          "${selectedTool.name[0].toUpperCase()}${elements.length + 1}";
      if (target != null && target.type == Tool.bus) {
        String busNum = _getBusNum(
          target.label.isNotEmpty ? target.label : target.id,
        );
        if (selectedTool == Tool.generator) {
          int count =
              elements
                  .where(
                    (e) =>
                        e.type == Tool.generator && e.parentBusId == target.id,
                  )
                  .length +
              1;
          newId = "G_${busNum}_$count";
        } else if (selectedTool == Tool.load) {
          int count =
              elements
                  .where(
                    (e) => e.type == Tool.load && e.parentBusId == target.id,
                  )
                  .length +
              1;
          newId = "Load_${busNum}_$count";
        } else if (selectedTool == Tool.transformer) {
          int count =
              elements
                  .where(
                    (e) =>
                        e.type == Tool.transformer &&
                        e.parentBusId == target.id,
                  )
                  .length +
              1;
          newId = "T_${busNum}_$count";
        }
      } else if (selectedTool == Tool.line &&
          pendingStartId != null &&
          target != null) {
        DrawingElement? startEl;
        try {
          startEl = elements.firstWhere((e) => e.id == pendingStartId);
        } catch (_) {}

        // Null Safety 수정: startEl이 null이 아닐 때만 조건 진행하도록 보완
        if (startEl != null &&
            startEl.type == Tool.bus &&
            target.type == Tool.bus) {
          String startNum = _getBusNum(
            startEl.label.isNotEmpty ? startEl.label : startEl.id,
          );
          String endNum = _getBusNum(
            target.label.isNotEmpty ? target.label : target.id,
          );
          newId = "L_${startNum}_$endNum";
        } else {
          String sId = startEl?.id ?? 'X';
          String eId = target.label.isNotEmpty ? target.label : target.id;
          newId = "Conn_${sId}_$eId";
        }
      }

      if (selectedTool == Tool.bus) {
        _saveState();
        final newEl = DrawingElement(id: newId, type: Tool.bus, position: pos);
        elements.add(newEl);
        selectedElement = newEl;
        _canvasFocusNode.requestFocus();
      } else if (selectedTool == Tool.generator || selectedTool == Tool.load || selectedTool == Tool.transformer) {
        _saveState(); Offset finalPos = target != null ? _getSnapPoint(target, pos) : pos;
        final newEl = DrawingElement(
          id: newId, 
          type: selectedTool, 
          position: finalPos, 
          width: 40, 
          height: 40, 
          parentBusId: target?.id,
          label: newId,
        );
        if (selectedTool == Tool.generator) {
          newEl.pPu = 1.0;
          newEl.vPu = 1.0;
          newEl.isSynchronousCondenser = false;
        }
        elements.add(newEl);
        selectedElement = newEl;
        _canvasFocusNode.requestFocus();
      } else if (selectedTool == Tool.line) {
        if (lineStart == null) {
          lineStart = target != null ? _getSnapPoint(target, pos) : pos;
          pendingStartId = target?.id;
          if (target != null) pendingStartAnchor = lineStart! - target.position;
        } else if (lineMid == null && target == null) {
          lineMid = pos;
        } else {
          _saveState(); Offset endP = target != null ? _getSnapPoint(target, pos) : pos;
          final newLine = DrawingElement(id: newId, type: Tool.line, position: lineStart!, midPosition: lineMid, endPosition: endP, startElementId: pendingStartId, endElementId: target?.id, startAnchor: pendingStartAnchor, endAnchor: target != null ? (endP - target.position) : null);
          elements.add(newLine);
          selectedElement = newLine;
          _canvasFocusNode.requestFocus();
          
          if (target != null && pendingStartId != null) {
            DrawingElement? startEl;
            try {
              startEl = elements.firstWhere((e) => e.id == pendingStartId);
            } catch (_) {}
            if (startEl != null &&
                startEl.type == Tool.bus &&
                target.type != Tool.bus) {
              _updateConnectedElementsId(startEl);
            } else if (target.type == Tool.bus &&
                startEl != null &&
                startEl.type != Tool.bus) {
              _updateConnectedElementsId(target);
            }
          }

          lineStart = null;
          lineMid = null;
          pendingStartId = null;
        }
      } else if (selectedTool == Tool.text) {
        _saveState(); 
        final newText = DrawingElement(id: newId, type: Tool.text, position: pos, label: "텍스트 입력");
        elements.add(newText);
        selectedElement = newText;
        _canvasFocusNode.requestFocus();
      }
    });
  }

  Widget _buildBusGenLoadWidget(DrawingElement e) {
    bool isSelected = (selectedElement == e);
    if (e.type == Tool.text) {
      return Positioned(
        left: e.position.dx,
        top: e.position.dy,
        child: GestureDetector(
          onTap: () => setState(() => selectedElement = e),
          onPanStart: (_) => _saveState(),
          onPanUpdate: (d) => _moveElement(e, d.delta),
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Text(
              e.label.isEmpty ? e.id : e.label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isSelected ? const Color(0xFF2563EB) : Colors.black,
              ),
            ),
          ),
        ),
      );
    }

    Color baseColor = e.type == Tool.bus
        ? const Color(0xFF1E293B)
        : (e.type == Tool.generator
              ? (e.isSlack ? const Color(0xFFDC2626) : const Color(0xFF2563EB))
              : (e.type == Tool.load
                    ? const Color(0xFF059669)
                    : const Color(0xFF7C3AED)));
    Color drawColor = isSelected ? const Color(0xFF2563EB) : baseColor;
    
    final int quarterTurns = ((e.angle / (math.pi / 2)).round() % 4 + 4) % 4;
    final int counterQuarterTurns = (4 - quarterTurns) % 4;

    Widget shapeContent;
    if (e.type == Tool.generator) {
      final isSC = e.isSynchronousCondenser;
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: e.width, 
            height: e.height, 
            decoration: BoxDecoration(
              color: Colors.white, 
              border: Border.all(
                color: isSelected ? const Color(0xFF2563EB) : drawColor, 
                width: isSelected ? 2.5 : 2.0,
              ), 
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: isSelected ? const Color(0x332563EB) : Colors.black12, 
                  blurRadius: isSelected ? 8 : 3,
                ),
              ],
            ), 
            child: Center(
              child: RotatedBox(
                quarterTurns: counterQuarterTurns,
                child: Text(
                  isSC ? "SC" : (e.isSlack ? "S" : "G"), 
                  style: TextStyle(
                    color: drawColor, 
                    fontWeight: FontWeight.bold, 
                    fontSize: isSC ? e.height * 0.35 : e.height * 0.45,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: -18,
            child: RotatedBox(
              quarterTurns: counterQuarterTurns,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: isSelected ? const Color(0xFF2563EB) : Colors.black12),
                ),
                child: Text(
                  e.label.isNotEmpty ? e.label : e.id,
                  style: TextStyle(
                    fontWeight: FontWeight.bold, 
                    color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF0F172A), 
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else if (e.type == Tool.load) {
      shapeContent = CustomPaint(
        size: Size(e.width, e.height), 
        painter: LoadArrowPainter(color: isSelected ? const Color(0xFF2563EB) : drawColor),
      );
    } else if (e.type == Tool.transformer) {
      bool isVert = e.height >= e.width;
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(e.width, e.height), 
            painter: TransformerPainter(color: isSelected ? const Color(0xFF2563EB) : drawColor, isVertical: isVert),
          ),
          Positioned(
            top: -18,
            child: RotatedBox(
              quarterTurns: counterQuarterTurns,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : Colors.black12,
                  ),
                ),
                child: Text(
                  e.label.isNotEmpty ? e.label : e.id,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : const Color(0xFF0F172A),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      // BUS BAR
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: e.width,
            height: e.height,
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF2563EB)
                  : (e.isSlack
                        ? const Color(0xFFDC2626)
                        : const Color(0xFF0F172A)),
              borderRadius: BorderRadius.circular(2.0),
              boxShadow: [
                if (isSelected)
                  const BoxShadow(
                    color: Color(0x662563EB),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
              ],
            ),
          ),
          Positioned(
            top: -20,
            child: RotatedBox(
              quarterTurns: counterQuarterTurns,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : Colors.black12,
                  ),
                ),
                child: Text(
                  e.label.isNotEmpty
                      ? (e.label.toLowerCase().startsWith('bus')
                            ? e.label
                            : "Bus ${e.label}")
                      : e.id,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : const Color(0xFF0F172A),
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final bool isTransposed = (quarterTurns % 2 == 1);
    final double elemW = isTransposed ? e.height : e.width;
    final double elemH = isTransposed ? e.width : e.height;

    const double topPad = 36.0;
    const double sidePad = 24.0;
    const double bottomPad = 24.0;

    final double boxW = elemW + sidePad * 2;
    final double boxH = elemH + topPad + bottomPad;

    final double leftOffset = e.position.dx - (boxW / 2);
    final double topOffset = e.position.dy - (elemH / 2) - topPad;

    return Positioned(
      left: leftOffset,
      top: topOffset,
      child: SizedBox(
        width: boxW,
        height: boxH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (e.type == Tool.load)
              Positioned(
                left: 0,
                right: 0,
                top: (quarterTurns == 0) ? (topPad + elemH + 2) : (topPad - 18),
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _canvasFocusNode.requestFocus();
                      setState(() => selectedElement = e);
                    },
                    onDoubleTap: () {
                      _canvasFocusNode.requestFocus();
                      setState(() {
                        selectedElement = e;
                        isInspectorOpen = true;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: isSelected ? const Color(0xFF2563EB) : Colors.black12),
                      ),
                      child: Text(
                        e.label.isNotEmpty ? e.label : e.id,
                        style: TextStyle(
                          fontWeight: FontWeight.bold, 
                          color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF0F172A), 
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: sidePad,
              top: topPad,
              width: elemW,
              height: elemH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _canvasFocusNode.requestFocus();
                  setState(() => selectedElement = e);
                },
                onDoubleTap: () {
                  _canvasFocusNode.requestFocus();
                  setState(() {
                    selectedElement = e;
                    isInspectorOpen = true;
                  });
                },
                onPanStart: (d) {
                  if (selectedTool == Tool.move) {
                    _saveState();
                    setState(() => selectedElement = e);
                  }
                },
                onPanUpdate: (d) {
                  if (selectedTool == Tool.move) {
                    _moveElement(e, d.delta);
                  }
                },
                child: MouseRegion(
                  cursor: selectedTool == Tool.move ? SystemMouseCursors.move : SystemMouseCursors.click,
                  child: RotatedBox(
                    quarterTurns: quarterTurns,
                    child: SizedBox(
                      width: e.width,
                      height: e.height,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          shapeContent,
                          if (isSelected) ...[
                            IgnorePointer(
                              child: Container(
                                width: e.width + 8,
                                height: e.height + 8,
                                decoration: BoxDecoration(
                                  border: Border.all(color: const Color(0xFF2563EB), width: 1.5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                            Positioned(
                              right: -6,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (_) => _saveState(),
                                onPanUpdate: (d) {
                                  setState(() {
                                    e.width = (e.width + d.delta.dx).clamp(20, 800);
                                    if (e.type != Tool.bus) e.height = e.width;
                                  });
                                },
                                child: MouseRegion(
                                  cursor: isTransposed
                                      ? SystemMouseCursors.resizeUpDown
                                      : SystemMouseCursors.resizeLeftRight,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: const Color(0xFF2563EB), width: 2),
                                      borderRadius: BorderRadius.circular(2),
                                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (isSelected)
              Positioned(
                top: 4,
                left: (boxW - 28) / 2,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _rotateElement(e);
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2563EB),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                      ),
                      child: const Icon(Icons.rotate_right, size: 18, color: Colors.white),
                    ),
                  ),
                ),
              ),

          ],
        ),
      ),
    );
  }

  Widget _buildLineWidget(DrawingElement e) {
    if (e.endPosition == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: CustomPaint(
        painter: LinePainter(
          e.position,
          e.midPosition,
          e.endPosition!,
          isSelected: selectedElement == e,
          aiPath: e.aiPath,
        ),
      ),
    );
  }

  void _moveElement(DrawingElement e, Offset delta) {
    setState(() {
      e.position += delta;
      for (var line in elements.where((el) => el.type == Tool.line)) {
        if (line.startElementId == e.id) {
          line.position += delta;
          line.aiPath = null;
        }
        if (line.endElementId == e.id) {
          line.endPosition = (line.endPosition ?? line.position) + delta;
          line.aiPath = null;
        }
        if (line.startElementId == e.id || line.endElementId == e.id) {
          if (line.midPosition != null)
            line.midPosition = line.midPosition! + delta;
        }
      }
      if (e.type == Tool.bus) {
        for (var child in elements.where((el) => el.parentBusId == e.id))
          child.position += delta;
      }
    });
  }

  void _checkSelection(Offset pos) {
    setState(() => selectedElement = _findElementAt(pos));
  }
}

class _FlowPathSample {
  final Offset point;
  final double angle;

  const _FlowPathSample({required this.point, required this.angle});
}

class FlowArrowPainter extends CustomPainter {
  const FlowArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = const Color(0xFF0284C7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;

    final centerY = size.height / 2;
    final arrow = Path()
      ..moveTo(size.width * 0.86, centerY)
      ..lineTo(size.width * 0.28, size.height * 0.16)
      ..lineTo(size.width * 0.43, centerY)
      ..lineTo(size.width * 0.28, size.height * 0.84)
      ..close();
    canvas.drawPath(arrow, glowPaint);
    canvas.drawPath(arrow, arrowPaint);
    canvas.drawPath(arrow, outlinePaint);
  }

  @override
  bool shouldRepaint(covariant FlowArrowPainter oldDelegate) => false;
}

class LoadArrowPainter extends CustomPainter {
  final Color color;
  LoadArrowPainter({this.color = Colors.black});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double w = size.width;
    final double h = size.height;
    final double cx = w / 2;

    // Classic filled arrow pointing downwards (shaft + arrowhead):
    final double stemW = math.max(3.0, w * 0.22);
    final double headH = h * 0.48;
    final double headW = w * 0.85;
    final double stemH = h - headH;

    final path = Path();
    path.moveTo(cx - stemW / 2, 0);
    path.lineTo(cx + stemW / 2, 0);
    path.lineTo(cx + stemW / 2, stemH);
    path.lineTo(cx + headW / 2, stemH);
    path.lineTo(cx, h);
    path.lineTo(cx - headW / 2, stemH);
    path.lineTo(cx - stemW / 2, stemH);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class LinePainter extends CustomPainter {
  final Offset start;
  final Offset? mid;
  final Offset end;
  final bool isSelected;
  final List<Offset>? aiPath;
  LinePainter(
    this.start,
    this.mid,
    this.end, {
    this.isSelected = false,
    this.aiPath,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = isSelected ? Colors.yellowAccent : const Color(0xFFC62828)
      ..strokeWidth = isSelected ? 4.0 : 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path path = Path();
    if (aiPath != null && aiPath!.length >= 2) {
      path.moveTo(aiPath!.first.dx, aiPath!.first.dy);
      for (int i = 1; i < aiPath!.length; i++) {
        path.lineTo(aiPath![i].dx, aiPath![i].dy);
      }
    } else {
      path.moveTo(start.dx, start.dy);
      if (mid != null) path.lineTo(mid!.dx, mid!.dy);
      path.lineTo(end.dx, end.dy);
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(CustomPainter old) => true;
}

class PreviewLinePainter extends CustomPainter {
  final Offset start;
  final Offset? mid;
  final Offset current;
  PreviewLinePainter(this.start, this.mid, this.current);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;
    Path path = Path()..moveTo(start.dx, start.dy);
    canvas.drawCircle(start, 4, dotPaint);
    if (mid != null) {
      path.lineTo(mid!.dx, mid!.dy);
      canvas.drawCircle(mid!, 4, dotPaint);
    }
    path.lineTo(current.dx, current.dy);
    canvas.drawPath(path, p);
    canvas.drawCircle(
      current,
      3,
      dotPaint..color = Colors.blue.withOpacity(0.5),
    );
  }

  @override
  bool shouldRepaint(CustomPainter old) => true;
}

class InfiniteGridPainter extends CustomPainter {
  final Matrix4 transform;
  InfiniteGridPainter(this.transform);

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = transform.getMaxScaleOnAxis();
    final double tx = transform.getTranslation().x;
    final double ty = transform.getTranslation().y;

    final p = Paint()
      ..color = Colors.grey[100]!
      ..strokeWidth = 1;

    const double gridSize = 40.0;
    final double scaledGridSize = gridSize * scale;

    if (scaledGridSize < 2.0) return;

    double startX = tx % scaledGridSize;
    double startY = ty % scaledGridSize;

    for (double x = startX; x < size.width; x += scaledGridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = startY; y < size.height; y += scaledGridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(InfiniteGridPainter old) => old.transform != transform;
}

class TransformerPainter extends CustomPainter {
  final Color color;
  final bool isVertical;
  TransformerPainter({required this.color, this.isVertical = true});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    if (isVertical) {
      double r = (size.height / 3.2).clamp(8.0, size.width / 2);
      double cy1 = size.height / 2 - r * 0.65;
      double cy2 = size.height / 2 + r * 0.65;
      canvas.drawCircle(Offset(size.width / 2, cy1), r, paint);
      canvas.drawCircle(Offset(size.width / 2, cy2), r, paint);
    } else {
      double r = (size.width / 3.2).clamp(8.0, size.height / 2);
      double cx1 = size.width / 2 - r * 0.65;
      double cx2 = size.width / 2 + r * 0.65;
      canvas.drawCircle(Offset(cx1, size.height / 2), r, paint);
      canvas.drawCircle(Offset(cx2, size.height / 2), r, paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter old) => false;
}

// ==========================================
// RIGHT PROPERTY INSPECTOR PANEL
// ==========================================
