"""In-memory session and image cache for VisionFlow review pipeline.

Stores original image bytes and metadata associated with a review document_id.
Ensures thread-safety, LRU/TTL cleanup, and zero path traversal vulnerability.
"""
from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Dict, Optional

import cv2
import numpy as np


@dataclass
class ImageSession:
    document_id: str
    image_bytes: bytes
    content_type: str
    width: int
    height: int
    created_at: float = field(default_factory=time.time)


class ReviewSessionStore:
    def __init__(self, max_items: int = 100, ttl_seconds: int = 3600):
        self._max_items = max_items
        self._ttl_seconds = ttl_seconds
        self._store: Dict[str, ImageSession] = {}
        self._lock = threading.Lock()

    def _cleanup_locked(self) -> None:
        now = time.time()
        # 1. Remove expired sessions
        expired_ids = [
            doc_id
            for doc_id, sess in self._store.items()
            if now - sess.created_at > self._ttl_seconds
        ]
        for doc_id in expired_ids:
            del self._store[doc_id]

        # 2. If item count exceeds max_items, evict oldest
        if len(self._store) >= self._max_items:
            sorted_items = sorted(
                self._store.items(), key=lambda item: item[1].created_at
            )
            excess = len(self._store) - self._max_items + 1
            for doc_id, _ in sorted_items[:excess]:
                del self._store[doc_id]

    def create_session(
        self, image_bytes: bytes, content_type: str = "image/png"
    ) -> ImageSession:
        nparr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if img is not None:
            height, width = img.shape[:2]
        else:
            height, width = 0, 0

        doc_id = f"doc_{uuid.uuid4().hex[:12]}"
        session = ImageSession(
            document_id=doc_id,
            image_bytes=image_bytes,
            content_type=content_type,
            width=width,
            height=height,
        )

        with self._lock:
            self._cleanup_locked()
            self._store[doc_id] = session

        return session

    def get_session(self, document_id: str) -> Optional[ImageSession]:
        with self._lock:
            session = self._store.get(document_id)
            if session is None:
                return None
            if time.time() - session.created_at > self._ttl_seconds:
                del self._store[document_id]
                return None
            return session

    def clear(self) -> None:
        with self._lock:
            self._store.clear()

    def __len__(self) -> int:
        with self._lock:
            return len(self._store)


# Global singleton review session store instance
session_store = ReviewSessionStore()
