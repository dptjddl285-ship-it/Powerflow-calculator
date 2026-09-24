import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/widgets/powerlens_ai/powerlens_companion_layout.dart';

void main() {
  group('PowerLensCompanionLayout', () {
    test('keeps the robot anchored while the panel opens and closes', () {
      const viewport = Size(1600, 1200);
      const panelBounds = Size(620, 650);
      const alignment = Alignment(0.25, 0.25);

      final closed = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: alignment,
        panelOpen: false,
        panelBounds: panelBounds,
      );
      final opened = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: alignment,
        panelOpen: true,
        panelBounds: panelBounds,
      );

      expect(
        PowerLensCompanionLayout.robotCenter(opened),
        PowerLensCompanionLayout.robotCenter(closed),
      );
    });

    test('moves the group by the pointer delta when not near an edge', () {
      const viewport = Size(1600, 1200);
      const panelBounds = Size(500, 500);
      const startAlignment = Alignment(0, 0);
      const delta = Offset(100, 50);
      final start = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: startAlignment,
        panelOpen: true,
        panelBounds: panelBounds,
      );
      final desiredCenter = PowerLensCompanionLayout.robotCenter(start) + delta;
      final moved = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: PowerLensCompanionLayout.alignmentForRobotCenter(
          desiredCenter,
          viewport,
        ),
        panelOpen: true,
        panelBounds: panelBounds,
      );

      expect(moved.topLeft, start.topLeft + delta);
    });

    test('clamps an open group inside the viewport at both edges', () {
      const viewport = Size(1280, 720);
      const panelBounds = Size(900, 576);
      final group = PowerLensCompanionLayout.groupRect(
        viewport: viewport,
        robotCenterAlignment: Alignment.bottomRight,
        panelOpen: true,
        panelBounds: panelBounds,
      );

      expect(group.left, greaterThanOrEqualTo(12));
      expect(group.top, greaterThanOrEqualTo(12));
      expect(group.right, lessThanOrEqualTo(viewport.width - 12));
      expect(group.bottom, lessThanOrEqualTo(viewport.height - 12));
    });
  });
}
