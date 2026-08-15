import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/drawing_element.dart';
import '../widgets/custom_painters.dart';

const double CANVAS_SIZE = 100000.0;
const double CANVAS_CENTER = 50000.0;

class PowerCanvasPage extends StatefulWidget {
  const PowerCanvasPage({super.key});
  @override
  State<PowerCanvasPage> createState() => PowerCanvasPageState();
}

class PowerCanvasPageState extends State<PowerCanvasPage> {
  final TransformationController _transformationController =
      TransformationController();

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetCamera());
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
    if (e.type != Tool.bus) return e.position;
    double cosA = math.cos(-e.angle);
    double sinA = math.sin(-e.angle);
    Offset rel = touchPos - e.position;
    double localX = (rel.dx * cosA - rel.dy * sinA).clamp(
      -e.width / 2,
      e.width / 2,
    );
    double localY = (rel.dx * sinA + rel.dy * cosA).clamp(
      -e.height / 2,
      e.height / 2,
    );
    cosA = math.cos(e.angle);
    sinA = math.sin(e.angle);
    return e.position +
        Offset(localX * cosA - localY * sinA, localX * sinA + localY * cosA);
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

    for (var el in elements) {
      if (el.type == Tool.generator ||
          el.type == Tool.load ||
          el.type == Tool.transformer) {
        bool isConnected = false;

        if (el.parentBusId == bus.id) {
          isConnected = true;
        } else {
          isConnected = elements.any(
            (line) =>
                line.type == Tool.line &&
                ((line.startElementId == bus.id &&
                        line.endElementId == el.id) ||
                    (line.startElementId == el.id &&
                        line.endElementId == bus.id)),
          );
        }

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

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: payload,
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message']),
            backgroundColor: Colors.green,
          ),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("서버 접속 실패!\n$e"), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _uploadImageToAI() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("AI가 도면을 분석 중입니다... 🧠")));

    var uri = Uri.parse('http://127.0.0.1:8000/analyze_image');
    var request = http.MultipartRequest('POST', uri);
    Uint8List imageBytes = await image.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes('file', imageBytes, filename: image.name),
    );

    try {
      var response = await request.send();
      if (!mounted) return;
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var result = jsonDecode(responseData);

        if (result['status'] == 'success') {
          _applyAiDataToCanvas(result['data']);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("AI 분석 완료! 화면 중앙에 배치되었습니다."),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("AI 분석 서버 오류!"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("접속 실패: $e"), backgroundColor: Colors.red),
      );
    }
  }

  void _applyAiDataToCanvas(Map<String, dynamic> aiData) {
    _saveState();
    setState(() {
      elements.clear();
      _resetCamera();

      const double offsetMargin = 150.0;

      for (var node in aiData['nodes']) {
        String id = node['id'];
        String aiClass = node['class'].toLowerCase();
        double cx = node['bbox'][0] + CANVAS_CENTER + offsetMargin;
        double cy = node['bbox'][1] + CANVAS_CENTER + offsetMargin;
        double w = node['bbox'][2].toDouble();
        double h = node['bbox'][3].toDouble();

        Tool type = Tool.bus;
        if (aiClass.contains('gen'))
          type = Tool.generator;
        else if (aiClass.contains('load'))
          type = Tool.load;
        else if (aiClass.contains('trans'))
          type = Tool.transformer;
        else if (aiClass.contains('bus'))
          type = Tool.bus;

        if (type == Tool.bus) {
          if (w > h) {
            h = 10.0;
          } else {
            w = 10.0;
          }
        } else {
          double size = math.max(w, h).clamp(30.0, 50.0);
          w = size;
          h = size;
        }

        elements.add(
          DrawingElement(
            id: id,
            type: type,
            position: Offset(cx, cy),
            width: w,
            height: h,
          ),
        );
      }

      for (var line in aiData['lines']) {
        String lineId = line['line_id'];
        List<dynamic> rawPath = line['path'];

        if (rawPath.length >= 2) {
          Offset startPos = Offset(
            rawPath.first[0].toDouble() + CANVAS_CENTER + offsetMargin,
            rawPath.first[1].toDouble() + CANVAS_CENTER + offsetMargin,
          );
          Offset endPos = Offset(
            rawPath.last[0].toDouble() + CANVAS_CENTER + offsetMargin,
            rawPath.last[1].toDouble() + CANVAS_CENTER + offsetMargin,
          );

          Offset midPos = rawPath.length > 2
              ? Offset(
                  rawPath[(rawPath.length / 2).floor()][0].toDouble() +
                      CANVAS_CENTER +
                      offsetMargin,
                  rawPath[(rawPath.length / 2).floor()][1].toDouble() +
                      CANVAS_CENTER +
                      offsetMargin,
                )
              : Offset(
                  (startPos.dx + endPos.dx) / 2,
                  (startPos.dy + endPos.dy) / 2,
                );

          List<Offset> parsedPath = [];
          for (var pt in rawPath) {
            parsedPath.add(
              Offset(
                pt[0].toDouble() + CANVAS_CENTER + offsetMargin,
                pt[1].toDouble() + CANVAS_CENTER + offsetMargin,
              ),
            );
          }

          elements.add(
            DrawingElement(
              id: lineId,
              type: Tool.line,
              position: startPos,
              midPosition: midPos,
              endPosition: endPos,
              aiPath: parsedPath,
              startElementId: line['connected_to'][0],
              endElementId: line['connected_to'][1],
            ),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          "Power Designer Pro",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blueGrey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.undo, color: Colors.white),
            onPressed: historyStack.isNotEmpty ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo, color: Colors.white),
            onPressed: redoStack.isNotEmpty ? _redo : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 8.0,
              horizontal: 16.0,
            ),
            child: ElevatedButton.icon(
              onPressed: _sendDataToServer,
              icon: const Icon(Icons.cloud_upload, color: Colors.white),
              label: const Text(
                "조류계산 (파이썬 전송)",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolBar(),
          Expanded(child: _buildCanvas()),
        ],
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
          panEnabled: selectedTool == Tool.move && selectedElement == null,
          boundaryMargin: const EdgeInsets.all(10000),
          minScale: 0.1,
          maxScale: 3.0,
          constrained: false,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () {
              if (selectedElement != null)
                _showPropertiesDialog(selectedElement!);
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
                    _buildQuickDeleteButton(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMovableInfoBox(DrawingElement e) {
    if (!e.showInfo || e.type == Tool.bus) return const SizedBox.shrink();

    String name = e.label.isNotEmpty ? e.label : e.id;
    String info = "[$name]\n";
    if (e.type == Tool.generator)
      info += e.isSlack
          ? "V:${e.vPu}∠${e.thetaDeg}°"
          : "P:${e.pPu}\nV:${e.vPu}";
    else if (e.type == Tool.load)
      info += "P:${e.pPu}\nQ:${e.qPu}";
    else if (e.type == Tool.line)
      info += "${e.rPu}+j${e.xPu}";
    else
      return const SizedBox.shrink();

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

  Widget _buildToolBar() {
    return Container(
      padding: const EdgeInsets.all(10),
      color: Colors.grey[100],
      child: Wrap(
        spacing: 8,
        children: [
          _toolBtn(Tool.move, Icons.near_me, "선택/이동"),
          _toolBtn(Tool.bus, Icons.remove, "모선"),
          _toolBtn(Tool.generator, Icons.radio_button_checked, "발전기"),
          _toolBtn(Tool.load, Icons.change_history, "부하"),
          _toolBtn(Tool.transformer, Icons.crop_square, "변압기"),
          _toolBtn(Tool.line, Icons.polyline, "선로연결"),
          _toolBtn(Tool.text, Icons.text_fields, "라벨"),
          ActionChip(
            backgroundColor: Colors.purpleAccent,
            avatar: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
            label: const Text(
              "도면 사진 분석",
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            onPressed: _uploadImageToAI,
          ),
          IconButton(
            onPressed: () {
              _saveState();
              setState(() {
                elements.clear();
                lineStart = null;
                lineMid = null;
                _resetCamera();
              });
            },
            icon: const Icon(Icons.refresh, color: Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn(Tool tool, IconData icon, String label) {
    bool isSel = selectedTool == tool;
    return ActionChip(
      backgroundColor: isSel ? Colors.blue : Colors.white,
      avatar: Icon(icon, size: 16, color: isSel ? Colors.white : Colors.black),
      label: Text(
        label,
        style: TextStyle(
          color: isSel ? Colors.white : Colors.black,
          fontSize: 12,
        ),
      ),
      onPressed: () => setState(() {
        selectedTool = tool;
        selectedElement = null;
        lineStart = null;
        lineMid = null;
      }),
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
        elements.add(DrawingElement(id: newId, type: Tool.bus, position: pos));
      } else if (selectedTool == Tool.generator ||
          selectedTool == Tool.load ||
          selectedTool == Tool.transformer) {
        _saveState();
        Offset finalPos = target != null ? _getSnapPoint(target!, pos) : pos;
        elements.add(
          DrawingElement(
            id: newId,
            type: selectedTool,
            position: finalPos,
            width: 40,
            height: 40,
            parentBusId: target?.id,
          ),
        );
      } else if (selectedTool == Tool.line) {
        if (lineStart == null) {
          lineStart = target != null ? _getSnapPoint(target!, pos) : pos;
          pendingStartId = target?.id;
          if (target != null) pendingStartAnchor = lineStart! - target.position;
        } else if (lineMid == null && target == null) {
          lineMid = pos;
        } else {
          _saveState();
          Offset endP = target != null ? _getSnapPoint(target!, pos) : pos;
          elements.add(
            DrawingElement(
              id: newId,
              type: Tool.line,
              position: lineStart!,
              midPosition: lineMid,
              endPosition: endP,
              startElementId: pendingStartId,
              endElementId: target?.id,
              startAnchor: pendingStartAnchor,
              endAnchor: target != null ? (endP - target.position) : null,
            ),
          );

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
        elements.add(
          DrawingElement(
            id: newId,
            type: Tool.text,
            position: pos,
            label: "텍스트 입력",
          ),
        );
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
          child: Text(
            e.label.isEmpty ? e.id : e.label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
    Color baseColor = e.type == Tool.bus
        ? Colors.black
        : (e.type == Tool.generator
              ? (e.isSlack ? Colors.red : Colors.black)
              : Colors.blue);
    Color drawColor = isSelected ? Colors.blue : baseColor;

    Widget shapeContent;
    if (e.type == Tool.generator) {
      shapeContent = Container(
        width: e.width,
        height: e.height,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: drawColor, width: 2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            "G",
            style: TextStyle(
              color: drawColor,
              fontWeight: FontWeight.bold,
              fontSize: e.height * 0.4,
            ),
          ),
        ),
      );
    } else if (e.type == Tool.load) {
      shapeContent = CustomPaint(
        size: Size(e.width, e.height),
        painter: TrianglePainter(
          fillColor: baseColor.withOpacity(0.1),
          strokeColor: drawColor,
        ),
      );
    } else if (e.type == Tool.transformer) {
      shapeContent = CustomPaint(
        size: Size(e.width, e.height),
        painter: TransformerPainter(color: drawColor),
      );
    } else {
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: e.width,
            height: e.height,
            decoration: BoxDecoration(
              color: e.type == Tool.bus
                  ? baseColor
                  : baseColor.withOpacity(0.1),
              border: Border.all(color: drawColor, width: 2),
              shape: e.type == Tool.bus ? BoxShape.rectangle : BoxShape.circle,
            ),
          ),
          if (e.type == Tool.bus)
            Positioned(
              top: -20,
              child: Text(
                e.label.isNotEmpty ? "Bus ${e.label}" : e.id,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: drawColor,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      );
    }

    return Positioned(
      left: e.position.dx - (e.width / 2) - 100,
      top: e.position.dy - (e.height / 2) - 100,
      child: SizedBox(
        width: e.width + 200,
        height: e.height + 200,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(angle: e.angle, child: shapeContent),
            if (isSelected) ...[
              Positioned(
                left: 30,
                child: _handle(
                  Icons.open_with,
                  Colors.orange,
                  onPanStart: (_) => _saveState(),
                  onPanUpdate: (d) => _moveElement(e, d.delta),
                ),
              ),
              Positioned(
                top: 30,
                child: _handle(
                  Icons.rotate_right,
                  Colors.green,
                  onTap: () {
                    _saveState();
                    setState(
                      () => e.angle = (e.angle + math.pi / 2) % (math.pi * 2),
                    );
                  },
                ),
              ),
              Positioned(
                right: 30,
                child: _handle(
                  Icons.unfold_more,
                  Colors.blue,
                  onPanStart: (_) => _saveState(),
                  onPanUpdate: (d) {
                    setState(() {
                      e.width = (e.width + d.delta.dx).clamp(10, 600);
                      if (e.type != Tool.bus) e.height = e.width;
                    });
                  },
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

  Widget _handle(
    IconData icon,
    Color color, {
    Function(DragUpdateDetails)? onPanUpdate,
    Function(DragStartDetails)? onPanStart,
    VoidCallback? onTap,
  }) => GestureDetector(
    onPanStart: onPanStart,
    onPanUpdate: onPanUpdate,
    onTap: onTap,
    child: CircleAvatar(
      radius: 14,
      backgroundColor: color,
      child: Icon(icon, size: 14, color: Colors.white),
    ),
  );

  void _checkSelection(Offset pos) {
    setState(() => selectedElement = _findElementAt(pos));
  }

  void _showPropertiesDialog(DrawingElement e) {
    final lCtrl = TextEditingController(text: e.label);
    final vCtrl = TextEditingController(text: e.vPu.toString());
    final pCtrl = TextEditingController(text: e.pPu.toString());
    final qCtrl = TextEditingController(text: e.qPu.toString());
    final rCtrl = TextEditingController(text: e.rPu.toString());
    final xCtrl = TextEditingController(text: e.xPu.toString());
    final aCtrl = TextEditingController(text: e.thetaDeg.toString());

    bool tempShowInfo = e.showInfo;
    bool tempIsSlack = e.isSlack;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text("${e.id} 제원 설정"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text(
                      "화면에 값 표시",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    value: tempShowInfo,
                    activeColor: Colors.blue,
                    onChanged: (v) => setDialogState(() => tempShowInfo = v),
                  ),
                  const Divider(),
                  TextField(
                    controller: lCtrl,
                    decoration: InputDecoration(
                      labelText: e.type == Tool.bus ? "버스 번호" : "라벨 (이름)",
                    ),
                  ),
                  if (e.type == Tool.generator || e.type == Tool.bus) ...[
                    if (e.type == Tool.generator)
                      SwitchListTile(
                        title: const Text("슬랙 모선"),
                        value: tempIsSlack,
                        activeColor: Colors.red,
                        onChanged: (v) => setDialogState(() => tempIsSlack = v),
                      ),
                    TextField(
                      controller: vCtrl,
                      decoration: const InputDecoration(labelText: "전압 V (pu)"),
                    ),
                    if (tempIsSlack || e.type == Tool.bus)
                      TextField(
                        controller: aCtrl,
                        decoration: const InputDecoration(
                          labelText: "위상 θ (deg)",
                        ),
                      )
                    else
                      TextField(
                        controller: pCtrl,
                        decoration: const InputDecoration(
                          labelText: "출력 P (pu)",
                        ),
                      ),
                  ],
                  if (e.type == Tool.load) ...[
                    TextField(
                      controller: pCtrl,
                      decoration: const InputDecoration(labelText: "부하 P (pu)"),
                    ),
                    TextField(
                      controller: qCtrl,
                      decoration: const InputDecoration(labelText: "부하 Q (pu)"),
                    ),
                  ],
                  if (e.type == Tool.line) ...[
                    TextField(
                      controller: rCtrl,
                      decoration: const InputDecoration(labelText: "저항 R (pu)"),
                    ),
                    TextField(
                      controller: xCtrl,
                      decoration: const InputDecoration(
                        labelText: "리액턴스 X (pu)",
                      ),
                    ),
                  ],
                  if (e.type == Tool.transformer) ...[
                    TextField(
                      controller: rCtrl,
                      decoration: const InputDecoration(labelText: "저항 R (pu)"),
                    ),
                    TextField(
                      controller: xCtrl,
                      decoration: const InputDecoration(
                        labelText: "리액턴스 X (pu)",
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  _saveState();
                  setState(() {
                    e.label = lCtrl.text;
                    e.vPu = double.tryParse(vCtrl.text) ?? 1.0;
                    e.pPu = double.tryParse(pCtrl.text) ?? 0;
                    e.qPu = double.tryParse(qCtrl.text) ?? 0;
                    e.rPu = double.tryParse(rCtrl.text) ?? 0.01;
                    e.xPu = double.tryParse(xCtrl.text) ?? 0.05;
                    e.thetaDeg = double.tryParse(aCtrl.text) ?? 0;

                    e.showInfo = tempShowInfo;

                    if (e.type == Tool.generator && tempIsSlack != e.isSlack) {
                      if (tempIsSlack) {
                        for (var el in elements.where(
                          (el) => el.type == Tool.generator,
                        )) {
                          el.isSlack = false;
                        }
                      }
                      e.isSlack = tempIsSlack;
                    }

                    if (e.type == Tool.bus && e.label.isNotEmpty) {
                      String oldId = e.id;
                      String newBusNum = _getBusNum(e.label);
                      String newId = "bus_$newBusNum";

                      if (oldId != newId) {
                        e.id = newId;
                        for (var el in elements) {
                          if (el.parentBusId == oldId) el.parentBusId = newId;
                          if (el.startElementId == oldId)
                            el.startElementId = newId;
                          if (el.endElementId == oldId) el.endElementId = newId;
                        }
                      }
                      _updateConnectedElementsId(e);
                    }
                  });
                  Navigator.pop(context);
                },
                child: const Text("저장"),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildQuickDeleteButton() {
    if (selectedElement == null) return const SizedBox.shrink();
    return Positioned(
      left: selectedElement!.position.dx + 60,
      top: selectedElement!.position.dy - 80,
      child: FloatingActionButton.small(
        backgroundColor: Colors.red,
        onPressed: () {
          _saveState();
          setState(() {
            elements.remove(selectedElement);
            selectedElement = null;
          });
        },
        child: const Icon(Icons.delete, color: Colors.white),
      ),
    );
  }
}
