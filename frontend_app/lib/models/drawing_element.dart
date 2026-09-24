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
  List<Offset>? rawAiPath;
  List<Offset>? sourceAiPath;

  bool showInfo = false;

  bool isSlack = false;
  double vPu = 1.0;
  double thetaDeg = 0.0;
  double pPu = 0.0;
  double qPu = 0.0;
  double rPu = 0.01;
  double xPu = 0.05;
  double bPu = 0.0;
  double tapRatio = 1.0;
  int? circuitCount;
  String? busType;
  String? source;
  int? busNumber;
  int? connectedBusNumber;
  int? fromBus;
  int? toBus;
  String? verifiedClass;
  String? parameterStatus;
  List<String> parameterMissingFields;
  List<String> parameterInputFields;
  bool isEquipmentLead = false;
  bool isGenLead = false;
  bool electricalBranch = true;

  bool get isAutoAddedFromExcel =>
      source == 'excel_auto' || id.startsWith('gen_auto_');

  bool get isDoubleCircuit =>
      (circuitCount != null && circuitCount! > 1) ||
      label.contains("회선") ||
      label.contains("병렬");

  bool? isSynchronousCondenserExplicit;

  bool get isSynchronousCondenser {
    if (type != Tool.generator || isSlack) return false;
    if (isSynchronousCondenserExplicit != null) {
      return isSynchronousCondenserExplicit!;
    }
    if (label.startsWith("SC_") ||
        label.startsWith("SC ") ||
        label == "SC" ||
        label.contains("동기조상기") ||
        id.startsWith("sc_") ||
        id.startsWith("SC_")) {
      return true;
    }
    return false;
  }

  set isSynchronousCondenser(bool val) {
    isSynchronousCondenserExplicit = val;
  }

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
    this.rawAiPath,
    this.sourceAiPath,
    this.circuitCount,
    this.busType,
    this.source,
    this.isSynchronousCondenserExplicit,
    this.busNumber,
    this.connectedBusNumber,
    this.fromBus,
    this.toBus,
    this.verifiedClass,
    this.parameterStatus,
    this.parameterMissingFields = const [],
    this.parameterInputFields = const [],
    this.isEquipmentLead = false,
    this.isGenLead = false,
    this.electricalBranch = true,
  }) {
    parameterMissingFields = List<String>.from(parameterMissingFields);
    parameterInputFields = List<String>.from(parameterInputFields);
    if (type == Tool.generator && isSynchronousCondenserExplicit == null) {
      if (label.startsWith("SC_") ||
          label.startsWith("SC ") ||
          label == "SC" ||
          label.contains("동기조상기") ||
          id.startsWith("sc_") ||
          id.startsWith("SC_")) {
        isSynchronousCondenserExplicit = true;
      } else {
        isSynchronousCondenserExplicit = false;
      }
    }
  }

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
        rawAiPath: rawAiPath != null ? List.from(rawAiPath!) : null,
        sourceAiPath: sourceAiPath != null ? List.from(sourceAiPath!) : null,
        circuitCount: circuitCount,
        busType: busType,
        source: source,
        busNumber: busNumber,
        connectedBusNumber: connectedBusNumber,
        fromBus: fromBus,
        toBus: toBus,
        verifiedClass: verifiedClass,
        parameterStatus: parameterStatus,
        parameterMissingFields: List<String>.from(parameterMissingFields),
        parameterInputFields: List<String>.from(parameterInputFields),
        isEquipmentLead: isEquipmentLead,
        isGenLead: isGenLead,
        electricalBranch: electricalBranch,
      )
      ..showInfo = showInfo
      ..isSlack = isSlack
      ..vPu = vPu
      ..thetaDeg = thetaDeg
      ..pPu = pPu
      ..qPu = qPu
      ..rPu = rPu
      ..xPu = xPu
      ..bPu = bPu
      ..tapRatio = tapRatio
      ..isSynchronousCondenserExplicit = isSynchronousCondenserExplicit
      ..source = source;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'label': label,
      'type': type.name,
      'bus_number': busNumber,
      'connected_bus_number': connectedBusNumber,
      'parentBusId': parentBusId,
      'startElementId': startElementId,
      'endElementId': endElementId,
      'isSlack': isSlack,
      'isSynchronousCondenser': isSynchronousCondenser,
      'vPu': _isParameterMissing('vPu') ? null : vPu,
      'thetaDeg': thetaDeg,
      'pPu': _isParameterMissing('pPu') ? null : pPu,
      'qPu': _isParameterMissing('qPu') ? null : qPu,
      'rPu': _isParameterMissing('rPu') ? null : rPu,
      'xPu': _isParameterMissing('xPu') ? null : xPu,
      'bPu': _isParameterMissing('bPu') ? null : bPu,
      'tapRatio': _isParameterMissing('tapRatio') ? null : tapRatio,
      'parameterStatus': parameterStatus,
      'parameterMissingFields': parameterMissingFields,
      'parameterInputFields': parameterInputFields,
      'from_bus': fromBus,
      'to_bus': toBus,
      'verifiedClass': verifiedClass,
      'circuitCount': circuitCount,
      'bus_type': busType,
      'source': source,
      'isEquipmentLead': isEquipmentLead,
      'isGenLead': isGenLead,
      'electricalBranch': electricalBranch,
    };
  }

  bool _isParameterMissing(String field) =>
      parameterMissingFields.contains(field) ||
      (parameterStatus == 'MISSING' && parameterMissingFields.isEmpty);

  void markParameterInput(String field) {
    if (!parameterInputFields.contains(field)) parameterInputFields.add(field);
    parameterMissingFields.remove(field);
    if (parameterStatus == 'MISSING' && parameterMissingFields.isEmpty) {
      parameterStatus = 'MANUAL';
    }
  }

  void updateFromJson(Map<String, dynamic> json) {
    if (json.containsKey('label') && json['label'] != null) {
      label = json['label'].toString();
    }
    if (json.containsKey('isSynchronousCondenser') &&
        json['isSynchronousCondenser'] != null) {
      isSynchronousCondenser = json['isSynchronousCondenser'] == true;
    } else if (json.containsKey('is_synchronous_condenser') &&
        json['is_synchronous_condenser'] != null) {
      isSynchronousCondenser = json['is_synchronous_condenser'] == true;
    } else if (label.startsWith("SC_") ||
        label.startsWith("SC ") ||
        label == "SC" ||
        label.contains("동기조상기") ||
        id.startsWith("SC_") ||
        id.startsWith("sc_")) {
      isSynchronousCondenser = true;
    } else if (type == Tool.generator) {
      isSynchronousCondenser = false;
    }
    if (json.containsKey('isSlack') && json['isSlack'] != null) {
      isSlack = json['isSlack'] == true;
    } else if (json.containsKey('is_slack') && json['is_slack'] != null) {
      isSlack = json['is_slack'] == true;
    }
    if (json.containsKey('vPu') && json['vPu'] != null) {
      vPu = (json['vPu'] as num).toDouble();
    } else if (json.containsKey('v_pu') && json['v_pu'] != null) {
      vPu = (json['v_pu'] as num).toDouble();
    }
    if (json.containsKey('thetaDeg') && json['thetaDeg'] != null) {
      thetaDeg = (json['thetaDeg'] as num).toDouble();
    } else if (json.containsKey('theta_deg') && json['theta_deg'] != null) {
      thetaDeg = (json['theta_deg'] as num).toDouble();
    }
    if (json.containsKey('pPu') && json['pPu'] != null) {
      pPu = (json['pPu'] as num).toDouble();
    } else if (json.containsKey('p_pu') && json['p_pu'] != null) {
      pPu = (json['p_pu'] as num).toDouble();
    }
    if (json.containsKey('qPu') && json['qPu'] != null) {
      qPu = (json['qPu'] as num).toDouble();
    } else if (json.containsKey('q_pu') && json['q_pu'] != null) {
      qPu = (json['q_pu'] as num).toDouble();
    }
    if (json.containsKey('rPu') && json['rPu'] != null) {
      rPu = (json['rPu'] as num).toDouble();
    } else if (json.containsKey('r_pu') && json['r_pu'] != null) {
      rPu = (json['r_pu'] as num).toDouble();
    }
    if (json.containsKey('xPu') && json['xPu'] != null) {
      xPu = (json['xPu'] as num).toDouble();
    } else if (json.containsKey('x_pu') && json['x_pu'] != null) {
      xPu = (json['x_pu'] as num).toDouble();
    }
    if (json.containsKey('bPu') && json['bPu'] != null) {
      bPu = (json['bPu'] as num).toDouble();
    } else if (json.containsKey('b_pu') && json['b_pu'] != null) {
      bPu = (json['b_pu'] as num).toDouble();
    }
    if (json.containsKey('tapRatio') && json['tapRatio'] != null) {
      tapRatio = (json['tapRatio'] as num).toDouble();
    } else if (json.containsKey('tap') && json['tap'] != null) {
      tapRatio = (json['tap'] as num).toDouble();
    }
    if (json.containsKey('circuitCount') && json['circuitCount'] != null) {
      circuitCount = (json['circuitCount'] as num).toInt();
    }
    if (json.containsKey('bus_type') && json['bus_type'] != null) {
      busType = json['bus_type'].toString();
    }
    if (json.containsKey('parentBusId') && json['parentBusId'] != null) {
      parentBusId = json['parentBusId'].toString();
    }
    if (json.containsKey('startElementId') && json['startElementId'] != null) {
      startElementId = json['startElementId'].toString();
    }
    if (json.containsKey('endElementId') && json['endElementId'] != null) {
      endElementId = json['endElementId'].toString();
    }
    if (json.containsKey('from_bus') && json['from_bus'] != null) {
      fromBus = (json['from_bus'] as num).toInt();
    } else if (json.containsKey('fromBus') && json['fromBus'] != null) {
      fromBus = (json['fromBus'] as num).toInt();
    }
    if (json.containsKey('to_bus') && json['to_bus'] != null) {
      toBus = (json['to_bus'] as num).toInt();
    } else if (json.containsKey('toBus') && json['toBus'] != null) {
      toBus = (json['toBus'] as num).toInt();
    }
    if (json.containsKey('parameterStatus') &&
        json['parameterStatus'] != null) {
      parameterStatus = json['parameterStatus'].toString();
    }
    if (json['parameterMissingFields'] is List) {
      parameterMissingFields = (json['parameterMissingFields'] as List)
          .map((field) => field.toString())
          .toList();
    }
    if (json['parameterInputFields'] is List) {
      parameterInputFields = (json['parameterInputFields'] as List)
          .map((field) => field.toString())
          .toList();
    }
    if (json.containsKey('verifiedClass') && json['verifiedClass'] != null) {
      verifiedClass = json['verifiedClass'].toString();
    }
    if (json.containsKey('source') && json['source'] != null) {
      source = json['source'].toString();
    }
    if (json.containsKey('bus_number') && json['bus_number'] != null) {
      busNumber = (json['bus_number'] as num).toInt();
    } else if (json.containsKey('busNumber') && json['busNumber'] != null) {
      busNumber = (json['busNumber'] as num).toInt();
    }
    if (json.containsKey('connected_bus_number') &&
        json['connected_bus_number'] != null) {
      connectedBusNumber = (json['connected_bus_number'] as num).toInt();
    } else if (json.containsKey('connectedBusNumber') &&
        json['connectedBusNumber'] != null) {
      connectedBusNumber = (json['connectedBusNumber'] as num).toInt();
    }
    if (json.containsKey('isEquipmentLead') &&
        json['isEquipmentLead'] != null) {
      isEquipmentLead = json['isEquipmentLead'] == true;
    }
    if (json.containsKey('isGenLead') && json['isGenLead'] != null) {
      isGenLead = json['isGenLead'] == true;
    }
    if (json.containsKey('electricalBranch') &&
        json['electricalBranch'] != null) {
      electricalBranch = json['electricalBranch'] == true;
    }
  }

  factory DrawingElement.fromJson(Map<String, dynamic> json) {
    Tool parseTool(String? name) {
      if (name == null) return Tool.bus;
      final clean = name.toLowerCase().replaceAll('tool.', '');
      for (var t in Tool.values) {
        if (t.name == clean) return t;
      }
      return Tool.bus;
    }

    Offset parseOffset(dynamic val) {
      if (val is Map) {
        final dx = (val['dx'] as num?)?.toDouble() ?? 0.0;
        final dy = (val['dy'] as num?)?.toDouble() ?? 0.0;
        return Offset(dx, dy);
      }
      return Offset.zero;
    }

    final el = DrawingElement(
      id: json['id']?.toString() ?? 'unknown',
      type: parseTool(json['type']?.toString()),
      position: parseOffset(json['position']),
      midPosition: json['midPosition'] != null
          ? parseOffset(json['midPosition'])
          : null,
      endPosition: json['endPosition'] != null
          ? parseOffset(json['endPosition'])
          : null,
      width: (json['width'] as num?)?.toDouble() ?? 120.0,
      height: (json['height'] as num?)?.toDouble() ?? 10.0,
      angle: (json['angle'] as num?)?.toDouble() ?? 0.0,
      parentBusId: json['parentBusId']?.toString(),
      startElementId: json['startElementId']?.toString(),
      endElementId: json['endElementId']?.toString(),
      label: json['label']?.toString() ?? '',
      circuitCount: (json['circuitCount'] as num?)?.toInt(),
      busType: json['bus_type']?.toString(),
      source: json['source']?.toString(),
      busNumber:
          (json['bus_number'] as num?)?.toInt() ??
          (json['busNumber'] as num?)?.toInt(),
      isEquipmentLead: json['isEquipmentLead'] == true,
      isGenLead: json['isGenLead'] == true,
      electricalBranch: json['electricalBranch'] != false,
    );
    el.updateFromJson(json);
    if (el.type == Tool.bus && el.width < el.height) {
      double temp = el.width;
      el.width = el.height;
      el.height = temp;
      el.angle = (el.angle + 3.141592653589793 / 2) % (3.141592653589793 * 2);
    }
    return el;
  }
}
