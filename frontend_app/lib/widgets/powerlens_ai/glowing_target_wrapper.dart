import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/powerlens_ai_service.dart';

/// Wraps any widget and produces an animated sparkling / glowing aura
/// when [targetId] matches [PowerLensAIService.instance.activeHighlightTarget].
class GlowingTargetWrapper extends StatefulWidget {
  final String targetId;
  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry padding;
  final String? guideLabel;

  const GlowingTargetWrapper({
    super.key,
    required this.targetId,
    required this.child,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.guideLabel,
  });

  @override
  State<GlowingTargetWrapper> createState() => _GlowingTargetWrapperState();
}

class _GlowingTargetWrapperState extends State<GlowingTargetWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  bool _isHighlighted = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _checkHighlight();
    PowerLensAIService.instance.activeHighlightTarget.addListener(_onHighlightChanged);
  }

  @override
  void didUpdateWidget(covariant GlowingTargetWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId) {
      _checkHighlight();
    }
  }

  void _onHighlightChanged() {
    _checkHighlight();
  }

  void _checkHighlight() {
    final active = PowerLensAIService.instance.activeHighlightTarget.value;
    final shouldHighlight = active != null && active == widget.targetId;
    if (shouldHighlight != _isHighlighted) {
      if (mounted) {
        setState(() {
          _isHighlighted = shouldHighlight;
        });
        if (shouldHighlight) {
          _animController.repeat(reverse: true);
        } else {
          _animController.stop();
          _animController.reset();
        }
      }
    }
  }

  @override
  void dispose() {
    PowerLensAIService.instance.activeHighlightTarget.removeListener(_onHighlightChanged);
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(10);
    final label = widget.guideLabel ?? "✨ 여기를 확인하세요!";

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, _) {
        final t = _animController.value;
        final pulse = _isHighlighted ? (0.5 + 0.5 * math.sin(t * math.pi)) : 0.0;

        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: widget.padding,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: _isHighlighted
                      ? [
                          // Outer radiant aura
                          BoxShadow(
                            color: const Color(0xFFF59E0B).withValues(
                              alpha: 0.35 + 0.35 * pulse,
                            ),
                            blurRadius: 12 + 10 * pulse,
                            spreadRadius: 2 + 4 * pulse,
                          ),
                          // Inner bright glow
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(
                              alpha: 0.25 + 0.30 * pulse,
                            ),
                            blurRadius: 20 + 8 * pulse,
                            spreadRadius: 1 + 2 * pulse,
                          ),
                        ]
                      : null,
                ),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: _isHighlighted
                        ? Border.all(
                            color: Color.lerp(
                              const Color(0xFFF59E0B),
                              const Color(0xFF38BDF8),
                              pulse,
                            )!.withValues(alpha: 0.85 + 0.15 * pulse),
                            width: 2.5,
                          )
                        : null,
                  ),
                  child: widget.child,
                ),
              ),
            ),
            if (_isHighlighted)
              Positioned(
                top: -14,
                right: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.amber.withValues(alpha: 0.6),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
