"""Read Along — page-reading OCR (LFM3-VL) with macOS Vision fallback.

Scanned pages and images go through LFM3-VL, macOS Vision line boxes, and the
ink-gap word segmenter. A PDF of image-only pages is rendered once and OCR'd
page by page with a single model load; printed dark slides use macOS Vision
text instead of the page-reading model.
"""

from __future__ import annotations

import gc
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from ._config import DATA, MissingModelError, OCR_LOCAL, OCR_MODEL, OCR_PROMPT, _ocr_dir, _ocr_source
from .mapping import clean_ocr, map_lines
from .segment import _ink_mask
from .vision import _vision_box, usable_lines, vision_lines


def ocr_lfm3_many(paths: list[Path], on_text=None, phase=None) -> list[list[str] | None]:
    """OCR every image with one model load; None marks a page that fell back to Vision."""
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    if phase:
        phase("loading_model")
    model, processor = load(_ocr_source())
    out: list[list[str] | None] = []
    try:
        config = load_config(_ocr_source())
        formatted = apply_chat_template(processor, config, OCR_PROMPT, num_images=1)
        # Reuse the Metal buffer cache across pages; it is cleared once in
        # `finally` when the model is freed.
        for path in paths:
            if phase:
                phase("recognizing")
            try:
                result = generate(
                    model, processor, formatted, [str(path)],
                    max_tokens=2048, temperature=0.1, top_p=1.0, top_k=50,
                    min_p=0.0, repetition_penalty=1.1, enable_thinking=False,
                )
                text = result.text if hasattr(result, "text") else str(result)
                lines = clean_ocr(text)
                if len(lines) < 3:
                    raise RuntimeError("the OCR model returned too little text")
                out.append(lines)
            except Exception as e:
                print(f"[ocr] LFM3 failed on {path.name} ({e})", file=sys.stderr)
                out.append(None)
            if on_text:
                on_text(len(out) - 1, out[-1])
    finally:
        del model, processor
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:
            pass
    return out


def ocr_lfm3(path: Path) -> list[str]:
    lines = ocr_lfm3_many([path])[0]
    if lines is None:
        raise RuntimeError("the OCR model returned too little text")
    return lines


def _looks_printed(path: Path, vlines: list[dict]) -> bool:
    """Conservative printed-text hint: separate letter blobs vs connected ink.

    Vision is confidently wrong on cursive, so confidence is not used. A page
    is called printed only when the median blobs-per-word is high; otherwise
    the caller uses LFM3. Dark slide pages need light-on-dark ink detection.
    """
    import re

    lines = usable_lines(vlines)
    if len(lines) < 3:
        return False
    try:
        gray = np.array(Image.open(path).convert("L"))
    except Exception:
        return False
    H, W = gray.shape
    scores = []
    for line in lines:
        b = _vision_box(line)
        l, t = int(b[0] * W), int(b[1] * H)
        r, btm = int((b[0] + b[2]) * W), int((b[1] + b[3]) * H)
        crop = gray[t:btm, l:r]
        if crop.size == 0:
            continue
        col = _ink_mask(crop).astype(np.uint8).sum(0)
        blobs = []
        start = None
        for i, v in enumerate(col > 0):
            if v and start is None:
                start = i
            elif not v and start is not None:
                blobs.append(i - start)
                start = None
        if start is not None:
            blobs.append(len(col) - start)
        blobs = [x for x in blobs if x >= 2]
        words = max(1, len(line["text"].split()))
        if blobs:
            scores.append(len(blobs) / words)
    if len(scores) < 3:
        return False
    return float(np.median(scores)) >= 3.0


def run_ocr_many(
    paths: list[Path], progress=None, fast: bool = False, phase=None, on_page=None,
    auto: bool = False,
) -> list[tuple[list[dict], int, int]]:
    """OCR a batch of images, loading the model once, with per-page Vision fallback.

    ``fast`` skips LFM3 entirely and uses macOS Vision's text. ``auto`` uses
    Vision only for pages that look printed and LFM3 for the rest. ``on_page(i,
    lines, W, H)`` fires as each page finishes, so a long scan can become
    readable page by page.
    """
    if not fast and not auto and _ocr_dir() is None:
        raise MissingModelError("The handwriting model is not installed. Download it in Settings, or try Printed text recovery.")
    if phase:
        phase("vision")
    vision: list[list[dict]] = []
    for path in paths:
        try:
            vision.append(vision_lines(path))
        except Exception:
            vision.append([])

    out: list[tuple[list[dict], int, int] | None] = [None] * len(paths)
    readable = 0

    def got_text(i: int, lines: list[str] | None) -> None:
        nonlocal readable
        if phase:
            phase("mapping")
        if lines is None:
            vlines = vision[i]
            lines = [v["text"] for v in usable_lines(vlines)] if vlines else []
        W, H = Image.open(paths[i]).size
        mapped = map_lines(lines, vision[i])
        out[i] = (mapped, W, H)
        if mapped:
            readable += 1
        else:
            print(f"[ocr] no text found on {paths[i].name}", file=sys.stderr)
        if on_page:
            on_page(i, mapped, W, H)
        if progress:
            progress(i + 1, len(paths))

    if fast:
        if phase:
            phase("ocr")
        for i in range(len(paths)):
            got_text(i, None)
    elif auto:
        if phase:
            phase("ocr")
        printed = [_looks_printed(paths[i], vision[i]) for i in range(len(paths))]
        lfm_idx = [i for i, p in enumerate(printed) if not p]
        for i, p in enumerate(printed):
            if p:
                got_text(i, None)
        if lfm_idx:
            if _ocr_dir() is None:
                raise MissingModelError(
                    "The handwriting model is not installed. Download it in Settings, or try Printed text recovery."
                )

            def on_lfm(j: int, lines: list[str] | None) -> None:
                got_text(lfm_idx[j], lines)

            try:
                ocr_lfm3_many([paths[i] for i in lfm_idx], on_text=on_lfm, phase=phase)
            except Exception as e:
                print(f"[ocr] LFM3 failed ({e}); using macOS Vision text", file=sys.stderr)
                for i in lfm_idx:
                    if out[i] is None:
                        got_text(i, None)
    else:
        if phase:
            phase("ocr")
        try:
            ocr_lfm3_many(paths, on_text=got_text, phase=phase)
        except Exception as e:
            print(f"[ocr] LFM3 failed ({e}); using macOS Vision text", file=sys.stderr)
            for i in range(len(paths)):
                if out[i] is None:
                    got_text(i, None)

    if paths and readable == 0:
        raise RuntimeError("no readable text found")
    if any(x is None for x in out):
        raise RuntimeError("OCR did not finish every page")
    return out  # type: ignore[return-value]


def run_ocr(path: Path, fast: bool = False, auto: bool = False) -> tuple[list[dict], int, int]:
    return run_ocr_many([path], fast=fast, auto=auto)[0]
