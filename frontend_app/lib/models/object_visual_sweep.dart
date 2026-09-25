import 'review_models.dart';

enum ObjectReviewFlowStage {
  exceptionReview,
  categorySweep,
  finalAgentCheck,
  readyToComplete,
}

extension ObjectReviewFlowStageName on ObjectReviewFlowStage {
  String get wireName => switch (this) {
    ObjectReviewFlowStage.exceptionReview => 'EXCEPTION_REVIEW',
    ObjectReviewFlowStage.categorySweep => 'CATEGORY_SWEEP',
    ObjectReviewFlowStage.finalAgentCheck => 'FINAL_AGENT_CHECK',
    ObjectReviewFlowStage.readyToComplete => 'READY_TO_COMPLETE',
  };
}

enum ObjectCategory { bus, load, generator, transformer }

extension ObjectCategoryDetails on ObjectCategory {
  String get className => switch (this) {
    ObjectCategory.bus => 'bus',
    ObjectCategory.load => 'load',
    ObjectCategory.generator => 'generator',
    ObjectCategory.transformer => 'transformer',
  };

  String get label => switch (this) {
    ObjectCategory.bus => 'Bus',
    ObjectCategory.load => 'Load',
    ObjectCategory.generator => 'Generator',
    ObjectCategory.transformer => 'Transformer',
  };

  bool matches(String rawClassName) {
    final value = rawClassName.toLowerCase();
    return switch (this) {
      ObjectCategory.bus => value == 'bus',
      ObjectCategory.load => value.contains('load'),
      ObjectCategory.generator => value.contains('gen'),
      ObjectCategory.transformer => value.contains('trans'),
    };
  }

  static ObjectCategory? fromClassName(String rawClassName) {
    for (final category in ObjectCategory.values) {
      if (category.matches(rawClassName)) return category;
    }
    return null;
  }
}

/// Tracks exception-by-object review followed by one explicit pass per class.
/// Normal objects never enter an individual visited queue.
class ObjectVisualSweepState {
  final Set<ObjectCategory> reviewedCategories = <ObjectCategory>{};
  ObjectCategory? activeCategory;
  bool finalCheckInFlight = false;
  bool finalCheckPassed = false;
  bool hasResolvedExceptions = false;

  List<ReviewNodeItem> unresolvedExceptions(Iterable<ReviewNodeItem> nodes) {
    final exceptions = nodes
        .where((node) => node.reviewStatus.toUpperCase() == 'SUSPICIOUS')
        .toList();
    exceptions.sort((a, b) {
      final yOrder = _coordinate(a, 1).compareTo(_coordinate(b, 1));
      if (yOrder != 0) return yOrder;
      final xOrder = _coordinate(a, 0).compareTo(_coordinate(b, 0));
      return xOrder != 0 ? xOrder : a.id.compareTo(b.id);
    });
    return exceptions;
  }

  ReviewNodeItem? currentException(Iterable<ReviewNodeItem> nodes) {
    final exceptions = unresolvedExceptions(nodes);
    return exceptions.isEmpty ? null : exceptions.first;
  }

  bool selectCategory(
    ObjectCategory category,
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return false;
    }
    activeCategory = category;
    reviewedCategories.add(category);
    return true;
  }

  bool selectAdjacentCategory(
    int delta,
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (delta == 0 ||
        hasOpenMissingCandidates ||
        unresolvedExceptions(nodes).isNotEmpty) {
      return false;
    }

    final currentIndex = activeCategory == null
        ? -1
        : ObjectCategory.values.indexOf(activeCategory!);
    final nextIndex = activeCategory == null && delta > 0
        ? 0
        : currentIndex + delta;
    if (nextIndex < 0 || nextIndex >= ObjectCategory.values.length) {
      return false;
    }
    return selectCategory(
      ObjectCategory.values[nextIndex],
      nodes,
      hasOpenMissingCandidates: hasOpenMissingCandidates,
    );
  }

  void markExceptionResolved({bool wasException = true}) {
    hasResolvedExceptions = hasResolvedExceptions || wasException;
    invalidateFinalCheck();
  }

  bool isComplete(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) =>
      !hasOpenMissingCandidates &&
      unresolvedExceptions(nodes).isEmpty &&
      reviewedCategories.length == ObjectCategory.values.length;

  ObjectReviewFlowStage stage(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return ObjectReviewFlowStage.exceptionReview;
    }
    if (reviewedCategories.length < ObjectCategory.values.length) {
      return ObjectReviewFlowStage.categorySweep;
    }
    if (finalCheckPassed) return ObjectReviewFlowStage.readyToComplete;
    return finalCheckInFlight
        ? ObjectReviewFlowStage.finalAgentCheck
        : ObjectReviewFlowStage.categorySweep;
  }

  bool beginFinalCheck(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (!isComplete(
          nodes,
          hasOpenMissingCandidates: hasOpenMissingCandidates,
        ) ||
        finalCheckPassed ||
        finalCheckInFlight) {
      return false;
    }
    finalCheckInFlight = true;
    return true;
  }

  bool confirmFinalCheck(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (!isComplete(
      nodes,
      hasOpenMissingCandidates: hasOpenMissingCandidates,
    )) {
      finalCheckInFlight = false;
      return false;
    }
    finalCheckInFlight = false;
    finalCheckPassed = true;
    return true;
  }

  void failFinalCheck() {
    finalCheckInFlight = false;
    finalCheckPassed = false;
  }

  int get reviewedCategoryCount => reviewedCategories.length;

  void invalidateCategory(ObjectCategory? category) {
    if (category == null) return;
    reviewedCategories.remove(category);
    invalidateFinalCheck();
  }

  void invalidateFinalCheck() {
    finalCheckInFlight = false;
    finalCheckPassed = false;
  }

  void reset() {
    reviewedCategories.clear();
    activeCategory = null;
    finalCheckInFlight = false;
    finalCheckPassed = false;
    hasResolvedExceptions = false;
  }

  double _coordinate(ReviewNodeItem node, int index) =>
      node.bbox.length > index ? node.bbox[index] : 0;
}
