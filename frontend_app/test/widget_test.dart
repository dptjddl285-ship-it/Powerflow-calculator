import 'package:flutter_test/flutter_test.dart';

import 'package:circuit_solver/main.dart';

void main() {
  testWidgets('Power Designer renders its main controls', (WidgetTester tester) async {
    await tester.pumpWidget(const PowerDesignerApp());
    // Lensy intentionally has a repeating idle animation, so the widget tree
    // never reaches a settled ticker state. Pump one frame for initial layout.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Power Designer Pro'), findsOneWidget);
    expect(find.text('PowerLens 시작하기'), findsOneWidget);
    expect(find.text('도면 사진으로 시작'), findsOneWidget);
    expect(find.text('샘플로 빠르게 체험하기'), findsOneWidget);
  });
}
