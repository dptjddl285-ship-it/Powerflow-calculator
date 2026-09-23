"""Thread-safe in-memory store for the Review API prototype.

The service boundary intentionally hides storage details so this can be
replaced by SQLite or another persistent repository without changing routes.
"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from threading import RLock
from typing import Any

from .agent_activity import ReviewAgentRun
from .graph_document import GraphDocument
from .patches import PatchPreview


class DocumentAlreadyExistsError(Exception):
    pass


class DocumentNotFoundError(Exception):
    pass


class AnalysisAssetNotFoundError(Exception):
    pass


class PatchNotFoundError(Exception):
    pass


class AgentRunNotFoundError(Exception):
    pass


@dataclass(frozen=True)
class AnalysisAsset:
    image_bytes: bytes
    vision_result: dict[str, Any]


class ReviewStore:
    def __init__(self) -> None:
        self._documents: dict[str, GraphDocument] = {}
        self._assets: dict[str, AnalysisAsset] = {}
        self._patches: dict[str, PatchPreview] = {}
        self._agent_runs: dict[str, ReviewAgentRun] = {}
        self._lock = RLock()

    def put(self, document: GraphDocument, *, overwrite: bool = False) -> GraphDocument:
        with self._lock:
            if document.document_id in self._documents and not overwrite:
                raise DocumentAlreadyExistsError(document.document_id)
            if overwrite:
                self._assets.pop(document.document_id, None)
                self._patches = {
                    patch_id: patch
                    for patch_id, patch in self._patches.items()
                    if patch.document_id != document.document_id
                }
                self._agent_runs = {
                    run_id: run
                    for run_id, run in self._agent_runs.items()
                    if run.document_id != document.document_id
                }
            stored = GraphDocument.model_validate(document.model_dump())
            self._documents[document.document_id] = stored
            return stored.model_copy(deep=True)

    def get(self, document_id: str) -> GraphDocument:
        with self._lock:
            document = self._documents.get(document_id)
            if document is None:
                raise DocumentNotFoundError(document_id)
            return document.model_copy(deep=True)

    def replace(self, document: GraphDocument) -> GraphDocument:
        with self._lock:
            if document.document_id not in self._documents:
                raise DocumentNotFoundError(document.document_id)
            stored = GraphDocument.model_validate(document.model_dump())
            self._documents[document.document_id] = stored
            return stored.model_copy(deep=True)

    def list(self) -> list[GraphDocument]:
        with self._lock:
            return [
                document.model_copy(deep=True)
                for document in self._documents.values()
            ]

    def put_analysis_asset(
        self,
        document_id: str,
        *,
        image_bytes: bytes,
        vision_result: dict[str, Any],
    ) -> None:
        with self._lock:
            if document_id not in self._documents:
                raise DocumentNotFoundError(document_id)
            self._assets[document_id] = AnalysisAsset(
                image_bytes=bytes(image_bytes),
                vision_result=deepcopy(vision_result),
            )

    def get_analysis_asset(self, document_id: str) -> AnalysisAsset:
        with self._lock:
            asset = self._assets.get(document_id)
            if asset is None:
                raise AnalysisAssetNotFoundError(document_id)
            return AnalysisAsset(
                image_bytes=bytes(asset.image_bytes),
                vision_result=deepcopy(asset.vision_result),
            )

    def put_patch(self, patch: PatchPreview) -> PatchPreview:
        with self._lock:
            if patch.document_id not in self._documents:
                raise DocumentNotFoundError(patch.document_id)
            stored = PatchPreview.model_validate(patch.model_dump())
            self._patches[patch.patch_id] = stored
            return stored.model_copy(deep=True)

    def get_patch(self, patch_id: str) -> PatchPreview:
        with self._lock:
            patch = self._patches.get(patch_id)
            if patch is None:
                raise PatchNotFoundError(patch_id)
            return patch.model_copy(deep=True)

    def replace_patch(self, patch: PatchPreview) -> PatchPreview:
        with self._lock:
            if patch.patch_id not in self._patches:
                raise PatchNotFoundError(patch.patch_id)
            stored = PatchPreview.model_validate(patch.model_dump())
            self._patches[patch.patch_id] = stored
            return stored.model_copy(deep=True)

    def list_patches(self, document_id: str) -> list[PatchPreview]:
        with self._lock:
            if document_id not in self._documents:
                raise DocumentNotFoundError(document_id)
            return [
                patch.model_copy(deep=True)
                for patch in self._patches.values()
                if patch.document_id == document_id
            ]

    def put_agent_run(self, run: ReviewAgentRun) -> ReviewAgentRun:
        with self._lock:
            if run.document_id not in self._documents:
                raise DocumentNotFoundError(run.document_id)
            stored = ReviewAgentRun.model_validate(run.model_dump())
            self._agent_runs[run.run_id] = stored
            return stored.model_copy(deep=True)

    def get_agent_run(self, run_id: str) -> ReviewAgentRun:
        with self._lock:
            run = self._agent_runs.get(run_id)
            if run is None:
                raise AgentRunNotFoundError(run_id)
            return run.model_copy(deep=True)

    def list_agent_runs(self, document_id: str) -> list[ReviewAgentRun]:
        with self._lock:
            if document_id not in self._documents:
                raise DocumentNotFoundError(document_id)
            return [
                run.model_copy(deep=True)
                for run in self._agent_runs.values()
                if run.document_id == document_id
            ]

    def clear(self) -> None:
        with self._lock:
            self._documents.clear()
            self._assets.clear()
            self._patches.clear()
            self._agent_runs.clear()


review_store = ReviewStore()


__all__ = [
    "DocumentAlreadyExistsError",
    "DocumentNotFoundError",
    "AnalysisAssetNotFoundError",
    "PatchNotFoundError",
    "AgentRunNotFoundError",
    "AnalysisAsset",
    "ReviewStore",
    "review_store",
]
