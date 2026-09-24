import 'package:circuit_solver/models/drawing_element.dart';
import 'package:circuit_solver/models/verified_sld_canvas_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VerifiedSldCanvasMapper', () {
    test(
      'preserves verified IDs, classes, bus numbers, endpoints, and raw path',
      () {
        final result = VerifiedSldCanvasMapper.map({
          'status': 'VERIFIED',
          'nodes': [
            {
              'id': 'west-terminal',
              'class': 'bus',
              'bbox': [20, 20, 24, 8],
              'bus_number': 41,
              'display_label': 'West',
            },
            {
              'id': 'east-terminal',
              'class': 'bus',
              'bbox': [80, 60, 24, 8],
              'bus_number': 72,
              'display_label': 'East',
            },
          ],
          'lines': [
            {
              'line_id': 'edge-original-id',
              'connected_to': ['west-terminal', 'east-terminal'],
              'path': [
                [10, 12],
                [28, 25],
                [45, 40],
                [81, 61],
              ],
              'display_label': 'Feed',
            },
          ],
        }, canvasCenter: const Offset(100, 100));

        expect(result.isValid, isTrue, reason: result.error);
        final firstBus = result.elements.first;
        final secondBus = result.elements[1];
        final line = result.elements.last;
        expect(firstBus.id, 'west-terminal');
        expect(firstBus.type, Tool.bus);
        expect(firstBus.verifiedClass, 'bus');
        expect(firstBus.busNumber, 41);
        expect(secondBus.id, 'east-terminal');
        expect(secondBus.busNumber, 72);
        expect(line.id, 'edge-original-id');
        expect(line.startElementId, 'west-terminal');
        expect(line.endElementId, 'east-terminal');
        expect(line.electricalBranch, isTrue);
        expect(line.sourceAiPath, const [
          Offset(10, 12),
          Offset(28, 25),
          Offset(45, 40),
          Offset(81, 61),
        ]);
        expect(line.aiPath!.length, 4);
        expect(line.rawAiPath!.length, 4);
        expect(
          line.aiPath!.first - line.sourceAiPath!.first,
          const Offset(50, 60),
        );
        expect(
          line.aiPath!.last - line.sourceAiPath!.last,
          const Offset(50, 60),
        );
      },
    );

    test(
      'uses only explicit device connection metadata and preserves class',
      () {
        final result = VerifiedSldCanvasMapper.map({
          'status': 'VERIFIED',
          'nodes': [
            {
              'id': 'bus-alpha',
              'class': 'bus',
              'bbox': [10, 10, 20, 8],
              'bus_number': 44,
            },
            {
              'id': 'generator-900',
              'class': 'generator',
              'bbox': [70, 40, 18, 18],
              'bus_number': 44,
              'connected_bus_number': 44,
              'connected_bus_id': 'bus-alpha',
              'display_label': 'G west',
            },
          ],
          'lines': [],
        }, canvasCenter: const Offset(500, 500));

        expect(result.isValid, isTrue, reason: result.error);
        final generator = result.elements.last;
        expect(generator.id, 'generator-900');
        expect(generator.type, Tool.generator);
        expect(generator.verifiedClass, 'generator');
        expect(generator.busNumber, 44);
        expect(generator.connectedBusNumber, 44);
        expect(generator.parentBusId, 'bus-alpha');
        expect(generator.isAutoAddedFromExcel, isFalse);
      },
    );

    test('rejects ID/label inference and unverified topology or paths', () {
      final missingNumber = VerifiedSldCanvasMapper.map({
        'status': 'VERIFIED',
        'nodes': [
          {
            'id': 'bus_17',
            'class': 'bus',
            'bbox': [10, 10, 20, 8],
            'display_label': 'Bus 17',
          },
        ],
        'lines': [],
      }, canvasCenter: const Offset(100, 100));
      expect(missingNumber.isValid, isFalse);
      expect(missingNumber.error, contains('bus_number'));

      final badEndpoint = VerifiedSldCanvasMapper.map({
        'status': 'VERIFIED',
        'nodes': [
          {
            'id': 'bus-a',
            'class': 'bus',
            'bbox': [10, 10, 20, 8],
            'bus_number': 1,
          },
        ],
        'lines': [
          {
            'line_id': 'bad-edge',
            'connected_to': ['bus-a', 'bus_2'],
            'path': [
              [10, 10],
              [20, 20],
            ],
          },
        ],
      }, canvasCenter: const Offset(100, 100));
      expect(badEndpoint.isValid, isFalse);
      expect(badEndpoint.error, contains('endpoint'));

      final unverified = VerifiedSldCanvasMapper.map({
        'status': 'REVIEW',
        'nodes': [],
        'lines': [],
      }, canvasCenter: const Offset(100, 100));
      expect(unverified.isValid, isFalse);
      expect(unverified.error, contains('VERIFIED'));
    });

    test(
      'serializes missing Excel values as null instead of model defaults',
      () {
        final line = DrawingElement(
          id: 'unbound-line',
          type: Tool.line,
          position: Offset.zero,
          parameterStatus: 'MISSING',
          parameterMissingFields: const ['rPu', 'xPu', 'bPu', 'tapRatio'],
        );

        final json = line.toJson();
        expect(json['rPu'], isNull);
        expect(json['xPu'], isNull);
        expect(json['bPu'], isNull);
        expect(json['tapRatio'], isNull);
      },
    );

    test(
      'transfers verified transformer endpoints and Excel tap through JSON',
      () {
        final transformer = DrawingElement(
          id: 'transformer-id',
          type: Tool.transformer,
          position: Offset.zero,
          fromBus: 3,
          toBus: 24,
          parameterStatus: 'VALID',
        )..tapRatio = 1.03;

        final restored = DrawingElement.fromJson({
          ...transformer.toJson(),
          'position': {'dx': 0.0, 'dy': 0.0},
        });

        expect(restored.fromBus, 3);
        expect(restored.toBus, 24);
        expect(restored.tapRatio, 1.03);
      },
    );
  });
}
