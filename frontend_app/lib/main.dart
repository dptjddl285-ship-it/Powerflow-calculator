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
import 'widgets/inspector_panel.dart';

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

class PowerCanvasPageState extends State<PowerCanvasPage> {
  final TransformationController _transformationController = TransformationController();
  final FocusNode _canvasFocusNode = FocusNode();

  List<DrawingElement> elements = [];
  List<List<DrawingElement>> historyStack = [];
  List<List<DrawingElement>> redoStack = [];

  Tool selectedTool = Tool.move;
  DrawingElement? selectedElement;
  Offset? lineStart; Offset? lineMid; Offset? currentMousePos;
  String? pendingStartId; Offset? pendingStartAnchor; DrawingElement? snapTarget; 

  Map<String, dynamic>? lastSimulationResult;
  bool showResultOverlay = false;
  bool isInspectorOpen = true;
  bool isSimulating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetCamera();
      _canvasFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _canvasFocusNode.dispose();
    super.dispose();
  }

  void _resetCamera() {
    final size = MediaQuery.of(context).size;
    if (size.width == 0) return;
    _transformationController.value = Matrix4.identity()
      ..translate(-(CANVAS_CENTER - size.width / 2), -(CANVAS_CENTER - size.height / 2), 0.0);
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
    final double availWidth = mediaQuery.size.width - 64 - (isInspectorOpen ? 320 : 0);
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

    final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    final focusedWidget = FocusManager.instance.primaryFocus;
    // Any focus outside canvas means the user is actively typing or editing in an input field / inspector
    final isEditingInput = focusedWidget != null && focusedWidget != _canvasFocusNode;

    if (isEditingInput) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        FocusManager.instance.primaryFocus?.unfocus();
        _canvasFocusNode.requestFocus();
      }
      // CRITICAL: Return immediately so Backspace, Delete, and shortcuts NEVER delete elements while typing!
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyF || event.logicalKey == LogicalKeyboardKey.space) {
      _zoomToFit();
      return;
    }

    // Only allow element deletion when Delete key is pressed on the canvas (Backspace is strictly reserved for text editing)
    if (event.logicalKey == LogicalKeyboardKey.delete && _canvasFocusNode.hasFocus) {
      _deleteSelectedElement();
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
    } else if (selectedElement != null && _canvasFocusNode.hasFocus && event.logicalKey == LogicalKeyboardKey.keyR) {
      _saveState();
      setState(() {
        selectedElement!.angle = (selectedElement!.angle + math.pi / 2) % (math.pi * 2);
      });
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
    } else if (!isCtrl) {
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        setState(() => selectedTool = Tool.move);
      } else if (event.logicalKey == LogicalKeyboardKey.keyB) {
        setState(() { selectedTool = Tool.bus; selectedElement = null; });
      } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
        setState(() { selectedTool = Tool.generator; selectedElement = null; });
      } else if (event.logicalKey == LogicalKeyboardKey.keyL) {
        setState(() { selectedTool = Tool.load; selectedElement = null; });
      } else if (event.logicalKey == LogicalKeyboardKey.keyT) {
        setState(() { selectedTool = Tool.transformer; selectedElement = null; });
      } else if (event.logicalKey == LogicalKeyboardKey.keyW) {
        setState(() { selectedTool = Tool.line; selectedElement = null; });
      }
    }
  }

  void _deleteSelectedElement() {
    if (selectedElement == null) return;
    _saveState();
    final target = selectedElement!;
    setState(() {
      if (target.type == Tool.bus) {
        elements.removeWhere((el) =>
            el.id == target.id ||
            el.parentBusId == target.id ||
            el.startElementId == target.id ||
            el.endElementId == target.id);
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
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

  void _saveState() {
    historyStack.add(elements.map((e) => e.copy()).toList()); redoStack.clear();
    if (historyStack.length > 30) historyStack.removeAt(0);
  }

  void _undo() {
    if (historyStack.isEmpty) return;
    setState(() { redoStack.add(elements.map((e) => e.copy()).toList()); elements = historyStack.removeLast(); selectedElement = null; });
  }

  void _redo() {
    if (redoStack.isEmpty) return;
    setState(() { historyStack.add(elements.map((e) => e.copy()).toList()); elements = redoStack.removeLast(); selectedElement = null; });
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    double l2 = (a - b).distanceSquared; if (l2 == 0.0) return (p - a).distance;
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2; t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy))).distance;
  }

  Offset _getSnapPoint(DrawingElement e, Offset touchPos) {
    if (e.type != Tool.bus) return e.position;
    double cosA = math.cos(-e.angle); double sinA = math.sin(-e.angle);
    Offset rel = touchPos - e.position;
    double localX = (rel.dx * cosA - rel.dy * sinA).clamp(-e.width/2, e.width/2);
    double localY = (rel.dx * sinA + rel.dy * cosA).clamp(-e.height/2, e.height/2);
    cosA = math.cos(e.angle); sinA = math.sin(e.angle);
    return e.position + Offset(localX * cosA - localY * sinA, localX * sinA + localY * cosA);
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
        
        if (localX.abs() <= (e.width / 2) + 10 && localY.abs() <= (e.height / 2) + 10) return e;
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
            if (_distToSegment(pos, e.aiPath![i], e.aiPath![i+1]) < hitPadding) return e;
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
      if (el.type == Tool.generator || el.type == Tool.load || el.type == Tool.transformer) {
        bool isConnected = false;
        
        if (el.parentBusId == bus.id) {
          isConnected = true; // 모선 위에 직접 찰칵(스냅) 붙인 경우
        } else {
          // 단순 연결선(Line)을 길게 그려서 연결한 경우인지 스캔
          isConnected = elements.any((line) => 
            line.type == Tool.line && 
            ((line.startElementId == bus.id && line.endElementId == el.id) ||
             (line.startElementId == el.id && line.endElementId == bus.id))
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
        try { startEl = elements.firstWhere((e) => e.id == el.startElementId); } catch(_) {}
        try { endEl = elements.firstWhere((e) => e.id == el.endElementId); } catch(_) {}

        // Null Safety 수정: startEl과 endEl의 Null 체크를 명확히 함
        if (startEl != null && endEl != null && startEl.type == Tool.bus && endEl.type == Tool.bus) {
          String startNum = _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id);
          String endNum = _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id);
          el.id = 'L_${startNum}_$endNum';
        } else if (startEl != null && endEl != null) {
          el.id = 'Conn_${startEl.id}_${endEl.id}';
        }
      }
    }
  }

  Future<void> _sendDataToServer() async {
    final url = Uri.parse('http://127.0.0.1:8000/run_simulation'); 
    final payload = jsonEncode({'elements': elements.map((e) => e.toJson()).toList()});

    setState(() => isSimulating = true);

    try {
      final response = await http.post(url, headers: {'Content-Type': 'application/json'}, body: payload);
      if (!mounted) return;
      setState(() => isSimulating = false);

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result['data'] != null && (result['status'] == 'success' || result['status'] == 'warning')) {
          setState(() {
            lastSimulationResult = result['data'];
            final busResults = result['data']['bus_results'] as List<dynamic>? ?? [];
            for (var br in busResults) {
              int bNum = (br['bus'] as num).toInt();
              double pgenPu = (br['pgen_pu'] as num?)?.toDouble() ?? 0.0;
              double qgenPu = (br['qgen_pu'] as num?)?.toDouble() ?? 0.0;
              double vPu = (br['volt_pu'] as num?)?.toDouble() ?? 1.0;
              double angleDeg = (br['angle_deg'] as num?)?.toDouble() ?? 0.0;

              for (var el in elements) {
                if (el.type == Tool.bus && (el.label == "$bNum" || el.label.startsWith("$bNum ") || el.id == "bus_$bNum")) {
                  el.vPu = vPu;
                  el.thetaDeg = angleDeg;
                } else if (el.type == Tool.generator && (el.label == "G_$bNum" || el.label.startsWith("G_$bNum ") || el.label.startsWith("SC_$bNum") || el.id == "gen_$bNum" || el.parentBusId == "bus_$bNum")) {
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
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
            SnackBar(content: Text(result['message'] ?? "조류 계산 실패"), backgroundColor: Colors.orange),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("서버 응답 오류가 발생했습니다."), backgroundColor: Colors.red),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                              isConverged ? "조류 계산 수렴 완료 ($iterations회 반복)" : "조류 계산 미수렴",
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              "슬랙 모선: #${slackBus ?? '자동'} | 최대 불평형량 오차: ${maxMismatch.toStringAsExponential(3)}",
                              style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Row(
                          children: [
                            Text(
                              showPu ? "단위: pu" : "단위: MW / MVAR",
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
                        _buildKpiItem("총 발전 (P / Q)", "${summary['total_gen_p_mw'] ?? 0} MW / ${summary['total_gen_q_mvar'] ?? 0} MVAR", Colors.blue[900]!),
                        _buildKpiItem("총 부하 (P / Q)", "${summary['total_load_p_mw'] ?? 0} MW / ${summary['total_load_q_mvar'] ?? 0} MVAR", Colors.teal[900]!),
                        _buildKpiItem("총 송전 손실 (Loss)", "${summary['total_loss_p_mw'] ?? 0} MW / ${summary['total_loss_q_mvar'] ?? 0} MVAR", Colors.red[900]!),
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
                              content: Text("✅ 계산된 전압 및 위상각이 캔버스 모선에 실시간 반영되었습니다!"),
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
                                  content: Text("📋 CSV 데이터가 클립보드에 복사되었습니다! 엑셀(Ctrl+V)에 바로 붙여넣을 수 있습니다."),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 18, color: Colors.white),
                            label: const Text("CSV 텍스트 복사 (엑셀용)", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[700]),
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
        Text(title, style: TextStyle(fontSize: 12, color: Colors.grey[700], fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
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
              const DataColumn(label: Text("Bus", style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Volt (pu)" : "Volt", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Angle (deg)" : "Angle", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Pgen (pu)" : "Pgen", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Qgen (pu)" : "Qgen", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Pload (pu)" : "Pload", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Qload (pu)" : "Qload", style: const TextStyle(fontWeight: FontWeight.bold))),
              const DataColumn(label: Text("Type", style: TextStyle(fontWeight: FontWeight.bold))),
            ],
            rows: busResults.map((r) {
              String type = r['type'] ?? 'PQ';
              Color rowColor = type == 'SLACK'
                  ? Colors.amber[50]!
                  : (type == 'PV' ? Colors.blue[50]! : Colors.transparent);

              double volt = showPu ? (r['volt_pu'] as num).toDouble() : (r['volt'] as num).toDouble();
              double angle = (r['angle'] as num).toDouble();
              double pgen = showPu ? (r['pgen_pu'] as num).toDouble() : (r['pgen'] as num).toDouble();
              double qgen = showPu ? (r['qgen_pu'] as num).toDouble() : (r['qgen'] as num).toDouble();
              double pload = showPu ? (r['pload_pu'] as num).toDouble() : (r['pload'] as num).toDouble();
              double qload = showPu ? (r['qload_pu'] as num).toDouble() : (r['qload'] as num).toDouble();

              return DataRow(
                color: MaterialStateProperty.all(rowColor),
                cells: [
                  DataCell(Text("${r['bus']}", style: const TextStyle(fontWeight: FontWeight.bold))),
                  DataCell(Text(volt.toStringAsFixed(4))),
                  DataCell(Text(angle.toStringAsFixed(4))),
                  DataCell(Text(pgen.toStringAsFixed(4))),
                  DataCell(Text(qgen.toStringAsFixed(4))),
                  DataCell(Text(pload.toStringAsFixed(4))),
                  DataCell(Text(qload.toStringAsFixed(4))),
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: type == 'SLACK' ? Colors.red[100] : (type == 'PV' ? Colors.blue[100] : Colors.grey[200]),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: type == 'SLACK' ? Colors.red[900] : (type == 'PV' ? Colors.blue[900] : Colors.grey[800]),
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
              const DataColumn(label: Text("No.", style: TextStyle(fontWeight: FontWeight.bold))),
              const DataColumn(label: Text("선로", style: TextStyle(fontWeight: FontWeight.bold))),
              const DataColumn(label: Text("From", style: TextStyle(fontWeight: FontWeight.bold))),
              const DataColumn(label: Text("To", style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "P From (pu)" : "P From (MW)", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Q From (pu)" : "Q From (MVAR)", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "P To (pu)" : "P To (MW)", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Q To (pu)" : "Q To (MVAR)", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text(showPu ? "Loss P (pu)" : "Loss P (MW)", style: const TextStyle(fontWeight: FontWeight.bold))),
            ],
            rows: List.generate(sortedLines.length, (idx) {
              final r = sortedLines[idx];
              return DataRow(
                cells: [
                  DataCell(Text("${idx + 1}", style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))),
                  DataCell(Text("${r['label'] ?? ''}", style: const TextStyle(fontWeight: FontWeight.w600))),
                  DataCell(Text("${r['from_bus']}")),
                  DataCell(Text("${r['to_bus']}")),
                  DataCell(Text(showPu ? "${r['p_from_pu']}" : "${r['p_from_mw']}")),
                  DataCell(Text(showPu ? "${r['q_from_pu']}" : "${r['q_from_mvar']}")),
                  DataCell(Text(showPu ? "-" : "${r['p_to_mw']}")),
                  DataCell(Text(showPu ? "-" : "${r['q_to_mvar']}")),
                  DataCell(Text(showPu ? "${r['loss_p_pu']}" : "${r['loss_p_mw']}", style: const TextStyle(color: Colors.red))),
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

  Future<void> _openReviewPage() async {
    bool hasApplied = false;
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => ObjectReviewPage(
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

  Future<void> _uploadImageToAI() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return; 

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("AI가 도면을 분석 중입니다... 🧠")));

    var uri = Uri.parse('http://127.0.0.1:8000/analyze_image'); 
    var request = http.MultipartRequest('POST', uri);
    Uint8List imageBytes = await image.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: image.name));

    try {
      var response = await request.send();
      if (!mounted) return; // Async Gap 경고 해결
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var result = jsonDecode(responseData);

        if (result['status'] == 'success') {
          _applyAiDataToCanvas(result['data']);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("AI 분석 완료! 화면 중앙에 배치되었습니다."), backgroundColor: Colors.green));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("AI 분석 서버 오류!"), backgroundColor: Colors.red));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("접속 실패: $e"), backgroundColor: Colors.red));
    }
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
          const SnackBar(content: Text("파일 데이터를 읽을 수 없습니다."), backgroundColor: Colors.red),
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
        SnackBar(content: Text("엑셀 파일 선택/업로드 오류: $e"), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _applyExcelDataToCanvas(Map<String, dynamic> excelData) async {
    _saveState();

    var buses = excelData['buses'] as Map<String, dynamic>? ?? {};
    var gens = excelData['generators'] as Map<String, dynamic>? ?? {};
    var branches = excelData['branches'] as Map<String, dynamic>? ?? {};
    var transformers = excelData['transformers'] as Map<String, dynamic>? ?? {};

    // 0. If canvas is empty, auto-generate single-line diagram in circle layout
    if (elements.isEmpty && buses.isNotEmpty) {
      setState(() {
        final sortedBusKeys = buses.keys.toList()
          ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
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
          final bPos = Offset(centerX + radius * math.cos(angle), centerY + radius * math.sin(angle));

          final busEl = DrawingElement(
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
            final genEl = DrawingElement(
              id: "gen_$bNum",
              type: Tool.generator,
              position: gPos,
              width: 44,
              height: 44,
              parentBusId: busEl.id,
              label: "G_$bNum" + (gInfo['is_slack'] == true ? " (Slack)" : ""),
            )
              ..isSlack = (gInfo['is_slack'] == true)
              ..vPu = (gInfo['voltage_setpoint'] as num?)?.toDouble() ?? 1.0
              ..pPu = (gInfo['is_slack'] == true) ? 0.0 : ((gInfo['pg_pu'] as num?)?.toDouble() ?? 0.0)
              ..qPu = (gInfo['is_slack'] == true) ? 0.0 : ((gInfo['qg_pu'] as num?)?.toDouble() ?? 0.0);
            elements.add(genEl);
          }

          if (busEl.pPu > 0 || busEl.qPu > 0) {
            final lPos = Offset(bPos.dx, bPos.dy + 60);
            final loadEl = DrawingElement(
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
          final lineEl = DrawingElement(
            id: "line_${fb}_$tb",
            type: Tool.line,
            position: startB.position,
            endPosition: endB.position,
            startElementId: startB.id,
            endElementId: endB.id,
            label: isTr ? "Line $fb-$tb (T: ${info['tap'] ?? 1.0})" : "Line $fb-$tb",
          )
            ..rPu = (info['r_pu'] as num?)?.toDouble() ?? 0.01
            ..xPu = (info['x_pu'] as num?)?.toDouble() ?? 0.05
            ..bPu = (info['b_pu'] as num?)?.toDouble() ?? 0.0
            ..tapRatio = (info['tap'] as num?)?.toDouble() ?? 1.0;
          elements.add(lineEl);
        }

        branches.forEach((k, v) {
          final m = RegExp(r'(\d+)\D+(\d+)').firstMatch(k);
          if (m != null) addLine(int.parse(m.group(1)!), int.parse(m.group(2)!), v, false);
        });
        transformers.forEach((k, v) {
          final m = RegExp(r'(\d+)\D+(\d+)').firstMatch(k);
          if (m != null) addLine(int.parse(m.group(1)!), int.parse(m.group(2)!), v, true);
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
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "✅ 엑셀 데이터 매핑 완료 (백엔드 일원화)!\n"
                  "• 모선: ${summary['bus'] ?? 0}개, 발전기: ${summary['generator'] ?? 0}개, "
                  "부하: ${summary['load'] ?? 0}개, 선로: ${summary['line'] ?? 0}개, 변압기: ${summary['transformer'] ?? 0}개",
                ),
                backgroundColor: Colors.green.shade700,
                duration: const Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint("Backend apply_excel_to_elements call error: $e");
    }
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
      for (var node in rawNodes) {
        String id = (node['id'] ?? node['node_id'] ?? '').toString();
        String aiClass = (node['class'] ?? node['className'] ?? 'bus').toString().toLowerCase();
        final rawBbox = node['bbox'] ?? [100, 100, 40, 40];
        double cx = ((rawBbox[0] as num).toDouble()) + shiftX;
        double cy = ((rawBbox[1] as num).toDouble()) + shiftY;
        double w = (rawBbox[2] as num).toDouble();
        double h = (rawBbox[3] as num).toDouble();
        
        Tool type = Tool.bus; 
        if (aiClass.contains('gen')) type = Tool.generator;
        else if (aiClass.contains('load')) type = Tool.load;
        else if (aiClass.contains('trans')) type = Tool.transformer; 
        else if (aiClass.contains('bus')) type = Tool.bus;

        // Preserve bbox aspect ratio and dimensions without forced 34-52px square
        if (type == Tool.bus) {
          if (w > h) { h = math.max(h, 8.0); w = math.max(w, 40.0); } 
          else { w = math.max(w, 8.0); h = math.max(h, 40.0); }       
        } else if (type == Tool.load) {
          w = math.max(w, 18.0);
          h = math.max(h, 24.0);
        } else if (type == Tool.generator) {
          double size = math.max(math.max(w, h), 26.0);
          w = size; h = size;
        } else if (type == Tool.transformer) {
          w = math.max(w, 24.0);
          h = math.max(h, 24.0);
        }

        // Calculate 90-degree snapped rotation angle from metadata orientation if available
        double angle = 0.0;
        final orientationMeta = node['orientation'] ?? (node['metadata'] is Map ? node['metadata']['orientation'] : null);
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
        }

        String label = (node['display_label'] ?? '').toString();
        if (label.isEmpty && id.isNotEmpty) {
          label = id;
        }

        // Determine parentBusId from node metadata if available
        String? parentBusId = node['connected_bus_id']?.toString();
        int? devBusNum = (node['connected_bus_number'] as num?)?.toInt() ?? (node['bus_number'] as num?)?.toInt();
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
        if (type == Tool.bus && devBusNum != null) {
          if (devBusNum == 1 || node['is_slack'] == true || node['isSlack'] == true) {
            newEl.isSlack = true;
          }
        }
        elements.add(newEl);
      }

      // 3. Parse lines using exact pixel paths
      for (var line in rawLines) {
        String lineId = (line['line_id'] ?? line['id'] ?? '').toString();
        String lineLabel = (line['display_label'] ?? line['display_name'] ?? '').toString();
        List<dynamic> rawPath = line['path'] ?? [];
        List<dynamic> connectedTo = line['connected_to'] ?? [];
        
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
          Offset startPos = Offset((rawPath.first[0] as num).toDouble() + shiftX, (rawPath.first[1] as num).toDouble() + shiftY);
          Offset endPos = Offset((rawPath.last[0] as num).toDouble() + shiftX, (rawPath.last[1] as num).toDouble() + shiftY);
          
          Offset midPos = rawPath.length > 2 
              ? Offset((rawPath[(rawPath.length/2).floor()][0] as num).toDouble() + shiftX, (rawPath[(rawPath.length/2).floor()][1] as num).toDouble() + shiftY)
              : Offset((startPos.dx + endPos.dx)/2, (startPos.dy + endPos.dy)/2);

          List<Offset> parsedPath = [];
          for (var pt in rawPath) {
            parsedPath.add(Offset((pt[0] as num).toDouble() + shiftX, (pt[1] as num).toDouble() + shiftY));
          }

          elements.add(DrawingElement(
            id: lineId, type: Tool.line, 
            position: startPos, midPosition: midPos, endPosition: endPos,
            aiPath: parsedPath,
            label: lineLabel.isNotEmpty ? lineLabel : lineId,
            startElementId: connectedTo.isNotEmpty ? connectedTo[0].toString() : null,
            endElementId: connectedTo.length > 1 ? connectedTo[1].toString() : null,
          ));
        }
      }

      // 4. For Loads without explicit orientation metadata, compute snapped 90-deg angle from connected line endpoint
      for (var el in elements.where((e) => e.type == Tool.load)) {
        if (el.angle == 0.0) {
          DrawingElement? connLine;
          for (var l in elements.where((e) => e.type == Tool.line)) {
            if (l.startElementId == el.id || l.endElementId == el.id) {
              connLine = l;
              break;
            }
          }
          if (connLine != null && connLine.aiPath != null && connLine.aiPath!.isNotEmpty) {
            Offset nearPt = connLine.startElementId == el.id
                ? connLine.aiPath!.first
                : connLine.aiPath!.last;
            double dx = el.position.dx - nearPt.dx;
            double dy = el.position.dy - nearPt.dy;
            if (dx.abs() > dy.abs()) {
              el.angle = dx > 0 ? -math.pi / 2 : math.pi / 2; // Pointing Right vs Left
            } else {
              el.angle = dy > 0 ? 0.0 : math.pi; // Pointing Down vs Up
            }
          }
        }
      }

      // 5. Connect every Generator & Load to its parent Bus (via bus number, line, or spatial proximity)
      for (var dev in elements.where((e) => e.type == Tool.generator || e.type == Tool.load)) {
        if (dev.parentBusId == null || dev.parentBusId!.isEmpty) {
          int? bNum;
          final mId = RegExp(r'^(?:gen|load|g|l)[-_ ]*(\d+)', caseSensitive: false).firstMatch(dev.id);
          if (mId != null) bNum = int.tryParse(mId.group(1)!);
          if (bNum == null && dev.label.isNotEmpty) {
            final mLbl = RegExp(r'^(?:gen|load|g|l)[-_ ]*(\d+)', caseSensitive: false).firstMatch(dev.label);
            if (mLbl != null) bNum = int.tryParse(mLbl.group(1)!);
          }
          if (bNum != null) {
            final targetBus = elements.where((e) => e.type == Tool.bus && (e.id == "bus_$bNum" || e.id == "$bNum" || e.label == "$bNum" || e.label.startsWith("$bNum "))).firstOrNull;
            if (targetBus != null) {
              dev.parentBusId = targetBus.id;
            }
          }
        }
        if (dev.parentBusId == null || dev.parentBusId!.isEmpty) {
          for (var l in elements.where((e) => e.type == Tool.line)) {
            if (l.startElementId == dev.id && l.endElementId != null) {
              var other = elements.where((e) => e.id == l.endElementId).firstOrNull;
              if (other != null && other.type == Tool.bus) {
                dev.parentBusId = other.id;
                break;
              }
            } else if (l.endElementId == dev.id && l.startElementId != null) {
              var other = elements.where((e) => e.id == l.startElementId).firstOrNull;
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

      if (aiData['excel_data'] != null) {
        _applyExcelDataToCanvas(aiData['excel_data']);
      }

      _resetCamera();
    });
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
                children: [
                  _buildCanvas(),
                  _buildCanvasViewControls(),
                ],
              ),
            ),

            // 3. Right Property Inspector (320px)
            if (isInspectorOpen)
              SizedBox(
                width: 320,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(left: BorderSide(color: Colors.grey.shade300, width: 1)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(-2, 0)),
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
                    onClose: () => setState(() => selectedElement = null),
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

  PreferredSizeWidget _buildTopAppBar() {
    final int busCount = elements.where((e) => e.type == Tool.bus).length;
    final int lineCount = elements.where((e) => e.type == Tool.line).length;
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
              child: const Icon(Icons.bolt, color: Colors.amberAccent, size: 18),
            ),
            const SizedBox(width: 8),
            const Text(
              "PowerLens Pro",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.3),
            ),
          ],
        ),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hub_outlined, color: Colors.cyanAccent, size: 14),
              const SizedBox(width: 6),
              Text(
                "모선 $busCount · 선로 $lineCount",
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              if (hasResults) ...[
                const SizedBox(width: 8),
                Container(width: 5, height: 5, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                const Text(
                  "수렴됨",
                  style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.undo, color: Colors.white, size: 20),
          tooltip: "되돌리기 (Ctrl+Z)",
          onPressed: historyStack.isNotEmpty ? _undo : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo, color: Colors.white, size: 20),
          tooltip: "다시실행 (Ctrl+Y)",
          onPressed: redoStack.isNotEmpty ? _redo : null,
        ),
        IconButton(
          icon: const Icon(Icons.fit_screen, color: Colors.cyanAccent, size: 20),
          tooltip: "도면 전체 화면 맞춤 (F / Space)",
          onPressed: _zoomToFit,
        ),
        const SizedBox(width: 6),
        Container(height: 24, width: 1, color: Colors.white24),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
          child: OutlinedButton.icon(
            onPressed: _importExcelCase,
            icon: const Icon(Icons.table_chart, color: Colors.tealAccent, size: 16),
            label: const Text("엑셀 가져오기", style: TextStyle(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.tealAccent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
          child: OutlinedButton.icon(
            onPressed: _openReviewPage,
            icon: const Icon(Icons.auto_awesome, color: Colors.purpleAccent, size: 16),
            label: const Text("AI 도면 검수실", style: TextStyle(color: Colors.purpleAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.purpleAccent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ),
        if (hasResults)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
            child: OutlinedButton.icon(
              onPressed: () => _showPowerFlowResultDialog(lastSimulationResult!),
              icon: const Icon(Icons.assessment_outlined, color: Colors.amberAccent, size: 16),
              label: const Text("수치 결과표", style: TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.amberAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
          child: ElevatedButton.icon(
            onPressed: isSimulating ? null : _sendDataToServer,
            icon: isSimulating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
            label: Text(
              isSimulating ? "해석 중..." : "조류계산 실행",
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent.shade700,
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
        ),
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
          BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(1, 0)),
        ],
      ),
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
              border: isSel ? Border.all(color: Colors.blue.shade800, width: 1.5) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: isSel ? Colors.white : Colors.blueGrey.shade800),
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

  Widget _actionPaletteItem(IconData icon, String label, Color color, VoidCallback onTap) {
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
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasViewControls() {
    return Positioned(
      left: 16,
      bottom: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 8, offset: const Offset(0, 2)),
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
            Container(height: 20, width: 1, color: Colors.grey.shade300, margin: const EdgeInsets.symmetric(horizontal: 4)),
            IconButton(
              icon: Icon(
                showResultOverlay ? Icons.visibility : Icons.visibility_off,
                size: 20,
                color: showResultOverlay ? Colors.blueAccent : Colors.grey,
              ),
              tooltip: showResultOverlay ? "조류계산 결과 숨기기" : "조류계산 결과 도면 표시",
              onPressed: () => setState(() => showResultOverlay = !showResultOverlay),
            ),
            IconButton(
              icon: Icon(
                isInspectorOpen ? Icons.dock : Icons.chrome_reader_mode_outlined,
                size: 20,
                color: isInspectorOpen ? Colors.blueAccent : Colors.grey,
              ),
              tooltip: isInspectorOpen ? "속성 패널 접기" : "속성 패널 열기",
              onPressed: () => setState(() => isInspectorOpen = !isInspectorOpen),
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
                  setState(() { currentMousePos = e.localPosition; snapTarget = _findElementAt(e.localPosition); });
                }
              },
              child: Container(
                width: CANVAS_SIZE, 
                height: CANVAS_SIZE,
                color: Colors.transparent, 
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ...elements.where((e) => e.type == Tool.line).map((e) => _buildLineWidget(e)),
                    ...elements.where((e) => e.type != Tool.line).map((e) => _buildBusGenLoadWidget(e)),
                    ...elements.where((e) => e.type != Tool.text).map((e) => _buildMovableInfoBox(e)),
                    ..._buildResultOverlays(),
                    _buildSnapTargetIndicator(),
                    
                    if (lineStart != null && currentMousePos != null) 
                      Positioned.fill(
                        child: CustomPaint(
                          painter: PreviewLinePainter(
                            lineStart!,
                            lineMid,
                            snapTarget != null ? _getSnapPoint(snapTarget!, currentMousePos!) : currentMousePos!,
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

  List<Widget> _buildResultOverlays() {
    if (!showResultOverlay || lastSimulationResult == null) return [];
    final busResults = lastSimulationResult!['bus_results'] as List<dynamic>? ?? [];
    final lineResults = lastSimulationResult!['line_results'] as List<dynamic>? ?? [];
    
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

        Color voltColor = (v >= 0.95 && v <= 1.05) ? Colors.greenAccent.shade700 : Colors.deepOrangeAccent;

        overlays.add(
          Positioned(
            left: el.position.dx - 80,
            top: el.position.dy + (el.height / 2) + 14,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xE60F172A), // Dark slate
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: voltColor.withOpacity(0.7), width: 1.2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
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
                          style: TextStyle(color: voltColor, fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "∠${ang >= 0 ? '+' : ''}${ang.toStringAsFixed(2)}°",
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                    if (pgen.abs() > 0.01 || qgen.abs() > 0.01)
                      Text(
                        "Gen: ${pgen.toStringAsFixed(1)} MW / ${qgen.toStringAsFixed(1)} MVAR",
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 9.5),
                      ),
                    if (pload.abs() > 0.01 || qload.abs() > 0.01)
                      Text(
                        "Load: ${pload.toStringAsFixed(1)} MW / ${qload.toStringAsFixed(1)} MVAR",
                        style: const TextStyle(color: Colors.amberAccent, fontSize: 9.5),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }

    // 2. Line Flow Badges
    for (var el in elements.where((e) => e.type == Tool.line && e.endPosition != null)) {
      DrawingElement? startEl;
      DrawingElement? endEl;
      try { startEl = elements.firstWhere((e) => e.id == el.startElementId); } catch (_) {}
      try { endEl = elements.firstWhere((e) => e.id == el.endElementId); } catch (_) {}
      final String? sBusStr = (startEl != null) ? _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id) : (el.startElementId != null ? _getBusNum(el.startElementId!) : null);
      final String? eBusStr = (endEl != null) ? _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id) : (el.endElementId != null ? _getBusNum(el.endElementId!) : null);
      final bool isBothBuses = (startEl?.type == Tool.bus && endEl?.type == Tool.bus) ||
          (sBusStr != null && eBusStr != null && int.tryParse(sBusStr) != null && int.tryParse(eBusStr) != null &&
           startEl?.type != Tool.generator && endEl?.type != Tool.generator &&
           startEl?.type != Tool.load && endEl?.type != Tool.load &&
           startEl?.type != Tool.transformer && endEl?.type != Tool.transformer &&
           !el.id.contains('trans') && !el.id.contains('load') && !el.id.contains('gen')) ||
          (RegExp(r'^line_\d+_\d+$').hasMatch(el.id)) ||
          (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(el.label));
      final bool isGenLead = !isBothBuses && (startEl?.type == Tool.generator || endEl?.type == Tool.generator || el.label.contains("↔ G_") || el.label.contains("G_") || (el.id.startsWith("lead_") && el.id.contains("gen")));
      final bool isLoadLead = !isBothBuses && !isGenLead && (startEl?.type == Tool.load || endEl?.type == Tool.load || el.label.contains("↔ Load_") || el.label.contains("Load_") || (el.id.startsWith("lead_") && el.id.contains("load")));
      final mid = el.midPosition ?? (el.position + el.endPosition!) / 2;

      if (isGenLead && (el.pPu.abs() > 0.001 || el.qPu.abs() > 0.001)) {
        final double pMw = el.pPu * 100.0;
        overlays.add(
          Positioned(
            left: mid.dx - 45,
            top: mid.dy - 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xE61E293B),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.greenAccent.withOpacity(0.6), width: 1),
                ),
                child: Text(
                  "${pMw.abs().toStringAsFixed(1)} MW (발전)",
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 9.5, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        );
        continue;
      }

      if (isLoadLead && (el.pPu.abs() > 0.001 || el.qPu.abs() > 0.001)) {
        final double pMw = el.pPu * 100.0;
        overlays.add(
          Positioned(
            left: mid.dx - 45,
            top: mid.dy - 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xE61E293B),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.orangeAccent.withOpacity(0.6), width: 1),
                ),
                child: Text(
                  "${pMw.abs().toStringAsFixed(1)} MW (부하)",
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 9.5, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        );
        continue;
      }

      if (startEl == null || endEl == null) continue;

      final fb = _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id);
      final tb = _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id);

      final lRes = lineResults.firstWhere(
        (l) => (l['from_bus'].toString() == fb && l['to_bus'].toString() == tb) ||
               (l['from_bus'].toString() == tb && l['to_bus'].toString() == fb),
        orElse: () => null,
      );

      if (lRes != null) {
        final double pFrom = (lRes['p_from_mw'] as num?)?.toDouble() ?? 0.0;
        final double lossP = (lRes['loss_p_mw'] as num?)?.toDouble() ?? 0.0;

        overlays.add(
          Positioned(
            left: mid.dx - 50,
            top: mid.dy - 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xE61E293B),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 1),
                ),
                child: Text(
                  "${pFrom.abs().toStringAsFixed(1)} MW (손실: ${lossP.toStringAsFixed(1)})",
                  style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        );
      }
    }

    return overlays;
  }

  Widget _buildSnapTargetIndicator() {
    if (snapTarget == null || currentMousePos == null || lineStart == null) return const SizedBox.shrink();
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
      info += e.isSlack ? "V:${e.vPu}∠${e.thetaDeg}° (Slack)\nP:${e.pPu} Q:${e.qPu}" : "P:${e.pPu} Q:${e.qPu}\nV:${e.vPu}";
    } else if (e.type == Tool.load) {
      info += "P:${e.pPu}\nQ:${e.qPu}";
    } else if (e.type == Tool.line) {
      DrawingElement? startEl;
      DrawingElement? endEl;
      try { startEl = elements.firstWhere((el) => el.id == e.startElementId); } catch (_) {}
      try { endEl = elements.firstWhere((el) => el.id == e.endElementId); } catch (_) {}
      final String? sBusStr = (startEl != null) ? _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id) : (e.startElementId != null ? _getBusNum(e.startElementId!) : null);
      final String? eBusStr = (endEl != null) ? _getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id) : (e.endElementId != null ? _getBusNum(e.endElementId!) : null);
      final bool isBothBuses = (startEl?.type == Tool.bus && endEl?.type == Tool.bus) ||
          (sBusStr != null && eBusStr != null && int.tryParse(sBusStr) != null && int.tryParse(eBusStr) != null &&
           startEl?.type != Tool.generator && endEl?.type != Tool.generator &&
           startEl?.type != Tool.load && endEl?.type != Tool.load &&
           startEl?.type != Tool.transformer && endEl?.type != Tool.transformer &&
           !e.id.contains('trans') && !e.id.contains('load') && !e.id.contains('gen')) ||
          (RegExp(r'^line_\d+_\d+$').hasMatch(e.id)) ||
          (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(e.label));
      final bool isGenLead = !isBothBuses && (startEl?.type == Tool.generator || endEl?.type == Tool.generator || e.label.contains("↔ G_") || e.label.contains("G_") || (e.id.startsWith("lead_") && e.id.contains("gen")));
      final bool isLoadLead = !isBothBuses && !isGenLead && (startEl?.type == Tool.load || endEl?.type == Tool.load || e.label.contains("↔ Load_") || e.label.contains("Load_") || (e.id.startsWith("lead_") && e.id.contains("load")));
      if (isGenLead) {
        info += "발전: ${(e.pPu * 100.0).toStringAsFixed(1)} MW\n무효: ${(e.qPu * 100.0).toStringAsFixed(1)} MVAR";
      } else if (isLoadLead) {
        info += "부하: ${(e.pPu * 100.0).toStringAsFixed(1)} MW\n무효: ${(e.qPu * 100.0).toStringAsFixed(1)} MVAR";
      } else {
        info += "${e.rPu}+j${e.xPu}" + (e.bPu != 0 ? "\nB:${e.bPu}" : "") + (e.tapRatio != 1.0 ? "\nTap:${e.tapRatio}" : "");
      }
    } else if (e.type == Tool.transformer) {
      info += "Tap: ${e.tapRatio} pu";
    } else {
      return const SizedBox.shrink();
    }

    Offset basePos = (e.type == Tool.line) ? (e.midPosition ?? (e.position + (e.endPosition ?? e.position)) / 2) : e.position;

    return Positioned(
      left: basePos.dx + e.infoOffset.dx, top: basePos.dy + e.infoOffset.dy,
      child: GestureDetector(
        onPanStart: (_) => _saveState(),
        onPanUpdate: (d) => setState(() => e.infoOffset += d.delta),
        onTap: () => setState(() => selectedElement = e),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            border: Border.all(color: selectedElement == e ? Colors.blue : Colors.grey, width: 1),
            borderRadius: BorderRadius.circular(4),
            boxShadow: [if(selectedElement == e) const BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
          child: Text(info, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black)),
        ),
      ),
    );
  }

  void _handleDrawingTap(Offset pos) {
    setState(() {
      DrawingElement? target = _findElementAt(pos);
      
      String newId = "${selectedTool.name[0].toUpperCase()}${elements.length + 1}";
      if (target != null && target.type == Tool.bus) {
        String busNum = _getBusNum(target.label.isNotEmpty ? target.label : target.id);
        if (selectedTool == Tool.generator) {
          int count = elements.where((e) => e.type == Tool.generator && e.parentBusId == target.id).length + 1;
          newId = "G_${busNum}_$count";
        } else if (selectedTool == Tool.load) {
          int count = elements.where((e) => e.type == Tool.load && e.parentBusId == target.id).length + 1;
          newId = "Load_${busNum}_$count";
        } else if (selectedTool == Tool.transformer) {
          int count = elements.where((e) => e.type == Tool.transformer && e.parentBusId == target.id).length + 1;
          newId = "T_${busNum}_$count";
        }
      } else if (selectedTool == Tool.line && pendingStartId != null && target != null) {
        DrawingElement? startEl;
        try { startEl = elements.firstWhere((e) => e.id == pendingStartId); } catch(_) {}

        // Null Safety 수정: startEl이 null이 아닐 때만 조건 진행하도록 보완
        if (startEl != null && startEl.type == Tool.bus && target.type == Tool.bus) {
          String startNum = _getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id);
          String endNum = _getBusNum(target.label.isNotEmpty ? target.label : target.id);
          newId = "L_${startNum}_$endNum";
        } else {
          String sId = startEl?.id ?? 'X';
          String eId = target.label.isNotEmpty ? target.label : target.id;
          newId = "Conn_${sId}_$eId";
        }
      }

      if (selectedTool == Tool.bus) {
        _saveState(); elements.add(DrawingElement(id: newId, type: Tool.bus, position: pos));
      } else if (selectedTool == Tool.generator || selectedTool == Tool.load || selectedTool == Tool.transformer) {
        _saveState(); Offset finalPos = target != null ? _getSnapPoint(target, pos) : pos;
        elements.add(DrawingElement(id: newId, type: selectedTool, position: finalPos, width: 40, height: 40, parentBusId: target?.id));
      } else if (selectedTool == Tool.line) {
        if (lineStart == null) {
          lineStart = target != null ? _getSnapPoint(target, pos) : pos; pendingStartId = target?.id;
          if (target != null) pendingStartAnchor = lineStart! - target.position;
        } else if (lineMid == null && target == null) {
          lineMid = pos;
        } else {
          _saveState(); Offset endP = target != null ? _getSnapPoint(target, pos) : pos;
          elements.add(DrawingElement(id: newId, type: Tool.line, position: lineStart!, midPosition: lineMid, endPosition: endP, startElementId: pendingStartId, endElementId: target?.id, startAnchor: pendingStartAnchor, endAnchor: target != null ? (endP - target.position) : null));
          
          if (target != null && pendingStartId != null) {
            DrawingElement? startEl; try { startEl = elements.firstWhere((e) => e.id == pendingStartId); } catch(_) {}
            if (startEl != null && startEl.type == Tool.bus && target.type != Tool.bus) {
              _updateConnectedElementsId(startEl);
            } else if (target.type == Tool.bus && startEl != null && startEl.type != Tool.bus) {
              _updateConnectedElementsId(target);
            }
          }

          lineStart = null; lineMid = null; pendingStartId = null;
        }
      } else if (selectedTool == Tool.text) {
        _saveState(); elements.add(DrawingElement(id: newId, type: Tool.text, position: pos, label: "텍스트 입력"));
      }
    });
  }

  Widget _buildBusGenLoadWidget(DrawingElement e) {
    bool isSelected = (selectedElement == e && selectedTool == Tool.move);
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
            : (e.type == Tool.load ? const Color(0xFF059669) : const Color(0xFF7C3AED)));
    Color drawColor = isSelected ? const Color(0xFF2563EB) : baseColor;
    
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
          Positioned(
            top: -18,
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
        ],
      );
    } else if (e.type == Tool.load) {
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(e.width, e.height), 
            painter: LoadArrowPainter(color: isSelected ? const Color(0xFF2563EB) : drawColor),
          ),
          Positioned(
            bottom: -18,
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
        ],
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
                  : (e.isSlack ? const Color(0xFFDC2626) : const Color(0xFF0F172A)), 
              borderRadius: BorderRadius.circular(2.0),
              boxShadow: [
                if (isSelected)
                  const BoxShadow(color: Color(0x662563EB), blurRadius: 8, spreadRadius: 1),
              ],
            ),
          ),
          Positioned(
            top: -20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: isSelected ? const Color(0xFF2563EB) : Colors.black12),
              ),
              child: Text(
                e.label.isNotEmpty ? (e.label.toLowerCase().startsWith('bus') ? e.label : "Bus ${e.label}") : e.id, 
                style: TextStyle(
                  fontWeight: FontWeight.bold, 
                  color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF0F172A), 
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Precise hit bounds with slight padding only when selected for control points
    const double pad = 12.0;
    final double boxWidth = e.width + (isSelected ? pad * 2 : 0);
    final double boxHeight = e.height + (isSelected ? pad * 2 : 0);
    final double leftOffset = e.position.dx - (e.width / 2) - (isSelected ? pad : 0);
    final double topOffset = e.position.dy - (e.height / 2) - (isSelected ? pad : 0);

    return Positioned(
      left: leftOffset,
      top: topOffset,
      child: SizedBox(
        width: boxWidth,
        height: boxHeight,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => selectedElement = e);
              },
              onDoubleTap: () {
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
                child: Transform.rotate(angle: e.angle, child: shapeContent),
              ),
            ),

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
                top: -8,
                child: GestureDetector(
                  onTap: () {
                    _saveState();
                    setState(() => e.angle = (e.angle + math.pi / 2) % (math.pi * 2));
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2563EB),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)],
                      ),
                      child: const Icon(Icons.rotate_right, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -6,
                child: GestureDetector(
                  onPanStart: (_) => _saveState(),
                  onPanUpdate: (d) {
                    setState(() {
                      e.width = (e.width + d.delta.dx).clamp(20, 800);
                      if (e.type != Tool.bus) e.height = e.width;
                    });
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
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
    );
  }

  Widget _buildLineWidget(DrawingElement e) {
    if (e.endPosition == null) return const SizedBox.shrink();
    return Positioned.fill(child: CustomPaint(painter: LinePainter(e.position, e.midPosition, e.endPosition!, isSelected: selectedElement == e, aiPath: e.aiPath)));
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
          if (line.midPosition != null) line.midPosition = line.midPosition! + delta;
        }
      }
      if (e.type == Tool.bus) { for (var child in elements.where((el) => el.parentBusId == e.id)) child.position += delta; }
    });
  }


  void _checkSelection(Offset pos) { setState(() => selectedElement = _findElementAt(pos)); }

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
  final Offset start; final Offset? mid; final Offset end; final bool isSelected;
  final List<Offset>? aiPath; 
  LinePainter(this.start, this.mid, this.end, {this.isSelected = false, this.aiPath});
  
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
  @override bool shouldRepaint(CustomPainter old) => true;
}

class PreviewLinePainter extends CustomPainter {
  final Offset start; final Offset? mid; final Offset current;
  PreviewLinePainter(this.start, this.mid, this.current);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final dotPaint = Paint()..color = Colors.blue..style = PaintingStyle.fill;
    Path path = Path()..moveTo(start.dx, start.dy); canvas.drawCircle(start, 4, dotPaint);
    if (mid != null) { path.lineTo(mid!.dx, mid!.dy); canvas.drawCircle(mid!, 4, dotPaint); }
    path.lineTo(current.dx, current.dy); canvas.drawPath(path, p); canvas.drawCircle(current, 3, dotPaint..color = Colors.blue.withOpacity(0.5));
  }
  @override bool shouldRepaint(CustomPainter old) => true;
}

class InfiniteGridPainter extends CustomPainter {
  final Matrix4 transform;
  InfiniteGridPainter(this.transform);

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = transform.getMaxScaleOnAxis();
    final double tx = transform.getTranslation().x;
    final double ty = transform.getTranslation().y;

    final p = Paint()..color = Colors.grey[100]!..strokeWidth = 1;
    
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

