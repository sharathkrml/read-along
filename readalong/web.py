"""Read Along — HTTP backend.

A small ThreadingHTTPServer that the Swift UI talks to. ``APP`` is the live
:class:`~readalong.app.App` instance, set by :mod:`readalong.__main__` at
startup; the native backend sets ``READALONG_URL`` to point at it.
"""

from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .app import App
from ._config import ROOT
from .export import export_image

APP: App | None = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        p = urlparse(self.path).path
        try:
            if p == "/library":
                self._json(APP.library())
            elif p == "/setup/status":
                self._json(APP.models.status_all())
            elif p == "/sample":
                sample = next((candidate for candidate in (ROOT / "ocr.pdf", ROOT / "ocr-pdf.pdf")
                               if candidate.exists()), None)
                if not sample:
                    self._send(404, b"sample unavailable", "text/plain")
                else:
                    self._send(200, sample.read_bytes(), "application/pdf")
            elif p == "/image":
                self._serve_page(0)
            elif p.startswith("/page/"):
                try:
                    self._serve_page(int(p.rsplit("/", 1)[1]))
                except ValueError:
                    self._send(404, b"bad page", "text/plain")
            elif p.startswith("/source/"):
                doc_id = p.rsplit("/", 1)[1]
                if not re.fullmatch(r"[a-f0-9]{32}", doc_id):
                    self._send(404, b"invalid document id", "text/plain")
                    return
                try:
                    src = APP.documents.source(doc_id)
                except Exception:
                    self._send(404, b"source unavailable", "text/plain")
                    return
                if not src.exists():
                    self._send(404, b"source unavailable", "text/plain")
                    return
                ctype = "application/pdf" if src.suffix.lower() == ".pdf" else "image/jpeg"
                self._send(200, src.read_bytes(), ctype)
            elif p == "/model":
                self._json(APP.model_snapshot())
            elif p == "/state":
                self._json(APP.state())
            elif p == "/mics":
                self._json(APP.mics())
            elif p == "/export":
                q = parse_qs(urlparse(self.path).query)
                mode = q.get("mode", ["read"])[0]
                try:
                    page = int(q.get("page", ["-1"])[0])
                except ValueError:
                    page = -1
                data = export_image(APP, mode, page)
                self._send(200, data, "image/jpeg", {
                    "Content-Disposition": 'attachment; filename="read-along-highlighted.jpg"',
                })
            else:
                self._send(404, b"not found", "text/plain")
        except Exception as e:
            self._send(500, str(e).encode(), "text/plain")

    def _serve_page(self, i: int):
        model = APP.model
        if not model or not model.get("pages") or i < 0 or i >= len(model["pages"]):
            self._send(404, b"no page", "text/plain")
            return
        f = APP.workspace / "pages" / model["pages"][i]["image"]
        if not f.exists():
            self._send(404, b"no page", "text/plain")
            return
        ctype = "image/png" if f.suffix.lower() == ".png" else "image/jpeg"
        self._send(200, f.read_bytes(), ctype)

    def do_POST(self):
        p = urlparse(self.path).path
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n > 36 * 1024 * 1024:
                self.close_connection = True
                self._json({"error": "Choose a file smaller than 25 MB"}, 413)
                return
            body = json.loads(self.rfile.read(n) or b"{}")
            if p in ("/upload", "/documents/import"):
                doc = APP.import_document(
                    body["data"], body.get("name", ""), str(body.get("mode", "auto")),
                )
                self._json({"ok": True, "document": doc})
            elif p == "/documents/open":
                APP.open_document(str(body.get("id", "")))
                self._json({"ok": True, "state": APP.state()})
            elif p == "/documents/rename":
                doc = APP.rename_document(str(body.get("id", "")), str(body.get("title", "")))
                self._json({"ok": True, "document": doc})
            elif p == "/documents/delete":
                next_id = APP.delete_document(str(body.get("id", "")))
                self._json({"ok": True, "active": next_id})
            elif p == "/setup/download":
                APP.models.start(str(body.get("model", "")))
                self._json({"ok": True})
            elif p == "/setup/finish":
                APP.models.finish()
                self._json({"ok": True})
            elif p == "/setup/remove":
                if any(job["status"] == "running" for job in APP.jobs.values()):
                    self._json({"error": "wait for OCR to finish"}, 409)
                    return
                name = str(body.get("model", ""))
                if name == "speech":
                    APP.stop()
                    APP.asr.shutdown()
                APP.models.remove(name)
                self._json({"ok": True})
            elif p == "/ocr":
                APP.start_ocr(bool(body.get("fast", False)), bool(body.get("auto", False)))
                self._json({"ok": True})
            elif p == "/script":
                self._json({"ok": True, "model": APP.set_script(
                    int(body.get("page", 0)), body.get("text", ""))})
            elif p == "/start":
                APP.start()
                self._json({"ok": True})
            elif p == "/stop":
                APP.stop()
                self._json({"ok": True})
            elif p == "/jump":
                APP.jump(int(body.get("word", 0)), doc_id=body.get("doc_id"), revision=body.get("revision"))
                self._json({"ok": True, **APP.state()})
            elif p == "/mic":
                device = body.get("device", None)
                self._json(APP.set_mic_device(device))
            elif p == "/simulate":
                APP._on_text(str(body.get("text", "")), bool(body.get("final", True)))
                self._json(APP.state())
            else:
                self._send(404, b"not found", "text/plain")
        except Exception as e:
            self._json({"error": str(e)}, 400)
