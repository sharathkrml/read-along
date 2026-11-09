"""Read Along — persistent document library.

Owns library.json and isolated per-document workspaces
(``data/documents/<id>/``). Documents keep their own source, reading cache, and
saved position; the sidebar orders by recency (only actual reading bumps a
document to the top).
"""

from __future__ import annotations

import json
import re
import shutil
import threading
import time
import uuid
from pathlib import Path

from PIL import Image

from ._config import DATA
from .text import TEXT_SUFFIXES


class DocumentStore:
    """Persistent document metadata and isolated per-document workspaces."""

    def __init__(self, data: Path = DATA):
        self.data = data
        self.root = data / "documents"
        self.index = data / "library.json"
        self.lock = threading.RLock()
        self.docs: list[dict] = []
        self.active: str | None = None
        self._load()
        self._migrate_legacy()
        interrupted = False
        for doc in self.docs:
            if doc.get("status") == "processing":
                doc["status"] = "error"
                doc["error"] = "Processing was interrupted. Retry to finish this document."
                interrupted = True
        if interrupted:
            self._save()

    def _load(self) -> None:
        try:
            raw = json.loads(self.index.read_text())
            seen = set()
            for d in raw.get("documents", []):
                doc_id = d.get("id", "")
                source = d.get("source", "")
                if (not re.fullmatch(r"[a-f0-9]{32}", doc_id) or doc_id in seen
                        or Path(source).name != source or not source):
                    continue
                seen.add(doc_id)
                self.docs.append(d)
            active = raw.get("active")
            self.active = active if active in seen else (self.docs[0]["id"] if self.docs else None)
        except (OSError, ValueError, TypeError):
            self.docs = []
            self.active = None

    def _save(self) -> None:
        with self.lock:
            self.data.mkdir(parents=True, exist_ok=True)
            payload = {"version": 1, "active": self.active, "documents": self.docs}
            tmp = self.index.with_suffix(".tmp")
            # Never let a cache-write failure crash the app; on next launch the
            # library is reloaded from disk (or rebuilt empty).
            try:
                tmp.write_text(json.dumps(payload, indent=1))
                tmp.replace(self.index)
            except Exception:
                pass

    def _migrate_legacy(self) -> None:
        if self.index.exists() or self.docs:
            return
        legacy_pdf = self.data / "current.pdf"
        legacy_image = self.data / "current.jpg"
        legacy_text = next((self.data / ("current" + s) for s in sorted(TEXT_SUFFIXES)
                            if (self.data / ("current" + s)).exists()), None)
        legacy_cache = self.data / "cache.json"
        legacy_pages = self.data / "pages"
        source = next((p for p in (legacy_pdf, legacy_image, legacy_text) if p and p.exists()), None)
        if not source:
            return
        doc = self.create(source.name, source.suffix)
        target = self.path(doc["id"])
        shutil.copy2(source, target / doc["source"])
        if legacy_cache.exists():
            shutil.copy2(legacy_cache, target / "cache.json")
            doc["status"] = "ready"
        if source.suffix.lower() in TEXT_SUFFIXES:
            # --ocr-only leaves the generated viewer PDF as current.<ext>.pdf.
            generated = source.with_name(source.name + ".pdf")
            if generated.exists():
                shutil.copy2(generated, target / "source.pdf")
        if legacy_pages.exists():
            shutil.copytree(legacy_pages, target / "pages", dirs_exist_ok=True)
        self._save()

    def create(self, file_name: str, suffix: str) -> dict:
        title = Path(file_name).stem.replace("_", " ").replace("-", " ").strip() or "Untitled document"
        suffix = suffix.lower()
        doc = {
            "id": uuid.uuid4().hex,
            "title": title[:100],
            "file_name": Path(file_name).name or "Document",
            "source": ("source" + suffix if suffix in TEXT_SUFFIXES
                       else "source.pdf" if suffix == ".pdf" else "source.jpg"),
            "status": "idle",
            "error": "",
            "created": time.time(),
            "last_opened": time.time(),
            "position": 0,
            "total": 0,
            "pages": 0,
        }
        with self.lock:
            self.docs.insert(0, doc)
            self.active = doc["id"]
            self.path(doc["id"]).mkdir(parents=True, exist_ok=True)
            self._save()
        return doc

    def get(self, doc_id: str) -> dict:
        for doc in self.docs:
            if doc["id"] == doc_id:
                return doc
        raise ValueError("Document not found")

    def path(self, doc_id: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{32}", doc_id):
            raise ValueError("Invalid document id")
        return self.root / doc_id

    def source(self, doc_id: str) -> Path:
        workspace = self.path(doc_id)
        name = self.get(doc_id)["source"]
        if name not in ("source.pdf", "source.jpg") + tuple("source" + s for s in TEXT_SUFFIXES):
            raise ValueError("Invalid managed source")
        source = workspace / name
        if not source.resolve().is_relative_to(workspace.resolve()):
            raise ValueError("Invalid managed source")
        return source

    def open(self, doc_id: str) -> dict:
        """Select a document without touching recency — the sidebar only
        reorders when a reading session actually starts (see mark_read)."""
        with self.lock:
            doc = self.get(doc_id)
            self.active = doc_id
            self._save()
            return doc

    def mark_read(self, doc_id: str) -> None:
        """Bump recency only when the user actually reads the document."""
        with self.lock:
            doc = self.get(doc_id)
            doc["last_opened"] = time.time()
            self._save()

    def update(self, doc_id: str, **fields) -> dict:
        with self.lock:
            doc = self.get(doc_id)
            for key in ("status", "error", "position", "total", "pages", "title"):
                if key in fields:
                    doc[key] = fields[key]
            self._save()
            return doc

    def rename(self, doc_id: str, title: str) -> dict:
        title = " ".join(title.split()).strip()
        if not title:
            raise ValueError("Give the document a name")
        if len(title) > 100:
            raise ValueError("Keep the name under 100 characters")
        return self.update(doc_id, title=title)

    def delete(self, doc_id: str) -> str | None:
        with self.lock:
            doc = self.get(doc_id)
            self.docs.remove(doc)
            if self.active == doc_id:
                self.active = self.docs[0]["id"] if self.docs else None
            self._save()
            shutil.rmtree(self.path(doc_id), ignore_errors=True)
            return self.active

    def active_id(self) -> str | None:
        return self.active if self.active and any(d["id"] == self.active for d in self.docs) else None

    def active_source(self) -> Path | None:
        doc_id = self.active_id()
        return self.source(doc_id) if doc_id else None

    def public(self) -> dict:
        docs = sorted(self.docs, key=lambda d: d.get("last_opened", 0), reverse=True)
        return {"active": self.active_id(), "documents": [dict(d) for d in docs]}
