import 'drawing_element.dart';

class PowerFlowReadinessReport {
  final List<String> blockers;

  const PowerFlowReadinessReport(this.blockers);

  bool get ready => blockers.isEmpty;
}

class PowerFlowReadiness {
  static PowerFlowReadinessReport evaluate(List<DrawingElement> elements) {
    final blockers = <String>[];
    final buses = elements
        .where((element) => element.type == Tool.bus)
        .toList();
    if (buses.isEmpty) {
      return const PowerFlowReadinessReport(['모선(Bus)이 없습니다.']);
    }

    final busNumbers = <int, DrawingElement>{};
    final busNumberById = <String, int>{};
    for (final bus in buses) {
      final number = _busNumber(bus);
      if (number == null || number <= 0) {
        blockers.add('${_name(bus)}: 구조화된 모선 번호가 필요합니다.');
        continue;
      }
      if (busNumbers.containsKey(number)) {
        blockers.add('모선 번호 $number가 중복되었습니다.');
      } else {
        busNumbers[number] = bus;
      }
      busNumberById[bus.id] = number;
    }

    final slackBusNumbers = <int>{};
    for (final bus in buses) {
      final number = busNumberById[bus.id];
      final busType = bus.busType?.trim().toUpperCase();
      if (number != null &&
          (bus.isSlack ||
              busType == 'SLACK' ||
              busType == 'SWING' ||
              busType == '3' ||
              busType == '3.0')) {
        slackBusNumbers.add(number);
      }
    }

    final generators = elements
        .where((element) => element.type == Tool.generator)
        .toList();
    for (final generator in generators) {
      final busNumber = _deviceBusNumber(generator, busNumberById);
      if (busNumber == null || !busNumbers.containsKey(busNumber)) {
        blockers.add('${_name(generator)}: 연결된 모선을 확인할 수 없습니다.');
        continue;
      }
      if (generator.isSlack) slackBusNumbers.add(busNumber);
      final required = generator.isSlack || generator.isSynchronousCondenser
          ? const ['vPu']
          : const ['pPu', 'vPu'];
      _checkRequiredValues(generator, required, blockers);
    }

    for (final load in elements.where((element) => element.type == Tool.load)) {
      final busNumber = _deviceBusNumber(load, busNumberById);
      if (busNumber == null || !busNumbers.containsKey(busNumber)) {
        blockers.add('${_name(load)}: 연결된 모선을 확인할 수 없습니다.');
      }
      _checkRequiredValues(load, const ['pPu', 'qPu'], blockers);
    }

    final busesWithLoads = <int>{};
    for (final load in elements.where((element) => element.type == Tool.load)) {
      final number = _deviceBusNumber(load, busNumberById);
      if (number != null) busesWithLoads.add(number);
    }
    for (final bus in buses) {
      final number = busNumberById[bus.id];
      if (number == null) continue;
      if (slackBusNumbers.length == 1 &&
          number == slackBusNumbers.single &&
          !generators.any(
            (generator) =>
                generator.isSlack &&
                _deviceBusNumber(generator, busNumberById) == number,
          )) {
        _checkRequiredValues(bus, const ['vPu'], blockers);
      }
      if (!busesWithLoads.contains(number) &&
          (bus.pPu.abs() > 1e-9 || bus.qPu.abs() > 1e-9)) {
        _checkRequiredValues(bus, const ['pPu', 'qPu'], blockers);
      }
    }

    if (generators.where((element) => element.isSlack).length > 1) {
      blockers.add('Slack 발전기는 하나만 지정해야 합니다.');
    }

    if (slackBusNumbers.length != 1) {
      blockers.add(
        slackBusNumbers.isEmpty
            ? '명시적으로 지정된 Slack 모선이 없습니다.'
            : 'Slack 설정은 정확히 한 모선에만 지정해야 합니다.',
      );
    }

    final elementsById = {for (final element in elements) element.id: element};
    final branches = <_BranchConnection>[];
    for (final element in elements) {
      if (element.type == Tool.line) {
        if (!element.electricalBranch ||
            element.isEquipmentLead ||
            element.isGenLead ||
            element.id.toLowerCase().contains('lead')) {
          continue;
        }
        final start = elementsById[element.startElementId];
        final end = elementsById[element.endElementId];
        if (start?.type == Tool.generator ||
            start?.type == Tool.load ||
            start?.type == Tool.transformer ||
            end?.type == Tool.generator ||
            end?.type == Tool.load ||
            end?.type == Tool.transformer ||
            RegExp(
              r'(?:↔|->)\s*(?:G_|Load_)',
              caseSensitive: false,
            ).hasMatch(element.label)) {
          continue;
        }
        final endpoints = _lineEndpoints(element, busNumbers, busNumberById);
        if (endpoints == null) {
          blockers.add('${_name(element)}: 선로 양 끝점이 유효한 모선이 아닙니다.');
          continue;
        }
        branches.add(_BranchConnection(element, endpoints.$1, endpoints.$2));
      } else if (element.type == Tool.transformer) {
        final endpoints = _transformerEndpoints(
          element,
          busNumbers,
          busNumberById,
        );
        if (endpoints == null) {
          blockers.add('${_name(element)}: 변압기 양 끝 모선을 확인할 수 없습니다.');
          continue;
        }
        branches.add(_BranchConnection(element, endpoints.$1, endpoints.$2));
      }
    }

    if (branches.isEmpty) blockers.add('계통 선로 또는 변압기가 없습니다.');

    for (final branch in branches) {
      if (branch.fromBus == branch.toBus) {
        blockers.add('${_name(branch.element)}: 양 끝 모선이 같습니다.');
      }
      final required = branch.element.type == Tool.transformer
          ? <String>['rPu', 'xPu', 'bPu', 'tapRatio']
          : <String>['rPu', 'xPu', 'bPu'];
      if (branch.element.type == Tool.line &&
          (branch.element.parameterMissingFields.contains('tapRatio') ||
              branch.element.parameterInputFields.contains('tapRatio'))) {
        required.add('tapRatio');
      }
      _checkRequiredValues(branch.element, required, blockers);
      if (branch.element.rPu.abs() < 1e-9 && branch.element.xPu.abs() < 1e-9) {
        blockers.add('${_name(branch.element)}: R/X 직렬 임피던스가 0입니다.');
      }
      if (branch.element.type == Tool.transformer &&
          branch.element.tapRatio <= 0) {
        blockers.add('${_name(branch.element)}: Tap은 0보다 커야 합니다.');
      }
    }

    if (slackBusNumbers.length == 1 && branches.isNotEmpty) {
      final start = slackBusNumbers.single;
      final adjacent = <int, Set<int>>{
        for (final number in busNumbers.keys) number: <int>{},
      };
      for (final branch in branches) {
        adjacent[branch.fromBus]?.add(branch.toBus);
        adjacent[branch.toBus]?.add(branch.fromBus);
      }
      final visited = <int>{start};
      final queue = <int>[start];
      while (queue.isNotEmpty) {
        for (final next in adjacent[queue.removeAt(0)] ?? const <int>{}) {
          if (visited.add(next)) queue.add(next);
        }
      }
      final disconnected = busNumbers.keys.where(
        (bus) => !visited.contains(bus),
      );
      if (disconnected.isNotEmpty) {
        blockers.add(
          'Slack 모선에서 연결되지 않은 모선이 있습니다: ${disconnected.join(', ')}.',
        );
      }
    }

    return PowerFlowReadinessReport(List.unmodifiable(blockers.toSet()));
  }

