import 'package:flutter/material.dart';

enum Tool { bus, generator, load, line, move, text, transformer }

class DrawingElement {
  String id;
  Tool type;
  Offset position;
  Offset? midPosition;
  Offset? endPosition;
  double width, height, angle;
  String? startElementId;
  String? endElementId;
  Offset? startAnchor;
  Offset? endAnchor;
  String? parentBusId;
  String label;
  Offset infoOffset;

  List<Offset>? aiPath;

  bool showInfo = false;

  bool isSlack = false;
  double vPu = 1.0;
  double thetaDeg = 0.0;
  double pPu = 0.0;
  double qPu = 0.0;
  double rPu = 0.01;
  double xPu = 0.05;
  double bPu = 0.0;

  DrawingElement({
    required this.id,
    required this.type,
    required this.position,
    this.midPosition,
    this.endPosition,
    this.width = 120,
    this.height = 10,
    this.angle = 0,
    this.parentBusId,
    this.startElementId,
    this.endElementId,
    this.startAnchor,
    this.endAnchor,
    this.label = "",
    this.infoOffset = const Offset(40, -40),
    this.aiPath,
  });

  DrawingElement copy() {
    return DrawingElement(
        id: id,
        type: type,
        position: position,
        midPosition: midPosition,
        endPosition: endPosition,
        width: width,
        height: height,
        angle: angle,
        parentBusId: parentBusId,
        startElementId: startElementId,
        endElementId: endElementId,
        startAnchor: startAnchor,
        endAnchor: endAnchor,
        label: label,
        infoOffset: infoOffset,
        aiPath: aiPath != null ? List.from(aiPath!) : null,
      )
      ..showInfo = showInfo
      ..isSlack = isSlack
      ..vPu = vPu
      ..thetaDeg = thetaDeg
      ..pPu = pPu
      ..qPu = qPu
      ..rPu = rPu
      ..xPu = xPu
      ..bPu = bPu;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'parentBusId': parentBusId,
      'startElementId': startElementId,
      'endElementId': endElementId,
      'isSlack': isSlack,
      'vPu': vPu,
      'thetaDeg': thetaDeg,
      'pPu': pPu,
      'qPu': qPu,
      'rPu': rPu,
      'xPu': xPu,
      'bPu': bPu,
    };
  }
}
