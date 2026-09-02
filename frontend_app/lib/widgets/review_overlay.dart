import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/review_models.dart';

class ReviewOverlayView extends StatefulWidget {
  final Uint8List? imageBytes;
  final String? imageUrl;
  final int originalWidth;
  final int originalHeight;
  final List<ReviewNodeItem> nodes;
  final ReviewNodeItem? selectedNode;
  final Function(ReviewNodeItem) onSelectNode;
  final Function(String nodeId, double dx, double dy)? onNodeOffsetChanged;
  final bool showNodeLabels;
  final bool showLineLabels;

  // Connection Overlay additions
  final List<ReviewLineItem> lines;
  final ReviewLineItem? selectedLine;
  final Function(ReviewLineItem)? onSelectLine;
  final Function(String lineId, double dx, double dy)? onLineOffsetChanged;

  // Manual Object Mode
  final bool isManualAddMode;
  final String manualAddClass;
  final Function(List<double> bbox, String className)? onManualAddComplete;

  // Manual Line Mode
  final bool isManualAddLineMode;
  final ReviewNodeItem? manualLineStartNode;
  final Function(ReviewNodeItem startNode, ReviewNodeItem endNode)?
  onManualAddLineComplete;

  const ReviewOverlayView({
    super.key,
    required this.imageBytes,
    required this.imageUrl,
    required this.originalWidth,
    required this.originalHeight,
    required this.nodes,
    required this.selectedNode,
    required this.onSelectNode,
    this.onNodeOffsetChanged,
    this.showNodeLabels = true,
    this.showLineLabels = true,
    this.lines = const [],
    this.selectedLine,
    this.onSelectLine,
    this.onLineOffsetChanged,
    this.isManualAddMode = false,
    this.manualAddClass = 'bus',
    this.onManualAddComplete,
    this.isManualAddLineMode = false,
    this.manualLineStartNode,
    this.onManualAddLineComplete,
  });

  @override
  State<ReviewOverlayView> createState() => _ReviewOverlayViewState();
}

