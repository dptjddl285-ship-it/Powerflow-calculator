import 'package:flutter_test/flutter_test.dart';

import 'package:circuit_solver/main.dart';

void main() {
  testWidgets('Power Designer renders its main controls', (WidgetTester tester) async {
    await tester.pumpWidget(const PowerDesignerApp());
    await tester.pumpAndSettle();

    expect(find.text('Power Designer Pro'), findsOneWidget);
    expect(find.text('도면 사진 분석'), findsOneWidget);
    expect(find.text('조류계산 (파이썬 전송)'), findsOneWidget);
  });
}
