import 'package:flutter/material.dart';
import '../models/object_visual_sweep.dart';
import 'powerlens_ai/glowing_target_wrapper.dart';

class ObjectCategoryReviewBar extends StatelessWidget {
  final int totalCount;
  final Map<ObjectCategory, int> categoryCounts;
  final Set<ObjectCategory> reviewedCategories;
  final ObjectCategory? activeCategory;
  final bool interactionEnabled;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<ObjectCategory> onSelectCategory;

  const ObjectCategoryReviewBar({
    super.key,
    required this.totalCount,
    required this.categoryCounts,
    required this.reviewedCategories,
    required this.activeCategory,
    required this.interactionEnabled,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectCategory,
  });

  @override
  Widget build(BuildContext context) {
    final allReviewed =
        reviewedCategories.length == ObjectCategory.values.length;
    return GlowingTargetWrapper(
      targetId: 'object_category_bar',
      borderRadius: BorderRadius.circular(8),
      guideLabel: '✨ 객체 종류를 하나씩 확인',
      child: Container(
        key: const ValueKey('object-category-review-bar'),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _CategoryBadge(
              key: const ValueKey('object-category-chip-all'),
              label: '전체',
              count: totalCount,
              reviewed: allReviewed,
            ),
            for (final category in ObjectCategory.values)
              _CategoryBadge(
                key: ValueKey('object-category-chip-${category.name}'),
                label: category.label,
                count: categoryCounts[category] ?? 0,
                reviewed: reviewedCategories.contains(category),
                isCurrent: activeCategory == category,
                onTap: interactionEnabled
                    ? () => onSelectCategory(category)
                    : null,
              ),
            IconButton(
              key: const ValueKey('object-category-previous'),
              tooltip: '이전 종류 (←)',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            IconButton(
              key: const ValueKey('object-category-next'),
              tooltip: '다음 종류 (→)',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  final String label;
  final int count;
  final bool reviewed;
  final bool isCurrent;
  final VoidCallback? onTap;

  const _CategoryBadge({
    super.key,
    required this.label,
    required this.count,
    required this.reviewed,
    this.isCurrent = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF15803D);
    const red = Color(0xFFB91C1C);
    const cyan = Color(0xFF0891B2);
    final statusColor = reviewed ? green : red;
    final status = reviewed ? '확인' : '미확인';
    return Semantics(
      button: onTap != null,
      label: '$label $count개, $status',
      child: Tooltip(
        message: '$label $count개 · $status',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(
                color: reviewed
                    ? const Color(0xFFDCFCE7)
                    : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isCurrent ? cyan : statusColor,
                  width: isCurrent ? 2 : 1,
                ),
                boxShadow: isCurrent
                    ? [
                        BoxShadow(
                          color: cyan.withValues(alpha: 0.32),
                          blurRadius: 7,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    reviewed
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 12,
                    color: statusColor,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '$label $count',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
