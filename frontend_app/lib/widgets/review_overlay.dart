import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/object_visual_sweep.dart';
import '../models/review_models.dart';

class ReviewOverlayView extends StatefulWidget {
  final Uint8List? imageBytes;
  final String? imageUrl;
  final int originalWidth;
  final int originalHeight;
  final List<ReviewNodeItem> nodes;
  final ReviewNodeItem? selectedNode;
  final String? currentObjectReviewId;
  final bool objectReviewTargetActive;
  final Set<String> visitedObjectIds;

  /// Optional key attached to the selected node's rendered bounding box so a
  /// coaching companion can follow the actual on-screen target.
  final GlobalKey? focusTargetKey;
  final Function(ReviewNodeItem) onSelectNode;
  final Function(String nodeId, double dx, double dy)? onNodeOffsetChanged;
  final bool showNodeLabels;
  final bool showLineLabels;
  final bool busFocusOnly;
  final bool busMappingReview;
  final bool lineFocusOnly;
  final bool linesOnlyMode;

  // Connection Overlay additions
  final List<ReviewLineItem> lines;
  final ReviewLineItem? selectedLine;
  final Function(ReviewLineItem)? onSelectLine;
  final Function(String lineId, double dx, double dy)? onLineOffsetChanged;
  final Set<String> visitedLineIds;

  // Manual Object Mode
  final bool isManualAddMode;
  final String manualAddClass;
  final Function(List<double> bbox, String className)? onManualAddComplete;

  // Manual Line Mode
  final bool isManualAddLineMode;
  final ReviewNodeItem? manualLineStartNode;
  final Function(ReviewNodeItem startNode, ReviewNodeItem endNode)?
  onManualAddLineComplete;

  // Topology Violation Nodes for Warning Visual Cues
  final Set<String> violationNodeIds;

  // Guide Box & Missing Candidate Additions (Object Review V2)
  final Set<String> guideNodeIds;
  final String? currentCoachNodeId;
  final List<MissingCandidateItem> openMissingCandidates;
  final Function(MissingCandidateItem)? onSelectCandidate;
  final bool isObjectCategorySweepActive;
  final String? currentCategoryHighlightKey;

