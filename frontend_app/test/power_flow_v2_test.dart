import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/drawing_element.dart';
import 'package:circuit_solver/models/power_flow_readiness.dart';
import 'package:circuit_solver/models/power_flow_result_contract.dart';

DrawingElement _bus(int number, {bool slack = false}) {
  final bus = DrawingElement(
    id: 'bus_$number',
    type: Tool.bus,
    position: Offset(number * 100, 100),
    label: 'Bus $number',
    busNumber: number,
  )..isSlack = slack;
  if (slack) bus.markParameterInput('vPu');
  return bus;
}

DrawingElement _line(int from, int to) {
  final line =
      DrawingElement(
          id: 'line_${from}_$to',
          type: Tool.line,
          position: Offset(from * 100, 100),
          endPosition: Offset(to * 100, 100),
          label: 'Line $from-$to',
          fromBus: from,
          toBus: to,
        )
        ..rPu = 0.01
        ..xPu = 0.1
        ..bPu = 0.0;
  for (final field in ['rPu', 'xPu', 'bPu']) {
    line.markParameterInput(field);
  }
  return line;
}

void main() {
  group('Power Flow V2 readiness contract', () {
    test('accepts complete manual inputs without requiring Excel', () {
      final report = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        _line(1, 2),
      ]);

      expect(report.ready, isTrue);
      expect(report.blockers, isEmpty);
    });

    test('rejects missing and duplicate Slack assignments', () {
      final missing = PowerFlowReadiness.evaluate([
        _bus(1),
        _bus(2),
        _line(1, 2),
      ]);
      final duplicate = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2, slack: true),
        _line(1, 2),
      ]);

      expect(missing.ready, isFalse);
      expect(missing.blockers.join(' '), contains('Slack'));
      expect(duplicate.ready, isFalse);
      expect(duplicate.blockers.join(' '), contains('정확히 한 모선'));
    });

    test('does not treat displayed default zero B as an entered value', () {
      final line = _line(1, 2)..parameterInputFields.remove('bPu');
      line
        ..parameterStatus = 'MISSING'
        ..parameterMissingFields = ['bPu'];
      final report = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        line,
      ]);

      expect(report.ready, isFalse);
      expect(report.blockers.join(' '), contains('bPu'));
    });

    test('requires load P and Q provenance', () {
      final load =
          DrawingElement(
              id: 'load_2',
              type: Tool.load,
              position: const Offset(200, 160),
              parentBusId: 'bus_2',
            )
            ..pPu = 0.2
            ..qPu = 0.0
            ..parameterInputFields = ['pPu'];
      final report = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        _line(1, 2),
        load,
      ]);

      expect(report.ready, isFalse);
      expect(report.blockers.join(' '), contains('qPu'));
    });

    test('uses field-level Excel provenance when another field is missing', () {
      final generator =
          DrawingElement(
              id: 'gen_2',
              type: Tool.generator,
              position: const Offset(200, 160),
              parentBusId: 'bus_2',
              parameterStatus: 'MISSING',
              parameterMissingFields: ['qPu'],
            )
            ..pPu = 0.2
            ..vPu = 1.02;
      final report = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        _line(1, 2),
        generator,
      ]);

      expect(report.ready, isTrue, reason: report.blockers.join(' '));
    });

    test('blocks disconnected buses and malformed active branches', () {
      final disconnected = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        _bus(3),
        _line(1, 2),
      ]);
      final malformed = DrawingElement(
        id: 'line_dangling',
        type: Tool.line,
        position: const Offset(100, 100),
      );
      final invalidEndpoint = PowerFlowReadiness.evaluate([
        _bus(1, slack: true),
        _bus(2),
        malformed,
      ]);

      expect(disconnected.ready, isFalse);
      expect(disconnected.blockers.join(' '), contains('연결되지 않은 모선'));
      expect(invalidEndpoint.ready, isFalse);
      expect(invalidEndpoint.blockers.join(' '), contains('양 끝점'));
    });
  });

  group('Power Flow V2 solver result contract', () {
    test('accepts actual converged and nonconverged solver evidence only', () {
      final actual = <String, dynamic>{
        'converged': false,
        'iterations': 30,
        'max_mismatch': 0.03,
        'slack_bus': 1,
        'summary': <String, dynamic>{},
        'bus_results': [
          <String, dynamic>{'bus': 1, 'volt': 1.0},
        ],
        'line_results': [
          <String, dynamic>{'from_bus': 1, 'to_bus': 2},
        ],
      };

      expect(PowerFlowResultContract.hasActualResult(actual), isTrue);
      expect(PowerFlowResultContract.isConverged(actual), isFalse);
      expect(
        PowerFlowResultContract.hasActualResult({'converged': true}),
        isFalse,
      );
    });

    test('maps signed solver flow onto canvas orientation and routed path', () {
      expect(
        PowerFlowResultContract.followsCanvasDirection(
          canvasFromBus: 1,
          canvasToBus: 2,
          solverFromBus: 1,
          solverToBus: 2,
          pFromMw: 5,
        ),
        isTrue,
      );
      expect(
        PowerFlowResultContract.followsCanvasDirection(
          canvasFromBus: 1,
          canvasToBus: 2,
          solverFromBus: 1,
          solverToBus: 2,
          pFromMw: -5,
        ),
        isFalse,
      );
      expect(
        PowerFlowResultContract.followsCanvasDirection(
          canvasFromBus: 1,
          canvasToBus: 2,
          solverFromBus: 2,
          solverToBus: 1,
          pFromMw: -5,
        ),
        isTrue,
      );
      expect(PowerFlowResultContract.orientRoute([1, 2, 3], false), [3, 2, 1]);
    });
  });
}
