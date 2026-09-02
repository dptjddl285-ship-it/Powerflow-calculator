"""Context-Aware Conversational SLD Reviewer Agent.

Supports interactive Q&A during Single Line Diagram (SLD) verification:
- Inspects selected object/line context and evidence.
- Explains why a symbol was classified or flagged.
- Analyzes electrical impact of class modifications or line reconnections.
- Summarizes diagram-level review queue and missing candidates.
- Delegates to the configured ReviewAssistantProvider (Default: LocalReviewAssistantProvider).
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional
from .providers import (
    ChatMessagePayload,
    ReviewAssistantProvider,
    get_assistant_provider,
)


class AgentChatReviewer:
    def __init__(self, provider: Optional[ReviewAssistantProvider] = None):
        self._provider = provider

    @property
    def provider(self) -> ReviewAssistantProvider:
        return self._provider or get_assistant_provider()

    def chat(
        self,
        message: str,
        document_id: str,
        stage: str,  # "OBJECT_REVIEW", "CONNECTION_REVIEW", "FINAL"
        selected_node: Optional[Dict[str, Any]] = None,
        selected_line: Optional[Dict[str, Any]] = None,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        history: Optional[List[ChatMessagePayload]] = None,
    ) -> Dict[str, Any]:
        """Process a conversational query using diagram review context via active provider."""
        return self.provider.answer_chat(
            message=message,
            document_id=document_id,
            stage=stage,
            selected_node=selected_node,
            selected_line=selected_line,
            working_nodes=working_nodes,
            working_lines=working_lines,
            missing_candidates=missing_candidates,
            topology_issues=topology_issues,
            history=history,
        )


chat_reviewer = AgentChatReviewer()
