import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/drawing_element.dart';

class InspectorPanel extends StatefulWidget {
  final DrawingElement? selectedElement;
  final List<DrawingElement> elements;
  final Map<String, dynamic>? simulationResult;
  final double sBase;
  final VoidCallback onStateChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClose;
  final Function(DrawingElement) onBusRenamed;
  final VoidCallback onClearAll;

  const InspectorPanel({
    super.key,
    required this.selectedElement,
    required this.elements,
    this.simulationResult,
    this.sBase = 100.0,
    required this.onStateChanged,
    required this.onDeleteSelected,
    required this.onClose,
    required this.onBusRenamed,
    required this.onClearAll,
  });

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  bool useMw = true;
  bool _isShortcutsExpanded = true;
  late TextEditingController labelCtrl;
  late TextEditingController vCtrl;
  late TextEditingController pCtrl;
  late TextEditingController qCtrl;
  late TextEditingController rCtrl;
  late TextEditingController xCtrl;
  late TextEditingController bCtrl;
  late TextEditingController thetaCtrl;
  late TextEditingController tapCtrl;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    final e = widget.selectedElement;
    if (e == null) {
      labelCtrl = TextEditingController();
      vCtrl = TextEditingController();
      pCtrl = TextEditingController();
      qCtrl = TextEditingController();
      rCtrl = TextEditingController();
      xCtrl = TextEditingController();
      bCtrl = TextEditingController();
      thetaCtrl = TextEditingController();
      tapCtrl = TextEditingController();
      return;
    }

    labelCtrl = TextEditingController(text: e.label.isNotEmpty ? e.label : e.id);
    vCtrl = TextEditingController(text: e.vPu.toString());

    final double pVal = useMw ? (e.pPu * widget.sBase) : e.pPu;
    final double qVal = useMw ? (e.qPu * widget.sBase) : e.qPu;
    pCtrl = TextEditingController(text: _formatNum(pVal));
    qCtrl = TextEditingController(text: _formatNum(qVal));

