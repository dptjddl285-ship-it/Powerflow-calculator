import 'package:flutter/material.dart';
import 'dart:math' as math;

class TrianglePainter extends CustomPainter {
  final Color fillColor;
  final Color strokeColor;
  TrianglePainter({required this.fillColor, required this.strokeColor});

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(CustomPainter old) => false;
}

class LinePainter extends CustomPainter {
  final Offset start;
  final Offset? mid;
  final Offset end;
  final bool isSelected;
  final List<Offset>? aiPath;
  LinePainter(
    this.start,
    this.mid,
    this.end, {
    this.isSelected = false,
    this.aiPath,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = isSelected ? Colors.blue : Colors.black
      ..strokeWidth = isSelected ? 4 : 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Path path = Path();
    if (aiPath != null && aiPath!.isNotEmpty) {
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

  @override
  bool shouldRepaint(CustomPainter old) => true;
}

class PreviewLinePainter extends CustomPainter {
  final Offset start;
  final Offset? mid;
  final Offset current;
  PreviewLinePainter(this.start, this.mid, this.current);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;
    Path path = Path()..moveTo(start.dx, start.dy);
    canvas.drawCircle(start, 4, dotPaint);
    if (mid != null) {
      path.lineTo(mid!.dx, mid!.dy);
      canvas.drawCircle(mid!, 4, dotPaint);
    }
    path.lineTo(current.dx, current.dy);
    canvas.drawPath(path, p);
    canvas.drawCircle(
      current,
      3,
      dotPaint..color = Colors.blue.withOpacity(0.5),
    );
  }

  @override
  bool shouldRepaint(CustomPainter old) => true;
}

class InfiniteGridPainter extends CustomPainter {
  final Matrix4 transform;
  InfiniteGridPainter(this.transform);

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = transform.getMaxScaleOnAxis();
    final double tx = transform.getTranslation().x;
    final double ty = transform.getTranslation().y;

    final p = Paint()
      ..color = Colors.grey[100]!
      ..strokeWidth = 1;

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
  TransformerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    double radius = math.min(size.width, size.height) * 0.28;

    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2 - radius * 0.8),
      radius,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2 + radius * 0.8),
      radius,
      paint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter old) => false;
}
