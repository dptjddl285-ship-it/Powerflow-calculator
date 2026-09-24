import 'package:flutter/material.dart';
import '../models/review_models.dart';

/// Bus Mapping V2 Dedicated Inspector View
///
/// Follows the exception-focused UX philosophy:
/// - Normal VERIFIED buses: display AI-read number, evidence, NO [승인] button.
/// - UNCERTAIN / Issue buses: display reason, number edit input field, and [적용] button.
/// - Never shows hardcoded 99% confidence.
class BusInspectorView extends StatefulWidget {
  final ReviewNodeItem node;
  final ValueChanged<int> onApplyNumber;
  final String? Function(int number)? validateNumber;
  final List<ReviewNodeItem> allBuses;
  final List<ReviewNodeItem> connectedGens;
  final List<ReviewNodeItem> connectedLoads;

  const BusInspectorView({
    super.key,
    required this.node,
    required this.onApplyNumber,
    this.validateNumber,
    this.allBuses = const [],
    this.connectedGens = const [],
    this.connectedLoads = const [],
  });

  @override
  State<BusInspectorView> createState() => _BusInspectorViewState();
}

class _BusInspectorViewState extends State<BusInspectorView> {
  late TextEditingController _controller;
  bool _isEditing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.node.busNumber?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant BusInspectorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id ||
        oldWidget.node.busNumber != widget.node.busNumber) {
      _controller.text = widget.node.busNumber?.toString() ?? '';
      _errorMessage = null;
      _isEditing = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleApply() {
    final text = _controller.text.trim();
    final num = int.tryParse(text);
    if (num == null || num <= 0) {
      setState(() {
        _errorMessage = "1 이상의 유효한 정수 번호를 입력해주세요.";
      });
      return;
    }
    final validationMessage = widget.validateNumber?.call(num);
    if (validationMessage != null) {
      setState(() => _errorMessage = validationMessage);
      return;
    }

    setState(() {
      _errorMessage = null;
      _isEditing = false;
    });
    widget.onApplyNumber(num);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final isHumanModified = node.source.contains('human');

    final counts = <int, int>{};
    for (final b in widget.allBuses) {
      if (b.busNumber != null && b.busNumber! > 0) {
        counts[b.busNumber!] = (counts[b.busNumber!] ?? 0) + 1;
      }
    }
    final isDuplicate =
        node.busNumber != null && (counts[node.busNumber!] ?? 0) > 1;
    final hasActiveDupReason = node.busNumberReasons.any(
      (r) => r.startsWith('DUPLICATE_BUS_NUMBER_'),
    );
    final isUncertain =
        node.busNumber == null ||
        node.busNumber! <= 0 ||
        node.busNumberStatus == 'UNCERTAIN' ||
        isDuplicate ||
        hasActiveDupReason;
    final isVerified = !isUncertain && node.busNumberStatus == 'VERIFIED';

    final String statusLabel;
    final Color statusColor;
    if (isDuplicate || hasActiveDupReason) {
      statusLabel = "중복 번호";
      statusColor = const Color(0xFFEF4444);
    } else if (isUncertain) {
      statusLabel = "확인 필요";
      statusColor = const Color(0xFFD97706);
    } else if (isHumanModified) {
      statusLabel = "사람 수정됨";
      statusColor = const Color(0xFF059669);
    } else {
      statusLabel = "AI 확인";
      statusColor = const Color(0xFF2563EB);
    }

    final candidates = <int>{};
    if (node.suggestedBusNumber != null && node.suggestedBusNumber! > 0) {
      candidates.add(node.suggestedBusNumber!);
    }
    if (node.displayNumber != null && node.displayNumber! > 0) {
      candidates.add(node.displayNumber!);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isVerified ? const Color(0xFF86EFAC) : const Color(0xFFFDE68A),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Header: Status Badge & Bus Identifier
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isVerified
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.numbers_rounded,
                      color: isVerified
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFD97706),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.busNumber != null
                            ? "Bus #${node.busNumber}"
                            : "Bus 번호 미지정",
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "도면 객체 ID: ${node.id}",
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 2. Verified Mode: Display Details & Evidence (No approval button needed!)
          if (isVerified && !_isEditing) ...[
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "AI 판독 번호: ${node.busNumber}",
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('BusEditButton'),
                        onPressed: () => setState(() => _isEditing = true),
                        icon: const Icon(Icons.edit_outlined, size: 13),
                        label: const Text("수정", style: TextStyle(fontSize: 11)),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "✓ 고유 번호가 확인되어 자동으로 통과되었습니다.",
                    style: TextStyle(color: Color(0xFF16A34A), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],

          // 3. Edit / Uncertain Mode: Number Input + [적용]
          if (isUncertain || _isEditing) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isDuplicate
                      ? const Color(0xFFFCA5A5)
                      : const Color(0xFFFDE68A),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (node.busNumber == null)
                    const Text(
                      "⚠️ 번호를 명확하게 판독하지 못했습니다. 도면의 번호를 입력해주세요.",
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else if (isDuplicate)
                    Text(
                      "⚠️ 모선 번호 #${node.busNumber}가 다른 모선과 중복됩니다. 고유한 번호로 수정해주세요.",
                      style: const TextStyle(
                        color: Color(0xFFEF4444),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    const Text(
                      "도면의 모선 번호를 확인하고 수정하세요:",
                      style: TextStyle(color: Color(0xFF475569), fontSize: 11),
                    ),
                  const SizedBox(height: 8),

                  if (candidates.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          "추천: ",
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        ...candidates.map(
                          (c) => ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              "#$c",
                              style: const TextStyle(fontSize: 10.5),
                            ),
                            backgroundColor: const Color(0xFFEFF6FF),
                            onPressed: () {
                              _controller.text = c.toString();
                              setState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],

                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: TextField(
                            key: const ValueKey('BusNumberInputField'),
                            controller: _controller,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                            decoration: InputDecoration(
                              hintText: "모선 번호 (1~50, 예: 14)",
                              hintStyle: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            onSubmitted: (_) => _handleApply(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        key: const ValueKey('BusApplyButton'),
                        onPressed: _handleApply,
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text("적용", style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      if (isVerified && _isEditing) ...[
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => setState(() => _isEditing = false),
                          child: const Text(
                            "취소",
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Color(0xFFDC2626),
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),

          // 4. Connected Devices Info
          if (widget.connectedGens.isNotEmpty ||
              widget.connectedLoads.isNotEmpty) ...[
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
                    "⚡ 직결된 발전기/부하:",
                    style: TextStyle(
                      color: Color(0xFF334155),
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (widget.connectedGens.isNotEmpty)
                    Text(
                      "• 발전기: ${widget.connectedGens.map((g) => g.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(
                        color: Color(0xFF16A34A),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (widget.connectedLoads.isNotEmpty)
                    Text(
                      "• 부하: ${widget.connectedLoads.map((l) => l.effectiveDisplayLabel).join(', ')}",
                      style: const TextStyle(
                        color: Color(0xFFEA580C),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
