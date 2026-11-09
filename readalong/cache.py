"""Read Along — document cache and per-page word boxes.

Persists the OCR'd pages to cache.json (keyed by source mtime/size) with
stale-cache migration, and re-cuts word boxes for handwriting lines that did
not get exact boxes from a PDF text layer.
"""

from __future__ import annotations

import json
import shutil
import os
from pathlib import Path

import numpy as np
from PIL import Image

from ._config import DATA
from .segment import segment_line


def clear_pages(workspace: Path = DATA) -> None:
    pages = workspace / "pages"
    shutil.rmtree(pages, ignore_errors=True)
    pages.mkdir(parents=True, exist_ok=True)


def save_cache(path: Path, pages: list[dict]) -> None:
    st = os.stat(path)
    cache = path.parent / "cache.json"
    cache.parent.mkdir(parents=True, exist_ok=True)
    tmp = cache.with_suffix(".tmp")
    tmp.write_text(json.dumps({
        "version": 4, "mtime": st.st_mtime, "size": st.st_size, "pages": pages,
    }, indent=1))
    tmp.replace(cache)


def load_cache(path: Path) -> dict | None:
    cache = path.parent / "cache.json"
    pages_dir = path.parent / "pages"
    try:
        d = json.loads(cache.read_text())
        st = os.stat(path)
        if abs(d.get("mtime", -1) - st.st_mtime) < 0.001 and d.get("size") == st.st_size:
            if d.get("version") in (2, 4) and d.get("pages"):
                # Version 2 had row-wise column order and could contain lines
                # whose boxes failed to map. Text PDFs and clean Vision pages
                # can be upgraded in place; mapped OCR pages are reprocessed.
                # Version 3 dates from before the line-splitting fix; its
                # merged OCR lines had boxes that did not match their text.
                if d.get("version") == 2:
                    has_unboxed = any(
                        line.get("box") is None
                        for page in d["pages"] for line in page.get("lines", [])
                    )
                    if has_unboxed:
                        return None
                    d["version"] = 4
                    cache.write_text(json.dumps(d, indent=1))
                if all((pages_dir / p["image"]).exists() for p in d["pages"]):
                    return d
            elif d.get("lines") and path.suffix.lower() != ".pdf":
                # migrate the original single-image cache
                clear_pages(path.parent)
                shutil.copy(path, pages_dir / "p000.jpg")
                d = {
                    "version": 2, "mtime": st.st_mtime, "size": st.st_size,
                    "pages": [{
                        "image": "p000.jpg", "width": d["width"],
                        "height": d["height"], "lines": d["lines"],
                    }],
                }
                cache.write_text(json.dumps(d, indent=1))
                return d
    except Exception:
        pass
    return None


def attach_word_boxes(model: dict, workspace: Path = DATA) -> None:
    """Fill word boxes for every line that did not get exact boxes from a PDF."""
    # Exact lines (a text PDF, or a generated text/Markdown page) need no ink
    # segmentation; skipping their pages avoids decoding every page image.
    pending = {line["page"] for line in model["lines"]
               if not line.get("exact") and line.get("box")}
    for pi, page in enumerate(model["pages"]):
        if pi not in pending:
            continue
        path = workspace / "pages" / page["image"]
        if not path.exists():
            continue
        gray = np.array(Image.open(path).convert("L"))
        H, W = gray.shape
        for line in model["lines"]:
            if line["page"] != pi or line.get("exact"):
                continue
            box = line.get("box")
            if not box:
                continue
            px = (
                int(box[0] * W), int(box[1] * H),
                int((box[0] + box[2]) * W), int((box[1] + box[3]) * H),
            )
            boxes = segment_line(gray, px, [t["text"] for t in line["tokens"]])
            for tok, b in zip(line["tokens"], boxes):
                if b is None:
                    continue
                nb = [b[0] / W, b[1] / H, b[2] / W, b[3] / H]
                tok["box"] = nb
                if tok["w"] >= 0:
                    model["words"][tok["w"]]["box"] = nb
