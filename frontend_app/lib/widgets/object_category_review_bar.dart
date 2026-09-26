import 'package:flutter/material.dart';
import '../models/object_visual_sweep.dart';

@immutable
class ObjectReviewCategoryStatus {
  final String key;
  final int count;
  final ObjectCategoryState state;

  const ObjectReviewCategoryStatus({
    required this.key,
    required this.count,
    ObjectCategoryState? state,
    bool? reviewed,
  }) : state = state ??
            (reviewed == true
                ? ObjectCategoryState.reviewed
                : ObjectCategoryState.unreviewed);

  bool get reviewed => state == ObjectCategoryState.reviewed;
  bool get isCurrent => state == ObjectCategoryState.current;
  bool get isUnreviewed => state == ObjectCategoryState.unreviewed;
}

/// Category-level review bar with 3 states: UNREVIEWED (Red), CURRENT (Cyan/Blue pulse), REVIEWED (Green check).
/// Also includes Left (◀ 이전) and Right (확인 후 다음 ▶) navigation buttons and "전체 N" summary badge.
class ObjectCategoryReviewBar extends StatefulWidget {
  final int? totalCount;
  final List<ObjectReviewCategoryStatus> categories;
  final String? selectedCategoryKey;
  final String? nextPendingCategoryKey;
  final bool allReviewed;
  final ValueChanged<String> onSelectCategory;
  final VoidCallback? onConfirmCurrentAndNext;
  final VoidCallback? onPreviousCategory;
  final VoidCallback? onSelectAll;

  const ObjectCategoryReviewBar({
    super.key,
    this.totalCount,
    required this.categories,
    required this.onSelectCategory,
    this.selectedCategoryKey,
    this.nextPendingCategoryKey,
    this.allReviewed = false,
    this.onConfirmCurrentAndNext,
    this.onPreviousCategory,
    this.onSelectAll,
  });

  static Key categoryChipKey(String categoryKey) =>
      ValueKey<String>('object-category-chip-${categoryKey.toLowerCase()}');

  static Key get allChipKey =>
      const ValueKey<String>('object-category-chip-all');
  static Key get prevButtonKey =>
      const ValueKey<String>('object-category-btn-prev');
  static Key get nextButtonKey =>
      const ValueKey<String>('object-category-btn-next');

  @override
  State<ObjectCategoryReviewBar> createState() =>
      _ObjectCategoryReviewBarState();
}

