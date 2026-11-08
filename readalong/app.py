"""Read Along — backend application object.

Owns the live reading session: the current model/aligner, the OCR job queue,
the ASR client, the document library, and the JSON state the HTTP server and
Swift UI read. All public methods are safe to call from the HTTP handler
threads (they take ``self.lock``).
"""

from __future__ import annotations

import base64
import difflib
import io
import json
import os
import shutil
import signal
import threading
import time
from pathlib import Path

from PIL import Image

from ._config import AUDIO_PORT, DATA, ConflictError, LockedPDFError, MissingModelError
from .aligner import Aligner
from .audio_server import AudioServer
from .cache import attach_word_boxes, load_cache, save_cache
from .library import DocumentStore
from .models import Models
from .pdf import process_source
from .speech import ASR, list_mics
from .text_model import build_pages_model, group_at, group_boxes, norm_text, rebase_position


class App:
    def __init__(self, source_path: Path | None, documents: DocumentStore | None = None):
        self.source_path = source_path
        self.documents = documents
        self.doc_id = documents.active_id() if documents else None
        self.jobs: dict[str, dict] = {}
        self.last_position_write = 0.0
        self.lock = threading.RLock()
        self.model: dict | None = None
        self.model_revision = 0
        self.pages: list[dict] | None = None
        self.aligner: Aligner | None = None
        self.status = "idle"
        self.error = ""
        self.partial = ""
        self.ocr_status = "idle"
        self.ocr_error = ""
        self.ocr_done = 0
        self.ocr_total = 0
        self.ocr_gen = 0
        self.ocr_phase = ""
        self.ocr_error_code = ""
        self.ocr_page: int | None = None
        self._want_listen = False
        self.with_asr = True
        self._asr_starting = False
        self._asr_started = False
        self.models = Models()
        self.asr = ASR(self._on_text, self._on_status)
        self.audio_server: AudioServer | None = None
        self.mic_device: int | None = None
        try:
            raw = json.loads((DATA / "mic.json").read_text())
            device = raw.get("device")
            if isinstance(device, int):
                self.mic_device = device
                self.asr.device = device
        except Exception:
            pass

    def mics(self) -> dict:
        return list_mics()

    def set_mic_device(self, device) -> None:
        """Persisted across launches; restarts the stream if we are listening."""
        with self.lock:
            self.mic_device = device if isinstance(device, int) else None
            self.asr.device = self.mic_device
        try:
            DATA.mkdir(parents=True, exist_ok=True)
            (DATA / "mic.json").write_text(json.dumps({"device": self.mic_device}))
        except Exception:
            pass
        if self.status == "listening":
            self.stop()
            threading.Thread(target=self._restart_mic_bg, daemon=True).start()
        return {"ok": True, "device": self.mic_device}

    def _restart_mic_bg(self) -> None:
        try:
            time.sleep(0.2)
            self.start()
        except Exception as e:
            self._on_status("error", str(e))

    @property
    def workspace(self) -> Path:
        return self.source_path.parent if self.source_path else DATA

    def _job_key(self, doc_id: str | None = None) -> str:
        return doc_id or self.doc_id or "__active__"

    def _mirror_job(self, job: dict | None = None) -> None:
        job = job if job is not None else self.jobs.get(self._job_key())
        if job:
            self.ocr_status = job["status"]
            self.ocr_error = job["error"]
            self.ocr_done = job["done"]
            self.ocr_total = job["total"]
            self.ocr_phase = job["phase"]
            self.ocr_error_code = job.get("error_code", "")
            self.ocr_page = job.get("page")

    def require_snapshot(self, doc_id: str | None = None, revision: int | None = None) -> None:
        if doc_id is not None and doc_id != self.doc_id:
            raise ConflictError("The selected document changed. Try again in the current document.")
        if revision is not None and revision != self.model_revision:
            raise ConflictError("The recovered text changed. Reload it before trying again.")

    def model_snapshot(self) -> dict:
        with self.lock:
            return {**(self.model or {"pages": [], "lines": [], "words": [], "groups": []}),
                    "doc_id": self.doc_id, "model_revision": self.model_revision}

    def _publish_model(self, model: dict, pages: list[dict]) -> None:
        old_pos = self.aligner.pos if self.aligner else 0
        old_conf = self.aligner.conf if self.aligner else 0.0
        pos = rebase_position(self.model, model, old_pos)
        if self.model != model:
            self.model_revision += 1
        self.model = model
        self.pages = pages
        self.aligner = Aligner([w["norm"] for w in model["words"]])
        self.aligner.pos = pos
        self.aligner.conf = old_conf
        self._persist_position(force=True)

    def _on_text(self, text: str, final: bool) -> None:
        with self.lock:
            self.partial = text
            if self.aligner:
                before = self.aligner.pos
                self.aligner.update(text, final)
                if self.aligner.pos != before:
                    self._persist_position()

    def _on_status(self, status: str, msg: str = "") -> None:
        with self.lock:
            self.status = status
            if status == "error":
                self.error = msg
            elif status in ("loading", "listening"):
                self.error = ""

    def _persist_position(self, force: bool = False) -> None:
        if not self.documents or not self.doc_id or not self.aligner:
            return
        now = time.time()
        try:
            doc = self.documents.get(self.doc_id)
        except ValueError:
            return
        doc["position"] = self.aligner.pos
        if force or now - self.last_position_write >= 1:
            self.documents.update(self.doc_id, position=self.aligner.pos)
            self.last_position_write = now

    def library(self) -> dict:
        if not self.documents:
            return {"active": None, "documents": []}
        payload = self.documents.public()
        for doc in payload["documents"]:
            job = self.jobs.get(doc["id"])
            doc.update({
                "ocr_done": job["done"] if job else 0,
                "ocr_total": job["total"] if job else 0,
                "ocr_phase": job["phase"] if job else "",
            })
        return payload

    def load(self) -> bool:
        if not self.source_path:
            return False
        d = load_cache(self.source_path)
        if not d:
            self._mirror_job()
            return False
        self.pages = d["pages"]
        model = build_pages_model(self.pages)
        attach_word_boxes(model, self.source_path.parent)
        if not model["words"]:
            return False
        saved_pos = 0
        if self.documents and self.doc_id:
            doc = self.documents.get(self.doc_id)
            saved_pos = min(int(doc.get("position", 0)), len(model["words"]))
        self._publish_model(model, self.pages)
        self.aligner.pos = max(0, saved_pos)
        if self.documents and self.doc_id:
            self.documents.update(self.doc_id, total=len(model["words"]), pages=len(model["pages"]))
            if self._job_key() not in self.jobs:
                self.ocr_status = "done" if doc.get("status") == "ready" else doc.get("status", "idle")
                self.ocr_error = doc.get("error", "")
        else:
            self.ocr_status = "done"
        self._mirror_job()
        return True

    def _begin_ocr(self, doc_id: str | None = None) -> int:
        with self.lock:
            if any(job["status"] == "running" for job in self.jobs.values()):
                raise ValueError("Another document is already being processed")
            key = self._job_key(doc_id)
            self.ocr_gen += 1
            job = {
                "gen": self.ocr_gen, "status": "running", "error": "",
                "done": 0, "total": 0, "phase": "checking", "error_code": "", "page": None,
            }
            self.jobs[key] = job
            if self.documents and doc_id:
                self.documents.update(doc_id, status="processing", error="")
            if key == self._job_key():
                self._mirror_job(job)
            return self.ocr_gen

    def ocr_now(self, fast: bool = False, auto: bool = False) -> None:
        """Run OCR in the calling thread (startup, --ocr-only)."""
        if not self.source_path:
            return
        gen = self._begin_ocr(self.doc_id)
        self._run_ocr(gen, self.source_path, fast, auto, self.doc_id)

    def start_ocr(self, fast: bool = False, auto: bool = False, doc_id: str | None = None) -> None:
        """Start one OCR job; its workspace is independent of the open document."""
        target = doc_id or self.doc_id
        path = self.documents.source(target) if self.documents and target else self.source_path
        if not path:
            raise ValueError("Choose a document first")
        gen = self._begin_ocr(target)
        threading.Thread(
            target=self._run_ocr, args=(gen, path, fast, auto, target), daemon=True,
        ).start()

    def _run_ocr(self, gen: int, path: Path, fast: bool = False, auto: bool = False,
                 doc_id: str | None = None) -> None:
        key = self._job_key(doc_id)

        def valid() -> bool:
            return key in self.jobs and self.jobs[key]["gen"] == gen

        def update(**fields) -> None:
            with self.lock:
                if not valid():
                    return
                self.jobs[key].update(fields)
                if key == self._job_key():
                    self._mirror_job()

        def progress(done: int, total: int) -> None:
            update(done=done, total=total)

        def phase(name: str) -> None:
            update(phase=name)

        def set_model(model: dict, pages: list[dict]) -> None:
            self._publish_model(model, pages)

        def on_page(pages: list[dict]) -> None:
            model = build_pages_model(pages)
            attach_word_boxes(model, path.parent)
            with self.lock:
                if not valid():
                    return
                if doc_id == self.doc_id:
                    set_model(model, pages)
                save_cache(path, pages)
            if self.documents and doc_id:
                self.documents.update(doc_id, total=len(model["words"]), pages=len(model["pages"]))
        try:
            model, pages = process_source(
                path, progress=progress, fast=fast, phase=phase, on_page=on_page, auto=auto,
            )
            with self.lock:
                if not valid():
                    return
                if doc_id == self.doc_id:
                    set_model(model, pages)
                self.jobs[key].update(status="done", error="", phase="")
                if key == self._job_key():
                    self._mirror_job()
            if self.documents and doc_id:
                self.documents.update(
                    doc_id, status="ready", error="", total=len(model["words"]), pages=len(model["pages"]),
                )
        except Exception as e:
            with self.lock:
                if not valid():
                    return
                code = "missing_model" if isinstance(e, MissingModelError) else "locked_pdf" if isinstance(e, LockedPDFError) else "processing_failed"
                self.jobs[key].update(status="needs_model" if code == "missing_model" else "error",
                                      error=str(e), phase="", error_code=code)
                if key == self._job_key():
                    self._mirror_job()
            if self.documents and doc_id:
                self.documents.update(doc_id, status="error", error=str(e))

    def state(self) -> dict:
        with self.lock:
            s = {
                "doc_id": self.doc_id,
                "model_revision": self.model_revision,
                "status": self.status, "error": self.error, "partial": self.partial,
                "rms": self.asr.rms, "ocr_status": self.ocr_status,
                "ocr_error": self.ocr_error, "ocr_done": self.ocr_done,
                "ocr_total": self.ocr_total, "ocr_phase": self.ocr_phase,
                "ocr_error_code": self.ocr_error_code, "ocr_page": self.ocr_page,
                "ocr_required_model": "ocr" if self.ocr_error_code == "missing_model" else None,
                "model_ready": bool(self.model),
                "model_words": len(self.model["words"]) if self.model else 0,
                "model_pages": len(self.model["pages"]) if self.model else 0,
                "speech_ready": self.models.ready("speech"),
                "ocr_ready": self.models.ready("ocr"),
                "audio_port": AUDIO_PORT,
                "pos": 0, "total": 0, "current": None, "next": None,
                "page": 0, "next_page": None,
                "current_boxes": [], "next_boxes": [], "confidence": 0.0,
            }
            if not self.model or not self.aligner:
                return s
            pos = self.aligner.pos
            s["pos"] = pos
            s["total"] = len(self.model["words"])
            s["confidence"] = self.aligner.conf
            gi = group_at(self.model, pos)
            if gi < 0:
                return s
            cur = self.model["groups"][gi]
            nxt = self.model["groups"][gi + 1] if gi + 1 < len(self.model["groups"]) else None
            s["current"] = [cur["start"], cur["end"]]
            s["page"] = cur["page"]
            s["next_page"] = nxt["page"] if nxt else None
            if nxt:
                s["next"] = [nxt["start"], nxt["end"]]
            s["current_boxes"] = group_boxes(cur, self.model)
            if nxt and nxt["page"] == cur["page"]:
                s["next_boxes"] = group_boxes(nxt, self.model)
            return s

    def start(self, doc_id: str | None = None) -> None:
        with self.lock:
            self.require_snapshot(doc_id)
            if self.status == "listening" or (self.status == "loading" and self._want_listen):
                return
            if not self.models.ready("speech"):
                raise ValueError("Set up the speech model first — open Setup.")
            if not self.model:
                raise ValueError("the page is still being read — wait a moment")
            self.status = "loading"
            self.error = ""
            self._want_listen = True
            if self.documents and self.doc_id:
                self.documents.mark_read(self.doc_id)
        threading.Thread(target=self._start_bg, daemon=True).start()

    def _start_bg(self) -> None:
        try:
            self.asr.ensure()
            if not self._want_listen:
                self._on_status("idle")
                return
            # Audio server was already started at app launch (__main__.py).
            self.asr.start()
        except Exception as e:
            self._on_status("error", str(e))

    def _start_audio_server(self) -> None:
        """Relay PCM captured by the Swift mic layer into the ASR queue."""
        if self.audio_server is None:
            self.audio_server = AudioServer(self.asr.feed_audio, port=AUDIO_PORT)
            self.audio_server.start()

    def _stop_audio_server(self) -> None:
        if self.audio_server is not None:
            try:
                self.audio_server.stop()
            except Exception:
                pass
            self.audio_server = None

    def stop(self, doc_id: str | None = None) -> None:
        with self.lock:
            self.require_snapshot(doc_id)
            self._persist_position(force=True)
            self._want_listen = False
            self.asr.stop()
            self._stop_audio_server()
            self._on_status("idle")

    def jump(self, word: int, doc_id: str | None = None, revision: int | None = None) -> None:
        with self.lock:
            self.require_snapshot(doc_id, revision)
            if not self.aligner or not self.model:
                return
            self.aligner.pos = max(0, min(word, len(self.model["words"])))
            self.aligner.conf = 1.0
            self.partial = ""
            self._persist_position(force=True)

    def set_script(self, page: int, text: str, doc_id: str | None = None,
                   revision: int | None = None) -> dict:
        with self.lock:
            self.require_snapshot(doc_id, revision)
            if (self.jobs.get(self._job_key()) or {}).get("status") == "running":
                raise ConflictError("Wait for text recovery to finish before saving corrections. Your draft can stay open.")
            if not self.pages or not self.source_path:
                raise ValueError("no page loaded")
            if not 0 <= page < len(self.pages):
                raise ValueError("Page is out of range")
            if not isinstance(text, str):
                raise ValueError("Correction must be text")
            self.stop()
            old = self.pages[page]["lines"]
            texts = [line.strip() for line in text.splitlines() if line.strip()]
            lines = [{"text": line, "box": None} for line in texts]
            matcher = difflib.SequenceMatcher(None, [line["text"] for line in old], texts, autojunk=False)
            for a0, b0, length in matcher.get_matching_blocks():
                for offset in range(length):
                    lines[b0 + offset] = dict(old[a0 + offset])
            pages = [dict(p) for p in self.pages]
            pages[page] = {**pages[page], "lines": lines,
                           "reading_status": "ready" if any(norm_text(line) for line in texts) else "empty"}
            model = build_pages_model(pages)
            attach_word_boxes(model, self.source_path.parent)
            save_cache(self.source_path, pages)
            self._publish_model(model, pages)
            self.partial = ""
            if self.documents and self.doc_id:
                self.documents.update(
                    self.doc_id, status="ready", position=self.aligner.pos,
                    total=len(model["words"]), pages=len(model["pages"]),
                )
            return self.model_snapshot()

    def open_document(self, doc_id: str) -> dict:
        if not self.documents:
            raise ValueError("Document library is unavailable")
        self.stop()
        doc = self.documents.open(doc_id)
        with self.lock:
            self.doc_id = doc_id
            self.source_path = self.documents.source(doc_id)
            self.model = None
            self.pages = None
            self.aligner = None
            self.partial = ""
            self.error = ""
            self.ocr_status = "done" if doc.get("status") == "ready" else doc.get("status", "idle")
            self.ocr_error = doc.get("error", "")
            self.ocr_done = 0
            self.ocr_total = 0
            self.ocr_phase = ""
            self.last_position_write = 0
        loaded = self.load()
        if not loaded and doc.get("status") == "ready":
            self.start_ocr(doc_id=doc_id)
        return doc

    def import_document(self, data_url: str, name: str = "", mode: str = "auto") -> dict:
        if not self.documents:
            raise ValueError("Document library is unavailable")
        if any(job["status"] == "running" for job in self.jobs.values()):
            raise ValueError("Wait for the current import to finish before adding another document")
        try:
            raw = data_url.split(",", 1)[-1]
            data = base64.b64decode(raw, validate=True)
        except Exception as e:
            raise ValueError("The file could not be read") from e
        if not data:
            raise ValueError("The file is empty")
        if len(data) > 25 * 1024 * 1024:
            raise ValueError("Choose a file smaller than 25 MB")
        is_pdf = name.lower().endswith(".pdf") or data[:5] == b"%PDF-"
        if is_pdf and data[:5] != b"%PDF-":
            raise ValueError("This is not a valid PDF")
        doc = self.documents.create(name or "Untitled document", ".pdf" if is_pdf else ".jpg")
        source = self.documents.source(doc["id"])
        try:
            if is_pdf:
                source.write_bytes(data)
            else:
                with Image.open(io.BytesIO(data)) as image:
                    image.convert("RGB").save(source, "JPEG", quality=95)
        except Exception:
            self.documents.delete(doc["id"])
            raise ValueError("Choose a valid PDF, JPG, PNG, or WebP file")
        self.open_document(doc["id"])
        self.start_ocr(fast=mode == "fast", auto=mode == "auto", doc_id=doc["id"])
        return dict(doc)

    def upload(self, data_url: str, name: str = "") -> dict:
        return self.import_document(data_url, name, "auto")

    def rename_document(self, doc_id: str, title: str) -> dict:
        if not self.documents:
            raise ValueError("Document library is unavailable")
        return self.documents.rename(doc_id, title)

    def delete_document(self, doc_id: str) -> str | None:
        if not self.documents:
            raise ValueError("Document library is unavailable")
        job = self.jobs.get(doc_id)
        if job and job["status"] == "running":
            raise ValueError("Wait for processing to finish before deleting this document")
        was_active = doc_id == self.doc_id
        if was_active:
            self.stop()
        next_id = self.documents.delete(doc_id)
        self.jobs.pop(doc_id, None)
        if was_active:
            if next_id:
                self.open_document(next_id)
            else:
                with self.lock:
                    self.doc_id = None
                    self.source_path = None
                    self.model = None
                    self.pages = None
                    self.aligner = None
                    self.partial = ""
                    self.ocr_status = "idle"
                    self.ocr_error = ""
        return next_id

    def shutdown(self) -> None:
        # Position is persisted continuously; never hang process exit on it.
        if self.lock.acquire(timeout=2):
            try:
                self._persist_position(force=True)
            finally:
                self.lock.release()
        self.models.shutdown()
        self.asr.shutdown()
        self._stop_audio_server()

    def ensure_loaded(self) -> None:
        """Load the document after Setup finishes, once downloads are done."""
        threading.Thread(target=self._ensure_loaded_bg, daemon=True).start()

    def _ensure_loaded_bg(self) -> None:
        while self.models.any_downloading():
            time.sleep(1)
        _startup(self, self.with_asr)

    def _start_asr_early(self) -> None:
        """Warm the speech server once the first page is readable."""
        with self.lock:
            if self._asr_started or self._asr_starting or self.asr.running:
                return
            if not self.with_asr or not self.models.ready("speech"):
                return
            if self.status in ("listening", "loading"):
                return
            self._asr_starting = True
        threading.Thread(target=self._start_asr_early_bg, daemon=True).start()

    def _start_asr_early_bg(self) -> None:
        try:
            _ensure_asr(self)
            with self.lock:
                self._asr_started = True
        finally:
            with self.lock:
                self._asr_starting = False


def _startup(app: App, with_asr: bool) -> None:
    """Load the document after Setup finishes, once downloads are done.

    Setup is nonblocking: Read to me and text PDFs work without models.
    """
    try:
        if not app.load():
            app.ocr_now()
    finally:
        # ASR (Phonon) is started on demand by Follow me, not at launch, to
        # keep baseline RAM down. _ensure_asr is retained for explicit warm-up.
        pass


def _ensure_asr(app: App) -> None:
    """Warm the engine in the background without touching user-visible status.

    Microphone only opens on explicit start. A background warm-up failure stays
    silent; the user's next start retries and reports it then. Never wipe a
    user-requested loading state.
    """
    try:
        app.asr.ensure(notify=False)
        with app.lock:
            if app.status == "loading" and not app.asr.running and not app._want_listen:
                app.status = "idle"
    except Exception:
        pass
