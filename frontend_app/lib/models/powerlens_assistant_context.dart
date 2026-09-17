// PowerLens Assistant Context Model
// Represents the runtime system context sent to the PowerLens Global AI backend.

class PowerLensAssistantContext {
  final String currentScreen; // 'HOME', 'OBJECT_REVIEW', 'BUS_MAPPING', 'CONNECTION_REVIEW', 'FINAL_CAD'
  final String workflowStage; // 'HOME', 'OBJECT_REVIEW', 'BUS_MAPPING', 'CONNECTION_REVIEW', 'FINAL', 'EXCEL', 'POWERFLOW'
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

  final bool finalVerified;
  final bool excelLoaded;
  final String excelMappingStatus;

  final bool powerflowReady;
  final bool powerflowRunning;
  final bool? powerflowConverged;

  final String? selectedElement;
  final List<String> currentBlockers;

  const PowerLensAssistantContext({
    this.currentScreen = 'HOME',
    this.workflowStage = 'HOME',
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
    this.finalVerified = false,
    this.excelLoaded = false,
    this.excelMappingStatus = 'NONE',
    this.powerflowReady = false,
    this.powerflowRunning = false,
    this.powerflowConverged,
    this.selectedElement,
    this.currentBlockers = const [],
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
        'final_verified': finalVerified,
        'excel_loaded': excelLoaded,
        'excel_mapping_status': excelMappingStatus,
        'powerflow_ready': powerflowReady,
        'powerflow_running': powerflowRunning,
        if (powerflowConverged != null) 'powerflow_converged': powerflowConverged,
        if (selectedElement != null) 'selected_element': selectedElement,
        'current_blockers': currentBlockers,
      };

  PowerLensAssistantContext copyWith({
    String? currentScreen,
    String? workflowStage,
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
    bool? finalVerified,
    bool? excelLoaded,
    String? excelMappingStatus,
    bool? powerflowReady,
    bool? powerflowRunning,
    bool? powerflowConverged,
    String? selectedElement,
    List<String>? currentBlockers,
  }) {
    return PowerLensAssistantContext(
      currentScreen: currentScreen ?? this.currentScreen,
      workflowStage: workflowStage ?? this.workflowStage,
      documentId: documentId ?? this.documentId,
      hasDiagram: hasDiagram ?? this.hasDiagram,
      analysisRunning: analysisRunning ?? this.analysisRunning,
      totalObjects: totalObjects ?? this.totalObjects,
      suspiciousObjects: suspiciousObjects ?? this.suspiciousObjects,
      unresolvedMissingCandidates: unresolvedMissingCandidates ?? this.unresolvedMissingCandidates,
      totalBuses: totalBuses ?? this.totalBuses,
      unresolvedBusNumbers: unresolvedBusNumbers ?? this.unresolvedBusNumbers,
      duplicateBusNumbers: duplicateBusNumbers ?? this.duplicateBusNumbers,
      totalConnections: totalConnections ?? this.totalConnections,
      ambiguousConnections: ambiguousConnections ?? this.ambiguousConnections,
      topologyIssueCount: topologyIssueCount ?? this.topologyIssueCount,
      finalVerified: finalVerified ?? this.finalVerified,
      excelLoaded: excelLoaded ?? this.excelLoaded,
      excelMappingStatus: excelMappingStatus ?? this.excelMappingStatus,
      powerflowReady: powerflowReady ?? this.powerflowReady,
      powerflowRunning: powerflowRunning ?? this.powerflowRunning,
      powerflowConverged: powerflowConverged ?? this.powerflowConverged,
      selectedElement: selectedElement ?? this.selectedElement,
      currentBlockers: currentBlockers ?? this.currentBlockers,
    );
  }
}
