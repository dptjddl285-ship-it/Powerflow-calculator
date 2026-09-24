import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'drawing_element.dart';

class VerifiedSldCanvasMapping {
  final List<DrawingElement> elements;
  final String? error;

  const VerifiedSldCanvasMapping._(this.elements, this.error);

  bool get isValid => error == null;

  factory VerifiedSldCanvasMapping.success(List<DrawingElement> elements) =>
      VerifiedSldCanvasMapping._(elements, null);

  factory VerifiedSldCanvasMapping.failure(String error) =>
      VerifiedSldCanvasMapping._(const [], error);
}

class VerifiedSldCanvasMapper {
  static VerifiedSldCanvasMapping map(
    Map<String, dynamic> verifiedSld, {
    required Offset canvasCenter,
  }) {
    if (verifiedSld['status'] != 'VERIFIED') {
      return VerifiedSldCanvasMapping.failure('SLD 검증 상태가 VERIFIED가 아닙니다.');
    }
    final rawNodes = verifiedSld['nodes'];
    final rawLines = verifiedSld['lines'];
    if (rawNodes is! List || rawNodes.isEmpty || rawLines is! List) {
      return VerifiedSldCanvasMapping.failure('검증된 노드/선로 목록이 없습니다.');
    }

    final nodes = <Map<String, dynamic>>[];
    final nodeIds = <String>{};
    final allIds = <String>{};
    final nodeTypes = <String, Tool>{};
    final busNumbersById = <String, int>{};
    var centerX = 0.0;
    var centerY = 0.0;

    for (final raw in rawNodes) {
      if (raw is! Map) {
        return VerifiedSldCanvasMapping.failure('검증된 노드 형식이 올바르지 않습니다.');
      }
      final node = Map<String, dynamic>.from(raw);
      final id = node['id']?.toString() ?? '';
      final className = node['class']?.toString() ?? '';
      final bbox = node['bbox'];
      if (id.isEmpty || !allIds.add(id)) {
        return VerifiedSldCanvasMapping.failure('노드 ID가 비어 있거나 중복되었습니다: $id');
      }
      if (bbox is! List || bbox.length != 4 || bbox.any((v) => v is! num)) {
        return VerifiedSldCanvasMapping.failure('노드 $id 의 검증 bbox가 올바르지 않습니다.');
      }
      final values = bbox.map((v) => (v as num).toDouble()).toList();
      if (values.any((v) => !v.isFinite) || values[2] <= 0 || values[3] <= 0) {
        return VerifiedSldCanvasMapping.failure(
          '노드 $id 의 검증 bbox 값이 유효하지 않습니다.',
        );
      }

      final Tool? type = switch (className) {
        'bus' => Tool.bus,
        'generator' => Tool.generator,
        'load' => Tool.load,
        'transformer' => Tool.transformer,
        _ => null,
      };
      if (type == null) {
        return VerifiedSldCanvasMapping.failure(
          '지원하지 않는 검증 객체 class입니다: $className',
        );
      }
      final busNumber = _readInt(node['bus_number']);
      final connectedBusNumber = _readInt(node['connected_bus_number']);
      if (busNumber != null &&
          connectedBusNumber != null &&
          busNumber != connectedBusNumber) {
        return VerifiedSldCanvasMapping.failure(
          '설비 $id 의 bus_number와 connected_bus_number가 서로 다릅니다.',
        );
      }
      if (type == Tool.bus && busNumber == null) {
        return VerifiedSldCanvasMapping.failure(
          '모선 $id 에 명시적 bus_number가 없습니다.',
        );
      }
      if ((type == Tool.generator || type == Tool.load) &&
          busNumber == null &&
          connectedBusNumber == null) {
        return VerifiedSldCanvasMapping.failure('설비 $id 에 명시적 연결 모선 번호가 없습니다.');
      }

      nodes.add(node);
      nodeIds.add(id);
      nodeTypes[id] = type;
      if (type == Tool.bus) busNumbersById[id] = busNumber!;
      centerX += values[0];
      centerY += values[1];
    }

    final shift = Offset(
      canvasCenter.dx - centerX / nodes.length,
      canvasCenter.dy - centerY / nodes.length,
    );
    final elements = <DrawingElement>[];
    for (final node in nodes) {
      final id = node['id'].toString();
      final className = node['class'].toString();
      final bbox = (node['bbox'] as List).cast<num>();
      final connectedBusId = node['connected_bus_id']?.toString();
      final connectedBusNumber = _readInt(node['connected_bus_number']);
      final busNumber = _readInt(node['bus_number']);
      if (connectedBusId != null &&
          (!nodeIds.contains(connectedBusId) ||
              nodeTypes[connectedBusId] != Tool.bus)) {
        return VerifiedSldCanvasMapping.failure(
          '설비 $id 의 connected_bus_id가 검증된 모선 ID를 가리키지 않습니다.',
        );
      }
      if (connectedBusId != null &&
          connectedBusNumber != null &&
          busNumbersById[connectedBusId] != connectedBusNumber) {
        return VerifiedSldCanvasMapping.failure(
          '설비 $id 의 연결 모선 ID/번호가 서로 다릅니다.',
        );
      }
      final x = (bbox[0]).toDouble() + shift.dx;
      final y = (bbox[1]).toDouble() + shift.dy;
      final element = DrawingElement(
        id: id,
        type: nodeTypes[id]!,
        position: Offset(x, y),
        width: bbox[2].toDouble(),
        height: bbox[3].toDouble(),
        label: (node['display_label'] ?? node['display_name'] ?? id).toString(),
        parentBusId: connectedBusId,
        busNumber: busNumber,
        connectedBusNumber: connectedBusNumber,
        verifiedClass: className,
        source: 'verified_sld',
      );
      final orientation =
          node['orientation'] ??
          (node['metadata'] is Map ? node['metadata']['orientation'] : null);
      element.angle = _orientationAngle(orientation);
      elements.add(element);
    }

    final elementsById = {for (final element in elements) element.id: element};
    for (final raw in rawLines) {
      if (raw is! Map) {
        return VerifiedSldCanvasMapping.failure('검증된 선로 형식이 올바르지 않습니다.');
      }
      final line = Map<String, dynamic>.from(raw);
      final id = (line['line_id'] ?? line['id'])?.toString() ?? '';
      final connectedTo = line['connected_to'];
      final rawPath = line['path'];
      if (id.isEmpty || !allIds.add(id)) {
        return VerifiedSldCanvasMapping.failure('선로 ID가 비어 있거나 중복되었습니다: $id');
      }
      if (connectedTo is! List || connectedTo.length != 2) {
        return VerifiedSldCanvasMapping.failure(
          '선로 $id 의 검증 endpoint가 정확히 2개가 아닙니다.',
        );
      }
      final startId = connectedTo[0].toString();
      final endId = connectedTo[1].toString();
      final startElement = elementsById[startId];
      final endElement = elementsById[endId];
      if (startElement == null || endElement == null || startId == endId) {
        return VerifiedSldCanvasMapping.failure(
          '선로 $id 의 endpoint가 검증 노드와 일치하지 않습니다.',
        );
      }
      if (rawPath is! List || rawPath.length < 2) {
        return VerifiedSldCanvasMapping.failure('선로 $id 에 검증된 경로가 없습니다.');
      }
      final sourcePath = <Offset>[];
      for (final rawPoint in rawPath) {
        if (rawPoint is! List ||
            rawPoint.length < 2 ||
            rawPoint[0] is! num ||
            rawPoint[1] is! num) {
          return VerifiedSldCanvasMapping.failure(
            '선로 $id 의 검증 경로 좌표가 올바르지 않습니다.',
          );
        }
        final point = Offset(
          (rawPoint[0] as num).toDouble(),
          (rawPoint[1] as num).toDouble(),
        );
        if (!point.dx.isFinite || !point.dy.isFinite) {
          return VerifiedSldCanvasMapping.failure(
            '선로 $id 의 검증 경로 좌표가 유효하지 않습니다.',
          );
        }
        sourcePath.add(point);
      }
      final displayPath = sourcePath.map((point) => point + shift).toList();
      final isBusToBus =
          startElement.type == Tool.bus && endElement.type == Tool.bus;
      elements.add(
        DrawingElement(
          id: id,
          type: Tool.line,
          position: displayPath.first,
          midPosition: displayPath.length > 2
              ? displayPath[displayPath.length ~/ 2]
              : null,
          endPosition: displayPath.last,
          startElementId: startId,
          endElementId: endId,
          startAnchor: displayPath.first - startElement.position,
          endAnchor: displayPath.last - endElement.position,
          label: (line['display_label'] ?? line['display_name'] ?? id)
              .toString(),
          aiPath: List<Offset>.from(displayPath),
          rawAiPath: List<Offset>.from(displayPath),
          sourceAiPath: List<Offset>.from(sourcePath),
          verifiedClass: 'line',
          source: 'verified_sld',
          isEquipmentLead: !isBusToBus,
          isGenLead:
              startElement.type == Tool.generator ||
              endElement.type == Tool.generator,
          electricalBranch: isBusToBus,
        ),
      );
    }

    return VerifiedSldCanvasMapping.success(elements);
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return null;
  }

  static double _orientationAngle(dynamic orientation) {
    switch (orientation?.toString().toLowerCase()) {
      case 'down':
      case 'south':
      case '90':
        return 0;
      case 'up':
      case 'north':
      case '270':
        return math.pi;
      case 'left':
      case 'west':
      case '180':
        return math.pi / 2;
      case 'right':
      case 'east':
      case '0':
        return -math.pi / 2;
      default:
        return 0;
    }
  }
}
