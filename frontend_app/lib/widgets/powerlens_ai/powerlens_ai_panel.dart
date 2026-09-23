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

  double _panelWidth = 380;
  double _panelHeight = 520;
  bool _isMaximized = false;
  Offset? _resizeOrigin;
  double _resizeOriginWidth = 380;
  double _resizeOriginHeight = 520;
  Offset _panelOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _panelOffset = _aiService.panelOffset;
    _aiService.refreshProviderStatus();
    _aiService.ensureInitialGreeting(
      widget.assistantContext.workflowStage,
      widget.assistantContext,
    );
    _aiService.notifyStageChange(widget.assistantContext);
  }

  void _updatePanelOffset(
    Offset delta,
    Size screenSize,
    double currentWidth,
    double currentHeight,
  ) {
    if (_isMaximized) return;

    // Boundary clamping so the panel cannot be dragged outside visible view.
    // Panel is anchored at bottom-right (right: 20, bottom: 70~130).
    final minDx = -(screenSize.width - currentWidth - 30.0);
    final maxDx = 10.0;
    final minDy = -(screenSize.height - currentHeight - 40.0);
    final maxDy = 50.0;

    final newDx = (_panelOffset.dx + delta.dx).clamp(minDx, maxDx).toDouble();
    final newDy = (_panelOffset.dy + delta.dy).clamp(minDy, maxDy).toDouble();

    setState(() {
      _panelOffset = Offset(newDx, newDy);
      _aiService.panelOffset = _panelOffset;
    });
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
    if (_aiService.isLoading) return;
    final query = presetText ?? _inputController.text;
    if (query.trim().isEmpty) return;
    _inputController.clear();
    _aiService.sendMessage(query, widget.assistantContext);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = (screenSize.width * 0.76).clamp(380.0, 980.0).toDouble();
    final maxHeight = (screenSize.height * 0.84).clamp(520.0, 760.0).toDouble();
    final panelWidth = _isMaximized
        ? maxWidth
        : _panelWidth.clamp(320.0, maxWidth).toDouble();
    final panelHeight = _isMaximized
        ? maxHeight
        : _panelHeight.clamp(420.0, maxHeight).toDouble();

    final content = AnimatedBuilder(
      animation: _aiService,
      builder: (context, _) => Column(
        children: [
          _buildHeader(screenSize, panelWidth, panelHeight),
          _buildQuickActions(),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(child: _buildMessageList()),
          if (_aiService.isLoading) _buildLoadingIndicator(),
          if (_aiService.lastFailedQuery != null && !_aiService.isLoading)
            _buildRetryBanner(),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          _buildInputRow(),
        ],
      ),
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

    // Desktop overlay panel with draggable support.
    final desktopPanel = Container(
      width: panelWidth,
      height: panelHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _panelOffset != Offset.zero
              ? const Color(0xFF38BDF8).withOpacity(0.6)
              : const Color(0xFFCBD5E1),
          width: _panelOffset != Offset.zero ? 1.5 : 1,
        ),
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
        child: Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              right: 0,
              bottom: 0,
              child: _buildResizeHandle(maxWidth, maxHeight),
            ),
          ],
        ),
      ),
    );

    return Transform.translate(
      offset: _isMaximized ? Offset.zero : _panelOffset,
      child: desktopPanel,
    );
  }

  Widget _buildResizeHandle(double maxWidth, double maxHeight) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          if (_isMaximized) return;
          _resizeOrigin = details.globalPosition;
          _resizeOriginWidth = _panelWidth;
          _resizeOriginHeight = _panelHeight;
        },
        onPanUpdate: (details) {
          if (_isMaximized || _resizeOrigin == null) return;
          setState(() {
            _panelWidth =
                (_resizeOriginWidth +
                        details.globalPosition.dx -
                        _resizeOrigin!.dx)
                    .clamp(320.0, maxWidth)
                    .toDouble();
            _panelHeight =
                (_resizeOriginHeight +
                        details.globalPosition.dy -
                        _resizeOrigin!.dy)
                    .clamp(420.0, maxHeight)
                    .toDouble();
          });
        },
        onPanEnd: (_) => _resizeOrigin = null,
        child: const SizedBox(
          width: 26,
          height: 26,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.all(5),
              child: Icon(
                Icons.drag_handle,
                size: 15,
                color: Color(0xFF94A3B8),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Size screenSize, double panelWidth, double panelHeight) {
    final bool isGemini = _aiService.geminiStatus == 'CONNECTED';
    final bool isMoved = _panelOffset != Offset.zero && !_isMaximized;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          // Draggable header area
          Expanded(
            child: MouseRegion(
              cursor: widget.isMobile
                  ? MouseCursor.defer
                  : SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.isMobile
                    ? null
                    : () {
                        setState(() {
                          _panelOffset = Offset.zero;
                          _aiService.resetPanelOffset();
                        });
                      },
                onPanUpdate: widget.isMobile
                    ? null
                    : (details) {
                        _updatePanelOffset(
                          details.delta,
                          screenSize,
                          panelWidth,
                          panelHeight,
                        );
                      },
                child: Row(
                  children: [
                    if (!widget.isMobile)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Tooltip(
                          message: "헤더를 드래그하여 채팅창 이동\n(더블클릭 시 원래 위치로 복원)",
                          child: Icon(
                            Icons.drag_indicator,
                            color: Colors.white54,
                            size: 18,
                          ),
                        ),
                      ),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white30, width: 1),
                      ),
                      child: const Icon(
                        Icons.smart_toy_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 2,
                            children: [
                              const Text(
                                "Lensy AI",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: isGemini
                                      ? const Color(0x3322C55E)
                                      : const Color(0x3338BDF8),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isGemini
                                        ? const Color(0xFF22C55E)
                                        : const Color(0xFF38BDF8),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: isGemini
                                            ? const Color(0xFF22C55E)
                                            : const Color(0xFF38BDF8),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        isGemini ? "Gemini" : "로컬 AI",
                                        style: TextStyle(
                                          color: isGemini
                                              ? const Color(0xFF86EFAC)
                                              : const Color(0xFFBAE6FD),
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Text(
                            !widget.isMobile && isMoved
                                ? "드래그로 위치 이동됨 (더블클릭 시 복원)"
                                : "앱 조작 및 계통 검수 동반자",
                            style: TextStyle(
                              color: !widget.isMobile && isMoved
                                  ? const Color(0xFF38BDF8)
                                  : Colors.white.withOpacity(0.7),
                              fontSize: 10.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (!widget.isMobile && isMoved) ...[
            IconButton(
              icon: const Icon(
                Icons.restart_alt,
                color: Color(0xFF38BDF8),
                size: 18,
              ),
              tooltip: "원래 위치로 복원",
              onPressed: () => setState(() {
                _panelOffset = Offset.zero;
                _aiService.resetPanelOffset();
              }),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
          ],
          if (!widget.isMobile)
            IconButton(
              icon: Icon(
                _isMaximized ? Icons.close_fullscreen : Icons.open_in_full,
                color: Colors.white70,
                size: 18,
              ),
              tooltip: _isMaximized ? "채팅 패널 크기 복원" : "채팅 패널 크게 보기",
              onPressed: () => setState(() => _isMaximized = !_isMaximized),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          if (!widget.isMobile) const SizedBox(width: 8),
          IconButton(
            icon: const Icon(
              Icons.help_outline,
              color: Colors.white60,
              size: 18,
            ),
            tooltip: "AI 연결 상태 안내",
            onPressed: () => _showApiStatusDialog(context, isGemini),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
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

  void _showApiStatusDialog(BuildContext context, bool isGemini) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isGemini ? Icons.check_circle : Icons.info_outline,
              color: isGemini ? Colors.greenAccent : Colors.cyanAccent,
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              isGemini ? "Gemini AI 연결 상태" : "로컬 도우미 모드 동작 중",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isGemini
                  ? "✅ 백엔드를 통해 Google Gemini 모델과 실시간 연결되어 자연스러운 심층 추론 대화를 제공하고 있습니다."
                  : "⚡ 현재 백엔드 로컬 도우미 모드로 동작 중입니다.\n\n"
                        "• 도면 이동, 샘플 불러오기, 단계 전환, 조류계산 실행 등 모든 앱 조작 명령은 로컬 규칙으로 100% 정상 작동합니다.\n"
                        "• 백엔드 .env 파일에 GEMINI_API_KEY를 등록하시면 실시간 생성형 AI 추론 기능이 활성화됩니다.",
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              "확인",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
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
                avatar: const Icon(
                  Icons.bolt,
                  size: 13,
                  color: Color(0xFF2563EB),
                ),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFBFDBFE)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                visualDensity: VisualDensity.compact,
                onPressed: _aiService.isLoading ? null : () => _handleSend(act),
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
        return ['샘플 도면 불러줘', '사진 다시 넣을래', '이 단계에서 뭘 해야 해?'];
      case 'OBJECT_REVIEW':
        final hasIssues = widget.assistantContext.suspiciousObjects > 0 ||
            widget.assistantContext.unresolvedMissingCandidates > 0;
        return [
          hasIssues
              ? '검토 필요 항목 (${widget.assistantContext.suspiciousObjects})'
              : '객체 검수 완료하기',
          '다음 단계로 넘어가',
          '이 단계에서 뭘 해야 해?'
        ];
      case 'BUS_MAPPING':
        final hasBusIssues = widget.assistantContext.unresolvedBusNumbers > 0 ||
            widget.assistantContext.duplicateBusNumbers > 0;
        return [
          hasBusIssues ? '미지정 모선 확인' : '모선 번호 승인하기',
          '다음 단계로 넘어가',
          '이 단계에서 뭘 해야 해?'
        ];
      case 'CONNECTION_REVIEW':
        final hasConnIssues = widget.assistantContext.ambiguousConnections > 0 ||
            widget.assistantContext.topologyIssueCount > 0;
        return [
          hasConnIssues ? '연결 오류 점검' : '결선 검수 완료하기',
          '다음 단계로 넘어가',
          '이 단계에서 뭘 해야 해?'
        ];
      case 'FINAL':
      case 'FINAL_CAD':
        return ['조류계산 해줘', '흐름 방향 보여줘', '이 단계에서 뭘 해야 해?'];
      default:
        return ['처음 화면으로 돌아가줘', '다음 단계로 가자', '이 단계에서 뭘 해야 해?'];
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            "확인하고 있어요…",
            style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildRetryBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFFFFBEB),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 15, color: Color(0xFFD97706)),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              "응답이 늦어졌어요. 다시 시도할까요?",
              style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
            ),
          ),
          TextButton(
            onPressed: () =>
                _aiService.retryLastMessage(widget.assistantContext),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text("다시 시도", style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildInputRow() {
    final isDisabled = _aiService.isLoading;
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
                enabled: !isDisabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _handleSend(),
                decoration: const InputDecoration(
                  hintText: "질문을 입력하세요 (예: 다음에 뭐 해?)...",
                  hintStyle: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Material(
            color: isDisabled
                ? const Color(0xFF94A3B8)
                : const Color(0xFF2563EB),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: isDisabled ? null : () => _handleSend(),
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
