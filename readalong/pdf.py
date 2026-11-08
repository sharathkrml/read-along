"""Read Along — PDF and image ingestion.

PDFs with a text layer are read directly with PyMuPDF (exact word boxes, no
OCR). Scanned PDFs and images go through LFM3-VL, macOS Vision line boxes, and
the ink-gap word segmenter, one page at a time with a single model load.
`process_source` ties ingestion, word-box attachment, and caching together.
"""

from __future__ import annotations

import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageOps

from ._config import DATA, LockedPDFError
from .cache import attach_word_boxes, clear_pages, save_cache
from .ocr import run_ocr_many
from .text_model import build_pages_model, norm_text
from .vision import reading_order


def pdf_lines(words: list, page_w: float, page_h: float) -> list[dict]:
    """Group PyMuPDF words into visual lines, with exact word boxes.

    Some PDFs put each word in its own block/line (a list item, for example).
    Lines on the same baseline and close together are merged back into one.
    """
    groups: dict[tuple[int, int], list] = {}
    for w in words:
        groups.setdefault((w[5], w[6]), []).append(w)
    raw = []
    for ws in groups.values():
        ws.sort(key=lambda w: w[7])
        raw.append(list(ws))
    raw.sort(key=lambda ws: (min(w[1] for w in ws), min(w[0] for w in ws)))

    merged: list[list] = []
    for ws in raw:
        if merged:
            prev = merged[-1]
            if (abs(min(w[1] for w in ws) - min(w[1] for w in prev)) < 3
                    and min(w[0] for w in ws) - max(w[2] for w in prev) < 25):
                prev.extend(ws)
                continue
        merged.append(list(ws))

    lines = []
    for ws in merged:
        ws.sort(key=lambda w: w[0])
        text = " ".join(w[4] for w in ws).strip()
        if not text:
            continue
        x0 = min(w[0] for w in ws)
        y0 = min(w[1] for w in ws)
        x1 = max(w[2] for w in ws)
        y1 = max(w[3] for w in ws)
        if re.fullmatch(r"\d{1,3}", text) and y0 > page_h * 0.9:
            continue
        lines.append({
            "text": text,
            "box": [x0 / page_w, y0 / page_h, (x1 - x0) / page_w, (y1 - y0) / page_h],
            "word_boxes": [
                [w[0] / page_w, w[1] / page_h, (w[2] - w[0]) / page_w, (w[3] - w[1]) / page_h]
                for w in ws
            ],
        })
    return reading_order(lines, lambda line: line["box"])


def pdf_pages(path: Path, progress=None, fast: bool = False, phase=None, on_page=None, auto: bool = False) -> list[dict]:
    import pymupdf

    pages_dir = path.parent / "pages"
    with pymupdf.open(path) as doc:
        if doc.needs_pass:
            raise LockedPDFError("This PDF is locked. Open an unlocked copy to recover its text.")
        n_pages = doc.page_count
    clear_pages(path.parent)
    if phase:
        phase("rendering")
    if not n_pages:
        return []

    def render_chunk(start: int, end: int) -> list[tuple]:
        with pymupdf.open(path) as doc:
            out = []
            for i in range(start, end):
                page = doc[i]
                pix = page.get_pixmap(dpi=150)
                img = pages_dir / f"p{i:03d}.png"
                pix.save(img)
                words = page.get_text("words")
                has_text = len(words) >= 10
                lines = pdf_lines(words, page.rect.width, page.rect.height) if has_text else []
                out.append((i, img, pix.width, pix.height, lines, has_text))
            return out

    # PyMuPDF documents are not thread-safe; each worker opens its own. Small
    # PDFs stay sequential so the thread setup does not cost more than it saves.
    workers = min(4, n_pages) if n_pages >= 8 else 1
    rendered: list[tuple | None] = [None] * n_pages
    if workers == 1:
        for item in render_chunk(0, n_pages):
            rendered[item[0]] = item
    else:
        chunk = (n_pages + workers - 1) // workers
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = [
                ex.submit(render_chunk, s, min(s + chunk, n_pages))
                for s in range(0, n_pages, chunk)
            ]
            for fut in futs:
                for item in fut.result():
                    rendered[item[0]] = item

    pages: list[dict] = []
    jobs: list[tuple[int, Path]] = []
    for item in rendered:
        if item is None:
            continue
        i, img, W, H, lines, has_text = item
        if not has_text:
            jobs.append((i, img))
        pages.append({"image": img.name, "width": W, "height": H, "lines": lines,
                      "reading_status": "ready" if has_text else "pending"})

    if jobs:
        # Publish text-layer pages immediately; scanned pages fill in below.
        if on_page:
            on_page(pages)
        if progress:
            progress(0, len(jobs))  # includes the model load before page 1

        def job_page(j: int, lines: list[dict], W: int, H: int) -> None:
            i, _ = jobs[j]
            pages[i]["lines"] = lines
            pages[i]["width"] = W
            pages[i]["height"] = H
            pages[i]["reading_status"] = "ready" if any(norm_text(line["text"]) for line in lines) else "empty"
            if on_page:
                on_page(pages)

        results = run_ocr_many(
            [img for _, img in jobs], progress, fast=fast, phase=phase, on_page=job_page,
            auto=auto,
        )
        for (i, _), (lines, W, H) in zip(jobs, results):
            pages[i]["lines"] = lines
            pages[i]["width"] = W
            pages[i]["height"] = H
    return pages


def image_pages(path: Path, progress=None, fast: bool = False, phase=None, on_page=None, auto: bool = False) -> list[dict]:
    if phase:
        phase("rendering")
    clear_pages(path.parent)
    out = path.parent / "pages" / "p000.jpg"
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    if max(im.size) > 2000:
        im.thumbnail((2000, 2000), Image.Resampling.LANCZOS)
    im.save(out, "JPEG", quality=92)
    if on_page:
        on_page([{"image": out.name, "width": im.width, "height": im.height,
                  "lines": [], "reading_status": "pending"}])
    if progress:
        progress(0, 1)
    lines, W, H = run_ocr_many([out], progress, fast=fast, phase=phase, auto=auto)[0]
    pages = [{"image": out.name, "width": W, "height": H, "lines": lines,
              "reading_status": "ready" if any(norm_text(line["text"]) for line in lines) else "empty"}]
    if on_page:
        on_page(pages)
    return pages


def process_source(path: Path, progress=None, fast: bool = False, phase=None, on_page=None, auto: bool = False) -> tuple[dict, list[dict]]:
    if path.suffix.lower() == ".pdf":
        pages = pdf_pages(path, progress, fast=fast, phase=phase, on_page=on_page, auto=auto)
    else:
        pages = image_pages(path, progress, fast=fast, phase=phase, on_page=on_page, auto=auto)
    model = build_pages_model(pages)
    if phase:
        phase("mapping")
    attach_word_boxes(model, path.parent)
    if phase:
        phase("saving")
    save_cache(path, pages)
    return model, pages
