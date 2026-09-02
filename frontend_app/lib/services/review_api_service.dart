import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/review_models.dart';

class ReviewApiService {
  static const String baseUrl = 'http://127.0.0.1:8000';

  Future<ReviewDocument> detectObjects(
    Uint8List imageBytes,
    String filename,
  ) async {
    final uri = Uri.parse('$baseUrl/review/detect_objects');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(
      http.MultipartFile.fromBytes('file', imageBytes, filename: filename),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(
        '객체 검출 요청 실패: HTTP ${response.statusCode} - ${response.body}',
      );
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data['status'] != 'success') {
      throw Exception(data['message'] ?? '객체 검출 실패');
    }

    return ReviewDocument.fromJson(data, rawBytes: imageBytes);
  }

  String getOriginalImageUrl(String documentId) {
    return '$baseUrl/review/image/$documentId';
  }

  Future<Uint8List> fetchOriginalImageBytes(String documentId) async {
    final uri = Uri.parse(getOriginalImageUrl(documentId));
    final response = await http.get(uri);
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception('원본 이미지 다운로드 실패: HTTP ${response.statusCode}');
  }

  Future<Map<String, dynamic>> agentReviewNode(
    String documentId,
    ReviewNodeItem node,
  ) async {
    final uri = Uri.parse('$baseUrl/review/agent_review_node');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'document_id': documentId, 'node': node.toJson()}),
    );

    if (response.statusCode != 200) {
      throw Exception('Agent 검수 실패: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['result'] ?? {};
  }

  Future<CompletenessReviewResult> checkCompleteness({
    required String documentId,
    required List<ReviewNodeItem> workingNodes,
  }) async {
    final uri = Uri.parse('$baseUrl/review/check_completeness');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'working_nodes': workingNodes.map((n) => n.toJson()).toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('도면 완결성 검사 실패: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return CompletenessReviewResult.fromJson(data['result'] ?? {});
  }

  Future<Map<String, dynamic>> verifyObjectsGate({
    required String documentId,
    required List<ReviewNodeItem> workingNodes,
    List<MissingCandidateItem> missingCandidates = const [],
    bool humanCompletenessConfirmed = false,
  }) async {
    final uri = Uri.parse('$baseUrl/review/verify_objects_gate');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'working_nodes': workingNodes.map((n) => n.toJson()).toList(),
        'missing_candidates': missingCandidates.map((c) => c.toJson()).toList(),
        'human_completeness_confirmed': humanCompletenessConfirmed,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Gate 검증 실패: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> detectConnections(
    String documentId,
    List<ReviewNodeItem> confirmedNodes,
  ) async {
    final uri = Uri.parse('$baseUrl/review/detect_connections');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'confirmed_nodes': confirmedNodes.map((n) => n.toJson()).toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('결선 인식 실패: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> traceConnectionCandidate({
    required String documentId,
    required List<ReviewNodeItem> workingNodes,
    required String sourceNodeId,
    required String targetNodeId,
  }) async {
    final uri = Uri.parse('$baseUrl/review/trace_connection_candidate');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'working_nodes': workingNodes.map((node) => node.toJson()).toList(),
        'source_node_id': sourceNodeId,
        'target_node_id': targetNodeId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('선로 픽셀 재추적 실패: HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> agentReviewConnection({
    required String documentId,
    required ReviewLineItem line,
    required List<ReviewNodeItem> nodes,
    required List<ReviewLineItem> lines,
  }) async {
    final uri = Uri.parse('$baseUrl/review/agent_review_connection');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'line': line.toJson(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'lines': lines.map((l) => l.toJson()).toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Agent 결선 검수 실패: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return data['result'] ?? {};
  }

  Future<Map<String, dynamic>> validateTopology({
    required String documentId,
    required List<ReviewNodeItem> nodes,
    required List<ReviewLineItem> lines,
  }) async {
    final uri = Uri.parse('$baseUrl/review/validate_topology');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'lines': lines.map((l) => l.toJson()).toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('토폴로지 유효성 검사 실패: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> verifyFinalGate({
    required String documentId,
    required List<ReviewNodeItem> workingNodes,
    required List<ReviewLineItem> workingLines,
    bool humanCompletenessConfirmed = false,
  }) async {
    final uri = Uri.parse('$baseUrl/review/verify_final_gate');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'working_nodes': workingNodes.map((n) => n.toJson()).toList(),
        'working_lines': workingLines.map((l) => l.toJson()).toList(),
        'human_completeness_confirmed': humanCompletenessConfirmed,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('최종 회로도 검증 실패: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> sendAgentChat({
    required String documentId,
    required String message,
    required String stage,
    ReviewNodeItem? selectedNode,
    ReviewLineItem? selectedLine,
    List<ReviewNodeItem> workingNodes = const [],
    List<ReviewLineItem> workingLines = const [],
    List<MissingCandidateItem> missingCandidates = const [],
    List<Map<String, dynamic>> topologyIssues = const [],
    List<ChatMessageItem> history = const [],
  }) async {
    final uri = Uri.parse('$baseUrl/review/agent_chat');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'message': message,
        'stage': stage,
        if (selectedNode != null) 'selected_node': selectedNode.toJson(),
        if (selectedLine != null) 'selected_line': selectedLine.toJson(),
        'working_nodes': workingNodes.map((n) => n.toJson()).toList(),
        'working_lines': workingLines.map((l) => l.toJson()).toList(),
        'missing_candidates': missingCandidates.map((c) => c.toJson()).toList(),
        'topology_issues': topologyIssues,
        'history': history.map((h) => h.toPayload()).toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Agent 대화 실패: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<ProactiveSummaryItem> fetchProactiveSummary({
    required String documentId,
    required String stage,
    List<ReviewNodeItem> workingNodes = const [],
    List<ReviewLineItem> workingLines = const [],
    List<MissingCandidateItem> missingCandidates = const [],
    List<Map<String, dynamic>> topologyIssues = const [],
  }) async {
    final uri = Uri.parse('$baseUrl/review/proactive_summary');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document_id': documentId,
        'stage': stage,
        'working_nodes': workingNodes.map((n) => n.toJson()).toList(),
        'working_lines': workingLines.map((l) => l.toJson()).toList(),
        'missing_candidates': missingCandidates.map((c) => c.toJson()).toList(),
        'topology_issues': topologyIssues,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Proactive Summary 요청 실패: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return ProactiveSummaryItem.fromJson(data);
  }

  Future<List<Map<String, dynamic>>> fetchAgentRuns(String documentId) async {
    final uri = Uri.parse('$baseUrl/review/documents/$documentId/agent-runs');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Agent 활동 기록 조회 실패: HTTP ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is List) {
      return data.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> fetchAgentRun(String documentId, String runId) async {
    final uri = Uri.parse('$baseUrl/review/documents/$documentId/agent-runs/$runId');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Agent 실행 상세 조회 실패: HTTP ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return Map<String, dynamic>.from(data as Map);
  }
}