class _ObjectCategoryReviewBarState extends State<ObjectCategoryReviewBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  bool get _hasCurrentOrPending =>
      !widget.allReviewed &&
      widget.categories.any((c) => c.state != ObjectCategoryState.reviewed);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
      lowerBound: 0,
      upperBound: 1,
    );
    _updatePulse();
  }

  @override
  void didUpdateWidget(covariant ObjectCategoryReviewBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePulse();
  }

  void _updatePulse() {
    if (_hasCurrentOrPending) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  int get _computedTotalCount {
    if (widget.totalCount != null) return widget.totalCount!;
    return widget.categories.fold<int>(0, (sum, c) => sum + c.count);
  }

  @override
  Widget build(BuildContext context) {
    final reviewedCount = widget.categories
        .where((category) => category.state == ObjectCategoryState.reviewed)
        .length;

    return Container(
      key: const ValueKey<String>('object-category-review-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.category_rounded,
                size: 14,
                color: Color(0xFF475569),
              ),
              const SizedBox(width: 5),
              const Expanded(
                child: Text(
                  '설비 종류별 확인',
                  style: TextStyle(
                    color: Color(0xFF1E293B),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$reviewedCount/${widget.categories.length} 확인',
                style: TextStyle(
                  color: widget.allReviewed
                      ? const Color(0xFF15803D)
                      : const Color(0xFF64748B),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              // Left Arrow Button (◀ 이전)
              SizedBox(
                height: 26,
                child: OutlinedButton(
                  key: ObjectCategoryReviewBar.prevButtonKey,
                  onPressed: widget.onPreviousCategory,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    side: BorderSide(
                      color: widget.onPreviousCategory != null
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFFE2E8F0),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 9,
                        color: widget.onPreviousCategory != null
                            ? const Color(0xFF334155)
                            : const Color(0xFF94A3B8),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '이전',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: widget.onPreviousCategory != null
                              ? const Color(0xFF334155)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Right Arrow Button (확인 후 다음 ▶)
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  final isNextEnabled = widget.onConfirmCurrentAndNext != null;
                  return SizedBox(
                    height: 26,
                    child: ElevatedButton(
                      key: ObjectCategoryReviewBar.nextButtonKey,
                      onPressed: widget.onConfirmCurrentAndNext,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.allReviewed
                            ? const Color(0xFF15803D)
                            : (isNextEnabled
                                ? const Color(0xFF0284C7)
                                : const Color(0xFF94A3B8)),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        elevation: isNextEnabled && !widget.allReviewed
                            ? 1.5 + _pulseController.value * 2.0
                            : 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.allReviewed ? '확인 완료' : '확인 후 다음',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            widget.allReviewed
                                ? Icons.check_circle_rounded
                                : Icons.arrow_forward_ios_rounded,
                            size: 9,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildAllSummaryChip(),
              ...widget.categories.map((c) => _buildCategoryChip(c)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAllSummaryChip() {
    final isGreen = widget.allReviewed;
    final color =
        isGreen ? const Color(0xFF15803D) : const Color(0xFFDC2626);
    final bgColor =
        isGreen ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2);
    final borderColor =
        isGreen ? const Color(0xFF16A34A) : const Color(0xFFFCA5A5);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ObjectCategoryReviewBar.allChipKey,
        borderRadius: BorderRadius.circular(6),
        onTap: widget.onSelectAll,
        child: Semantics(
          button: true,
          label: '전체 $_computedTotalCount개, ${isGreen ? '확인 완료' : '미완료'}',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isGreen
                      ? Icons.check_circle_outline_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 11,
                  color: color,
                ),
                const SizedBox(width: 4),
                Text(
                  '전체 $_computedTotalCount',
                  style: TextStyle(
                    color: color,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  isGreen ? '확인 완료' : '미완료',
                  style: TextStyle(
                    color: color,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryChip(ObjectReviewCategoryStatus category) {
    final isCurrent = category.state == ObjectCategoryState.current;
    final isReviewed = category.state == ObjectCategoryState.reviewed;
    final isUnreviewed = category.state == ObjectCategoryState.unreviewed;

    final Color color;
    final Color bgColor;
    final Color borderColor;
    final String statusText;
    final IconData icon;

    if (isReviewed) {
      color = const Color(0xFF15803D); // Green
      bgColor = const Color(0xFFECFDF5);
      borderColor = const Color(0xFF16A34A);
      statusText = '확인 완료';
      icon = Icons.check_circle_outline_rounded;
    } else if (isCurrent) {
      color = const Color(0xFF0891B2); // Cyan / Blue
      bgColor = const Color(0xFFECFEFF);
      borderColor = const Color(0xFF06B6D4);
      statusText = '확인 중';
      icon = Icons.radio_button_checked_rounded;
    } else {
      // unreviewed
      color = const Color(0xFFDC2626); // Red
      bgColor = const Color(0xFFFEF2F2);
      borderColor = const Color(0xFFF87171);
      statusText = '미확인';
      icon = Icons.radio_button_unchecked_rounded;
    }

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulseShadow = isCurrent
            ? [
                BoxShadow(
                  color: color.withValues(
                    alpha: 0.25 + 0.35 * _pulseController.value,
                  ),
                  blurRadius: 6.0 + 4.0 * _pulseController.value,
                  spreadRadius: 1.0 + 0.8 * _pulseController.value,
                ),
              ]
            : const <BoxShadow>[];

        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: ObjectCategoryReviewBar.categoryChipKey(category.key),
            borderRadius: BorderRadius.circular(6),
            onTap: () => widget.onSelectCategory(category.key),
            child: Semantics(
              button: true,
              selected: isCurrent,
              label:
                  '${_categoryLabel(category.key)}, ${category.count}개, $statusText',
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7.5, vertical: 4.5),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isCurrent
                        ? Color.lerp(
                            borderColor,
                            const Color(0xFF0284C7),
                            _pulseController.value,
                          )!
                        : borderColor,
                    width: isCurrent ? 1.8 : 1.1,
                  ),
                  boxShadow: pulseShadow,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 11,
                      color: color,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      '${_categoryLabel(category.key)} ${category.count}',
                      style: TextStyle(
                        color: isCurrent || isReviewed
                            ? color
                            : const Color(0xFF334155),
                        fontSize: 9.5,
                        fontWeight: isCurrent || isReviewed
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: color,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _categoryLabel(String key) {
    switch (key.toLowerCase()) {
      case 'bus':
        return 'Bus';
      case 'load':
        return 'Load';
      case 'generator':
        return 'Generator';
      case 'transformer':
        return 'Transformer';
      default:
        if (key.isEmpty) return key;
        return '${key[0].toUpperCase()}${key.substring(1)}';
    }
  }
}
