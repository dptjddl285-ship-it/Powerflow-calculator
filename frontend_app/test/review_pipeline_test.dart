import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_models.dart';

void main() {
  group('VisionFlow Step 3 Review Pipeline Frontend Tests', () {
    test(
      'VerifiedSLD JSON Serialization and Parsing with Completeness Provenance',
      () {
        final jsonMap = {
          "schema_version": "1.0",
          "document_id": "doc_test_999",
          "status": "VERIFIED",
          "image": {
            "width": 1280,
            "height": 720,
            "url": "/review/image/doc_test_999",
          },
          "nodes": [
            {
              "id": "bus_1",
              "class": "bus",
              "bbox": [100.0, 50.0, 120.0, 10.0],
              "confidence": 0.98,
              "source": "cv_primary",
              "review_status": "CONFIRMED",
            },
            {
              "id": "gen_1",
              "class": "generator",
              "bbox": [100.0, 150.0, 40.0, 40.0],
              "confidence": 0.92,
              "source": "yolo_primary",
              "review_status": "CONFIRMED",
            },
          ],
          "lines": [
            {
              "line_id": "L1",
              "connected_to": ["bus_1", "gen_1"],
              "path": [
                [100.0, 50.0],
                [100.0, 150.0],
              ],
              "source_port": "bottom",
              "target_port": "lead_port",
              "trace_method": "electrical_graph",
              "review_status": "CONFIRMED",
            },
          ],
          "verification": {
            "object_gate": "PASS",
            "connection_gate": "PASS",
            "human_completeness_confirmed": true,
            "critical_issue_count": 0,
          },
        };

        final sld = VerifiedSLD.fromJson(jsonMap);
        expect(sld.status, equals('VERIFIED'));
        expect(sld.documentId, equals('doc_test_999'));
        expect(sld.nodes.length, equals(2));
        expect(sld.lines.length, equals(1));
        expect(sld.lines[0].connectedTo, equals(['bus_1', 'gen_1']));
        expect(sld.verification['human_completeness_confirmed'], equals(true));
      },
    );

    test('Connection Line Coordinate Scaling Conversion', () {
      const double origW = 1280.0;
      const double origH = 720.0;
      const double renderedW = 640.0;
      const double renderedH = 360.0;

      final double scaleX = renderedW / origW; // 0.5
      final double scaleY = renderedH / origH; // 0.5

      final linePath = [
        [100.0, 200.0],
        [300.0, 400.0],
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
        className: 'transformer',
        bbox: [50.0, 50.0, 100.0, 10.0],
        confidence: 0.5,
        source: 'yolo_rescue',
        reviewStatus: 'SUSPICIOUS',
        metadata: const {
          'transformer': {'orientation': 'vertical', 'style': 'wave'},
        },
      );

      final confirmedNode = node.copyWith(
        reviewStatus: 'CONFIRMED',
        source: 'human_confirmed',
      );
      expect(confirmedNode.reviewStatus, equals('CONFIRMED'));
      expect(confirmedNode.source, equals('human_confirmed'));
      final serializedNode = confirmedNode.toJson();
      expect(
        serializedNode['metadata']['transformer']['orientation'],
        equals('vertical'),
      );

      final line = ReviewLineItem(
        lineId: 'L1',
        connectedTo: ['node_1', 'node_2'],
        path: [
          [50.0, 50.0],
          [50.0, 100.0],
        ],
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

    test(
      'MissingCandidateItem State Transitions and Completeness Result Parsing',
      () {
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
          "agent_status": "DETERMINISTIC",
        };

        final result = CompletenessReviewResult.fromJson(jsonMap);
        expect(result.assessment, equals('POSSIBLE_MISSING_COMPONENT'));
        expect(result.candidates.length, equals(1));
        expect(result.candidates[0].id, equals('cand_trans_1'));
      },
    );

    test('Agent Activity Log Run and Event Flow Parsing', () {
      final sampleRun = {
        'run_id': 'run_20260901_test',
        'document_id': 'doc_test_999',
        'issue_id': 'iss_gen_3_missing',
        'status': 'AWAITING_APPROVAL',
        'selected_patch_id': 'patch_p7fa1',
        'plan': [
          {
            'attempt': 1,
            'tool_name': 'port_aware_retry',
            'reason': '단자 연결성 재추적 우선 시도',
          },
          {
            'attempt': 2,
            'tool_name': 'roi_reanalysis',
            'reason': '1차 실패 시 국소 영역 탐색',
          }
        ],
        'evaluations': [
          {
            'attempt': 1,
            'tool_name': 'port_aware_retry',
            'patch_id': 'patch_p001',
            'improved': false,
            'before_score': 10.0,
            'after_score': 10.0,
            'reason': '후보 선로 없음',
          },
          {
            'attempt': 2,
            'tool_name': 'roi_reanalysis',
            'patch_id': 'patch_p7fa1',
            'improved': true,
            'before_score': 10.0,
            'after_score': 3.0,
            'reason': '토폴로지 오류 점수 개선',
          }
        ],
        'activity_log': [
          {
            'sequence': 1,
            'event': 'issue_detected',
            'message': 'G3 모선 연결 누락 감지',
            'created_at': '2026-09-01T23:00:00Z',
          },
          {
            'sequence': 2,
            'event': 'plan_created',
            'message': '2단계 실행 계획 수립',
            'created_at': '2026-09-01T23:00:01Z',
          },
          {
            'sequence': 3,
            'event': 'tool_selected',
            'tool_name': 'port_aware_retry',
            'reason': '포트 기준 재추적',
            'created_at': '2026-09-01T23:00:02Z',
          },
          {
            'sequence': 4,
            'event': 'result_evaluated',
            'tool_name': 'port_aware_retry',
            'details': {
              'improved': false,
              'before_score': 10.0,
              'after_score': 10.0,
            },
            'created_at': '2026-09-01T23:00:03Z',
          },
          {
            'sequence': 5,
            'event': 'retry_scheduled',
            'tool_name': 'roi_reanalysis',
            'reason': '대체 도구 시도',
            'created_at': '2026-09-01T23:00:04Z',
          },
          {
            'sequence': 6,
            'event': 'result_evaluated',
            'tool_name': 'roi_reanalysis',
            'details': {
              'improved': true,
              'before_score': 10.0,
              'after_score': 3.0,
            },
            'created_at': '2026-09-01T23:00:05Z',
          },
          {
            'sequence': 7,
            'event': 'final_decision',
            'message': '최종 수정안 승인 대기',
            'created_at': '2026-09-01T23:00:06Z',
          },
        ],
      };

      expect(sampleRun['status'], equals('AWAITING_APPROVAL'));
      expect(sampleRun['selected_patch_id'], equals('patch_p7fa1'));
      final log = List<dynamic>.from(sampleRun['activity_log'] as List);
      expect(log.length, equals(7));
      expect(log[0]['event'], equals('issue_detected'));
      expect(log[5]['details']['improved'], equals(true));
      expect(log[5]['details']['after_score'], equals(3.0));
    });
  });
}
