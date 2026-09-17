import 'package:flutter/material.dart';
import '../../models/powerlens_assistant_context.dart';
import '../../services/powerlens_ai_service.dart';
import 'powerlens_ai_message.dart';

class PowerLensAIPanel extends StatefulWidget {
  final PowerLensAssistantContext assistantContext;
  final VoidCallback onClose;
  final bool isMobile;

  const PowerLensAIPanel({
    super.key,
    required this.assistantContext,
    required this.onClose,
    this.isMobile = false,
  });

  @override
  State<PowerLensAIPanel> createState() => _PowerLensAIPanelState();
}

class _PowerLensAIPanelState extends State<PowerLensAIPanel> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final PowerLensAIService _aiService = PowerLensAIService();

  @override
  void initState() {
    super.initState();
    _aiService.ensureInitialGreeting(widget.assistantContext.workflowStage);
    _aiService.notifyStageChange(widget.assistantContext);
  }

  @override
  void didUpdateWidget(covariant PowerLensAIPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistantContext.workflowStage !=
        widget.assistantContext.workflowStage) {
      _aiService.notifyStageChange(widget.assistantContext);
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend([String? presetText]) {
    final query = presetText ?? _inputController.text;
    if (query.trim().isEmpty) return;
    _inputController.clear();
    _aiService.sendMessage(query, widget.assistantContext);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    final content = Column(
      children: [
        _buildHeader(),
        _buildQuickActions(),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),
        Expanded(child: _buildMessageList()),
        if (_aiService.isLoading) _buildLoadingIndicator(),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),
        _buildInputRow(),
      ],
    );

    if (widget.isMobile) {
      return Container(
        height: MediaQuery.of(context).size.height * 0.85,
        padding: EdgeInsets.only(bottom: bottomInset),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 16,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: content,
      );
    }

    // Desktop Overlay Panel
    return Container(
      width: 380,
      height: 520,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: content,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "PowerLens AI",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  "도면 분석 & 조류계산 전역 어시스턴트",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            tooltip: "닫기",
            onPressed: widget.onClose,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    final stage = widget.assistantContext.workflowStage;
    final actions = _getStageActionButtons(stage);

    return Container(
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: actions.map((act) {
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text(
                  act,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2563EB),
                  ),
                ),
                avatar: const Icon(Icons.lightbulb_outline, size: 13, color: Color(0xFF2563EB)),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFBFDBFE)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                visualDensity: VisualDensity.compact,
                onPressed: () => _handleSend(act),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  List<String> _getStageActionButtons(String stage) {
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

  Widget _buildMessageList() {
    return AnimatedBuilder(
      animation: _aiService,
      builder: (context, _) {
        final msgs = _aiService.messages;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          itemCount: msgs.length,
          itemBuilder: (context, index) {
            final m = msgs[index];
            return PowerLensAIMessageBubble(
              message: m,
              onActionSelected: (act) => _handleSend(act),
            );
          },
        );
      },
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
          ),
          const SizedBox(width: 8),
          Text(
            "AI 답변 생성 중...",
            style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildInputRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: TextField(
                controller: _inputController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _handleSend(),
                decoration: const InputDecoration(
                  hintText: "질문을 입력하세요 (예: 다음에 뭐 해?)...",
                  hintStyle: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F172A)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Material(
            color: const Color(0xFF2563EB),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _handleSend(),
              child: const Padding(
                padding: EdgeInsets.all(8.0),
                child: Icon(Icons.send_rounded, color: Colors.white, size: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
