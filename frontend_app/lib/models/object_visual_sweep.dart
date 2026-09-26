import 'package:flutter/material.dart';
import 'review_models.dart';

/// High-contrast CTA action color distinct from category colors (especially Bus cyan)
const Color objectReviewCtaColor = Color(0xFFEA580C);

/// Distinct identity color per equipment category
Color objectCategoryColor(String? className) {
  if (className == null) return const Color(0xFF64748B);
  switch (className.trim().toLowerCase()) {
    case 'bus':
      return const Color(0xFF06B6D4); // Cyan / sky blue
    case 'load':
      return const Color(0xFFF97316); // Orange / amber
    case 'generator':
    case 'gen':
      return const Color(0xFF10B981); // Green
    case 'transformer':
    case 'trans':
      return const Color(0xFFA855F7); // Purple / violet
    default:
      return const Color(0xFF0284C7);
  }
}

enum ObjectReviewFlowStage {
  exceptionReview,
  categoryReview,
  // Kept as a wire-compatible legacy value; the normal flow now reviews
  // detected categories rather than asking users to visit every object.
  visualSweep,
  waitingHumanComplete,
  readyToComplete,
}

extension ObjectReviewFlowStageName on ObjectReviewFlowStage {
  String get wireName => switch (this) {
    ObjectReviewFlowStage.exceptionReview => 'EXCEPTION_REVIEW',
    ObjectReviewFlowStage.categoryReview => 'CATEGORY_REVIEW',
    ObjectReviewFlowStage.visualSweep => 'VISUAL_SWEEP',
    ObjectReviewFlowStage.waitingHumanComplete => 'WAITING_HUMAN_COMPLETE',
    ObjectReviewFlowStage.readyToComplete => 'READY_TO_COMPLETE',
  };
}

enum ObjectCategoryState {
  unreviewed,
  current,
  reviewed,
}

/// Tracks the ordered visual pass without changing object classification.
/// Suspicious objects count as visited only after an explicit resolution.
class ObjectVisualSweepState {
  final Set<String> visitedObjectIds = <String>{};
  final Set<String> reviewedCategoryKeys = <String>{};
  final Map<String, Set<String>> _reviewedCategoryObjectIds = {};
  bool humanCompleteConfirmed = false;
  bool hasResolvedExceptions = false;
  String _currentCategoryKey = 'bus';

  String get currentCategoryKey => _currentCategoryKey;
  set currentCategoryKey(String key) =>
      _currentCategoryKey = key.trim().toLowerCase();

  List<ReviewNodeItem> orderedTargets(Iterable<ReviewNodeItem> nodes) {
    final targets = nodes
        .where((node) => node.reviewStatus.toUpperCase() != 'REJECTED')
        .toList();
    targets.sort((a, b) {
      final yOrder = _coordinate(a, 1).compareTo(_coordinate(b, 1));
      if (yOrder != 0) return yOrder;
      final xOrder = _coordinate(a, 0).compareTo(_coordinate(b, 0));
      if (xOrder != 0) return xOrder;
      return a.id.compareTo(b.id);
    });
    return targets;
  }

  List<ReviewNodeItem> unresolvedExceptions(Iterable<ReviewNodeItem> nodes) =>
      orderedTargets(
        nodes.where((node) => node.reviewStatus.toUpperCase() == 'SUSPICIOUS'),
      );

  List<String> reviewCategoryKeys(Iterable<ReviewNodeItem> nodes) {
    final keys = orderedTargets(nodes)
        .map((node) => node.className.trim().toLowerCase())
        .where((key) => key.isNotEmpty)
        .toSet()
        .toList();
    const preferredOrder = ['bus', 'load', 'generator', 'transformer'];
    keys.sort((a, b) {
      final aIndex = preferredOrder.indexOf(a);
      final bIndex = preferredOrder.indexOf(b);
      if (aIndex >= 0 || bIndex >= 0) {
        if (aIndex < 0) return 1;
        if (bIndex < 0) return -1;
        return aIndex.compareTo(bIndex);
      }
      return a.compareTo(b);
    });
    return keys;
  }

  List<String> pendingCategoryKeys(Iterable<ReviewNodeItem> nodes) =>
      reviewCategoryKeys(
        nodes,
      ).where((key) => !isCategoryReviewed(key, nodes)).toList();

  bool isCategoryReviewed(String categoryKey, Iterable<ReviewNodeItem> nodes) {
    final key = categoryKey.trim().toLowerCase();
    if (!reviewedCategoryKeys.contains(key)) return false;
    final reviewedIds = _reviewedCategoryObjectIds[key];
    if (reviewedIds == null) return false;
    final currentIds = orderedTargets(
      nodes.where((node) => node.className.trim().toLowerCase() == key),
    ).map((node) => node.id).toSet();
    return currentIds.isNotEmpty &&
        currentIds.length == reviewedIds.length &&
        currentIds.containsAll(reviewedIds);
  }

  bool isAllCategoriesReviewed(Iterable<ReviewNodeItem> nodes) {
    final categories = reviewCategoryKeys(nodes);
    if (categories.isEmpty) return false;
    return categories.every((key) => isCategoryReviewed(key, nodes));
  }

