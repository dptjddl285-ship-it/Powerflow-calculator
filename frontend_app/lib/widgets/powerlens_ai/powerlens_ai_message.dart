import 'package:flutter/material.dart';

class PowerLensAIMessageItem {
  final String id;
  final String sender; // 'user' or 'assistant'
  final String text;
  final DateTime timestamp;
  final String stage;
  final List<String> suggestedActions;
  final String? agentStatus;

  PowerLensAIMessageItem({
    required this.id,
    required this.sender,
    required this.text,
    DateTime? timestamp,
    this.stage = 'HOME',
    this.suggestedActions = const [],
    this.agentStatus,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => sender == 'user';
}

class PowerLensAIMessageBubble extends StatelessWidget {
  final PowerLensAIMessageItem message;
  final void Function(String action)? onActionSelected;

  const PowerLensAIMessageBubble({
    super.key,
    required this.message,
    this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8B5CF6).withOpacity(0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.auto_awesome, color: Colors.white, size: 15),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14.0,
                    vertical: 10.0,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? const Color(0xFF2563EB)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(14),
                      topRight: const Radius.circular(14),
                      bottomLeft: Radius.circular(isUser ? 14 : 2),
                      bottomRight: Radius.circular(isUser ? 2 : 14),
                    ),
                    border: isUser
                        ? null
                        : Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: _buildRichMessage(context, message.text, isUser),
                ),
                if (message.suggestedActions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: message.suggestedActions.map((action) {
                      return ActionChip(
                        label: Text(
                          action,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1D4ED8),
                          ),
                        ),
                        backgroundColor: const Color(0xFFEFF6FF),
                        side: const BorderSide(color: Color(0xFFBFDBFE)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onActionSelected?.call(action),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Icon(Icons.person, color: Colors.white, size: 16),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRichMessage(BuildContext context, String text, bool isUser) {
    final defaultStyle = TextStyle(
      color: isUser ? Colors.white : const Color(0xFF0F172A),
      fontSize: 12.5,
      height: 1.45,
      letterSpacing: -0.1,
    );

    // Simple markdown-style renderer for bold (**bold**) and normal text
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\*\*(.*?)\*\*');
    int lastIndex = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: text.substring(lastIndex, match.start),
          style: defaultStyle,
        ));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: defaultStyle.copyWith(
          fontWeight: FontWeight.w700,
          color: isUser ? Colors.white : const Color(0xFF1E3A8A),
        ),
      ));
      lastIndex = match.end;
    }

    if (lastIndex < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastIndex),
        style: defaultStyle,
      ));
    }

    return SelectableText.rich(
      TextSpan(children: spans),
    );
  }
}
