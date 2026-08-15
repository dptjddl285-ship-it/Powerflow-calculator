import 'package:flutter/material.dart';
import 'screens/power_canvas_page.dart';

void main() => runApp(const PowerDesignerApp());

class PowerDesignerApp extends StatelessWidget {
  const PowerDesignerApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: PowerCanvasPage(),
    debugShowCheckedModeBanner: false,
  );
}