  ObjectCategoryState getCategoryState(
    String categoryKey,
    Iterable<ReviewNodeItem> nodes,
  ) {
    final key = categoryKey.trim().toLowerCase();
    if (isAllCategoriesReviewed(nodes)) {
      return ObjectCategoryState.reviewed;
    }
    if (key == _currentCategoryKey) {
      return ObjectCategoryState.current;
    }
    if (isCategoryReviewed(key, nodes)) {
      return ObjectCategoryState.reviewed;
    }
    return ObjectCategoryState.unreviewed;
  }

  bool confirmCurrentAndGoNext(Iterable<ReviewNodeItem> nodes) {
    final categories = reviewCategoryKeys(nodes);
    if (categories.isEmpty) return false;

    // 1. Mark current category reviewed
    markCategoryReviewed(_currentCategoryKey, nodes);

    // 2. Advance to next category in order
    final currentIndex = categories.indexOf(_currentCategoryKey);
    if (currentIndex >= 0 && currentIndex < categories.length - 1) {
      _currentCategoryKey = categories[currentIndex + 1];
      return true;
    }
    return false;
  }

  bool goPreviousCategory(Iterable<ReviewNodeItem> nodes) {
    final categories = reviewCategoryKeys(nodes);
    if (categories.isEmpty) return false;
    final currentIndex = categories.indexOf(_currentCategoryKey);
    if (currentIndex > 0) {
      _currentCategoryKey = categories[currentIndex - 1];
      return true;
    }
    return false;
  }

  bool canGoPrevious(Iterable<ReviewNodeItem> nodes) {
    final categories = reviewCategoryKeys(nodes);
    return categories.indexOf(_currentCategoryKey) > 0;
  }

  void selectCategory(String categoryKey, Iterable<ReviewNodeItem> nodes) {
    final key = categoryKey.trim().toLowerCase();
    final categories = reviewCategoryKeys(nodes);
    if (categories.contains(key)) {
      _currentCategoryKey = key;
    }
  }

  bool markCategoryReviewed(
    String categoryKey,
    Iterable<ReviewNodeItem> nodes,
  ) {
    final key = categoryKey.trim().toLowerCase();
    if (key.isEmpty || !reviewCategoryKeys(nodes).contains(key)) return false;
    final wasReviewed = isCategoryReviewed(key, nodes);
    final ids = orderedTargets(
      nodes.where((node) => node.className.trim().toLowerCase() == key),
    ).map((node) => node.id).toSet();
    reviewedCategoryKeys.add(key);
    _reviewedCategoryObjectIds[key] = ids;
    final changed = !wasReviewed;
    if (changed) humanCompleteConfirmed = false;
    return changed;
  }

  ReviewNodeItem? currentTarget(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    final exceptions = unresolvedExceptions(nodes);
    if (exceptions.isNotEmpty) return exceptions.first;
    if (hasOpenMissingCandidates) return null;
    final targets = orderedTargets(nodes);
    if (!isCategoryReviewed(_currentCategoryKey, nodes)) {
      for (final node in targets) {
        if (node.className.trim().toLowerCase() == _currentCategoryKey) {
          return node;
        }
      }
    }
    final pending = pendingCategoryKeys(nodes);
    if (pending.isNotEmpty) {
      for (final node in targets) {
        if (node.className.trim().toLowerCase() == pending.first) return node;
      }
    }
    for (final node in targets) {
      if (node.className.trim().toLowerCase() == _currentCategoryKey) {
        return node;
      }
    }
    return targets.isNotEmpty ? targets.first : null;
  }

  void markExceptionResolved(
    String objectId, {
    bool wasException = true,
    String? categoryKey,
  }) {
    visitedObjectIds.add(objectId);
    hasResolvedExceptions = hasResolvedExceptions || wasException;
    if (categoryKey != null) {
      final key = categoryKey.trim().toLowerCase();
      reviewedCategoryKeys.remove(key);
      _reviewedCategoryObjectIds.remove(key);
    }
    humanCompleteConfirmed = false;
  }

  bool isComplete(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return false;
    }
    final categories = reviewCategoryKeys(nodes);
    return categories.isNotEmpty &&
        categories.every((key) => isCategoryReviewed(key, nodes));
  }

  ObjectReviewFlowStage stage(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return ObjectReviewFlowStage.exceptionReview;
    }
    if (!isComplete(nodes)) return ObjectReviewFlowStage.categoryReview;
    return humanCompleteConfirmed
        ? ObjectReviewFlowStage.readyToComplete
        : ObjectReviewFlowStage.waitingHumanComplete;
  }

  bool confirmHumanComplete(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (!isComplete(
      nodes,
      hasOpenMissingCandidates: hasOpenMissingCandidates,
    )) {
      return false;
    }
    humanCompleteConfirmed = true;
    return true;
  }

  int visitedCount(Iterable<ReviewNodeItem> nodes) => orderedTargets(
    nodes,
  ).where((node) => visitedObjectIds.contains(node.id)).length;

  int reviewedCategoryCount(Iterable<ReviewNodeItem> nodes) =>
      reviewCategoryKeys(
        nodes,
      ).where((key) => isCategoryReviewed(key, nodes)).length;

  void invalidateHumanComplete() => humanCompleteConfirmed = false;

  void reset() {
    visitedObjectIds.clear();
    reviewedCategoryKeys.clear();
    _reviewedCategoryObjectIds.clear();
    humanCompleteConfirmed = false;
    hasResolvedExceptions = false;
    _currentCategoryKey = 'bus';
  }

  double _coordinate(ReviewNodeItem node, int index) =>
      node.bbox.length > index ? node.bbox[index] : 0;
}
