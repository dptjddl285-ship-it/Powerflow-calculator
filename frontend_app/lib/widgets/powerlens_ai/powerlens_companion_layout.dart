import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class PowerLensCompanionLayout {
  const PowerLensCompanionLayout._();

  static const double robotAnchorWidth = 120;
  static const double robotAnchorHeight = 108;
  static const double closedGroupWidth = 420;
  static const double panelGap = 12;

  static Rect groupRect({
    required Size viewport,
    required Alignment robotCenterAlignment,
    required bool panelOpen,
    required Size panelBounds,
    double margin = 12,
  }) {
    final groupWidth = panelOpen ? panelBounds.width : closedGroupWidth;
    final groupHeight = panelOpen
        ? panelBounds.height + panelGap + robotAnchorHeight
        : robotAnchorHeight;
    final robotCenter = Offset(
      (robotCenterAlignment.x + 1) * viewport.width / 2,
      (robotCenterAlignment.y + 1) * viewport.height / 2,
    );
    final left = robotCenter.dx + robotAnchorWidth / 2 - groupWidth;
    final top = robotCenter.dy + robotAnchorHeight / 2 - groupHeight;
    final maxLeft = math.max(margin, viewport.width - groupWidth - margin);
    final maxTop = math.max(margin, viewport.height - groupHeight - margin);

    return Rect.fromLTWH(
      left.clamp(margin, maxLeft).toDouble(),
      top.clamp(margin, maxTop).toDouble(),
      groupWidth,
      groupHeight,
    );
  }

  static Offset robotCenter(Rect group) => Offset(
    group.right - robotAnchorWidth / 2,
    group.bottom - robotAnchorHeight / 2,
  );

  static Alignment alignmentForRobotCenter(Offset center, Size viewport) =>
      Alignment(
        (center.dx * 2 / viewport.width) - 1,
        (center.dy * 2 / viewport.height) - 1,
      );
}
