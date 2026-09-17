import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/powerlens_assistant_context.dart';
import '../widgets/powerlens_ai/powerlens_ai_message.dart';

class PowerLensAIService extends ChangeNotifier {
  static final PowerLensAIService _instance = PowerLensAIService._internal();
  factory PowerLensAIService() => _instance;
  static PowerLensAIService get instance => _instance;
  PowerLensAIService._internal();

  static const String baseUrl = 'http://127.0.0.1:8000';

  final List<PowerLensAIMessageItem> _messages = [];
  List<PowerLensAIMessageItem> get messages => List.unmodifiable(_messages);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _lastNotifiedStage;

  void ensureInitialGreeting(String stage) {
    if (_messages.isNotEmpty) return;

    final greeting = _getStageGreeting(stage);
    _messages.add(
      PowerLensAIMessageItem(
        id: 'msg_welcome',
        sender: 'assistant',
        text: greeting,
        stage: stage,
        suggestedActions: _getQuickActions(stage),
        agentStatus: 'LOCAL_READY',
      ),
    );
    _lastNotifiedStage = stage;
    notifyListeners();
  }

  void notifyStageChange(PowerLensAssistantContext context) {
    final newStage = context.workflowStage;
    if (_lastNotifiedStage == newStage) return;
    _lastNotifiedStage = newStage;

    final proactiveText = _getStageProactiveText(context);
    if (proactiveText != null) {
      _messages.add(
        PowerLensAIMessageItem(
          id: 'proactive_${DateTime.now().millisecondsSinceEpoch}',
          sender: 'assistant',
          text: proactiveText,
          stage: newStage,
          suggestedActions: _getQuickActions(newStage),
          agentStatus: 'PROACTIVE',
        ),
      );
      notifyListeners();
    }
  }

  void onStageChanged(String stage, [PowerLensAssistantContext? context]) {
    if (_lastNotifiedStage == stage) return;
    _lastNotifiedStage = stage;

    String? proactiveText;
    if (stage == 'EXCEL_LOADED') {
      proactiveText = "제원이 연결되었습니다. 조류계산을 실행할 수 있습니다.";
    } else if (stage == 'POWERFLOW_CONVERGED') {
      proactiveText = "계산이 수렴했습니다. 결과를 같이 살펴볼까요?";
    } else if (context != null) {
      proactiveText = _getStageProactiveText(context);
    } else {
      switch (stage) {
        case 'HOME':
          proactiveText = "단선도를 불러오면 객체와 연결 상태를 함께 확인해드릴게요.";
          break;
        case 'OBJECT_REVIEW':
          proactiveText = "객체 분석이 끝났습니다. 확인이 필요한 항목만 먼저 살펴보세요.";
          break;
        case 'BUS_MAPPING':
          proactiveText = "이제 모선 번호를 확인합니다.";
          break;
        case 'CONNECTION_REVIEW':
          proactiveText = "모선 확인이 끝났습니다. 다음은 선로 연결 상태를 확인합니다.";
          break;
        case 'FINAL':
        case 'FINAL_CAD':
          proactiveText = "단선도 검증이 끝났습니다. 조류계산을 위해 계통 제원을 연결할 수 있습니다.";
          break;
      }
    }

    if (proactiveText != null) {
      _messages.add(
        PowerLensAIMessageItem(
          id: 'proactive_${DateTime.now().millisecondsSinceEpoch}',
          sender: 'assistant',
          text: proactiveText,
          stage: stage,
          suggestedActions: _getQuickActions(stage),
          agentStatus: 'PROACTIVE',
        ),
      );
      notifyListeners();
    }
  }

