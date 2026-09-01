import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_models.dart';

void main() {
  group('VisionFlow Step 3 Review Pipeline Frontend Tests', () {
    test('VerifiedSLD JSON Serialization and Parsing with Completeness Provenance', () {
      final jsonMap = {
        "schema_version": "1.0",
        "document_id": "doc_test_999",
        "status": "VERIFIED",
        "image": {
          "width": 1280,
          "height": 720,
          "url": "/review/image/doc_test_999"
        },
        "nodes": [
          {
            "id": "bus_1",
            "class": "bus",
            "bbox": [100.0, 50.0, 120.0, 10.0],
            "confidence": 0.98,
            "source": "cv_primary",
            "review_status": "CONFIRMED"
          },
          {
            "id": "gen_1",
            "class": "generator",
            "bbox": [100.0, 150.0, 40.0, 40.0],
            "confidence": 0.92,
            "source": "yolo_primary",
            "review_status": "CONFIRMED"
          }
        ],
        "lines": [
          {
            "line_id": "L1",
            "connected_to": ["bus_1", "gen_1"],
            "path": [
              [100.0, 50.0],
              [100.0, 150.0]
            ],
            "source_port": "bottom",
            "target_port": "lead_port",
            "trace_method": "electrical_graph",
            "review_status": "CONFIRMED"
          }
        ],
        "verification": {
          "object_gate": "PASS",
          "connection_gate": "PASS",
          "human_completeness_confirmed": true,
          "critical_issue_count": 0
        }
      };

      final sld = VerifiedSLD.fromJson(jsonMap);
      expect(sld.status, equals('VERIFIED'));
      expect(sld.documentId, equals('doc_test_999'));
      expect(sld.nodes.length, equals(2));
      expect(sld.lines.length, equals(1));
      expect(sld.lines[0].connectedTo, equals(['bus_1', 'gen_1']));
      expect(sld.verification['human_completeness_confirmed'], equals(true));
    });

    test('Connection Line Coordinate Scaling Conversion', () {
      const double origW = 1280.0;
      const double origH = 720.0;
      const double renderedW = 640.0;
      const double renderedH = 360.0;

      final double scaleX = renderedW / origW; // 0.5
      final double scaleY = renderedH / origH; // 0.5

      final linePath = [
        [100.0, 200.0],
        [300.0, 400.0]
      ];

      final screenPt1X = linePath[0][0] * scaleX;
      final screenPt1Y = linePath[0][1] * scaleY;
      final screenPt2X = linePath[1][0] * scaleX;
      final screenPt2Y = linePath[1][1] * scaleY;

      expect(screenPt1X, equals(50.0));
      expect(screenPt1Y, equals(100.0));
      expect(screenPt2X, equals(150.0));
      expect(screenPt2Y, equals(200.0));
    });

    test('ReviewNodeItem and ReviewLineItem State Transitions', () {
      final node = ReviewNodeItem(
        id: 'node_1',
        className: 'bus',
        bbox: [50.0, 50.0, 100.0, 10.0],
        confidence: 0.5,
        source: 'yolo_rescue',
        reviewStatus: 'SUSPICIOUS',
      );

      final confirmedNode = node.copyWith(
        reviewStatus: 'CONFIRMED',
        source: 'human_confirmed',
      );
      expect(confirmedNode.reviewStatus, equals('CONFIRMED'));
      expect(confirmedNode.source, equals('human_confirmed'));

      final line = ReviewLineItem(
        lineId: 'L1',
        connectedTo: ['node_1', 'node_2'],
        path: [[50.0, 50.0], [50.0, 100.0]],
        reviewStatus: 'AMBIGUOUS',
      );

      final reconnectedLine = line.copyWith(
        connectedTo: ['node_1', 'node_3'],
        reviewStatus: 'CONFIRMED',
        source: 'human_reconnected',
      );
      expect(reconnectedLine.connectedTo, equals(['node_1', 'node_3']));
      expect(reconnectedLine.reviewStatus, equals('CONFIRMED'));
    });

    test('MissingCandidateItem State Transitions and Completeness Result Parsing', () {
      final candidate = MissingCandidateItem(
        id: 'cand_trans_1',
        suspectedClass: 'transformer',
        descriptionKo: 'Bus 1과 8 사이 권선 심볼 누락 의심',
        status: 'OPEN',
      );

      expect(candidate.status, equals('OPEN'));
      expect(candidate.suspectedClass, equals('transformer'));

      final dismissed = candidate.copyWith(status: 'DISMISSED_BY_HUMAN');
      expect(dismissed.status, equals('DISMISSED_BY_HUMAN'));

      final resolved = candidate.copyWith(status: 'RESOLVED_BY_MANUAL_ADD');
      expect(resolved.status, equals('RESOLVED_BY_MANUAL_ADD'));

      final jsonMap = {
        "assessment": "POSSIBLE_MISSING_COMPONENT",
        "message_ko": "누락 가능성 감지",
        "candidates": [candidate.toJson()],
        "class_counts": {"bus": 9, "transformer": 0},
        "agent_status": "DETERMINISTIC"
      };

      final result = CompletenessReviewResult.fromJson(jsonMap);
      expect(result.assessment, equals('POSSIBLE_MISSING_COMPONENT'));
      expect(result.candidates.length, equals(1));
      expect(result.candidates[0].id, equals('cand_trans_1'));
    });
  });
}