class _ReviewOverlayViewState extends State<ReviewOverlayView>
    with SingleTickerProviderStateMixin {
  Offset? _dragStart;
  Offset? _dragCurrent;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // 1. Distinct Class Color (Symbol Identity)
  Color _getClassColor(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) {
      return const Color(0xFF00E676); // Vibrant Green/Teal
    }
    if (cls.contains('load')) return const Color(0xFFFF9100); // Vibrant Orange
    if (cls.contains('trans')) return const Color(0xFFD500F9); // Vibrant Purple
    return const Color(0xFF2979FF); // Vibrant Blue for Bus
  }

  // 2. Distinct Status Border & Badge Color (Review State)
  Color _getStatusColor(String status) {
    final s = status.toUpperCase();
    if (s == 'CONFIRMED') return const Color(0xFF00E676); // Green
    if (s == 'SUSPICIOUS') return const Color(0xFFFFD600); // Amber/Yellow
    if (s == 'REJECTED') return const Color(0xFFFF1744); // Red
    return const Color(0xFF00E5FF); // Cyan for DETECTED
  }

  IconData _getClassIcon(String className) {
    final cls = className.toLowerCase();
    if (cls.contains('gen')) return Icons.bolt;
    if (cls.contains('load')) return Icons.arrow_downward;
    if (cls.contains('trans')) return Icons.sync_alt;
    return Icons.horizontal_rule; // bus
  }

  // Distance from point P to line segment AB
  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final double l2 =
        (b.dx - a.dx) * (b.dx - a.dx) + (b.dy - a.dy) * (b.dy - a.dy);
    if (l2 == 0) return (p - a).distance;
    final double t = math.max(
      0,
      math.min(
        1,
        ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2,
      ),
    );
    final Offset projection = Offset(
      a.dx + t * (b.dx - a.dx),
      a.dy + t * (b.dy - a.dy),
    );
    return (p - projection).distance;
  }

  ReviewLineItem? _findLineNearTap(
    Offset tapPos,
    double scaleX,
    double scaleY,
  ) {
    ReviewLineItem? closestLine;
    double minDistance = 20.0; // 20px tap tolerance

    for (var line in widget.lines) {
      if (line.path.length < 2) continue;
      for (int i = 0; i < line.path.length - 1; i++) {
        final a = Offset(line.path[i][0] * scaleX, line.path[i][1] * scaleY);
        final b = Offset(
          line.path[i + 1][0] * scaleX,
          line.path[i + 1][1] * scaleY,
        );
        final dist = _distanceToSegment(tapPos, a, b);
        if (dist < minDistance) {
          minDistance = dist;
          closestLine = line;
        }
      }
    }
    return closestLine;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageBytes == null &&
        (widget.imageUrl == null || widget.imageUrl!.isEmpty)) {
      return const Center(child: Text("회로도 이미지가 없습니다."));
    }

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, _) {
        final pulseVal = _pulseAnimation.value;

        return LayoutBuilder(
          builder: (context, constraints) {
            final double containerW = constraints.maxWidth;
            final double containerH = constraints.maxHeight;

            final double origW = widget.originalWidth > 0
                ? widget.originalWidth.toDouble()
                : 1280.0;
            final double origH = widget.originalHeight > 0
                ? widget.originalHeight.toDouble()
                : 720.0;

            final double scaleW = containerW / origW;
            final double scaleH = containerH / origH;
            final double fitScale = math.min(scaleW, scaleH);

            final double renderedW = origW * fitScale;
            final double renderedH = origH * fitScale;

            final double scaleX = renderedW / origW;
            final double scaleY = renderedH / origH;

            // Compute connected node IDs for the selected line (for endpoint highlight)
            final Set<String> lineEndpointNodeIds = {};
            if (widget.selectedLine != null) {
              lineEndpointNodeIds.addAll(widget.selectedLine!.connectedTo);
            }

            return Center(
              child: SizedBox(
                width: renderedW,
                height: renderedH,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (!widget.isManualAddMode &&
                        !widget.isManualAddLineMode) {
                      final line = _findLineNearTap(
                        details.localPosition,
                        scaleX,
                        scaleY,
                      );
                      if (line != null) {
                        widget.onSelectLine?.call(line);
                      }
                    }
                  },
                  onPanStart: (details) {
                    if (widget.isManualAddMode) {
                      setState(() {
                        _dragStart = details.localPosition;
                        _dragCurrent = details.localPosition;
                      });
                    }
                  },
                  onPanUpdate: (details) {
                    if (widget.isManualAddMode) {
                      setState(() {
                        _dragCurrent = details.localPosition;
                      });
                    }
                  },
                  onPanEnd: (details) {
                    if (widget.isManualAddMode &&
                        _dragStart != null &&
                        _dragCurrent != null) {
                      final double left = math.min(
                        _dragStart!.dx,
                        _dragCurrent!.dx,
                      );
                      final double top = math.min(
                        _dragStart!.dy,
                        _dragCurrent!.dy,
                      );
                      final double w = (_dragStart!.dx - _dragCurrent!.dx)
                          .abs();
                      final double h = (_dragStart!.dy - _dragCurrent!.dy)
                          .abs();

                      final isBus = widget.manualAddClass == 'bus';
                      final validSize = isBus
                          ? math.max(w, h) > 14 && math.min(w, h) > 2
                          : w > 10 && h > 10;
                      if (validSize) {
                        final double origLeft = left / scaleX;
                        final double origTop = top / scaleY;
                        final double origWidth = w / scaleX;
                        final double origHeight = h / scaleY;
                        final double origCx = origLeft + origWidth / 2.0;
                        final double origCy = origTop + origHeight / 2.0;

                        widget.onManualAddComplete?.call([
                          origCx,
                          origCy,
                          origWidth,
                          origHeight,
                        ], widget.manualAddClass);
                      }
                      setState(() {
                        _dragStart = null;
                        _dragCurrent = null;
                      });
                    }
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 1. Base Original Image
                      Positioned.fill(
                        child: widget.imageBytes != null
                            ? Image.memory(
                                widget.imageBytes!,
                                width: renderedW,
                                height: renderedH,
                                fit: BoxFit.fill,
                              )
                            : Image.network(
                                widget.imageUrl!,
                                width: renderedW,
                                height: renderedH,
                                fit: BoxFit.fill,
                              ),
                      ),

                      // 2. Leader Lines Painter (for displaced node & line labels)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _LeaderLinePainter(
                            nodes: widget.nodes,
                            lines: widget.lines,
                            scaleX: scaleX,
                            scaleY: scaleY,
                          ),
                        ),
                      ),

                      // 3. Connection Line Paths Overlay (Custom Painter with Pulse & Dimming)
                      if (widget.lines.isNotEmpty)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ConnectionOverlayPainter(
                              lines: widget.lines,
                              selectedLine: widget.selectedLine,
                              scaleX: scaleX,
                              scaleY: scaleY,
                              pulseValue: pulseVal,
                            ),
                          ),
                        ),

                      // 4. Line Display Label Badges (Draggable at Midpoints)
                      if (widget.showLineLabels)
                        ...widget.lines.map((line) {
                          if (line.path.length < 2) {
                            return const SizedBox.shrink();
                          }
                          final midIdx = line.path.length ~/ 2;
                          final midPt = line.path[midIdx];
                          final double baseMidX = midPt[0] * scaleX;
                          final double baseMidY = midPt[1] * scaleY;

                          final double posX = baseMidX + line.labelOffsetDx;
                          final double posY = baseMidY - 8 + line.labelOffsetDy;

                          final bool isLineSelected =
                              widget.selectedLine?.lineId == line.lineId;

                          return Positioned(
                            left: posX - 10,
                            top: posY - 6,
                            child: GestureDetector(
                              onTap: () => widget.onSelectLine?.call(line),
                              onPanUpdate: (details) {
                                widget.onLineOffsetChanged?.call(
                                  line.lineId,
                                  line.labelOffsetDx + details.delta.dx,
                                  line.labelOffsetDy + details.delta.dy,
                                );
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.move,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2.5,
                                    vertical: 0.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isLineSelected
                                        ? Colors.yellowAccent
                                        : const Color(0xFFB71C1C).withValues(
                                            alpha: 0.9,
                                          ),
                                    borderRadius: BorderRadius.circular(2),
                                    border: Border.all(
                                      color: isLineSelected
                                          ? Colors.orangeAccent
                                          : Colors.white70,
                                      width: isLineSelected ? 1.0 : 0.6,
                                    ),
                                  ),
                                  child: Text(
                                    line.effectiveDisplayLabel,
                                    style: TextStyle(
                                      color: isLineSelected
                                          ? Colors.black87
                                          : Colors.white,
                                      fontSize: 6.8,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),

                      // 5. Bounding Box & Draggable Label for each node
                      ...widget.nodes.map((node) {
                        final bbox = node.bbox;
                        if (bbox.length < 4) return const SizedBox.shrink();

                        final double cx = bbox[0];
                        final double cy = bbox[1];
                        final double w = bbox[2];
                        final double h = bbox[3];

                        final double renderLeft = (cx - w / 2.0) * scaleX;
                        final double renderTop = (cy - h / 2.0) * scaleY;
                        final double renderW = math.max(6.0, w * scaleX);
                        final double renderH = math.max(6.0, h * scaleY);

                        final bool isSelected =
                            widget.selectedNode?.id == node.id;
                        final bool isEndpointOfSelectedLine =
                            lineEndpointNodeIds.contains(node.id);

                        final Color classColor = _getClassColor(node.className);
                        final Color statusColor = _getStatusColor(
                          node.reviewStatus,
                        );

                        final double labelBaseX =
                            renderLeft + node.labelOffsetDx;
                        final double labelBaseY =
                            renderTop - 12 + node.labelOffsetDy;

                        final bool isHumanAdded = node.source.contains(
                          'human_added',
                        );
                        final bool isRejected =
                            node.reviewStatus == 'REJECTED';

                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Bounding Box Rect
                            Positioned(
                              left: renderLeft,
                              top: renderTop,
                              child: GestureDetector(
                                onTap: () {
                                  if (widget.isManualAddLineMode) {
                                    if (widget.manualLineStartNode == null) {
                                      widget.onSelectNode(node);
                                    } else if (widget.manualLineStartNode!.id !=
                                        node.id) {
                                      widget.onManualAddLineComplete?.call(
                                        widget.manualLineStartNode!,
                                        node,
                                      );
                                    }
                                  } else {
                                    widget.onSelectNode(node);
                                  }
                                },
                                child: Container(
                                  width: renderW,
                                  height: renderH,
                                  decoration: BoxDecoration(
                                    color: (isSelected ||
                                            isEndpointOfSelectedLine)
                                        ? Colors.yellowAccent.withValues(
                                            alpha: 0.25,
                                          )
                                        : classColor.withValues(alpha: 0.08),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.yellowAccent
                                          : (isEndpointOfSelectedLine
                                                ? Colors.cyanAccent
                                                : (isRejected
                                                    ? Colors.redAccent
                                                    : classColor)),
                                      width: isSelected
                                          ? 1.8
                                          : (isEndpointOfSelectedLine
                                                ? 1.8
                                                : 1.2),
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                    boxShadow: (isSelected ||
                                            isEndpointOfSelectedLine)
                                        ? [
                                            BoxShadow(
                                              color: (isSelected
                                                      ? Colors.yellowAccent
                                                      : Colors.cyanAccent)
                                                  .withValues(alpha: 0.4),
                                              blurRadius: 4,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                            ),

                            // Draggable Label Badge
                            if (widget.showNodeLabels)
                              Positioned(
                                left: labelBaseX,
                                top: labelBaseY,
                                child: GestureDetector(
                                  onTap: () => widget.onSelectNode(node),
                                  onPanUpdate: (details) {
                                    widget.onNodeOffsetChanged?.call(
                                      node.id,
                                      node.labelOffsetDx + details.delta.dx,
                                      node.labelOffsetDy + details.delta.dy,
                                    );
                                  },
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.move,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 2.5,
                                        vertical: 0.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.yellowAccent
                                            : (isEndpointOfSelectedLine
                                                  ? Colors.cyanAccent
                                                  : classColor.withValues(
                                                      alpha: 0.92,
                                                    )),
                                        borderRadius: BorderRadius.circular(2),
                                        border: Border.all(
                                          color: isSelected
                                              ? Colors.orangeAccent
                                              : statusColor,
                                          width: isSelected ? 1.0 : 0.6,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _getClassIcon(node.className),
                                            size: 8.0,
                                            color:
                                                (isSelected ||
                                                    isEndpointOfSelectedLine)
                                                ? Colors.black87
                                                : Colors.white,
                                          ),
                                          const SizedBox(width: 2.0),
                                          Text(
                                            node.effectiveDisplayLabel,
                                            style: TextStyle(
                                              color:
                                                  (isSelected ||
                                                      isEndpointOfSelectedLine)
                                                  ? Colors.black87
                                                  : Colors.white,
                                              fontSize: 7.2,
                                              fontWeight: FontWeight.bold,
                                              decoration: isRejected
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                            ),
                                          ),
                                          if (isHumanAdded) ...[
                                            const SizedBox(width: 1.5),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 2,
                                                    vertical: 0.2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.purpleAccent,
                                                borderRadius:
                                                    BorderRadius.circular(1.5),
                                              ),
                                              child: const Text(
                                                "HUMAN",
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 6.5,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                          if (node.reviewStatus ==
                                              'CONFIRMED') ...[
                                            const SizedBox(width: 1.5),
                                            const Icon(
                                              Icons.check_circle,
                                              size: 8,
                                              color: Colors.greenAccent,
                                            ),
                                          ] else if (node.reviewStatus ==
                                              'SUSPICIOUS') ...[
                                            const SizedBox(width: 1.5),
                                            const Icon(
                                              Icons.warning,
                                              size: 8,
                                              color: Colors.orangeAccent,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      }),

                      // 6. Manual Object Add Drawing Box Indicator
                      if (_dragStart != null && _dragCurrent != null)
                        Positioned(
                          left: math.min(_dragStart!.dx, _dragCurrent!.dx),
                          top: math.min(_dragStart!.dy, _dragCurrent!.dy),
                          width: (_dragStart!.dx - _dragCurrent!.dx).abs(),
                          height: (_dragStart!.dy - _dragCurrent!.dy).abs(),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.purpleAccent,
                                width: 2,
                              ),
                              color: Colors.purpleAccent.withValues(alpha: 0.2),
                            ),
                            child: Center(
                              child: Text(
                                "새 ${widget.manualAddClass.toUpperCase()}",
                                style: const TextStyle(
                                  color: Colors.purpleAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _LeaderLinePainter extends CustomPainter {
  final List<ReviewNodeItem> nodes;
  final List<ReviewLineItem> lines;
  final double scaleX;
  final double scaleY;

  _LeaderLinePainter({
    required this.nodes,
    required this.lines,
    required this.scaleX,
    required this.scaleY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final leaderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.fill;

    // Draw Node Leader Lines
    for (var node in nodes) {
      if (node.labelOffsetDx.abs() > 6 || node.labelOffsetDy.abs() > 6) {
        final bbox = node.bbox;
        if (bbox.length < 4) continue;
        final double cx = bbox[0] * scaleX;
        final double cy = bbox[1] * scaleY;
        final double renderLeft = (bbox[0] - bbox[2] / 2.0) * scaleX;
        final double renderTop = (bbox[1] - bbox[3] / 2.0) * scaleY;

        final double labelX = renderLeft + node.labelOffsetDx + 12;
        final double labelY = renderTop - 12 + node.labelOffsetDy;

        canvas.drawCircle(Offset(cx, cy), 2.5, dotPaint);
        canvas.drawLine(Offset(cx, cy), Offset(labelX, labelY), leaderPaint);
      }
    }

    // Draw Line Leader Lines
    for (var line in lines) {
      if (line.labelOffsetDx.abs() > 6 || line.labelOffsetDy.abs() > 6) {
        if (line.path.length < 2) continue;
        final midIdx = line.path.length ~/ 2;
        final double baseMidX = line.path[midIdx][0] * scaleX;
        final double baseMidY = line.path[midIdx][1] * scaleY;

        final double labelX = baseMidX + line.labelOffsetDx;
        final double labelY = baseMidY - 12 + line.labelOffsetDy;

        canvas.drawCircle(Offset(baseMidX, baseMidY), 2.5, dotPaint);
        canvas.drawLine(
          Offset(baseMidX, baseMidY),
          Offset(labelX, labelY),
          leaderPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LeaderLinePainter oldDelegate) => true;
}

class _ConnectionOverlayPainter extends CustomPainter {
  final List<ReviewLineItem> lines;
  final ReviewLineItem? selectedLine;
  final double scaleX;
  final double scaleY;
  final double pulseValue;

  _ConnectionOverlayPainter({
    required this.lines,
    required this.selectedLine,
    required this.scaleX,
    required this.scaleY,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var line in lines) {
      if (line.path.length < 2) continue;

      final bool isSelected = selectedLine?.lineId == line.lineId;
      final status = line.reviewStatus.toUpperCase();

      Color strokeColor;
      double strokeWidth;

      if (isSelected) {
        strokeColor = Colors.yellowAccent;
        strokeWidth = 3.5 + pulseValue * 1.5;
      } else if (status == 'REJECTED') {
        strokeColor = Colors.grey.withValues(alpha: 0.4);
        strokeWidth = 1.5;
      } else {
        strokeColor = const Color(0xFFE00000); // Solid red for active lines
        strokeWidth = status == 'AMBIGUOUS' ? 3.2 : 2.6;
      }

      final paint = Paint()
        ..color = strokeColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      // Glow effect for selected line with Pulse
      if (isSelected) {
        final glowPaint = Paint()
          ..color = Colors.yellowAccent.withValues(
            alpha: 0.3 + pulseValue * 0.4,
          )
          ..strokeWidth = 8.0 + pulseValue * 6.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

        final pathGlow = Path();
        pathGlow.moveTo(line.path[0][0] * scaleX, line.path[0][1] * scaleY);
        for (int i = 1; i < line.path.length; i++) {
          pathGlow.lineTo(line.path[i][0] * scaleX, line.path[i][1] * scaleY);
        }
        canvas.drawPath(pathGlow, glowPaint);
      }

      final linePath = Path();
      linePath.moveTo(line.path[0][0] * scaleX, line.path[0][1] * scaleY);
      for (int i = 1; i < line.path.length; i++) {
        linePath.lineTo(line.path[i][0] * scaleX, line.path[i][1] * scaleY);
      }
      canvas.drawPath(linePath, paint);

      // Draw endpoint port markers
      final dotPaint = Paint()
        ..color = strokeColor
        ..style = PaintingStyle.fill;

      final startPt = Offset(
        line.path.first[0] * scaleX,
        line.path.first[1] * scaleY,
      );
      final endPt = Offset(
        line.path.last[0] * scaleX,
        line.path.last[1] * scaleY,
      );

      canvas.drawCircle(
        startPt,
        isSelected ? (4.0 + pulseValue * 1.5) : 3.0,
        dotPaint,
      );
      canvas.drawCircle(
        endPt,
        isSelected ? (4.0 + pulseValue * 1.5) : 3.0,
        dotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectionOverlayPainter oldDelegate) => true;
}
