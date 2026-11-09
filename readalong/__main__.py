"""Read Along — executable entry point (`python -m readalong` or `python readalong.py`).

Parses CLI args, builds the :class:`~readalong.app.App`, starts the HTTP
server, and wires it into :mod:`readalong.web`. The bundled native backend
runs the root-level `readalong.py` shim, which delegates to this `main()`.
"""

from __future__ import annotations

import argparse
import atexit
import os
import shutil
import signal
import sys
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

from ._config import CACHE, DATA, IMAGE, PDF, WEB_PORT
from .app import App, _startup
from .library import DocumentStore
from .pdf import process_source
from .vision import VISION_HELPER_ARG, _vision_helper_main
from . import web

APP = web.APP  # module-level alias used by atexit/signal handlers


def main() -> None:
    if len(sys.argv) > 2 and sys.argv[1] == VISION_HELPER_ARG:
        raise SystemExit(_vision_helper_main(sys.argv[2:]))
    ap = argparse.ArgumentParser(description="OCR a page or PDF and read along with it.")
    ap.add_argument("--image", help="image or PDF to open (copied into data/)")
    ap.add_argument("--port", type=int, default=WEB_PORT)
    ap.add_argument("--no-asr", action="store_true", help="don't start the speech server")
    ap.add_argument("--ocr-only", action="store_true", help="run OCR, print, and exit")
    ap.add_argument("--fast", action="store_true", help="use macOS Vision text instead of the page-reading model")
    ap.add_argument("--auto", action="store_true", help="use Vision for pages that look printed, the model for the rest")
    args = ap.parse_args()

    global APP
    DATA.mkdir(parents=True, exist_ok=True)
    library_exists = (DATA / "library.json").exists()
    src = None

    if args.image and (not library_exists or args.ocr_only):
        src = Path(args.image).expanduser()
        if not src.exists():
            sys.exit(f"no such file: {src}")
        is_pdf = src.suffix.lower() == ".pdf"
        source = PDF if is_pdf else IMAGE
        shutil.copy(src, source)
        try:
            (IMAGE if is_pdf else PDF).unlink()
        except FileNotFoundError:
            pass
        try:
            CACHE.unlink()
        except FileNotFoundError:
            pass
    elif args.image:
        src = Path(args.image).expanduser()
        if not src.exists():
            sys.exit(f"no such file: {src}")
        source = PDF if src.suffix.lower() == ".pdf" else IMAGE
    elif PDF.exists():
        source = PDF
    elif IMAGE.exists():
        source = IMAGE
    else:
        source = None

    if args.ocr_only:
        if source is None:
            sys.exit("no image or PDF to OCR")
        model, pages = process_source(source, fast=args.fast, auto=args.auto)
        for i, page in enumerate(pages):
            print(f"\n--- page {i + 1} ({len(page['lines'])} lines) ---")
            for line in page["lines"]:
                n = len(line["text"].split())
                print(f"[{n:2d} words] {'box' if line['box'] else '---'}  {line['text']}")
        print(f"\n{len(pages)} page(s), {len(model['words'])} words")
        return

    documents = DocumentStore()
    if args.image and library_exists and src is not None:
        doc = documents.create(src.name, src.suffix)
        target = documents.source(doc["id"])
        if src.suffix.lower() == ".pdf":
            shutil.copy2(src, target)
        else:
            from PIL import Image
            with Image.open(src) as image:
                image.convert("RGB").save(target, "JPEG", quality=95)
        documents.open(doc["id"])
    web.APP = App(documents.active_source(), documents)
    APP = web.APP
    APP.with_asr = not args.no_asr
    # The audio relay is always on so the Swift mic layer can connect as soon
    # as Follow me is tapped; Python never opens the microphone itself.
    try:
        APP._start_audio_server()
    except Exception as exc:
        # A stale process holding the port must not take the whole backend
        # down; Follow me will report the relay error when it is started.
        print(f"[audio] relay unavailable: {exc}")
    threading.Thread(target=_startup, args=(APP, not args.no_asr), daemon=True).start()

    server = None
    port = args.port
    for p in range(args.port, args.port + 10):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", p), web.Handler)
            port = p
            break
        except OSError:
            continue
    if server is None:
        sys.exit("no free web port")

    atexit.register(APP.shutdown)
    url = f"http://127.0.0.1:{port}/"
    print(f"Read Along → {url}")
    signal.signal(signal.SIGTERM, _sigterm)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        APP.shutdown()
        # A stuck worker must not strand the process as an orphan backend.
        os._exit(0)


def _sigterm(signum, frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    raise SystemExit(main())