  static bool _hasParameterEvidence(DrawingElement element, String field) {
    if (element.parameterInputFields.contains(field)) return true;
    if (element.parameterStatus == 'VALID' &&
        element.parameterMissingFields.isEmpty) {
      return true;
    }
    return element.parameterStatus == 'MISSING' &&
        element.parameterMissingFields.isNotEmpty &&
        !element.parameterMissingFields.contains(field);
  }

  static void _checkRequiredValues(
    DrawingElement element,
    List<String> fields,
    List<String> blockers,
  ) {
    final available = <String, double>{
      'vPu': element.vPu,
      'pPu': element.pPu,
      'qPu': element.qPu,
      'rPu': element.rPu,
      'xPu': element.xPu,
      'bPu': element.bPu,
      'tapRatio': element.tapRatio,
    };
    for (final field in fields) {
      final value = available[field];
      if (value == null || !value.isFinite) {
        blockers.add('${_name(element)}: $field 값이 유효하지 않습니다.');
      } else if (!_hasParameterEvidence(element, field)) {
        blockers.add('${_name(element)}: $field 값을 Excel 또는 사용자가 입력해야 합니다.');
      }
    }
  }

  static int? _deviceBusNumber(
    DrawingElement element,
    Map<String, int> busNumberById,
  ) {
    if (element.connectedBusNumber != null) return element.connectedBusNumber;
    final parent = element.parentBusId;
    if (parent != null) return busNumberById[parent];
    return null;
  }

