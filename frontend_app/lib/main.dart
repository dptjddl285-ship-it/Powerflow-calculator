import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:convert'; 
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http; 
import 'package:image_picker/image_picker.dart';

import 'screens/review_page.dart';

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

enum Tool { bus, generator, load, line, move, text, transformer }

class DrawingElement {
  String id; Tool type; Offset position; Offset? midPosition; Offset? endPosition;
  double width, height, angle; String? startElementId; String? endElementId;
  Offset? startAnchor; Offset? endAnchor; String? parentBusId; String label;
  Offset infoOffset;
  
  List<Offset>? aiPath; 

  bool showInfo = false; 

  bool isSlack = false; double vPu = 1.0; double thetaDeg = 0.0;
  double pPu = 0.0; double qPu = 0.0; double rPu = 0.01; double xPu = 0.05; double bPu = 0.0;

  DrawingElement({
    required this.id, required this.type, required this.position,
    this.midPosition, this.endPosition, this.width = 120, this.height = 10, this.angle = 0,
    this.parentBusId, this.startElementId, this.endElementId, this.startAnchor, this.endAnchor, this.label = "",
    this.infoOffset = const Offset(40, -40),
    this.aiPath,
  });

  DrawingElement copy() {
    return DrawingElement(
      id: id, type: type, position: position, midPosition: midPosition,
      endPosition: endPosition, width: width, height: height, angle: angle,
      parentBusId: parentBusId, startElementId: startElementId, endElementId: endElementId,
      startAnchor: startAnchor, endAnchor: endAnchor, label: label, infoOffset: infoOffset,
      aiPath: aiPath != null ? List.from(aiPath!) : null,
    )
    ..showInfo = showInfo 
    ..isSlack = isSlack..vPu = vPu..thetaDeg = thetaDeg
    ..pPu = pPu..qPu = qPu..rPu = rPu..xPu = xPu..bPu = bPu;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'parentBusId': parentBusId,
      'startElementId': startElementId,
      'endElementId': endElementId,
      'isSlack': isSlack,
      'vPu': vPu,
      'thetaDeg': thetaDeg,
      'pPu': pPu,
      'qPu': qPu,
      'rPu': rPu,
      'xPu': xPu,
      'bPu': bPu,
    };
  }
}

class PowerCanvasPage extends StatefulWidget {
  const PowerCanvasPage({super.key});
  @override
  State<PowerCanvasPage> createState() => PowerCanvasPageState();
}

class PowerCanvasPageState extends State<PowerCanvasPage> {
  final TransformationController _transformationController = TransformationController();

  List<DrawingElement> elements = [];
  List<List<DrawingElement>> historyStack = [];
  List<List<DrawingElement>> redoStack = [];

