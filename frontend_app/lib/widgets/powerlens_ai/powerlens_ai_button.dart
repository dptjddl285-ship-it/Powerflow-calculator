import 'package:flutter/material.dart';

class PowerLensAIFloatingButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isOpen;
  final bool isMobile;
  final int? alertCount;

  const PowerLensAIFloatingButton({
    super.key,
    required this.onPressed,
    this.isOpen = false,
    this.isMobile = false,
    this.alertCount,
  });

  @override
  Widget build(BuildContext context) {
    if (isMobile) {
      return FloatingActionButton.small(
        onPressed: onPressed,
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        elevation: 4,
        child: const Icon(Icons.auto_awesome, size: 20),
      );
    }

    // Desktop Pill Button
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2563EB).withOpacity(0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 18),
              const SizedBox(width: 8),
              const Text(
                "PowerLens AI",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: -0.2,
                ),
              ),
              if (alertCount != null && alertCount! > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    "$alertCount",
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontWeight: FontWeight.w800,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