  Future<void> sendMessage(String text, PowerLensAssistantContext context) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isLoading) return;

    final userMsg = PowerLensAIMessageItem(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      sender: 'user',
      text: trimmed,
      stage: context.workflowStage,
    );
    _messages.add(userMsg);
    _isLoading = true;
    notifyListeners();

    try {
      final uri = Uri.parse('$baseUrl/review/agent_chat');
      final payload = {
        'document_id': context.documentId,
        'message': trimmed,
        'stage': context.workflowStage,
        'working_nodes': [],
        'working_lines': [],
        'missing_candidates': [],
        'topology_issues': [],
        'history': _buildHistoryPayload(),
        'app_context': context.toJson(),
      };

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final result = data['result'] ?? {};
        final replyKo = result['reply_ko']?.toString() ?? '답변을 생성하지 못했습니다.';
        final agentStatus = result['agent_status']?.toString() ?? 'LOCAL_FALLBACK';
        final actions = (result['suggested_actions'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            _getQuickActions(context.workflowStage);

        _messages.add(
          PowerLensAIMessageItem(
            id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
            sender: 'assistant',
            text: replyKo,
            stage: context.workflowStage,
            suggestedActions: actions,
            agentStatus: agentStatus,
          ),
        );
      } else {
        _addLocalFallbackMessage(trimmed, context);
      }
    } catch (e) {
      _addLocalFallbackMessage(trimmed, context);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _addLocalFallbackMessage(String userQuery, PowerLensAssistantContext context) {
    String reply;
    final stage = context.workflowStage;

    if (userQuery.contains('다음에') || userQuery.contains('뭐 해') || userQuery.contains('다음')) {
      reply = _getNextActionAnswer(context);
    } else if (userQuery.contains('상태') || userQuery.contains('요약')) {
      reply = _getStatusSummary(context);
    } else if (userQuery.contains('엑셀') || userQuery.contains('제원')) {
      reply = "📊 **엑셀 계통 제원 연결 가이드:**\n"
          "1. 상단 메뉴의 [엑셀 가져오기] 버튼을 클릭합니다.\n"
          "2. 모선(Bus) 데이터와 선로(Branch) 임피던스(R, X, B)가 포함된 엑셀(.xlsx) 파일을 선택하세요.\n"
          "3. 연결이 완료되면 조류계산 실행 버튼이 활성화됩니다.";
    } else if (userQuery.contains('조류계산') || userQuery.contains('조건')) {
      reply = "⚡ **조류계산 실행 준비 조건:**\n"
          "1. 단선도 검증 완료 (고립 모선 없음, 슬랙 모선 지정됨)\n"
          "2. 엑셀 계통 제원(R, X, P, Q, V) 연결 완료\n"
          "3. 준비가 완료되면 [조류계산 실행]을 눌러 뉴턴-랩슨 수치해석을 진행하세요.";
    } else {
      reply = "🤖 **PowerLens 도면 어시스턴트 (로컬 모드):**\n\n"
          "현재 **${_getStageNameKo(stage)}** 단계입니다.\n"
          "${_getNextActionAnswer(context)}";
    }

    _messages.add(
      PowerLensAIMessageItem(
        id: 'ai_fallback_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'assistant',
        text: reply,
        stage: stage,
        suggestedActions: _getQuickActions(stage),
        agentStatus: 'LOCAL_FALLBACK',
      ),
    );
  }

  String _getNextActionAnswer(PowerLensAssistantContext ctx) {
    switch (ctx.workflowStage) {
      case 'HOME':
        return "💡 **다음 할 일 (홈):**\n"
            "1. 중앙의 **[단선도 AI 분석 시작하기]** 또는 **[IEEE-24 샘플로 체험]** 버튼을 누르세요.\n"
            "2. 이미지를 업로드하면 AI가 모선, 변압기, 발전기, 부하, 선로를 자동 탐지합니다.";
      case 'OBJECT_REVIEW':
        if (ctx.suspiciousObjects > 0) {
          return "💡 **다음 할 일 (객체 검수):**\n"
              "• **검토 필요 객체**: ${ctx.suspiciousObjects}건이 남아 있습니다.\n"
              "• 도면에서 노란색/주황색 심볼을 확인하고 [승인] 또는 [제외]를 선택하세요.\n"
              "• 모든 검토가 끝나면 하단의 **[객체 검수 완료 ➔]**를 눌러 모선 번호 확인으로 이동하세요.";
        } else {
          return "💡 **다음 할 일 (객체 검수 완료):**\n"
              "• 모든 객체 검수가 정상 완료되었습니다! (검토 필요 0건)\n"
              "• 하단의 **[객체 검수 완료 ➔]**를 눌러 **모선 번호 매핑** 단계로 넘어가세요.";
        }
      case 'BUS_MAPPING':
        if (ctx.unresolvedBusNumbers > 0 || ctx.duplicateBusNumbers > 0) {
          return "💡 **다음 할 일 (모선 번호 매핑):**\n"
              "• 미지정 모선 ${ctx.unresolvedBusNumbers}개, 중복 번호 ${ctx.duplicateBusNumbers}건이 있습니다.\n"
              "• 각 모선 바(Bar)를 클릭하여 올바른 모선 번호(1~24번)를 입력/확정하세요.";
        } else {
          return "💡 **다음 할 일 (모선 번호 매핑 완료):**\n"
              "• 모선 번호가 모두 올바르게 매핑되었습니다.\n"
              "• 하단 **[모선 확정 ➔ 결선 검수로]** 버튼을 눌러 다음 단계로 진행하세요.";
        }
      case 'CONNECTION_REVIEW':
        if (ctx.topologyIssueCount > 0) {
          return "💡 **다음 할 일 (결선 검수):**\n"
              "• 감지된 연결 구조 결함: ${ctx.topologyIssueCount}건\n"
              "• 붉은색 결선 오류를 확인하고 올바른 모선으로 재지정하거나 선로를 승인하세요.";
        } else {
          return "💡 **다음 할 일 (결선 검수 완료):**\n"
              "• 토폴로지 연결 상태가 모두 정상입니다.\n"
              "• **[결선 확정 ➔ 최종 검증]**을 눌러 완성된 단선도를 확인하세요.";
        }
      case 'FINAL':
      case 'FINAL_CAD':
        if (!ctx.excelLoaded) {
          return "💡 **다음 할 일 (계통 제원 연결):**\n"
              "• 단선도 검증이 끝났습니다!\n"
              "• 상단 메뉴의 **[엑셀 가져오기]**를 눌러 선로 임피던스와 발전/부하 제원 엑셀을 연결하세요.";
        } else if (ctx.powerflowConverged == true) {
          return "💡 **다음 할 일 (해석 완료):**\n"
              "• 조류계산이 성공적으로 수렴했습니다!\n"
              "• 상단 **[수치 결과표]**를 눌러 모선 전압과 선로 조류/손실을 확인하거나 엑셀로 다운로드하세요.";
        } else {
          return "💡 **다음 할 일 (조류계산 실행):**\n"
              "• 제원이 연결되었습니다. 우측 상단의 파란색 **[조류계산 실행]** 버튼을 눌러 수치해석을 시작하세요.";
        }
      default:
        return "💡 현재 단계를 진행하기 위해 화면의 안내 버튼을 확인해주세요.";
    }
  }

  String _getStatusSummary(PowerLensAssistantContext ctx) {
    final sb = StringBuffer();
    sb.writeln("📊 **현재 계통 및 도면 상태 요약:**");
    sb.writeln("• **현재 단계**: ${_getStageNameKo(ctx.workflowStage)}");
    if (ctx.hasDiagram) {
      sb.writeln("• **인식된 객체**: 총 ${ctx.totalObjects}개 (검토 필요: ${ctx.suspiciousObjects}개)");
      if (ctx.totalBuses > 0) {
        sb.writeln("• **모선(Bus)**: ${ctx.totalBuses}개 (미확정: ${ctx.unresolvedBusNumbers}개)");
      }
      if (ctx.totalConnections > 0) {
        sb.writeln("• **연결 선로**: ${ctx.totalConnections}개 (오류: ${ctx.topologyIssueCount}건)");
      }
    } else {
      sb.writeln("• 아직 분석할 단선도가 업로드되지 않았습니다.");
    }
    sb.writeln("• **제원 엑셀**: ${ctx.excelLoaded ? '연결 완료' : '미연결'}");
    sb.writeln("• **조류계산 준비**: ${ctx.powerflowReady ? '준비 완료' : '추가 작업 필요'}");
    return sb.toString();
  }

  String _getStageGreeting(String stage) {
    switch (stage) {
      case 'HOME':
        return "👋 안녕하세요! PowerLens AI 어시스턴트입니다.\n"
            "단선도 도면을 불러오시면 AI 객체 탐지부터 결선 검수, 엑셀 제원 연결 및 조류계산까지 전 과정을 친절히 안내해 드립니다.\n"
            "시작하려면 아래 **[다음에 뭐 해?]**를 누르거나 단선도 분석을 시작해보세요!";
      case 'OBJECT_REVIEW':
        return "🔍 **객체 검수 단계입니다.**\n"
            "AI가 도면에서 탐지한 모선, 발전기, 부하, 변압기 심볼의 위치와 종류를 확인해 주세요. "
            "검토가 필요한 항목만 우선적으로 확인하시면 빠르게 넘어갈 수 있습니다.";
      case 'BUS_MAPPING':
        return "🔢 **모선 번호 매핑 단계입니다.**\n"
            "각 모선에 부여된 번호(예: 1~24번)가 도면의 표기와 맞는지 확인해 주세요.";
      case 'CONNECTION_REVIEW':
        return "⚡ **결선 검수 단계입니다.**\n"
            "모선과 모선, 모선과 기기 간 선로 연결 상태와 분기 관계 오류를 검토해 주세요.";
      case 'FINAL':
      case 'FINAL_CAD':
        return "✨ **검증된 단선도(Verified SLD)가 완성되었습니다!**\n"
            "이제 엑셀 제원을 연결하여 뉴턴-랩슨 조류계산을 수행할 수 있습니다.";
      default:
        return "👋 PowerLens AI입니다. 무엇이든 편하게 물어보세요!";
    }
  }

  String? _getStageProactiveText(PowerLensAssistantContext ctx) {
    switch (ctx.workflowStage) {
      case 'HOME':
        return "단선도를 불러오면 객체와 연결 상태를 함께 확인해드릴게요.";
      case 'OBJECT_REVIEW':
        return "객체 분석이 끝났습니다. 확인이 필요한 항목만 먼저 살펴보세요.";
      case 'BUS_MAPPING':
        return "이제 모선 번호를 확인합니다.";
      case 'CONNECTION_REVIEW':
        return "모선 확인이 끝났습니다. 다음은 선로 연결 상태를 확인합니다.";
      case 'FINAL':
      case 'FINAL_CAD':
        return "단선도 검증이 끝났습니다. 조류계산을 위해 계통 제원을 연결할 수 있습니다.";
      default:
        return null;
    }
  }

  List<String> _getQuickActions(String stage) {
    switch (stage) {
      case 'HOME':
        return ['다음에 뭐 해?', '현재 상태 요약', '지원 도면 안내'];
      case 'OBJECT_REVIEW':
        return ['다음에 뭐 해?', '현재 상태 요약', '검토 필요 항목'];
      case 'BUS_MAPPING':
        return ['다음에 뭐 해?', '미지정 모선 확인', '현재 상태 요약'];
      case 'CONNECTION_REVIEW':
        return ['다음에 뭐 해?', '연결 오류 점검', '현재 상태 요약'];
      case 'FINAL':
      case 'FINAL_CAD':
        return ['다음에 뭐 해?', '엑셀 제원 연결 방법', '조류계산 조건'];
      default:
        return ['다음에 뭐 해?', '현재 상태 요약'];
    }
  }

  String _getStageNameKo(String stage) {
    switch (stage) {
      case 'HOME':
        return '홈 (도면 준비)';
      case 'OBJECT_REVIEW':
        return '객체 확인 (1단계)';
      case 'BUS_MAPPING':
        return '모선 번호 확인 (2단계)';
      case 'CONNECTION_REVIEW':
        return '결선 확인 (3단계)';
      case 'FINAL':
      case 'FINAL_CAD':
        return '최종 검증 & CAD (4단계)';
      default:
        return stage;
    }
  }

  List<Map<String, String>> _buildHistoryPayload() {
    return _messages.take(10).map((m) {
      return {
        'role': m.isUser ? 'user' : 'model',
        'parts': m.text,
      };
    }).toList();
  }

  void clearHistory() {
    _messages.clear();
    _lastNotifiedStage = null;
    notifyListeners();
  }
}
