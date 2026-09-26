// PowerLens Assistant Context Model
// Represents the runtime system context sent to the PowerLens Global AI backend.

class PowerLensAssistantContext {
  final String
  currentScreen; // 'HOME', 'OBJECT_REVIEW', 'BUS_MAPPING', 'CONNECTION_REVIEW', 'FINAL_CAD'
  final String
  workflowStage; // 'HOME', 'OBJECT_REVIEW', 'BUS_MAPPING', 'CONNECTION_REVIEW', 'FINAL', 'EXCEL', 'POWERFLOW'
  final String documentId;
  final bool hasDiagram;
  final bool analysisRunning;

  final int totalObjects;
  final int suspiciousObjects;
  final int unresolvedMissingCandidates;

  final int totalBuses;
  final int unresolvedBusNumbers;
  final int duplicateBusNumbers;

  final int totalConnections;
  final int ambiguousConnections;
  final int topologyIssueCount;
  final bool connectionVisualSweepStarted;
  final bool connectionVisualSweepComplete;

  final bool finalVerified;
  final bool excelLoaded;
  final String excelMappingStatus;

  final bool powerflowReady;
  final bool powerflowRunning;
  final bool? powerflowConverged;
  final Map<String, dynamic>? powerflowEvidence;

  final String? selectedElement;
  final Map<String, dynamic>? selectedNode;
  final Map<String, dynamic>? selectedLine;
  final List<Map<String, dynamic>> workingNodes;
  final List<Map<String, dynamic>> workingLines;
  final List<Map<String, dynamic>> missingCandidates;
  final List<Map<String, dynamic>> topologyIssues;
  final List<String> currentBlockers;

  // Review-stage state used by the deterministic Lensy coach. These fields
  // keep the guide honest about whether a human check or AI bus read is still
  // in progress; they are optional so existing callers remain compatible.
  final bool objectHumanCompletenessConfirmed;
  final String objectReviewStage;
  final int objectVisualSweepVisited;
  final int objectVisualSweepTotal;
  final String? objectVisualSweepCurrentId;
  final bool busMappingAiReading;
  final String? activeBusId;
  final String? busModelUsed;
  final bool busFallbackUsed;
  final String? busFailureCode;
  final String? objectWorkflowMessage;

  const PowerLensAssistantContext({
    this.currentScreen = 'HOME',
    this.workflowStage = 'HOME',
    this.objectWorkflowMessage,
    this.documentId = '',
    this.hasDiagram = false,
    this.analysisRunning = false,
    this.totalObjects = 0,
    this.suspiciousObjects = 0,
    this.unresolvedMissingCandidates = 0,
    this.totalBuses = 0,
    this.unresolvedBusNumbers = 0,
    this.duplicateBusNumbers = 0,
    this.totalConnections = 0,
    this.ambiguousConnections = 0,
    this.topologyIssueCount = 0,
    this.connectionVisualSweepStarted = false,
    this.connectionVisualSweepComplete = false,
    this.finalVerified = false,
    this.excelLoaded = false,
    this.excelMappingStatus = 'NONE',
    this.powerflowReady = false,
    this.powerflowRunning = false,
    this.powerflowConverged,
    this.powerflowEvidence,
    this.selectedElement,
    this.selectedNode,
    this.selectedLine,
    this.workingNodes = const [],
    this.workingLines = const [],
    this.missingCandidates = const [],
    this.topologyIssues = const [],
    this.currentBlockers = const [],
    this.objectHumanCompletenessConfirmed = false,
    this.objectReviewStage = '',
    this.objectVisualSweepVisited = 0,
    this.objectVisualSweepTotal = 0,
    this.objectVisualSweepCurrentId,
    this.busMappingAiReading = false,
    this.activeBusId,
    this.busModelUsed,
    this.busFallbackUsed = false,
    this.busFailureCode,
  });

  Map<String, dynamic> toJson() => {
    'current_screen': currentScreen,
    'workflow_stage': workflowStage,
    'document_id': documentId,
    'has_diagram': hasDiagram,
    'analysis_running': analysisRunning,
    'total_objects': totalObjects,
    'suspicious_objects': suspiciousObjects,
    'unresolved_missing_candidates': unresolvedMissingCandidates,
    'total_buses': totalBuses,
    'unresolved_bus_numbers': unresolvedBusNumbers,
    'duplicate_bus_numbers': duplicateBusNumbers,
    'total_connections': totalConnections,
    'ambiguous_connections': ambiguousConnections,
    'topology_issue_count': topologyIssueCount,
    'connection_visual_sweep_started': connectionVisualSweepStarted,
    'connection_visual_sweep_complete': connectionVisualSweepComplete,
    'final_verified': finalVerified,
    'excel_loaded': excelLoaded,
    'excel_mapping_status': excelMappingStatus,
    'powerflow_ready': powerflowReady,
    'powerflow_running': powerflowRunning,
    if (powerflowConverged != null) 'powerflow_converged': powerflowConverged,
    if (powerflowEvidence != null) 'powerflow_evidence': powerflowEvidence,
    if (selectedElement != null) 'selected_element': selectedElement,
    if (selectedNode != null) 'selected_node': selectedNode,
    if (selectedLine != null) 'selected_line': selectedLine,
    'working_nodes': workingNodes,
    'working_lines': workingLines,
    'missing_candidates': missingCandidates,
    'topology_issues': topologyIssues,
    'current_blockers': currentBlockers,
    'object_human_completeness_confirmed': objectHumanCompletenessConfirmed,
    'object_review_stage': objectReviewStage,
    'object_visual_sweep_visited': objectVisualSweepVisited,
    'object_visual_sweep_total': objectVisualSweepTotal,
    if (objectVisualSweepCurrentId != null)
      'object_visual_sweep_current_id': objectVisualSweepCurrentId,
    'bus_mapping_ai_reading': busMappingAiReading,
    if (activeBusId != null) 'active_bus_id': activeBusId,
    if (busModelUsed != null) 'bus_model_used': busModelUsed,
    'bus_fallback_used': busFallbackUsed,
    if (busFailureCode != null) 'bus_failure_code': busFailureCode,
    if (objectWorkflowMessage != null)
      'object_workflow_message': objectWorkflowMessage,
  };

