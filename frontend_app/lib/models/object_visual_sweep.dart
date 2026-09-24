import 'review_models.dart';

enum ObjectReviewFlowStage {
  exceptionReview,
  visualSweep,
  waitingHumanComplete,
  readyToComplete,
}

extension ObjectReviewFlowStageName on ObjectReviewFlowStage {
  String get wireName => switch (this) {
    ObjectReviewFlowStage.exceptionReview => 'EXCEPTION_REVIEW',
    ObjectReviewFlowStage.visualSweep => 'VISUAL_SWEEP',
    ObjectReviewFlowStage.waitingHumanComplete => 'WAITING_HUMAN_COMPLETE',
    ObjectReviewFlowStage.readyToComplete => 'READY_TO_COMPLETE',
  };
}

/// Tracks the ordered visual pass without changing object classification.
/// Suspicious objects count as visited only after an explicit resolution.
class ObjectVisualSweepState {
  final Set<String> visitedObjectIds = <String>{};
  bool humanCompleteConfirmed = false;
  bool hasResolvedExceptions = false;

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

  ReviewNodeItem? currentTarget(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    final exceptions = unresolvedExceptions(nodes);
    if (exceptions.isNotEmpty) return exceptions.first;
    if (hasOpenMissingCandidates) return null;
    for (final node in orderedTargets(nodes)) {
      if (!visitedObjectIds.contains(node.id)) return node;
    }
    return null;
  }

  bool visitCurrentTarget(
    String objectId,
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    final target = currentTarget(
      nodes,
      hasOpenMissingCandidates: hasOpenMissingCandidates,
    );
    if (target == null ||
        target.id != objectId ||
        target.reviewStatus.toUpperCase() == 'SUSPICIOUS') {
      return false;
    }
    final changed = visitedObjectIds.add(objectId);
    if (changed) humanCompleteConfirmed = false;
    return changed;
  }

  void markExceptionResolved(String objectId, {bool wasException = true}) {
    visitedObjectIds.add(objectId);
    hasResolvedExceptions = hasResolvedExceptions || wasException;
    humanCompleteConfirmed = false;
  }

  bool isComplete(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return false;
    }
    final targets = orderedTargets(nodes);
    return targets.isNotEmpty &&
        targets.every((node) => visitedObjectIds.contains(node.id));
  }

  ObjectReviewFlowStage stage(
    Iterable<ReviewNodeItem> nodes, {
    bool hasOpenMissingCandidates = false,
  }) {
    if (hasOpenMissingCandidates || unresolvedExceptions(nodes).isNotEmpty) {
      return ObjectReviewFlowStage.exceptionReview;
    }
    if (currentTarget(nodes) != null) return ObjectReviewFlowStage.visualSweep;
    if (!isComplete(nodes)) return ObjectReviewFlowStage.visualSweep;
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

  void invalidateHumanComplete() => humanCompleteConfirmed = false;

  void reset() {
    visitedObjectIds.clear();
    humanCompleteConfirmed = false;
    hasResolvedExceptions = false;
  }

  double _coordinate(ReviewNodeItem node, int index) =>
      node.bbox.length > index ? node.bbox[index] : 0;
}