  static int? _busNumber(DrawingElement bus) {
    if (bus.busNumber != null) return bus.busNumber;
    if (bus.verifiedClass != null) return null;
    return _firstNumber(bus.label) ?? _firstNumber(bus.id);
  }

  static int? _firstNumber(String value) {
    final match = RegExp(r'\d+').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  static (int, int)? _lineEndpoints(
    DrawingElement line,
    Map<int, DrawingElement> buses,
    Map<String, int> busNumberById,
  ) {
    if (line.fromBus != null && line.toBus != null) {
      if (buses.containsKey(line.fromBus) && buses.containsKey(line.toBus)) {
        return (line.fromBus!, line.toBus!);
      }
      return null;
    }
    final from = line.startElementId == null
        ? null
        : busNumberById[line.startElementId];
    final to = line.endElementId == null
        ? null
        : busNumberById[line.endElementId];
    if (from != null && to != null) return (from, to);
    if (line.verifiedClass != null) return null;
    return _labelEndpoints(line, buses);
  }

  static (int, int)? _transformerEndpoints(
    DrawingElement transformer,
    Map<int, DrawingElement> buses,
    Map<String, int> busNumberById,
  ) {
    if (transformer.fromBus != null && transformer.toBus != null) {
      if (buses.containsKey(transformer.fromBus) &&
          buses.containsKey(transformer.toBus)) {
        return (transformer.fromBus!, transformer.toBus!);
      }
      return null;
    }
    final from = transformer.startElementId == null
        ? null
        : busNumberById[transformer.startElementId];
    final to = transformer.endElementId == null
        ? null
        : busNumberById[transformer.endElementId];
    if (from != null && to != null) return (from, to);
    if (transformer.verifiedClass != null) return null;
    return _labelEndpoints(transformer, buses);
  }

  static (int, int)? _labelEndpoints(
    DrawingElement element,
    Map<int, DrawingElement> buses,
  ) {
    final match = RegExp(
      r'(\d+)\s*[-~_↔]\s*(\d+)',
    ).firstMatch('${element.label} ${element.id}');
    if (match == null) return null;
    final from = int.tryParse(match.group(1)!);
    final to = int.tryParse(match.group(2)!);
    if (from == null ||
        to == null ||
        !buses.containsKey(from) ||
        !buses.containsKey(to)) {
      return null;
    }
    return (from, to);
  }

  static String _name(DrawingElement element) =>
      element.label.isNotEmpty ? element.label : element.id;
}

class _BranchConnection {
  final DrawingElement element;
  final int fromBus;
  final int toBus;

  const _BranchConnection(this.element, this.fromBus, this.toBus);
}