  const ReviewOverlayView({
    super.key,
    required this.imageBytes,
    required this.imageUrl,
    required this.originalWidth,
    required this.originalHeight,
    required this.nodes,
    required this.selectedNode,
    this.currentObjectReviewId,
    this.objectReviewTargetActive = false,
    this.visitedObjectIds = const {},
    this.focusTargetKey,
    required this.onSelectNode,
    this.onNodeOffsetChanged,
    this.showNodeLabels = true,
    this.showLineLabels = true,
    this.busFocusOnly = false,
    this.busMappingReview = false,
    this.lineFocusOnly = false,
    this.linesOnlyMode = false,
    this.lines = const [],
    this.selectedLine,
    this.onSelectLine,
    this.onLineOffsetChanged,
    this.visitedLineIds = const {},
    this.isManualAddMode = false,
    this.manualAddClass = 'bus',
    this.onManualAddComplete,
    this.isManualAddLineMode = false,
    this.manualLineStartNode,
    this.onManualAddLineComplete,
    this.violationNodeIds = const {},
    this.guideNodeIds = const {},
    this.currentCoachNodeId,
    this.openMissingCandidates = const [],
    this.onSelectCandidate,
    this.isObjectCategorySweepActive = false,
    this.currentCategoryHighlightKey,
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
                            busMappingReview: widget.busMappingReview,
                            lineFocusOnly: widget.lineFocusOnly,
                            linesOnlyMode: widget.linesOnlyMode,
                            selectedLineId: widget.selectedLine?.lineId,
                            endpointNodeIds: lineEndpointNodeIds,
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
                              lineFocusOnly: widget.lineFocusOnly,
                              visitedLineIds: widget.visitedLineIds,
                            ),
                          ),
                        ),

                      // 4. Line Display Label Badges (Draggable at Midpoints)
                      if (widget.showLineLabels)
                        ...widget.lines.map((line) {
                          if (widget.busFocusOnly ||
                              (widget.lineFocusOnly &&
                                  widget.selectedLine != null &&
                                  widget.selectedLine?.lineId != line.lineId)) {
                            return const SizedBox.shrink();
                          }
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
                                        : const Color(
                                            0xFFB71C1C,
                                          ).withValues(alpha: 0.9),
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

                      // 4.5. Broad Candidate Guide Regions (for OPEN missing candidates with approximateRegion)
                      if (widget.openMissingCandidates.isNotEmpty)
                        ...widget.openMissingCandidates
                            .where(
                              (c) =>
                                  c.status == 'OPEN' &&
                                  c.approximateRegion != null &&
                                  c.approximateRegion!.length >= 4,
                            )
                            .map((cand) {
                              final region = cand.approximateRegion!;
                              final double cx = region[0];
                              final double cy = region[1];
                              final double w = region[2];
                              final double h = region[3];

                              final double renderLeft = (cx - w / 2.0) * scaleX;
                              final double renderTop = (cy - h / 2.0) * scaleY;
                              final double renderW = math.max(20.0, w * scaleX);
                              final double renderH = math.max(20.0, h * scaleY);

                              final double padX = math.max(8.0, renderW * 0.15);
                              final double padY = math.max(8.0, renderH * 0.15);

                              return Positioned(
                                left: renderLeft - padX,
                                top: renderTop - padY,
                                width: renderW + 2 * padX,
                                height: renderH + 2 * padY,
                                child: GestureDetector(
                                  onTap: () =>
                                      widget.onSelectCandidate?.call(cand),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.purpleAccent.withValues(
                                        alpha: 0.08 + 0.05 * pulseVal,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: Colors.purpleAccent.withValues(
                                          alpha: 0.85,
                                        ),
                                        width: 1.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.purpleAccent.withValues(
                                            alpha: 0.3 * pulseVal,
                                          ),
                                          blurRadius: 8.0,
                                          spreadRadius: 2.0,
                                        ),
                                      ],
                                    ),
                                    child: Align(
                                      alignment: Alignment.topLeft,
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          top: 1,
                                          left: 2,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.shade900
                                              .withValues(alpha: 0.9),
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                        child: Text(
                                          '누락 의심: ${cand.suspectedClass.toUpperCase()}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 7.5,
                                            fontWeight: FontWeight.bold,
                                          ),
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
                        final bool isCurrentObjectTarget =
                            widget.objectReviewTargetActive &&
                            widget.currentObjectReviewId == node.id;
                        final bool isVisitedObject =
                            widget.objectReviewTargetActive &&
                            widget.visitedObjectIds.contains(node.id) &&
                            !isCurrentObjectTarget;
                        final bool isSelectedForNodeStyle =
                            widget.objectReviewTargetActive
                            ? isCurrentObjectTarget
                            : isSelected;
                        final Color selectionColor =
                            widget.objectReviewTargetActive
                            ? Colors.cyanAccent
                            : Colors.yellowAccent;
                        final bool isEndpointOfSelectedLine =
                            lineEndpointNodeIds.contains(node.id);
                        final bool isViolation = widget.violationNodeIds
                            .contains(node.id);
                        final bool isBus =
                            node.className.toLowerCase() == 'bus';
                        final bool isCurrentCategory =
                            widget.isObjectCategorySweepActive &&
                            widget.currentCategoryHighlightKey != null &&
                            node.className.toLowerCase() ==
                                widget.currentCategoryHighlightKey!
                                    .toLowerCase();
                        final bool isAllCategoryOverview =
                            widget.isObjectCategorySweepActive &&
                            widget.currentCategoryHighlightKey == null;
                        final bool isGuide =
                            isCurrentCategory ||
                            (isBus
                                ? (widget.guideNodeIds.contains(node.id) ||
                                      isCurrentObjectTarget)
                                : (widget.guideNodeIds.contains(node.id) ||
                                      node.reviewStatus == 'SUSPICIOUS' ||
                                      isCurrentObjectTarget));
                        final bool isCurrentBusGuide =
                            isBus && widget.currentCoachNodeId == node.id;

                        double padX;
                        double padY;
                        if (isCurrentCategory) {
                          padX = (renderW * 0.18).clamp(8.0, 14.0);
                          padY = (renderH * 0.18).clamp(8.0, 14.0);
                        } else if (isBus) {
                          padX = 0.0;
                          padY = 0.0;
                        } else {
                          padX = math.max(6.0, renderW * 0.15);
                          padY = math.max(6.0, renderH * 0.15);
                        }
                        final double guideLeft = renderLeft - padX;
                        final double guideTop = renderTop - padY;
                        final double guideW = renderW + 2 * padX;
                        final double guideH = renderH + 2 * padY;

                        final double nodeDimOpacity = (widget.linesOnlyMode)
                            ? (isBus ? 0.12 : 0.025)
                            : (widget.busFocusOnly && !isBus)
                            ? 0.02
                            : (widget.lineFocusOnly &&
                                  widget.selectedLine != null &&
                                  !isEndpointOfSelectedLine &&
                                  !isSelected)
                            ? 0.0
                            : (widget.isObjectCategorySweepActive &&
                                  widget.currentCategoryHighlightKey != null &&
                                  !isCurrentCategory)
                            ? 0.38
                            : 1.0;

                        final Color classColor = _getClassColor(node.className);
                        final Color statusColor = _getStatusColor(
                          node.reviewStatus,
                        );

                        final bool isBusCallout = isBus;
                        double labelBaseX = isBusCallout
                            ? renderLeft + renderW + 8 + node.labelOffsetDx
                            : renderLeft + node.labelOffsetDx;
                        double labelBaseY = isBusCallout
                            ? renderTop + renderH / 2 - 8 + node.labelOffsetDy
                            : renderTop -
                                  (isCurrentCategory
                                      ? (padY + 16)
                                      : (widget.busFocusOnly &&
                                                isBus &&
                                                isSelected
                                            ? 20
                                            : 12)) +
                                  node.labelOffsetDy;
                        if (isBusCallout && labelBaseX + 112 > renderedW) {
                          labelBaseX = renderLeft - 112 + node.labelOffsetDx;
                        }
                        labelBaseX = labelBaseX
                            .clamp(2.0, math.max(2.0, renderedW - 112))
                            .toDouble();
                        labelBaseY = labelBaseY
                            .clamp(2.0, math.max(2.0, renderedH - 22))
                            .toDouble();

                        final bool isHumanAdded = node.source.contains(
                          'human_added',
                        );
                        final bool isRejected = node.reviewStatus == 'REJECTED';

                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // AI Guide Box (Padded soft glowing highlight for suspicious / focus targets)
                            if (isGuide)
                              Positioned(
                                key: ValueKey('ObjectGuideBox_${node.id}'),
                                left: guideLeft,
                                top: guideTop,
                                width: guideW,
                                height: guideH,
                                child: GestureDetector(
                                  key: isBus
                                      ? ValueKey('BusGuideBox_${node.id}')
                                      : null,
                                  onTap: () => widget.onSelectNode(node),
                                  child: isCurrentCategory
                                      ? Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            CustomPaint(
                                              size: Size(guideW, guideH),
                                              painter: _ObjectGuideBoxPainter(
                                                borderColor:
                                                    objectCategoryColor(
                                                      node.className,
                                                    ),
                                                glowColor: objectCategoryColor(
                                                  node.className,
                                                ),
                                                borderWidth: isSelected
                                                    ? 3.2
                                                    : 2.2,
                                                pulseVal: pulseVal,
                                                borderRadius: 4.0,
                                              ),
                                            ),
                                            if (isSelected)
                                              Positioned(
                                                top: -6,
                                                right: -6,
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: objectCategoryColor(
                                                      node.className,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha: 0.35,
                                                            ),
                                                        blurRadius: 3,
                                                      ),
                                                    ],
                                                  ),
                                                  child: const Text(
                                                    '선택됨',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        )
                                      : Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                            border: Border.all(
                                              color:
                                                  (isCurrentObjectTarget ||
                                                      isCurrentBusGuide)
                                                  ? const Color(0xFF06B6D4)
                                                  : isBus
                                                  ? (widget.busFocusOnly
                                                        ? Colors.transparent
                                                        : const Color(
                                                            0xFF2563EB,
                                                          ))
                                                  : Colors.amberAccent,
                                              width: isBus ? 1.4 : 1.6,
                                            ),
                                            boxShadow: isBus
                                                ? const <BoxShadow>[]
                                                : [
                                                    BoxShadow(
                                                      color:
                                                          (isCurrentObjectTarget ||
                                                                      isCurrentBusGuide
                                                                  ? const Color(
                                                                      0xFF06B6D4,
                                                                    )
                                                                  : Colors
                                                                        .amberAccent)
                                                              .withValues(
                                                                alpha:
                                                                    0.3 +
                                                                    0.35 *
                                                                        pulseVal,
                                                              ),
                                                      blurRadius:
                                                          6.0 + 4.0 * pulseVal,
                                                      spreadRadius: 1.5,
                                                    ),
                                                  ],
                                          ),
                                          child: Align(
                                            alignment: Alignment.topRight,
                                            child: Container(
                                              margin: const EdgeInsets.only(
                                                top: 1,
                                                right: 2,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 3,
                                                    vertical: 0.5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: isCurrentObjectTarget
                                                    ? const Color(0xFF0891B2)
                                                    : isCurrentBusGuide
                                                    ? const Color(0xFF0891B2)
                                                    : isBus
                                                    ? const Color(0xFF2563EB)
                                                    : const Color(0xFFD97706),
                                                borderRadius:
                                                    BorderRadius.circular(2),
                                              ),
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.help_outline,
                                                      size: 7.5,
                                                      color: Colors.white,
                                                    ),
                                                    const SizedBox(width: 1.5),
                                                    Text(
                                                      isCurrentObjectTarget
                                                          ? '현재 확인할 객체'
                                                          : isCurrentBusGuide
                                                          ? 'Lensy가 가리키는 모선'
                                                          : isBus
                                                          ? '번호 확인 필요'
                                                          : '확인 필요',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 6.8,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                ),
                              ),

                            // Bounding Box Rect
                            Positioned(
                              key: isSelectedForNodeStyle
                                  ? widget.focusTargetKey
                                  : null,
                              left: renderLeft,
                              top: renderTop,
                              child: Opacity(
                                opacity: nodeDimOpacity,
                                child: GestureDetector(
                                  onTap: () {
                                    if (widget.isManualAddLineMode) {
                                      if (widget.manualLineStartNode == null) {
                                        widget.onSelectNode(node);
                                      } else if (widget
                                              .manualLineStartNode!
                                              .id !=
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
                                    key: ValueKey('ObjectTightBox_${node.id}'),
                                    width: renderW,
                                    height: renderH,
                                    decoration: BoxDecoration(
                                      color:
                                          (widget.isObjectCategorySweepActive ||
                                              isAllCategoryOverview ||
                                              (widget.busFocusOnly && isBus))
                                          ? Colors.transparent
                                          : (isSelectedForNodeStyle
                                                ? selectionColor.withValues(
                                                    alpha:
                                                        0.2 + 0.15 * pulseVal,
                                                  )
                                                : (isViolation
                                                      ? Colors.redAccent
                                                            .withValues(
                                                              alpha:
                                                                  0.25 +
                                                                  0.2 *
                                                                      pulseVal,
                                                            )
                                                      : (isEndpointOfSelectedLine
                                                            ? const Color(
                                                                0xFFFFB300,
                                                              ).withValues(
                                                                alpha:
                                                                    0.25 +
                                                                    0.2 *
                                                                        pulseVal,
                                                              )
                                                            : (isVisitedObject
                                                                  ? const Color(
                                                                      0xFFF59E0B,
                                                                    ).withValues(
                                                                      alpha:
                                                                          0.08,
                                                                    )
                                                                  : classColor
                                                                        .withValues(
                                                                          alpha:
                                                                              0.08,
                                                                        ))))),
                                      border: Border.all(
                                        color: (widget.busFocusOnly && isBus)
                                            ? const Color(0xFF2563EB)
                                            : (isAllCategoryOverview
                                                  ? classColor
                                                  : (widget.isObjectCategorySweepActive
                                                        ? (isCurrentCategory
                                                              ? (isSelected
                                                                    ? objectCategoryColor(
                                                                        node.className,
                                                                      )
                                                                    : objectCategoryColor(
                                                                        node.className,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.4,
                                                                      ))
                                                              : classColor
                                                                    .withValues(
                                                                      alpha:
                                                                          0.25,
                                                                    ))
                                                        : (isSelectedForNodeStyle
                                                              ? selectionColor
                                                              : (isViolation
                                                                    ? Colors
                                                                          .redAccent
                                                                    : (isEndpointOfSelectedLine
                                                                          ? const Color(
                                                                              0xFFFFB300,
                                                                            )
                                                                          : (isRejected
                                                                                ? Colors.redAccent
                                                                                : (isVisitedObject
                                                                                      ? const Color(
                                                                                          0xFFF59E0B,
                                                                                        )
                                                                                      : classColor))))))),
                                        width: (widget.busFocusOnly && isBus)
                                            ? (isSelected ? 2.2 : 1.4)
                                            : (isAllCategoryOverview
                                                  ? 1.5
                                                  : (widget.isObjectCategorySweepActive
                                                        ? (isCurrentCategory
                                                              ? 1.0
                                                              : 0.8)
                                                        : (isSelectedForNodeStyle
                                                              ? (2.0 +
                                                                    1.2 *
                                                                        pulseVal)
                                                              : (isVisitedObject
                                                                    ? 1.5
                                                                    : (isViolation
                                                                          ? (2.2 +
                                                                                1.5 *
                                                                                    pulseVal)
                                                                          : (isEndpointOfSelectedLine
                                                                                ? (2.2 +
                                                                                      1.8 *
                                                                                          pulseVal)
                                                                                : 1.2)))))),
                                      ),
                                      borderRadius: BorderRadius.circular(2),
                                      boxShadow:
                                          (widget.isObjectCategorySweepActive ||
                                              isAllCategoryOverview ||
                                              (widget.busFocusOnly && isBus))
                                          ? const <BoxShadow>[]
                                          : (isSelectedForNodeStyle
                                                ? [
                                                    BoxShadow(
                                                      color: selectionColor
                                                          .withValues(
                                                            alpha:
                                                                0.5 +
                                                                0.4 * pulseVal,
                                                          ),
                                                      blurRadius:
                                                          6.0 + 6.0 * pulseVal,
                                                      spreadRadius:
                                                          1.0 + 1.5 * pulseVal,
                                                    ),
                                                  ]
                                                : (isViolation
                                                      ? [
                                                          BoxShadow(
                                                            color: Colors
                                                                .redAccent
                                                                .withValues(
                                                                  alpha:
                                                                      0.6 +
                                                                      0.35 *
                                                                          pulseVal,
                                                                ),
                                                            blurRadius:
                                                                8.0 +
                                                                8.0 * pulseVal,
                                                            spreadRadius:
                                                                2.0 +
                                                                2.0 * pulseVal,
                                                          ),
                                                        ]
                                                      : (isEndpointOfSelectedLine
                                                            ? [
                                                                BoxShadow(
                                                                  color:
                                                                      const Color(
                                                                        0xFFFFB300,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.6 +
                                                                            0.35 *
                                                                                pulseVal,
                                                                      ),
                                                                  blurRadius:
                                                                      8.0 +
                                                                      8.0 *
                                                                          pulseVal,
                                                                  spreadRadius:
                                                                      2.0 +
                                                                      2.0 *
                                                                          pulseVal,
                                                                ),
                                                              ]
                                                            : null))),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Draggable Label Badge
                            if (widget.showNodeLabels &&
                                !widget.linesOnlyMode &&
                                (nodeDimOpacity >= 0.5 ||
                                    isSelectedForNodeStyle))
                              Positioned(
                                left: labelBaseX,
                                top: labelBaseY,
                                child: Opacity(
                                  opacity: nodeDimOpacity,
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
                                        padding: EdgeInsets.symmetric(
                                          horizontal:
                                              (widget.busFocusOnly &&
                                                  isBus &&
                                                  isSelected)
                                              ? 6.0
                                              : 2.5,
                                          vertical:
                                              (widget.busFocusOnly &&
                                                  isBus &&
                                                  isSelected)
                                              ? 2.5
                                              : 0.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color:
                                              (widget.busFocusOnly &&
                                                  isBus &&
                                                  isSelected)
                                              ? const Color(0xFF2563EB)
                                              : (isSelectedForNodeStyle
                                                    ? selectionColor
                                                    : (isViolation
                                                          ? Colors.redAccent
                                                          : (isEndpointOfSelectedLine
                                                                ? const Color(
                                                                    0xFFFFB300,
                                                                  )
                                                                : classColor
                                                                      .withValues(
                                                                        alpha:
                                                                            0.92,
                                                                      )))),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: isSelectedForNodeStyle
                                                ? (widget.busFocusOnly && isBus
                                                      ? Colors.white
                                                      : Colors.orangeAccent)
                                                : (isViolation
                                                      ? Colors.white
                                                      : (isEndpointOfSelectedLine
                                                            ? Colors.white
                                                            : statusColor)),
                                            width: isSelectedForNodeStyle
                                                ? 1.5
                                                : (isViolation ||
                                                          isEndpointOfSelectedLine
                                                      ? (1.2 + 0.8 * pulseVal)
                                                      : 0.6),
                                          ),
                                          boxShadow:
                                              (widget.busFocusOnly &&
                                                  isBus &&
                                                  isSelected)
                                              ? [
                                                  BoxShadow(
                                                    color: const Color(
                                                      0xFF2563EB,
                                                    ).withValues(alpha: 0.6),
                                                    blurRadius: 8.0,
                                                    spreadRadius: 1.5,
                                                  ),
                                                ]
                                              : (isEndpointOfSelectedLine ||
                                                        isViolation
                                                    ? [
                                                        BoxShadow(
                                                          color:
                                                              (isViolation
                                                                      ? Colors
                                                                            .redAccent
                                                                      : const Color(
                                                                          0xFFFFB300,
                                                                        ))
                                                                  .withValues(
                                                                    alpha:
                                                                        0.6 *
                                                                        pulseVal,
                                                                  ),
                                                          blurRadius:
                                                              4.0 +
                                                              4.0 * pulseVal,
                                                        ),
                                                      ]
                                                    : null),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _getClassIcon(node.className),
                                              size:
                                                  (widget.busFocusOnly &&
                                                      isBus &&
                                                      isSelected)
                                                  ? 12.0
                                                  : 8.0,
                                              color:
                                                  (widget.busFocusOnly &&
                                                      isBus &&
                                                      isSelected)
                                                  ? Colors.white
                                                  : ((isSelected ||
                                                            isEndpointOfSelectedLine)
                                                        ? Colors.black87
                                                        : Colors.white),
                                            ),
                                            const SizedBox(width: 2.0),
                                            Text(
                                              (widget.busFocusOnly &&
                                                      isBus &&
                                                      isSelected)
                                                  ? "Bus #${node.busNumber ?? node.id}"
                                                  : node.effectiveDisplayLabel,
                                              style: TextStyle(
                                                color:
                                                    (widget.busFocusOnly &&
                                                        isBus &&
                                                        isSelected)
                                                    ? Colors.white
                                                    : ((isSelected ||
                                                              isEndpointOfSelectedLine)
                                                          ? Colors.black87
                                                          : Colors.white),
                                                fontSize:
                                                    (widget.busFocusOnly &&
                                                        isBus &&
                                                        isSelected)
                                                    ? 11.0
                                                    : 7.2,
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
                                                      BorderRadius.circular(
                                                        1.5,
                                                      ),
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
  final bool busMappingReview;
  final bool lineFocusOnly;
  final bool linesOnlyMode;
  final String? selectedLineId;
  final Set<String> endpointNodeIds;

  _LeaderLinePainter({
    required this.nodes,
    required this.lines,
    required this.scaleX,
    required this.scaleY,
    this.busMappingReview = false,
    this.lineFocusOnly = false,
    this.linesOnlyMode = false,
    this.selectedLineId,
    this.endpointNodeIds = const {},
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
      if (linesOnlyMode) continue;
      final isBus = node.className.trim().toLowerCase() == 'bus';
      if (busMappingReview && !isBus) continue;
      if (lineFocusOnly &&
          selectedLineId != null &&
          !endpointNodeIds.contains(node.id)) {
        continue;
      }
      if (node.labelOffsetDx.abs() > 6 || node.labelOffsetDy.abs() > 6) {
        final bbox = node.bbox;
        if (bbox.length < 4) continue;
        final double cx = bbox[0] * scaleX;
        final double cy = bbox[1] * scaleY;
        final double renderLeft = (bbox[0] - bbox[2] / 2.0) * scaleX;
        final double renderTop = (bbox[1] - bbox[3] / 2.0) * scaleY;

        if (busMappingReview && isBus) {
          const labelWidth = 112.0;
          var labelX = renderLeft + bbox[2] * scaleX + 8 + node.labelOffsetDx;
          final labelOnLeft = labelX + labelWidth > size.width;
          if (labelOnLeft) {
            labelX = renderLeft - labelWidth + node.labelOffsetDx;
          }
          labelX = labelX
              .clamp(2.0, math.max(2.0, size.width - labelWidth))
              .toDouble();
          final labelY =
              (renderTop + bbox[3] * scaleY / 2 - 8 + node.labelOffsetDy)
                  .clamp(2.0, math.max(2.0, size.height - 22))
                  .toDouble();
          final labelAnchor = Offset(
            labelOnLeft ? labelX + labelWidth : labelX,
            labelY + 8,
          );
          _drawBusMappingLeader(canvas, Offset(cx, cy), labelAnchor);
          canvas.drawCircle(
            Offset(cx, cy),
            3.2,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(
            Offset(cx, cy),
            2.0,
            Paint()
              ..color = Colors.black
              ..style = PaintingStyle.fill,
          );
        } else {
          final double labelX = renderLeft + node.labelOffsetDx + 12;
          final double labelY = renderTop - 12 + node.labelOffsetDy;
          canvas.drawCircle(Offset(cx, cy), 2.5, dotPaint);
          canvas.drawLine(Offset(cx, cy), Offset(labelX, labelY), leaderPaint);
        }
      }
    }

    // Draw Line Leader Lines
    if (!busMappingReview) {
      for (var line in lines) {
        if (lineFocusOnly &&
            selectedLineId != null &&
            line.lineId != selectedLineId) {
          continue;
        }
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
  }

  void _drawBusMappingLeader(Canvas canvas, Offset start, Offset end) {
    final delta = end - start;
    final distance = delta.distance;
    if (distance == 0) return;

    final dashedPath = Path();
    const dashLength = 4.5;
    const dashAndGap = 7.5;
    for (var offset = 0.0; offset < distance; offset += dashAndGap) {
      final dashEnd = math.min(offset + dashLength, distance);
      dashedPath
        ..moveTo(
          start.dx + delta.dx * (offset / distance),
          start.dy + delta.dy * (offset / distance),
        )
        ..lineTo(
          start.dx + delta.dx * (dashEnd / distance),
          start.dy + delta.dy * (dashEnd / distance),
        );
    }
    canvas.drawPath(
      dashedPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 3.2
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      dashedPath,
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _LeaderLinePainter oldDelegate) => true;
}

class _ConnectionOverlayPainter extends CustomPainter {
  static const Color _endpointHighlightColor = Color(0xFFFFB300);

  final List<ReviewLineItem> lines;
  final ReviewLineItem? selectedLine;
  final double scaleX;
  final double scaleY;
  final double pulseValue;
  final bool lineFocusOnly;
  final Set<String> visitedLineIds;

  _ConnectionOverlayPainter({
    required this.lines,
    required this.selectedLine,
    required this.scaleX,
    required this.scaleY,
    required this.pulseValue,
    this.lineFocusOnly = false,
    this.visitedLineIds = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var line in lines) {
      if (line.path.length < 2) continue;

      final bool isSelected = selectedLine?.lineId == line.lineId;
      final bool isVisited =
          visitedLineIds.contains(line.lineId) && !isSelected;
      final status = line.reviewStatus.toUpperCase();

      Color strokeColor;
      double strokeWidth;

      if (isSelected) {
        strokeColor = Colors.cyanAccent;
        strokeWidth = 4.2 + pulseValue * 1.5;
      } else if (isVisited) {
        strokeColor = const Color(0xFFF59E0B);
        strokeWidth = 3.2;
      } else if (ConnectionReviewGateEvaluator.lineHasCriticalIssue(line)) {
        strokeColor = const Color(0xFFDC2626); // critical electrical error
        strokeWidth = isSelected ? 4.2 + pulseValue * 1.5 : 3.2;
      } else if (ConnectionReviewGateEvaluator.isUnresolvedCrossing(line)) {
        strokeColor = const Color(0xFF9333EA); // actual crossing evidence
        strokeWidth = isSelected ? 4.2 + pulseValue * 1.5 : 3.2;
      } else if (status == 'AMBIGUOUS') {
        strokeColor = const Color(0xFFD97706); // endpoint uncertainty
        strokeWidth = isSelected ? 4.2 + pulseValue * 1.5 : 3.2;
      } else if (status == 'REJECTED') {
        strokeColor = Colors.grey.withValues(alpha: 0.4);
        strokeWidth = 1.5;
      } else {
        strokeColor = const Color(0xFF64748B); // neutral, auto-accepted line
        strokeWidth = isSelected ? 4.2 + pulseValue * 1.5 : 2.2;
      }

      if (lineFocusOnly && selectedLine != null && !isSelected && !isVisited) {
        strokeColor = Colors.grey.withValues(alpha: 0.18);
        strokeWidth = 1.0;
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
          ..color = Colors.cyanAccent.withValues(alpha: 0.3 + pulseValue * 0.4)
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
      final startPt = Offset(
        line.path.first[0] * scaleX,
        line.path.first[1] * scaleY,
      );
      final endPt = Offset(
        line.path.last[0] * scaleX,
        line.path.last[1] * scaleY,
      );

      if (isSelected) {
        final endpointRadius = 4.0 + pulseValue * 1.5;
        final endpointRingPaint = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill;
        final endpointFillPaint = Paint()
          ..color = _endpointHighlightColor
          ..style = PaintingStyle.fill;
        for (final point in [startPt, endPt]) {
          canvas.drawCircle(point, endpointRadius + 1.8, endpointRingPaint);
          canvas.drawCircle(point, endpointRadius, endpointFillPaint);
        }
      } else {
        final dotPaint = Paint()
          ..color = strokeColor
          ..style = PaintingStyle.fill;
        canvas.drawCircle(startPt, 3.0, dotPaint);
        canvas.drawCircle(endPt, 3.0, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectionOverlayPainter oldDelegate) => true;
}

class _ObjectGuideBoxPainter extends CustomPainter {
  final Color borderColor;
  final Color glowColor;
  final double borderWidth;
  final double pulseVal;
  final double borderRadius;

  const _ObjectGuideBoxPainter({
    required this.borderColor,
    required this.glowColor,
    required this.borderWidth,
    required this.pulseVal,
    this.borderRadius = 4.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    // Outer glow ONLY with BlurStyle.outer: interior remains 100% transparent!
    final glowPaint = Paint()
      ..color = glowColor.withValues(alpha: 0.35 + 0.35 * pulseVal)
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth + 1.2
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, 5.0 + 4.0 * pulseVal);
    canvas.drawRRect(rrect, glowPaint);

    // Sharp outer border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ObjectGuideBoxPainter oldDelegate) {
    return oldDelegate.pulseVal != pulseVal ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}
