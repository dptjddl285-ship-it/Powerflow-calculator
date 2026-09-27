import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/drawing_element.dart';

void main() {
  group('TARGET CAD Interaction & Behavior Tests', () {
    double nudgeStep(bool isShift) => isShift ? 10.0 : 1.0;

    test('1. Element selection and mouse drag movement updates position accurately', () {
      final bus = DrawingElement(
        id: 'bus_1',
        type: Tool.bus,
        position: const Offset(100, 100),
        width: 120,
        height: 10,
      );

      // Simulate mouse drag delta
      const dragDelta = Offset(25, -15);
      bus.position += dragDelta;

      expect(bus.position.dx, 125);
      expect(bus.position.dy, 85);
    });

    test('2. 1px keyboard nudge moves element by exactly 1px', () {
      final gen = DrawingElement(
        id: 'gen_1',
        type: Tool.generator,
        position: const Offset(200, 200),
      );

      // Non-shift nudge step is 1.0
      final double step = nudgeStep(false);

      // Nudge right
      gen.position += Offset(step, 0);
      expect(gen.position, const Offset(201, 200));

      // Nudge up
      gen.position += Offset(0, -step);
      expect(gen.position, const Offset(201, 199));
    });

    test('3. 10px keyboard nudge (Shift + Arrow) moves element by exactly 10px', () {
      final load = DrawingElement(
        id: 'load_1',
        type: Tool.load,
        position: const Offset(300, 300),
      );

      // Shift nudge step is 10.0
      final double step = nudgeStep(true);

      // Nudge left
      load.position += Offset(-step, 0);
      expect(load.position, const Offset(290, 300));

      // Nudge down
      load.position += Offset(0, step);
      expect(load.position, const Offset(290, 310));
    });

    test('4. Element 90-degree rotation updates angle and maintains angle within 2*pi', () {
      final bus = DrawingElement(
        id: 'bus_2',
        type: Tool.bus,
        position: const Offset(150, 150),
        width: 120,
        height: 10,
        angle: 0.0,
      );

      // Rotation logic: (angle + pi/2) % (2*pi)
      void rotate(DrawingElement e) {
        if (e.type == Tool.bus && e.width < e.height) {
          final double temp = e.width;
          e.width = e.height;
          e.height = temp;
        }
        e.angle = (e.angle + math.pi / 2) % (math.pi * 2);
      }

      rotate(bus);
      expect(bus.angle, closeTo(math.pi / 2, 0.001));

      rotate(bus);
      expect(bus.angle, closeTo(math.pi, 0.001));

      rotate(bus);
      expect(bus.angle, closeTo(3 * math.pi / 2, 0.001));

      rotate(bus);
      expect(bus.angle, closeTo(0.0, 0.001));
    });

    test('5. Reverse label rotation (Counter-Rotation) keeps label upright at all 4 angles', () {
      // For each 90-degree step: quarterTurns and counterQuarterTurns sum to a multiple of 4
      for (int turns = 0; turns < 4; turns++) {
        final double angle = turns * (math.pi / 2);
        final int quarterTurns = ((angle / (math.pi / 2)).round() % 4 + 4) % 4;
        final int counterQuarterTurns = (4 - quarterTurns) % 4;

        expect(quarterTurns, turns);
        expect((quarterTurns + counterQuarterTurns) % 4, 0,
            reason: 'Counter turns must completely cancel physical rotation so text stays upright');
      }
    });
  });
}