    rCtrl = TextEditingController(text: e.rPu.toString());
    xCtrl = TextEditingController(text: e.xPu.toString());
    bCtrl = TextEditingController(text: e.bPu.toString());
    thetaCtrl = TextEditingController(text: e.thetaDeg.toString());
    tapCtrl = TextEditingController(text: e.tapRatio.toString());
  }

  String _formatNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  @override
  void didUpdateWidget(covariant InspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateControllers();
  }

  void _updateControllers() {
    final e = widget.selectedElement;
    if (e == null) return;
    String newLabel = e.label.isNotEmpty ? e.label : e.id;
    if (labelCtrl.text != newLabel) labelCtrl.text = newLabel;
    if (vCtrl.text != e.vPu.toString()) vCtrl.text = e.vPu.toString();
    final double pVal = useMw ? (e.pPu * widget.sBase) : e.pPu;
    final double qVal = useMw ? (e.qPu * widget.sBase) : e.qPu;
    String newP = _formatNum(pVal);
    String newQ = _formatNum(qVal);
    if (pCtrl.text != newP) pCtrl.text = newP;
    if (qCtrl.text != newQ) qCtrl.text = newQ;
    if (rCtrl.text != e.rPu.toString()) rCtrl.text = e.rPu.toString();
    if (xCtrl.text != e.xPu.toString()) xCtrl.text = e.xPu.toString();
    if (bCtrl.text != e.bPu.toString()) bCtrl.text = e.bPu.toString();
    if (thetaCtrl.text != e.thetaDeg.toString()) thetaCtrl.text = e.thetaDeg.toString();
    if (tapCtrl.text != e.tapRatio.toString()) tapCtrl.text = e.tapRatio.toString();
  }

  @override
  void dispose() {
    labelCtrl.dispose();
    vCtrl.dispose();
    pCtrl.dispose();
    qCtrl.dispose();
    rCtrl.dispose();
    xCtrl.dispose();
    bCtrl.dispose();
    thetaCtrl.dispose();
    tapCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectedElement == null) {
      return _buildSystemOverview();
    }
    return _buildElementEditor();
  }

  bool _isActualTransmissionOrTransformerLine(DrawingElement el) {
    if (el.type != Tool.line) return false;
    DrawingElement? startEl;
    DrawingElement? endEl;
    try { startEl = widget.elements.firstWhere((e) => e.id == el.startElementId); } catch (_) {}
    try { endEl = widget.elements.firstWhere((e) => e.id == el.endElementId); } catch (_) {}

    // Exclude generator feeder leads
    final bool isGenLead = startEl?.type == Tool.generator || endEl?.type == Tool.generator ||
        el.label.contains("↔ G_") || el.label.contains("G_") || (el.id.startsWith("lead_") && el.id.contains("gen"));
    if (isGenLead) return false;

    // Exclude load feeder leads
    final bool isLoadLead = startEl?.type == Tool.load || endEl?.type == Tool.load ||
        el.label.contains("↔ Load_") || el.label.contains("Load_") || (el.id.startsWith("lead_") && el.id.contains("load"));
    if (isLoadLead) return false;

    if (el.id.startsWith("lead_") || el.label.contains("↔ Load_") || el.label.contains("↔ G_")) return false;

    // Transformer branches and transmission lines are both included
    return true;
  }

  Widget _buildSystemOverview() {
    final busCount = widget.elements.where((e) => e.type == Tool.bus).length;
    final genCount = widget.elements.where((e) => e.type == Tool.generator).length;
    final loadCount = widget.elements.where((e) => e.type == Tool.load).length;
    int lineCount = 0;
    if (widget.simulationResult != null) {
      if (widget.simulationResult!['total_branches'] is num) {
        lineCount = (widget.simulationResult!['total_branches'] as num).toInt();
      } else if (widget.simulationResult!['line_results'] is List && (widget.simulationResult!['line_results'] as List).isNotEmpty) {
        lineCount = (widget.simulationResult!['line_results'] as List).length;
      }
    }
    if (lineCount == 0) {
      lineCount = widget.elements.where(_isActualTransmissionOrTransformerLine).length;
    }
    final transCount = widget.elements.where((e) => e.type == Tool.transformer).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.dashboard_outlined, color: Colors.blueGrey, size: 20),
              const SizedBox(width: 8),
              const Text(
                "계통 개요 & 안내",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: "패널 접기",
                onPressed: widget.onClose,
              ),
            ],
          ),
          const Divider(height: 20),
          
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("기준 용량 (Sbase)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text("${widget.sBase.toStringAsFixed(0)} MVA", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          const Text("계통 구성 요소", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statBadge("모선 (Bus)", busCount, Colors.blue),
              _statBadge("발전기 (Gen)", genCount, Colors.redAccent),
              _statBadge("부하 (Load)", loadCount, Colors.orange),
              _statBadge("선로 (Line)", lineCount, Colors.teal),
              _statBadge("변압기 (Tr)", transCount, Colors.purple),
            ],
          ),
          const SizedBox(height: 20),

          InkWell(
            onTap: () => setState(() => _isShortcutsExpanded = !_isShortcutsExpanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("⌨️ 키보드 단축키", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isShortcutsExpanded ? "접기" : "펼치기",
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _isShortcutsExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_isShortcutsExpanded) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: [
                  _shortcutRow("Del / Backspace", "선택 요소 삭제"),
                  _shortcutRow("Esc", "선택 해제 / 도구 취소"),
                  _shortcutRow("Ctrl + Z", "실행 취소 (Undo)"),
                  _shortcutRow("Ctrl + Y", "다시 실행 (Redo)"),
                  _shortcutRow("V", "선택 및 이동 모드"),
                  _shortcutRow("B", "모선(Bus) 배치"),
                  _shortcutRow("G", "발전기 배치"),
                  _shortcutRow("L", "부하 배치"),
                  _shortcutRow("T", "변압기 배치"),
                  _shortcutRow("W", "선로 연결 (Wire)"),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text("도면 전체 초기화"),
              onPressed: widget.onClearAll,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(
            "$label: ",
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
          Text(
            "$count",
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _shortcutRow(String keys, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(
              keys,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
          ),
          Text(
            desc,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ],
      ),
    );
  }

  String? _getBusNumDigits(String? text) {
    if (text == null || text.isEmpty) return null;
    final match = RegExp(r'\d+').firstMatch(text);
    return match?.group(0);
  }

  Widget _buildElementEditor() {
    final e = widget.selectedElement!;
    final String title = e.label.isNotEmpty ? e.label : e.id;
    DrawingElement? lineStartEl;
    DrawingElement? lineEndEl;
    if (e.type == Tool.line) {
      try { lineStartEl = widget.elements.firstWhere((el) => el.id == e.startElementId); } catch (_) {}
      try { lineEndEl = widget.elements.firstWhere((el) => el.id == e.endElementId); } catch (_) {}
    }
    final sBusNum = _getBusNumDigits(lineStartEl?.label.isNotEmpty == true ? lineStartEl!.label : e.startElementId);
    final eBusNum = _getBusNumDigits(lineEndEl?.label.isNotEmpty == true ? lineEndEl!.label : e.endElementId);
    final bool isBothBuses = e.type == Tool.line && (
        (lineStartEl?.type == Tool.bus && lineEndEl?.type == Tool.bus) ||
        (sBusNum != null && eBusNum != null &&
         lineStartEl?.type != Tool.generator && lineEndEl?.type != Tool.generator &&
         lineStartEl?.type != Tool.load && lineEndEl?.type != Tool.load &&
         lineStartEl?.type != Tool.transformer && lineEndEl?.type != Tool.transformer &&
         !e.id.contains('trans') && !e.id.contains('load') && !e.id.contains('gen')) ||
        (RegExp(r'^line_\d+_\d+$').hasMatch(e.id)) ||
        (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(e.label))
    );
    final bool isGenLead = !isBothBuses && e.type == Tool.line && (
        lineStartEl?.type == Tool.generator || lineEndEl?.type == Tool.generator ||
        e.label.contains("↔ G_") || e.label.contains("G_") ||
        (e.id.startsWith("lead_") && e.id.contains("gen"))
    );
    final bool isLoadLead = !isBothBuses && !isGenLead && e.type == Tool.line && (
        lineStartEl?.type == Tool.load || lineEndEl?.type == Tool.load ||
        e.label.contains("↔ Load_") || e.label.contains("Load_") ||
        (e.id.startsWith("lead_") && e.id.contains("load"))
    );
    final bool isTransLead = !isBothBuses && !isGenLead && !isLoadLead && e.type == Tool.line && (
        lineStartEl?.type == Tool.transformer || lineEndEl?.type == Tool.transformer ||
        (e.id.startsWith("lead_") && e.id.contains("trans")) ||
        (e.label.contains("↔ T") && !e.label.contains("Load") && !e.label.contains("G_"))
    );
    final bool hasPowerFields = (e.type == Tool.generator || e.type == Tool.load || isGenLead || isLoadLead);

    Color typeColor = Colors.blueGrey;
    String typeName = "부품";
    IconData typeIcon = Icons.extension;

    if (e.type == Tool.bus) {
      typeColor = e.isSlack ? Colors.redAccent : Colors.blueAccent;
      typeName = e.isSlack ? "슬랙(Slack) 기준 모선" : "모선 (Bus)";
      typeIcon = Icons.horizontal_rule;
    } else if (e.type == Tool.generator) {
      typeColor = e.isSlack ? Colors.redAccent : Colors.green;
      typeName = e.isSlack ? "슬랙 발전기 (Swing)" : "PV 발전기 (전압 제어)";
      typeIcon = Icons.motion_photos_on;
    } else if (e.type == Tool.load) {
      typeColor = Colors.orange;
      typeName = "PQ 부하 (Load)";
      typeIcon = Icons.arrow_downward;
    } else if (e.type == Tool.transformer) {
      typeColor = Colors.purple;
      typeName = "변압기 (Transformer)";
      typeIcon = Icons.crop_square;
    } else if (isGenLead) {
      typeColor = Colors.green;
      typeName = "발전기 인입선 (Gen Feeder)";
      typeIcon = Icons.power_input;
    } else if (isLoadLead) {
      typeColor = Colors.orange;
      typeName = "부하 인입선 (Load Feeder)";
      typeIcon = Icons.power_input;
    } else if (isTransLead) {
      typeColor = Colors.purple;
      typeName = "변압기 인입선 (Trans Feeder)";
      typeIcon = Icons.power_input;
    } else if (e.type == Tool.line) {
      typeColor = Colors.teal;
      typeName = "송전 선로 (AC Line)";
      typeIcon = Icons.polyline;
    } else if (e.type == Tool.text) {
      typeColor = Colors.indigo;
      typeName = "텍스트 라벨";
      typeIcon = Icons.text_fields;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: typeColor.withOpacity(0.15),
                child: Icon(typeIcon, size: 18, color: typeColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      typeName,
                      style: TextStyle(fontSize: 11, color: typeColor, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: "선택 해제 (Esc)",
                onPressed: widget.onClose,
              ),
            ],
          ),
          const Divider(height: 20),

          _buildSimulationResultBox(e),

          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text("도면 위에 값 표시", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            value: e.showInfo,
            activeColor: Colors.blueAccent,
            onChanged: (v) {
              e.showInfo = v;
              widget.onStateChanged();
            },
          ),

          if (hasPowerFields) ...[
            const SizedBox(height: 6),
            const Text("전력 표시/입력 단위", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
            const SizedBox(height: 4),
            _buildUnitToggle(),
            const SizedBox(height: 10),
          ],

          // Bus Fields
          if (e.type == Tool.bus) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "버스 번호 / 라벨",
                  helperText: "예: 1, 2, 3...",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onBusRenamed(e);
                  widget.onStateChanged();
                },
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text("슬랙 모선 (Slack/Swing)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              subtitle: Text(
                e.isSlack ? "기준 모선 (위상 θ=0° 고정)" : "일반 모선",
                style: const TextStyle(fontSize: 10),
              ),
              value: e.isSlack,
              activeColor: Colors.redAccent,
              onChanged: (v) {
                if (v) {
                  for (var b in widget.elements.where((el) => el.type == Tool.bus)) {
                    b.isSlack = false;
                  }
                }
                e.isSlack = v;
                widget.onStateChanged();
              },
            ),
            if (e.isSlack) ...[
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "🚩 슬랙(Slack / 기준) 모선\n"
                        "• 계통의 기준 모선으로 위상각(θ = 0.0°)이 고정됩니다.\n"
                        "• 발전량은 계통 전체 수급 불균형과 손실을 보상하도록 조류계산 시 자동 결정됩니다.",
                        style: TextStyle(fontSize: 11, color: Colors.redAccent, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            _buildNumberField(
              label: "전압 크기 V",
              unit: "pu",
              controller: vCtrl,
              helperText: "기준 공칭 전압 대비 비율 (기본 1.0)",
              onChanged: (val) => e.vPu = val,
            ),
            _buildNumberField(
              label: "기준 위상각 θ",
              unit: "deg",
              controller: thetaCtrl,
              helperText: "기준 모선은 통상 0.0°",
              onChanged: (val) => e.thetaDeg = val,
            ),
          ],

          // Generator Fields
          if (e.type == Tool.generator) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "발전기 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text("슬랙 모선 발전기 (Slack/Swing)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              subtitle: Text(
                e.isSlack ? "기준 모선 (위상 θ=0°, 손실/부하 자동분담)" : (e.isSynchronousCondenser ? "동기조상기 (P=0 MW 고정, 전압 V 제어)" : "PV 발전기 (유효전력 P, 전압 V 지정)"),
                style: const TextStyle(fontSize: 10),
              ),
              value: e.isSlack,
              activeColor: Colors.redAccent,
              onChanged: (v) {
                if (v) {
                  for (var g in widget.elements.where((el) => el.type == Tool.generator)) {
                    g.isSlack = false;
                  }
                }
                e.isSlack = v;
                widget.onStateChanged();
              },
            ),
            if (e.isSlack) ...[
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "🚩 슬랙(Slack / 기준) 모선 발전기\n"
                        "• 전압(V)과 기준 위상(θ=0°)만 고정 제약조건입니다.\n"
                        "• 유효 발전량(P) 및 무효 발전량(Q)은 조류계산 시 전체 계통 수급 균형(부하 + 손실 - 타발전기)에 의해 자동 산출됩니다.\n"
                        "• 아래 표시된 수치는 엑셀에 저장되어 있던 참고값(직전 계산값)이며, 조류계산 시 입력 제약으로 쓰이지 않고 실제 수렴 결과값으로 갱신됩니다.",
                        style: TextStyle(fontSize: 11, color: Colors.redAccent, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (e.isSynchronousCondenser) ...[
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade300),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.bolt, size: 20, color: Colors.blueAccent),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "⚡ 동기조상기 (Synchronous Condenser)\n"
                        "• 유효 발전 출력 P = 0 MW (터빈 없는 전압 조정기)\n"
                        "• 목표 단자 전압(V)을 유지하기 위해 필요한 무효전력(Q)을 조류계산이 자동으로 공급/흡수 계산합니다.",
                        style: TextStyle(fontSize: 11, color: Colors.blueAccent, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            _buildNumberField(
              label: "목표 단자 전압 V",
              unit: "pu",
              controller: vCtrl,
              helperText: "발전기가 유지할 전압 (예: 1.04)",
              onChanged: (val) => e.vPu = val,
            ),
            if (e.isSlack) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("유효 발전량 P (슬랙)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                          Text(
                            e.pPu == 0 ? "계산 전 (미지수)" : "${(e.pPu * widget.sBase).toStringAsFixed(2)} MW",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: e.pPu == 0 ? Colors.grey : Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        e.pPu == 0 ? "• 조류계산 실행 시 계통 전체 수급 균형에 맞춰 자동 산출됩니다." : "• 조류계산 수렴 결과 산출된 슬랙 유효 발전량입니다.",
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                      const Divider(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("무효 발전량 Q (슬랙)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                          Text(
                            e.qPu == 0 ? "계산 전 (미지수)" : "${(e.qPu * widget.sBase).toStringAsFixed(2)} MVAR",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: e.qPu == 0 ? Colors.grey : Colors.blueAccent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        e.qPu == 0 ? "• 조류계산 실행 시 기준 단자 전압 유지를 위해 자동 산출됩니다." : "• 조류계산 수렴 결과 산출된 슬랙 무효 발전량입니다.",
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              _buildNumberField(
                label: e.isSynchronousCondenser ? "유효 발전 출력 P (0 MW 고정)" : "유효 발전 출력 P",
                unit: useMw ? "MW" : "pu",
                controller: pCtrl,
                helperText: useMw ? "(= ${e.pPu.toStringAsFixed(3)} pu)" : "(= ${(e.pPu * widget.sBase).toStringAsFixed(1)} MW)",
                onChanged: (val) => e.pPu = useMw ? (val / widget.sBase) : val,
              ),
              _buildNumberField(
                label: e.isSynchronousCondenser ? "무효 발전 출력 Q (계산 시 자동 산출)" : "무효 발전 출력 Q",
                unit: useMw ? "MVAR" : "pu",
                controller: qCtrl,
                helperText: useMw ? "(= ${e.qPu.toStringAsFixed(3)} pu)" : "(= ${(e.qPu * widget.sBase).toStringAsFixed(1)} MVAR)",
                onChanged: (val) => e.qPu = useMw ? (val / widget.sBase) : val,
              ),
            ],
            if (e.isSlack)
              _buildNumberField(
                label: "기준 위상각 θ",
                unit: "deg",
                controller: thetaCtrl,
                helperText: "슬랙 모선 기준각 (기본 0°)",
                onChanged: (val) => e.thetaDeg = val,
              ),
          ],

          // Load Fields
          if (e.type == Tool.load) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "부하 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            _buildNumberField(
              label: "소비 유효전력 P",
              unit: useMw ? "MW" : "pu",
              controller: pCtrl,
              helperText: useMw ? "(= ${e.pPu.toStringAsFixed(3)} pu)" : "(= ${(e.pPu * widget.sBase).toStringAsFixed(1)} MW)",
              onChanged: (val) => e.pPu = useMw ? (val / widget.sBase) : val,
            ),
            _buildNumberField(
              label: "소비 무효전력 Q",
              unit: useMw ? "MVAR" : "pu",
              controller: qCtrl,
              helperText: useMw ? "(= ${e.qPu.toStringAsFixed(3)} pu)" : "(= ${(e.qPu * widget.sBase).toStringAsFixed(1)} MVAR)",
              onChanged: (val) => e.qPu = useMw ? (val / widget.sBase) : val,
            ),
          ],

          // Generator Lead Line Fields
          if (e.type == Tool.line && isGenLead) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "인입선 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            _buildNumberField(
              label: "발전 주입 유효전력 P",
              unit: useMw ? "MW" : "pu",
              controller: pCtrl,
              helperText: useMw ? "(= ${e.pPu.toStringAsFixed(3)} pu)" : "(= ${(e.pPu * widget.sBase).toStringAsFixed(1)} MW)",
              onChanged: (val) {
                e.pPu = useMw ? (val / widget.sBase) : val;
                if (lineStartEl?.type == Tool.generator) lineStartEl!.pPu = e.pPu;
                else if (lineEndEl?.type == Tool.generator) lineEndEl!.pPu = e.pPu;
                widget.onStateChanged();
              },
            ),
            _buildNumberField(
              label: "발전 무효전력 Q",
              unit: useMw ? "MVAR" : "pu",
              controller: qCtrl,
              helperText: useMw ? "(= ${e.qPu.toStringAsFixed(3)} pu)" : "(= ${(e.qPu * widget.sBase).toStringAsFixed(1)} MVAR)",
              onChanged: (val) {
                e.qPu = useMw ? (val / widget.sBase) : val;
                if (lineStartEl?.type == Tool.generator) lineStartEl!.qPu = e.qPu;
                else if (lineEndEl?.type == Tool.generator) lineEndEl!.qPu = e.qPu;
                widget.onStateChanged();
              },
            ),
            _buildNumberField(
              label: "인입선 직렬 저항 R",
              unit: "pu",
              controller: rCtrl,
              helperText: "발전기 단자 직결 (기본 0.0)",
              onChanged: (val) => e.rPu = val,
            ),
            _buildNumberField(
              label: "인입선 직렬 리액턴스 X",
              unit: "pu",
              controller: xCtrl,
              helperText: "발전기 단자 직결 (기본 0.0)",
              onChanged: (val) => e.xPu = val,
            ),
          ] else if (e.type == Tool.line && isLoadLead) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "인입선 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            _buildNumberField(
              label: "부하 소비 유효전력 P",
              unit: useMw ? "MW" : "pu",
              controller: pCtrl,
              helperText: useMw ? "(= ${e.pPu.toStringAsFixed(3)} pu)" : "(= ${(e.pPu * widget.sBase).toStringAsFixed(1)} MW)",
              onChanged: (val) {
                e.pPu = useMw ? (val / widget.sBase) : val;
                if (lineStartEl?.type == Tool.load) lineStartEl!.pPu = e.pPu;
                else if (lineEndEl?.type == Tool.load) lineEndEl!.pPu = e.pPu;
                widget.onStateChanged();
              },
            ),
            _buildNumberField(
              label: "부하 소비 무효전력 Q",
              unit: useMw ? "MVAR" : "pu",
              controller: qCtrl,
              helperText: useMw ? "(= ${e.qPu.toStringAsFixed(3)} pu)" : "(= ${(e.qPu * widget.sBase).toStringAsFixed(1)} MVAR)",
              onChanged: (val) {
                e.qPu = useMw ? (val / widget.sBase) : val;
                if (lineStartEl?.type == Tool.load) lineStartEl!.qPu = e.qPu;
                else if (lineEndEl?.type == Tool.load) lineEndEl!.qPu = e.qPu;
                widget.onStateChanged();
              },
            ),
            _buildNumberField(
              label: "인입선 직렬 저항 R",
              unit: "pu",
              controller: rCtrl,
              helperText: "부하 단자 직결 (기본 0.0)",
              onChanged: (val) => e.rPu = val,
            ),
            _buildNumberField(
              label: "인입선 직렬 리액턴스 X",
              unit: "pu",
              controller: xCtrl,
              helperText: "부하 단자 직결 (기본 0.0)",
              onChanged: (val) => e.xPu = val,
            ),
          ] else if (e.type == Tool.line && isTransLead) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "인입선 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            _buildNumberField(
              label: "인입선 직렬 저항 R",
              unit: "pu",
              controller: rCtrl,
              helperText: "변압기 분기 직렬 저항 (엑셀 기준값 반영)",
              onChanged: (val) => e.rPu = val,
            ),
            _buildNumberField(
              label: "인입선 직렬 리액턴스 X",
              unit: "pu",
              controller: xCtrl,
              helperText: "변압기 분기 직렬 리액턴스 (엑셀 기준값 반영)",
              onChanged: (val) => e.xPu = val,
            ),
          ] else if (e.type == Tool.line) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "선로 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            if (e.isDoubleCircuit) ...[
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.alt_route, size: 20, color: Colors.teal),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "⚡ 복회선 적용됨 (Double Circuit - ${e.circuitCount ?? 2}회선 병렬 등가)\n"
                        "• 모선 간 2가닥 이상의 선로가 병렬 연결된 복회선입니다.\n"
                        "• 저항(R)과 리액턴스(X)가 1/2로 병렬 합성(등가 임피던스)되어 조류계산에 반영됩니다.",
                        style: const TextStyle(fontSize: 11, color: Colors.teal, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            _buildNumberField(
              label: "선로 저항 R",
              unit: "pu",
              controller: rCtrl,
              helperText: "선로 직렬 저항 (예: 0.02)",
              onChanged: (val) => e.rPu = val,
            ),
            _buildNumberField(
              label: "선로 리액턴스 X",
              unit: "pu",
              controller: xCtrl,
              helperText: "선로 직렬 유도 리액턴스 (예: 0.04)",
              onChanged: (val) => e.xPu = val,
            ),
            _buildNumberField(
              label: "대지 충전 서셉턴스 B",
              unit: "pu",
              controller: bCtrl,
              helperText: "장거리 선로 커패시턴스 (보통 0.0)",
              onChanged: (val) => e.bPu = val,
            ),
            _buildNumberField(
              label: "변압기 탭비 Tap",
              unit: "pu",
              controller: tapCtrl,
              helperText: "일반 선로는 1.0 (변압기 결합 시 탭비)",
              onChanged: (val) => e.tapRatio = val,
            ),
          ],

          // Transformer Fields
          if (e.type == Tool.transformer) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "변압기 라벨 (식별자)",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
            _buildNumberField(
              label: "권선비 / 탭비 Tap",
              unit: "pu",
              controller: tapCtrl,
              helperText: "엑셀 transformer 시트 기준 (1.00 = 100%, 1.03 = 103%)",
              onChanged: (val) => e.tapRatio = val,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "변압기는 탭비(Tap)만 보유하며, 임피던스(저항 R, 리액턴스 X)는 엑셀 branch 시트 규격에 따라 변압기와 연결된 선로(Line)에 적용됩니다.",
                      style: TextStyle(fontSize: 11, color: Color(0xFF1E293B), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Text Fields
          if (e.type == Tool.text) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: "라벨 텍스트 내용",
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (text) {
                  e.label = text;
                  widget.onStateChanged();
                },
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text("선택 요소 삭제 (Delete)", style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: widget.onDeleteSelected,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnitToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                if (!useMw) {
                  setState(() {
                    useMw = true;
                    _updateControllers();
                  });
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: useMw ? Colors.blue.shade700 : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "MW / MVAR",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: useMw ? Colors.white : Colors.blueGrey.shade800,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                if (useMw) {
                  setState(() {
                    useMw = false;
                    _updateControllers();
                  });
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: !useMw ? Colors.blue.shade700 : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "pu (Per Unit)",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: !useMw ? Colors.white : Colors.blueGrey.shade800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required TextEditingController controller,
    String? helperText,
    String? unit,
    required Function(double) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          helperText: helperText,
          helperStyle: const TextStyle(fontSize: 10, color: Colors.blueGrey),
          suffixText: unit,
          suffixStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.blue.shade700, width: 1.5),
          ),
        ),
        onChanged: (text) {
          final val = double.tryParse(text);
          if (val != null) {
            onChanged(val);
            widget.onStateChanged();
          }
        },
      ),
    );
  }

  Widget _buildSimulationResultBox(DrawingElement e) {
    if (widget.simulationResult == null) return const SizedBox.shrink();

    final busResults = widget.simulationResult!['bus_results'] as List<dynamic>? ?? [];
    final lineResults = widget.simulationResult!['line_results'] as List<dynamic>? ?? [];

    String getBusNum(String text) {
      final RegExp digitRegExp = RegExp(r'\d+');
      final match = digitRegExp.firstMatch(text);
      return match != null ? match.group(0)! : text;
    }

    if (e.type == Tool.bus) {
      final busNum = getBusNum(e.label.isNotEmpty ? e.label : e.id);
      final bRes = busResults.firstWhere(
        (b) => b['bus'].toString() == busNum,
        orElse: () => null,
      );
      if (bRes == null) return const SizedBox.shrink();

      final double v = (bRes['volt'] as num?)?.toDouble() ?? 1.0;
      final double ang = (bRes['angle'] as num?)?.toDouble() ?? 0.0;
      final double pgen = (bRes['pgen'] as num?)?.toDouble() ?? 0.0;
      final double qgen = (bRes['qgen'] as num?)?.toDouble() ?? 0.0;
      final double pload = (bRes['pload'] as num?)?.toDouble() ?? 0.0;
      final double qload = (bRes['qload'] as num?)?.toDouble() ?? 0.0;
      final bool isNormalVolt = (v >= 0.95 && v <= 1.05);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isNormalVolt ? Colors.green.shade50 : Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isNormalVolt ? Colors.green.shade300 : Colors.orange.shade300, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, size: 16, color: isNormalVolt ? Colors.green.shade700 : Colors.orange.shade700),
                const SizedBox(width: 6),
                Text("조류계산 해석 결과", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isNormalVolt ? Colors.green.shade900 : Colors.orange.shade900)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isNormalVolt ? Colors.green.shade600 : Colors.orange.shade600).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isNormalVolt ? "정상 전압" : "주의 전압",
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isNormalVolt ? Colors.green.shade700 : Colors.orange.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _resRow("모선 전압 크기 (V)", "${v.toStringAsFixed(4)} pu  (${(v * 100).toStringAsFixed(1)}%)"),
            _resRow("전압 위상각 (θ)", "${ang >= 0 ? '+' : ''}${ang.toStringAsFixed(2)}°"),
            if (pgen.abs() > 0.01 || qgen.abs() > 0.01)
              _resRow("발전 전력 (P / Q)", "${pgen.toStringAsFixed(1)} MW / ${qgen.toStringAsFixed(1)} MVAR"),
            if (pload.abs() > 0.01 || qload.abs() > 0.01)
              _resRow("부하 소비 (P / Q)", "${pload.toStringAsFixed(1)} MW / ${qload.toStringAsFixed(1)} MVAR"),
          ],
        ),
      );
    } else if (e.type == Tool.line) {
      DrawingElement? startEl;
      DrawingElement? endEl;
      try { startEl = widget.elements.firstWhere((el) => el.id == e.startElementId); } catch (_) {}
      try { endEl = widget.elements.firstWhere((el) => el.id == e.endElementId); } catch (_) {}

      final sBusNum = _getBusNumDigits(startEl?.label.isNotEmpty == true ? startEl!.label : e.startElementId);
      final eBusNum = _getBusNumDigits(endEl?.label.isNotEmpty == true ? endEl!.label : e.endElementId);
      final bool isBothBuses = (startEl?.type == Tool.bus && endEl?.type == Tool.bus) ||
          (sBusNum != null && eBusNum != null &&
           startEl?.type != Tool.generator && endEl?.type != Tool.generator &&
           startEl?.type != Tool.load && endEl?.type != Tool.load &&
           startEl?.type != Tool.transformer && endEl?.type != Tool.transformer &&
           !e.id.contains('trans') && !e.id.contains('load') && !e.id.contains('gen')) ||
          (RegExp(r'^line_\d+_\d+$').hasMatch(e.id)) ||
          (RegExp(r'^Line\s+\d+[-~]\d+').hasMatch(e.label));
      final bool isGen = !isBothBuses && (startEl?.type == Tool.generator || endEl?.type == Tool.generator || e.label.contains("↔ G_") || e.label.contains("G_") || (e.id.startsWith("lead_") && e.id.contains("gen")));
      final bool isLd = !isBothBuses && !isGen && (startEl?.type == Tool.load || endEl?.type == Tool.load || e.label.contains("↔ Load_") || e.label.contains("Load_") || (e.id.startsWith("lead_") && e.id.contains("load")));

      if (isGen || isLd) {
        final double pMw = e.pPu * widget.sBase;
        final double qMvar = e.qPu * widget.sBase;
        final Color boxColor = isGen ? Colors.green : Colors.orange;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: boxColor.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: boxColor.withOpacity(0.4), width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isGen ? Icons.motion_photos_on : Icons.arrow_downward, size: 16, color: boxColor),
                  const SizedBox(width: 6),
                  Text(isGen ? "발전기 인입 조류 (단자 직결)" : "부하 인입 조류 (단자 직결)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: boxColor)),
                ],
              ),
              const SizedBox(height: 8),
              _resRow(isGen ? "발전 주입 (P)" : "부하 소비 (P)", "${pMw.abs().toStringAsFixed(1)} MW  (${e.pPu.toStringAsFixed(3)} pu)"),
              _resRow(isGen ? "무효 주입 (Q)" : "무효 소비 (Q)", "${qMvar.abs().toStringAsFixed(1)} MVAR  (${e.qPu.toStringAsFixed(3)} pu)"),
              _resRow("인입 손실 (P loss)", "0.00 MW (단자 직결 손실 없음)"),
            ],
          ),
        );
      }

      if (startEl == null || endEl == null) return const SizedBox.shrink();

      final fb = getBusNum(startEl.label.isNotEmpty ? startEl.label : startEl.id);
      final tb = getBusNum(endEl.label.isNotEmpty ? endEl.label : endEl.id);
      final lRes = lineResults.firstWhere(
        (l) => (l['from_bus'].toString() == fb && l['to_bus'].toString() == tb) ||
               (l['from_bus'].toString() == tb && l['to_bus'].toString() == fb),
        orElse: () => null,
      );
      if (lRes == null) return const SizedBox.shrink();

      final double pFrom = (lRes['p_from_mw'] as num?)?.toDouble() ?? 0.0;
      final double lossP = (lRes['loss_p_mw'] as num?)?.toDouble() ?? 0.0;
      final double qFrom = (lRes['q_from_mvar'] as num?)?.toDouble() ?? 0.0;
      final double lossQ = (lRes['loss_q_mvar'] as num?)?.toDouble() ?? 0.0;

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade300, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timeline, size: 16, color: Colors.blue.shade700),
                const SizedBox(width: 6),
                Text("선로 조류 및 손실 결과", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
              ],
            ),
            const SizedBox(height: 8),
            _resRow("유효 조류 (P)", "${pFrom.abs().toStringAsFixed(1)} MW"),
            _resRow("무효 조류 (Q)", "${qFrom.abs().toStringAsFixed(1)} MVAR"),
            _resRow("선로 손실 (P loss)", "${lossP.toStringAsFixed(2)} MW"),
            _resRow("무효 손실 (Q loss)", "${lossQ.toStringAsFixed(2)} MVAR"),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _resRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        ],
      ),
    );
  }

}
