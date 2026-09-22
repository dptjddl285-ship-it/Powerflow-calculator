import 'dart:math' as math;
import 'package:flutter/material.dart';

class PowerLensAIFloatingButton extends StatefulWidget {
  final VoidCallback onPressed;
  final bool isOpen;
  final bool isMobile;
  final int? alertCount;
  final String? speechBubbleText;
  final String presenceState;

  /// Semantic screen target used to move Lensy beside the control it is
  /// talking about.  The parent screen animates the outer position; this
  /// value lets the mascot show a matching pointing cue.
  final String coachTarget;
  final String? coachMessage;
  final ValueChanged<Offset>? onDragDelta;

  const PowerLensAIFloatingButton({
    super.key,
    required this.onPressed,
    this.isOpen = false,
    this.isMobile = false,
    this.alertCount,
    this.speechBubbleText,
    this.presenceState = 'idle',
    this.coachTarget = 'floating',
    this.coachMessage,
    this.onDragDelta,
  });

  @override
  State<PowerLensAIFloatingButton> createState() =>
      _PowerLensAIFloatingButtonState();
}

class _PowerLensAIFloatingButtonState extends State<PowerLensAIFloatingButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  bool _speechDismissed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bubbleText =
        widget.coachMessage ??
        widget.speechBubbleText ??
        "도면 사진으로 시작할까요? 샘플로 체험할까요? ⚡";
    final presenceColor = _presenceColor;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: widget.onDragDelta == null
          ? null
          : (details) => widget.onDragDelta!(details.delta),
      child: AnimatedBuilder(
        animation: _animController,
        builder: (context, child) {
        final double t = _animController.value;
        // Floating hover offset (-7px to +7px)
        final state = widget.presenceState.toLowerCase();
        final double hoverY = state == 'thinking'
            ? -3.0 * math.sin(t * 4 * math.pi)
            : (state == 'success'
                  ? -10.0 * math.sin(t * 2 * math.pi)
                  : -7.0 * math.sin(t * 2 * math.pi));
        // Shadow scale: larger when close to ground, smaller when floating high
        final double shadowScale = 0.85 + 0.15 * math.cos(t * 2 * math.pi);
        // Blinking phase (blinks closed for 10% of cycle)
        final bool isBlinking = (t > 0.45 && t < 0.52);

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Speech Bubble (shown if not open and not dismissed)
            if (!widget.isOpen && !_speechDismissed) ...[
              GestureDetector(
                onTap: widget.onPressed,
                child: Container(
                  margin: const EdgeInsets.only(right: 12, bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: widget.isMobile ? 210 : 270,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                      bottomRight: Radius.circular(4),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.25),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                    border: Border.all(
                      color: const Color(0xFF38BDF8),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.tips_and_updates,
                          size: 14,
                          color: Colors.amberAccent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          bubbleText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => setState(() => _speechDismissed = true),
                        child: const Padding(
                          padding: EdgeInsets.all(2.0),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Living Mascot Character
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Floating Robot
                Transform.translate(
                  offset: Offset(0, hoverY),
                  child: GestureDetector(
                    onTap: widget.onPressed,
                    child: Tooltip(
                      message: "PowerLens AI 도우미 (클릭하여 대화하기)",
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: presenceColor, width: 1.8),
                          boxShadow: [
                            BoxShadow(
                              color: presenceColor.withValues(alpha: 0.45),
                              blurRadius: 16,
                              spreadRadius: 2,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Lensy stays a recognizable full-body companion.
                            // The desktop default intentionally has no permanent
                            // title/card copy; the contextual speech bubble is
                            // the only explanatory surface.
                            _buildRobotCharacter(t, isBlinking),
                            const SizedBox(width: 4),
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: presenceColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: presenceColor.withValues(alpha: 0.75),
                                    blurRadius: 7,
                                  ),
                                ],
                              ),
                            ),

                            if (widget.alertCount != null &&
                                widget.alertCount! > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.amberAccent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  "${widget.alertCount}",
                                  style: const TextStyle(
                                    color: Color(0xFF0F172A),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
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

                const SizedBox(height: 4),

                // Ground Soft Hover Shadow
                Transform.scale(
                  scaleX: shadowScale,
                  scaleY: 0.6,
                  child: Container(
                    width: widget.isMobile ? 36 : 60,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35 * shadowScale),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
        },
      ),
    );
  }

  Color get _presenceColor {
    switch (widget.presenceState.toLowerCase()) {
      case 'thinking':
        return const Color(0xFFF59E0B);
      case 'speaking':
        return const Color(0xFF38BDF8);
      case 'pointing':
        return const Color(0xFFA78BFA);
      case 'success':
        return const Color(0xFF22C55E);
      case 'blocked':
        return const Color(0xFFFB7185);
      default:
        return const Color(0xFF38BDF8);
    }
  }

  Widget _buildRobotCharacter(double t, bool isBlinking) {
    final stateColor = _presenceColor;

    return SizedBox(
      width: 76,
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: 0, left: 16, child: _buildRobotHead(t, isBlinking)),
          // Torso panel.
          Positioned(
            top: 40,
            left: 27,
            child: Container(
              width: 25,
              height: 25,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [stateColor, const Color(0xFF1D4ED8)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Colors.white38, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: stateColor.withValues(alpha: 0.28),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.bolt, size: 13, color: Colors.white),
              ),
            ),
          ),
          // Natural resting arms
          Positioned(
            top: 46,
            left: 49,
            child: Transform.rotate(
              angle: 0.35,
              child: Container(
                width: 17,
                height: 6,
                decoration: BoxDecoration(
                  color: stateColor,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white38, width: 0.8),
                ),
              ),
            ),
          ),
          Positioned(
            top: 46,
            left: 8,
            child: Transform.rotate(
              angle: -0.35,
              child: Container(
                width: 17,
                height: 6,
                decoration: BoxDecoration(
                  color: stateColor,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white38, width: 0.8),
                ),
              ),
            ),
          ),
          // Two feet make the silhouette read as a companion rather than a
          // floating head icon.
          Positioned(
            top: 64,
            left: 28,
            child: Container(
              width: 8,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
          Positioned(
            top: 64,
            left: 43,
            child: Container(
              width: 8,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRobotHead(double t, bool isBlinking) {
    // Antenna spark pulse
    final double sparkAlpha = 0.5 + 0.5 * math.sin(t * 4 * math.pi);
    final state = widget.presenceState.toLowerCase();
    final stateColor = _presenceColor;
    final isThinking = state == 'thinking';
    final isSpeaking = state == 'speaking';
    final isSuccess = state == 'success';

    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Antenna with glowing tip
          Positioned(
            top: -6,
            child: Column(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.amberAccent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.amberAccent.withValues(alpha: sparkAlpha),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                Container(width: 2, height: 6, color: const Color(0xFF94A3B8)),
              ],
            ),
          ),

          // Head Body
          Transform.rotate(
            angle: isThinking ? 0.04 * math.sin(t * 4 * math.pi) : 0,
            child: Container(
              width: 38,
              height: 34,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [stateColor, const Color(0xFF2563EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white38, width: 1.2),
                boxShadow: isSuccess
                    ? [
                        BoxShadow(
                          color: stateColor.withValues(alpha: 0.65),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Visor Screen
                  Container(
                    width: 28,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B132B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF1C2541),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildEye(
                          isBlinking || isThinking && (t > 0.45 && t < 0.65),
                        ),
                        _buildEye(
                          isBlinking || isThinking && (t > 0.45 && t < 0.65),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 2,
                    child: CustomPaint(
                      size: const Size(10, 4),
                      painter: _MascotMouthPainter(
                        color: stateColor,
                        speaking: isSpeaking,
                        success: isSuccess,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (isThinking)
            Positioned(
              right: -7,
              top: 11,
              child: Icon(Icons.more_horiz, size: 16, color: stateColor),
            ),
          if (isSuccess)
            Positioned(
              right: -8,
              top: -1,
              child: Icon(Icons.check_circle, size: 14, color: stateColor),
            ),

          // Ear bolts
          Positioned(
            left: -2,
            child: Container(
              width: 4,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Positioned(
            right: -2,
            child: Container(
              width: 4,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEye(bool isBlinking) {
    if (isBlinking) {
      return Container(
        width: 6,
        height: 2,
        decoration: BoxDecoration(
          color: const Color(0xFF38BDF8),
          borderRadius: BorderRadius.circular(1),
        ),
      );
    }
    return Container(
      width: 5,
      height: 7,
      decoration: BoxDecoration(
        color: const Color(0xFF38BDF8),
        borderRadius: BorderRadius.circular(3),
        boxShadow: const [BoxShadow(color: Color(0xFF38BDF8), blurRadius: 4)],
      ),
    );
  }
}

class _MascotMouthPainter extends CustomPainter {
  final Color color;
  final bool speaking;
  final bool success;

  const _MascotMouthPainter({
    required this.color,
    this.speaking = false,
    this.success = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    if (success) {
      path
        ..moveTo(1, 1)
        ..quadraticBezierTo(size.width / 2, size.height + 1, size.width - 1, 1);
    } else if (speaking) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: size.width * 0.55,
          height: size.height,
        ),
        paint,
      );
      return;
    } else {
      path
        ..moveTo(1, 1)
        ..lineTo(size.width - 1, 1);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MascotMouthPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.speaking != speaking ||
        oldDelegate.success != success;
  }
}
