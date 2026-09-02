import 'dart:convert';

import 'package:http/http.dart' as http;

class ReviewApiException implements Exception {
  final String message;
  ReviewApiException(this.message);

  @override
  String toString() => message;
}

class ReviewApiClient {
  final String baseUrl;

  const ReviewApiClient({this.baseUrl = 'http://127.0.0.1:8000'});

  Future<Map<String, dynamic>> createRoiIssue(
    String documentId, {
    required double xMin,
    required double yMin,
    required double xMax,
    required double yMax,
  }) {
    return _post('/review/documents/$documentId/issues', {
      'roi': {'x_min': xMin, 'y_min': yMin, 'x_max': xMax, 'y_max': yMax},
      'message': '사용자가 회로도에서 누락 후보 영역을 지정했습니다.',
    });
  }

  Future<Map<String, dynamic>> retryIssue(
    String documentId,
    String issueId, {
    String tool = 'auto',
    bool objectOnly = true,
  }) {
    return _post('/review/documents/$documentId/issues/$issueId/retry', {
      'tool': tool,
      'object_only': objectOnly,
    });
  }

  Future<Map<String, dynamic>> scanMissingObjects(String documentId) {
    return _post('/review/documents/$documentId/missing-object-scan', {});
  }

  Future<Map<String, dynamic>> applyPatch(
    String documentId,
    String patchId, {
    List<String>? selectedNodeIds,
  }) {
    final body = <String, dynamic>{'note': '회로도 수정안 미리보기에서 사용자 승인'};
    if (selectedNodeIds != null) {
      body['selected_node_ids'] = selectedNodeIds;
    }
    return _post('/review/documents/$documentId/patches/$patchId/apply', body);
  }

  Future<Map<String, dynamic>> rejectPatch(String documentId, String patchId) {
    return _post('/review/documents/$documentId/patches/$patchId/reject', {
      'note': '회로도 수정안 미리보기에서 사용자 거절',
    });
  }

  Future<Map<String, dynamic>> getAgentRun(
    String documentId,
    String runId,
  ) {
    return _get('/review/documents/$documentId/agent-runs/$runId');
  }

  Future<List<Map<String, dynamic>>> listAgentRuns(String documentId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/review/documents/$documentId/agent-runs'),
      headers: const {'Content-Type': 'application/json'},
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic>
          ? decoded['detail']?.toString()
          : null;
      throw ReviewApiException(detail ?? '검수 API 오류 (${response.statusCode})');
    }
    return (decoded as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await http.get(
      Uri.parse('$baseUrl$path'),
      headers: const {'Content-Type': 'application/json'},
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic>
          ? decoded['detail']?.toString()
          : null;
      throw ReviewApiException(detail ?? '검수 API 오류 (${response.statusCode})');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic>
          ? decoded['detail']?.toString()
          : null;
      throw ReviewApiException(detail ?? '검수 API 오류 (${response.statusCode})');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }
}