  Tool selectedTool = Tool.move;
  DrawingElement? selectedElement;
  Offset? lineStart; Offset? lineMid; Offset? currentMousePos;
  String? pendingStartId; Offset? pendingStartAnchor; DrawingElement? snapTarget; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetCamera());
  }

  void _resetCamera() {
    final size = MediaQuery.of(context).size;
    if (size.width == 0) return;
    _transformationController.value = Matrix4.identity()
      // translateDeprecated 경고 수정을 위해 Z축(0.0) 추가
      ..translate(-(CANVAS_CENTER - size.width / 2), -(CANVAS_CENTER - size.height / 2), 0.0);
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

    try {
      final response = await http.post(url, headers: {'Content-Type': 'application/json'}, body: payload);
      if (!mounted) return; // Async Gap 경고 해결
      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result['message']), backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("서버 응답 오류가 발생했습니다."), backgroundColor: Colors.red));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("서버 접속 실패!\n$e"), backgroundColor: Colors.red));
    }
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

  void _applyExcelDataToCanvas(Map<String, dynamic> excelData) {
    _saveState();
    setState(() {
      var buses = excelData['buses'] as Map<String, dynamic>? ?? {};
      var gens = excelData['generators'] as Map<String, dynamic>? ?? {};
      var branches = excelData['branches'] as Map<String, dynamic>? ?? {};
      int? slackBus = excelData['slack_bus_number'];

      int updatedBuses = 0;
      int updatedGens = 0;
      int updatedLoads = 0;
      int updatedLines = 0;

      // 1. Map ID to Bus Number
      Map<String, int> elIdToBusNum = {};
      for (var el in elements) {
        if (el.type == Tool.bus) {
          int? bNum;
          if (el.label.isNotEmpty) {
            String digits = el.label.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum == null) {
            String digits = el.id.split('_').last.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum != null) {
            elIdToBusNum[el.id] = bNum;
          }
        }
      }

      // 2. Apply parameters to each element
      for (var el in elements) {
        if (el.type == Tool.bus) {
          int? bNum = elIdToBusNum[el.id];
          if (bNum != null && buses.containsKey(bNum.toString())) {
            var bInfo = buses[bNum.toString()];
            el.isSlack = bInfo['is_slack'] == true;
            el.vPu = (bInfo['vm_pu'] as num?)?.toDouble() ?? 1.0;
            el.thetaDeg = (bInfo['va_deg'] as num?)?.toDouble() ?? 0.0;
            el.pPu = (bInfo['pload_pu'] as num?)?.toDouble() ?? 0.0;
            el.qPu = (bInfo['qload_pu'] as num?)?.toDouble() ?? 0.0;
            if (el.isSlack) {
              el.label = "$bNum (Slack)";
            }
            updatedBuses++;
          }
        } else if (el.type == Tool.generator) {
          int? bNum;
          if (el.parentBusId != null && elIdToBusNum.containsKey(el.parentBusId)) {
            bNum = elIdToBusNum[el.parentBusId];
          }
          if (bNum == null && el.parentBusId != null) {
            String digits = el.parentBusId!.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum == null && el.label.isNotEmpty) {
            String digits = el.label.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum == null && el.id.isNotEmpty) {
            String digits = el.id.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum != null && gens.containsKey(bNum.toString())) {
            var gInfo = gens[bNum.toString()];
            el.isSlack = gInfo['is_slack'] == true;
            el.pPu = (gInfo['pg_pu'] as num?)?.toDouble() ?? 0.0;
            el.qPu = (gInfo['qg_pu'] as num?)?.toDouble() ?? 0.0;
            el.vPu = (gInfo['voltage_setpoint'] as num?)?.toDouble() ?? 1.0;
            el.label = "G_$bNum" + (el.isSlack ? " (Slack)" : "");
            updatedGens++;
          }
        } else if (el.type == Tool.load) {
          int? bNum;
          if (el.parentBusId != null && elIdToBusNum.containsKey(el.parentBusId)) {
            bNum = elIdToBusNum[el.parentBusId];
          }
          if (bNum == null && el.parentBusId != null) {
            String digits = el.parentBusId!.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum == null && el.label.isNotEmpty) {
            String digits = el.label.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum == null && el.id.isNotEmpty) {
            String digits = el.id.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isNotEmpty) bNum = int.tryParse(digits);
          }
          if (bNum != null && buses.containsKey(bNum.toString())) {
            var bInfo = buses[bNum.toString()];
            el.pPu = (bInfo['pload_pu'] as num?)?.toDouble() ?? 0.0;
            el.qPu = (bInfo['qload_pu'] as num?)?.toDouble() ?? 0.0;
            el.label = "Load_$bNum";
            updatedLoads++;
          }
        } else if (el.type == Tool.line) {
          int? getBusNum(String? id) {
            if (id == null) return null;
            if (elIdToBusNum.containsKey(id)) return elIdToBusNum[id];
            String digits = id.replaceAll(RegExp(r'[^0-9]'), '');
            return digits.isNotEmpty ? int.tryParse(digits) : null;
          }
          int? fb = getBusNum(el.startElementId);
          int? tb = getBusNum(el.endElementId);
          if (fb == null || tb == null) {
            final match = RegExp(r'(\d+)\s*[-~↔]\s*(\d+)').firstMatch(el.label);
            if (match != null) {
              fb = int.tryParse(match.group(1)!);
              tb = int.tryParse(match.group(2)!);
            }
          }
          if (fb == null || tb == null) {
            final match = RegExp(r'(\d+)\s*[-~_]\s*(\d+)').firstMatch(el.id);
            if (match != null) {
              fb = int.tryParse(match.group(1)!);
              tb = int.tryParse(match.group(2)!);
            }
          }
          if (fb != null && tb != null) {
            el.label = "Line $fb-$tb";
            var brInfo = branches["${fb}_${tb}"] ??
                         branches["${tb}_${fb}"] ??
                         branches["($fb, $tb)"] ??
                         branches["($tb, $fb)"] ??
                         branches["$fb-$tb"] ??
                         branches["$tb-$fb"];
            if (brInfo != null) {
              el.rPu = (brInfo['r_pu'] as num?)?.toDouble() ?? 0.01;
              el.xPu = (brInfo['x_pu'] as num?)?.toDouble() ?? 0.05;
              el.bPu = (brInfo['b_pu'] as num?)?.toDouble() ?? 0.0;
              updatedLines++;
            }
          }
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ 엑셀 데이터 매칭 완료!\n• 슬랙 모선: #${slackBus ?? '자동지정'}\n• 모선: $updatedBuses개 | 발전기: $updatedGens개 | 부하: $updatedLoads개 | 선로: $updatedLines개",
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
    });
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

        elements.add(DrawingElement(
          id: id,
          type: type,
          position: Offset(cx, cy),
          width: w,
          height: h,
          angle: angle,
          label: label,
        ));
      }

      // 3. Parse lines using exact pixel paths
      for (var line in rawLines) {
        String lineId = (line['line_id'] ?? line['id'] ?? '').toString();
        String lineLabel = (line['display_label'] ?? line['display_name'] ?? '').toString();
        List<dynamic> rawPath = line['path'] ?? [];
        List<dynamic> connectedTo = line['connected_to'] ?? [];
        
        if (lineLabel.isEmpty && connectedTo.length >= 2) {
          String ep1 = connectedTo[0].toString().split('_').last;
          String ep2 = connectedTo[1].toString().split('_').last;
          lineLabel = "Line $ep1-$ep2";
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

      // 5. Connect every Generator & Load to its parent Bus (via line or spatial proximity)
      for (var dev in elements.where((e) => e.type == Tool.generator || e.type == Tool.load)) {
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
          if (nearestBus != null && minDist < 350.0) {
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
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Power Designer Pro", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blueGrey[900],
        actions: [
          IconButton(icon: const Icon(Icons.undo, color: Colors.white), onPressed: historyStack.isNotEmpty ? _undo : null),
          IconButton(icon: const Icon(Icons.redo, color: Colors.white), onPressed: redoStack.isNotEmpty ? _redo : null),
          IconButton(
            icon: const Icon(Icons.table_view, color: Colors.greenAccent),
            tooltip: "엑셀 계통 데이터 가져오기 (.xlsx)",
            onPressed: _importExcelCase,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: ElevatedButton.icon(
              onPressed: _importExcelCase,
              icon: const Icon(Icons.table_chart, color: Colors.white, size: 18),
              label: const Text("엑셀 데이터 적용", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[700]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: ElevatedButton.icon(
              onPressed: _openReviewPage,
              icon: const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
              label: const Text("AI 도면 검수실", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
            child: ElevatedButton.icon(
              onPressed: _sendDataToServer, 
              icon: const Icon(Icons.cloud_upload, color: Colors.white), 
              label: const Text("조류계산 (파이썬 전송)", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            ),
          ),
        ],
      ),
      body: Column(
        children: [_buildToolBar(), Expanded(child: _buildCanvas())],
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
            onDoubleTap: () { if (selectedElement != null) _showPropertiesDialog(selectedElement!); },
            onTapDown: (details) {
              setState(() => currentMousePos = details.localPosition);
              if (selectedTool == Tool.move) { _checkSelection(details.localPosition); } 
              else { _handleDrawingTap(details.localPosition); }
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
                    
                    if (lineStart != null && currentMousePos != null) 
                      Positioned.fill(child: CustomPaint(painter: PreviewLinePainter(lineStart!, lineMid, snapTarget != null ? _getSnapPoint(snapTarget!, currentMousePos!) : currentMousePos!))),
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
    if (e.type == Tool.generator) info += e.isSlack ? "V:${e.vPu}∠${e.thetaDeg}° (Slack)\nP:${e.pPu} Q:${e.qPu}" : "P:${e.pPu} Q:${e.qPu}\nV:${e.vPu}";
    else if (e.type == Tool.load) info += "P:${e.pPu}\nQ:${e.qPu}";
    else if (e.type == Tool.line) info += "${e.rPu}+j${e.xPu}" + (e.bPu != 0 ? "\nB:${e.bPu}" : "");
    else return const SizedBox.shrink();

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

  Widget _buildToolBar() {
    return Container(
      padding: const EdgeInsets.all(10), color: Colors.grey[100],
      child: Wrap(spacing: 8, children: [
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
          label: const Text("도면 사진 분석", style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          onPressed: _uploadImageToAI,
        ),
        IconButton(onPressed: () { _saveState(); setState(() { elements.clear(); lineStart = null; lineMid = null; _resetCamera(); }); }, icon: const Icon(Icons.refresh, color: Colors.red)),
      ]),
    );
  }

  Widget _toolBtn(Tool tool, IconData icon, String label) {
    bool isSel = selectedTool == tool;
    return ActionChip(
      backgroundColor: isSel ? Colors.blue : Colors.white,
      avatar: Icon(icon, size: 16, color: isSel ? Colors.white : Colors.black),
      label: Text(label, style: TextStyle(color: isSel ? Colors.white : Colors.black, fontSize: 12)),
      onPressed: () => setState(() { selectedTool = tool; selectedElement = null; lineStart = null; lineMid = null; }),
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
      return Positioned(left: e.position.dx, top: e.position.dy, child: GestureDetector(onTap: () => setState(() => selectedElement = e), child: Text(e.label.isEmpty ? e.id : e.label, style: const TextStyle(fontWeight: FontWeight.bold))));
    }
    Color baseColor = e.type == Tool.bus 
        ? Colors.black
        : (e.type == Tool.generator 
            ? (e.isSlack ? Colors.redAccent : Colors.black)
            : Colors.black);
    Color drawColor = isSelected ? Colors.cyanAccent : baseColor;
    
    Widget shapeContent;
    if (e.type == Tool.generator) {
      shapeContent = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: e.width, 
            height: e.height, 
            decoration: BoxDecoration(
              color: Colors.white, 
              border: Border.all(color: drawColor, width: 2.0), 
              shape: BoxShape.circle,
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3)],
            ), 
            child: Center(
              child: Text(
                "G", 
                style: TextStyle(color: drawColor, fontWeight: FontWeight.bold, fontSize: e.height * 0.45)
              )
            )
          ),
          Positioned(
            top: -16,
            child: Text(
              e.label.isNotEmpty ? e.label : e.id,
              style: TextStyle(fontWeight: FontWeight.bold, color: drawColor, fontSize: 10)
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
            painter: LoadArrowPainter(color: drawColor)
          ),
          Positioned(
            bottom: -16,
            child: Text(
              e.label.isNotEmpty ? e.label : e.id,
              style: TextStyle(fontWeight: FontWeight.bold, color: drawColor, fontSize: 10)
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
            painter: TransformerPainter(color: drawColor, isVertical: isVert),
          ),
          Positioned(
            top: -16,
            child: Text(
              e.label.isNotEmpty ? e.label : e.id,
              style: TextStyle(fontWeight: FontWeight.bold, color: drawColor, fontSize: 10)
            ),
          ),
        ],
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
              color: isSelected ? Colors.cyanAccent : Colors.black, 
              borderRadius: BorderRadius.circular(1.5),
            )
          ),
          Positioned(
            top: -18,
            child: Text(
              e.label.isNotEmpty ? (e.label.toLowerCase().startsWith('bus') ? e.label : "Bus ${e.label}") : e.id, 
              style: TextStyle(fontWeight: FontWeight.bold, color: drawColor, fontSize: 11)
            ),
          )
        ],
      );
    }

    return Positioned(
      left: e.position.dx - (e.width / 2) - 100, top: e.position.dy - (e.height / 2) - 100,
      child: SizedBox(
        width: e.width + 200, height: e.height + 200,
        child: Stack(alignment: Alignment.center, children: [
          Transform.rotate(angle: e.angle, child: shapeContent),
          if (isSelected) ...[
            Positioned(left: 30, child: _handle(Icons.open_with, Colors.orange, onPanStart: (_) => _saveState(), onPanUpdate: (d) => _moveElement(e, d.delta))),
            Positioned(top: 30, child: _handle(Icons.rotate_right, Colors.green, onTap: () { _saveState(); setState(() => e.angle = (e.angle + math.pi / 2) % (math.pi * 2)); })),
            Positioned(right: 30, child: _handle(Icons.unfold_more, Colors.blue, onPanStart: (_) => _saveState(), onPanUpdate: (d) { setState(() { e.width = (e.width + d.delta.dx).clamp(10, 600); if (e.type != Tool.bus) e.height = e.width; }); })),
          ],
        ]),
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

  Widget _handle(IconData icon, Color color, {Function(DragUpdateDetails)? onPanUpdate, Function(DragStartDetails)? onPanStart, VoidCallback? onTap}) => GestureDetector(onPanStart: onPanStart, onPanUpdate: onPanUpdate, onTap: onTap, child: CircleAvatar(radius: 14, backgroundColor: color, child: Icon(icon, size: 14, color: Colors.white)));

  void _checkSelection(Offset pos) { setState(() => selectedElement = _findElementAt(pos)); }

  void _showPropertiesDialog(DrawingElement e) {
    final lCtrl = TextEditingController(text: e.label); 
    final vCtrl = TextEditingController(text: e.vPu.toString());
    final pCtrl = TextEditingController(text: e.pPu.toString()); 
    final qCtrl = TextEditingController(text: e.qPu.toString());
    final rCtrl = TextEditingController(text: e.rPu.toString()); 
    final xCtrl = TextEditingController(text: e.xPu.toString());
    final bCtrl = TextEditingController(text: e.bPu.toString());
    final aCtrl = TextEditingController(text: e.thetaDeg.toString());
    
    bool tempShowInfo = e.showInfo;
    bool tempIsSlack = e.isSlack;

    showDialog(
      context: context, 
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(e.label.isNotEmpty ? "${e.label} 제원 설정" : "${e.id} 제원 설정"),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SwitchListTile(
                  title: const Text("화면에 값 표시", style: TextStyle(fontWeight: FontWeight.bold)),
                  value: tempShowInfo,
                  activeColor: Colors.blue,
                  onChanged: (v) => setDialogState(() => tempShowInfo = v),
                ),
                const Divider(),
                // ✅ [수정완료] 모선(bus)일 때는 '버스 번호', 그 외 부품은 '라벨 (이름)'으로 표시
                TextField(
                  controller: lCtrl, 
                  decoration: InputDecoration(labelText: e.type == Tool.bus ? "버스 번호" : "라벨 (이름)")
                ),
                if (e.type == Tool.generator) ...[
                  SwitchListTile(
                    title: const Text("슬랙 모선 (Slack/Swing)"),
                    subtitle: Text(tempIsSlack ? "기준 모선 (위상 θ=0° 고정)" : "PV 모선 (유효전력 P, 전압 V 지정)"),
                    value: tempIsSlack,
                    activeColor: Colors.redAccent,
                    onChanged: (v) => setDialogState(() => tempIsSlack = v),
                  ),
                  TextField(controller: vCtrl, decoration: const InputDecoration(labelText: "목표 전압 V (pu)")),
                  TextField(
                    controller: pCtrl,
                    decoration: InputDecoration(
                      labelText: tempIsSlack ? "발전 출력 P (pu) [슬랙 분담]" : "발전 출력 P (pu)",
                    ),
                  ),
                  TextField(controller: qCtrl, decoration: const InputDecoration(labelText: "무효 전력 Q (pu)")),
                  if (tempIsSlack)
                    TextField(controller: aCtrl, decoration: const InputDecoration(labelText: "기준 위상각 θ (deg)")),
                ],
                if (e.type == Tool.bus) ...[
                  TextField(controller: vCtrl, decoration: const InputDecoration(labelText: "전압 V (pu)")),
                  TextField(controller: aCtrl, decoration: const InputDecoration(labelText: "위상 θ (deg)")),
                ],
                if (e.type == Tool.load) ...[ 
                  TextField(controller: pCtrl, decoration: const InputDecoration(labelText: "부하 P (pu)")), 
                  TextField(controller: qCtrl, decoration: const InputDecoration(labelText: "부하 Q (pu)")) 
                ],
                if (e.type == Tool.line) ...[ 
                  TextField(controller: rCtrl, decoration: const InputDecoration(labelText: "저항 R (pu)")), 
                  TextField(controller: xCtrl, decoration: const InputDecoration(labelText: "리액턴스 X (pu)")), 
                  TextField(controller: bCtrl, decoration: const InputDecoration(labelText: "서셉턴스 B (pu)")), 
                ],
                if (e.type == Tool.transformer) ...[ 
                  TextField(controller: rCtrl, decoration: const InputDecoration(labelText: "저항 R (pu)")), 
                  TextField(controller: xCtrl, decoration: const InputDecoration(labelText: "리액턴스 X (pu)")), 
                  TextField(controller: bCtrl, decoration: const InputDecoration(labelText: "서셉턴스 B (pu)")), 
                ],
              ])
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
                    e.bPu = double.tryParse(bCtrl.text) ?? 0.0; 
                    e.thetaDeg = double.tryParse(aCtrl.text) ?? 0; 
                    
                    e.showInfo = tempShowInfo; 
                    
                    if (e.type == Tool.generator && tempIsSlack != e.isSlack) {
                      if (tempIsSlack) {
                        for (var el in elements.where((el) => el.type == Tool.generator)) { 
                          el.isSlack = false; 
                        }
                      }
                      e.isSlack = tempIsSlack;
                    }

                    // ✅ [수정완료] 버스 번호 입력 시 ID 자체를 bus_번호로 변경하고 연결 끊김 방지
                    if (e.type == Tool.bus && e.label.isNotEmpty) {
                      String oldId = e.id;
                      String newBusNum = _getBusNum(e.label);
                      String newId = "bus_$newBusNum"; // 새로운 ID로 변경!
                      
                      if (oldId != newId) {
                        e.id = newId;
                        // 기존 ID를 바라보던 부품/선로들의 참조 ID도 모두 새 ID로 갈아끼움
                        for (var el in elements) {
                          if (el.parentBusId == oldId) el.parentBusId = newId;
                          if (el.startElementId == oldId) el.startElementId = newId;
                          if (el.endElementId == oldId) el.endElementId = newId;
                        }
                      }
                      _updateConnectedElementsId(e);
                    }
                  }); 
                  Navigator.pop(context); 
                }, 
                child: const Text("저장")
              )
            ],
          );
        }
      )
    );
  }

  Widget _buildQuickDeleteButton() {
    if (selectedElement == null) return const SizedBox.shrink();
    return Positioned(left: selectedElement!.position.dx + 60, top: selectedElement!.position.dy - 80, child: FloatingActionButton.small(backgroundColor: Colors.red, onPressed: () { _saveState(); setState(() { elements.remove(selectedElement); selectedElement = null; }); }, child: const Icon(Icons.delete, color: Colors.white)));
  }
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
