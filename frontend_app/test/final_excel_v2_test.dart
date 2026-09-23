import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/models/review_final_contract.dart';
import 'package:circuit_solver/models/review_models.dart';

VerifiedSLD verifiedSld({String status = 'VERIFIED'}) => VerifiedSLD.fromJson({
  'document_id': 'verified-doc',
  'status': status,
  'image': {'width': 100, 'height': 100},
  'nodes': [],
  'lines': [],
});

void main() {
  group('Final Excel V2 contract', () {
    test('F1: Excel import is available only in verified final phase', () {
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: false,
          verifiedSld: verifiedSld(),
        ),
        isFalse,
      );
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: true,
          verifiedSld: verifiedSld(status: 'PENDING'),
        ),
        isFalse,
      );
      expect(
        ReviewFinalContract.canImportExcel(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
        ),
        isTrue,
      );
    });

    test('F2: an unknown comparison is not a verified match', () {
      expect(ReviewFinalContract.hasVerifiedExcelMatch(null), isFalse);
      expect(ReviewFinalContract.hasVerifiedExcelMatch(const {}), isFalse);
      expect(
        ReviewFinalContract.hasVerifiedExcelMatch({'is_matched': 'true'}),
        isFalse,
      );
    });

    test('F3: an explicit Excel mismatch blocks canvas handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': false},
        ),
        isFalse,
      );
    });

    test('F4: absent Excel data blocks canvas handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: null,
          mismatchReport: const {'is_matched': true},
        ),
        isFalse,
      );
    });

    test('F5: only a strict boolean matched report reveals the handoff', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': true},
        ),
        isTrue,
      );
    });

    test('F6: a non-verified diagram can never hand off', () {
      expect(
        ReviewFinalContract.canHandoffToCanvas(
          isFinalPhase: true,
          verifiedSld: verifiedSld(status: 'PENDING'),
          excelData: const {'sbase_mva': 100},
          mismatchReport: const {'is_matched': true},
        ),
        isFalse,
      );
    });

    test(
      'F7: mismatch repair copy is sourced from actual discrepancy messages',
      () {
        expect(
          ReviewFinalContract.mismatchMessages({
            'summary': '한 개 불일치',
            'discrepancies': [
              {'target': 'Bus 7', 'message': '모선 7번이 엑셀에서 누락되었습니다.'},
              {'target': 'Line 1-2'},
              'malformed row',
            ],
          }),
          ['모선 7번이 엑셀에서 누락되었습니다.', 'Line 1-2'],
        );
      },
    );

    test(
      'F8: a missing comparison report remains a blocker, not a green state',
      () {
        expect(
          ReviewFinalContract.canHandoffToCanvas(
            isFinalPhase: true,
            verifiedSld: verifiedSld(),
            excelData: const {'sbase_mva': 100},
            mismatchReport: null,
          ),
          isFalse,
        );
      },
    );
  });
}