  PowerLensAssistantContext copyWith({
    String? currentScreen,
    String? workflowStage,
    String? objectWorkflowMessage,
    String? documentId,
    bool? hasDiagram,
    bool? analysisRunning,
    int? totalObjects,
    int? suspiciousObjects,
    int? unresolvedMissingCandidates,
    int? totalBuses,
    int? unresolvedBusNumbers,
    int? duplicateBusNumbers,
    int? totalConnections,
    int? ambiguousConnections,
    int? topologyIssueCount,
    bool? connectionVisualSweepStarted,
    bool? connectionVisualSweepComplete,
    bool? finalVerified,
    bool? excelLoaded,
    String? excelMappingStatus,
    bool? powerflowReady,
    bool? powerflowRunning,
    bool? powerflowConverged,
    Map<String, dynamic>? powerflowEvidence,
    String? selectedElement,
    Map<String, dynamic>? selectedNode,
    Map<String, dynamic>? selectedLine,
    List<Map<String, dynamic>>? workingNodes,
    List<Map<String, dynamic>>? workingLines,
    List<Map<String, dynamic>>? missingCandidates,
    List<Map<String, dynamic>>? topologyIssues,
    List<String>? currentBlockers,
    bool? objectHumanCompletenessConfirmed,
    String? objectReviewStage,
    int? objectVisualSweepVisited,
    int? objectVisualSweepTotal,
    String? objectVisualSweepCurrentId,
    bool? busMappingAiReading,
    String? activeBusId,
    String? busModelUsed,
    bool? busFallbackUsed,
    String? busFailureCode,
  }) {
    return PowerLensAssistantContext(
      currentScreen: currentScreen ?? this.currentScreen,
      workflowStage: workflowStage ?? this.workflowStage,
      objectWorkflowMessage:
          objectWorkflowMessage ?? this.objectWorkflowMessage,
      documentId: documentId ?? this.documentId,
      hasDiagram: hasDiagram ?? this.hasDiagram,
      analysisRunning: analysisRunning ?? this.analysisRunning,
      totalObjects: totalObjects ?? this.totalObjects,
      suspiciousObjects: suspiciousObjects ?? this.suspiciousObjects,
      unresolvedMissingCandidates:
          unresolvedMissingCandidates ?? this.unresolvedMissingCandidates,
      totalBuses: totalBuses ?? this.totalBuses,
      unresolvedBusNumbers: unresolvedBusNumbers ?? this.unresolvedBusNumbers,
      duplicateBusNumbers: duplicateBusNumbers ?? this.duplicateBusNumbers,
      totalConnections: totalConnections ?? this.totalConnections,
      ambiguousConnections: ambiguousConnections ?? this.ambiguousConnections,
      topologyIssueCount: topologyIssueCount ?? this.topologyIssueCount,
      connectionVisualSweepStarted:
          connectionVisualSweepStarted ?? this.connectionVisualSweepStarted,
      connectionVisualSweepComplete:
          connectionVisualSweepComplete ?? this.connectionVisualSweepComplete,
      finalVerified: finalVerified ?? this.finalVerified,
      excelLoaded: excelLoaded ?? this.excelLoaded,
      excelMappingStatus: excelMappingStatus ?? this.excelMappingStatus,
      powerflowReady: powerflowReady ?? this.powerflowReady,
      powerflowRunning: powerflowRunning ?? this.powerflowRunning,
      powerflowConverged: powerflowConverged ?? this.powerflowConverged,
      powerflowEvidence: powerflowEvidence ?? this.powerflowEvidence,
      selectedElement: selectedElement ?? this.selectedElement,
      selectedNode: selectedNode ?? this.selectedNode,
      selectedLine: selectedLine ?? this.selectedLine,
      workingNodes: workingNodes ?? this.workingNodes,
      workingLines: workingLines ?? this.workingLines,
      missingCandidates: missingCandidates ?? this.missingCandidates,
      topologyIssues: topologyIssues ?? this.topologyIssues,
      currentBlockers: currentBlockers ?? this.currentBlockers,
      objectHumanCompletenessConfirmed:
          objectHumanCompletenessConfirmed ??
          this.objectHumanCompletenessConfirmed,
      objectReviewStage: objectReviewStage ?? this.objectReviewStage,
      objectVisualSweepVisited:
          objectVisualSweepVisited ?? this.objectVisualSweepVisited,
      objectVisualSweepTotal:
          objectVisualSweepTotal ?? this.objectVisualSweepTotal,
      objectVisualSweepCurrentId:
          objectVisualSweepCurrentId ?? this.objectVisualSweepCurrentId,
      busMappingAiReading: busMappingAiReading ?? this.busMappingAiReading,
      activeBusId: activeBusId ?? this.activeBusId,
      busModelUsed: busModelUsed ?? this.busModelUsed,
      busFallbackUsed: busFallbackUsed ?? this.busFallbackUsed,
      busFailureCode: busFailureCode ?? this.busFailureCode,
    );
  }
}
