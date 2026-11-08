"""Read Along — macOS Vision OCR line geometry.

Asks macOS Vision for per-line text boxes on a page image, runs Vision in a
short-lived child process so a native Vision crash degrades to no line boxes
instead of killing the reader, and orders lines with a recursive XY-cut that
finishes one column before the next (headings stay above columns; label/value
rows read left-to-right).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from ._config import ROOT

VISION_HELPER_ARG = "--vision-helper"


def _vision_lines(path: Path) -> list[dict]:
    import Quartz
    import Vision
    from Foundation import NSURL

    url = NSURL.fileURLWithPath_(str(path))
    src = Quartz.CGImageSourceCreateWithURL(url, None)
    if src is None:
        return []
    img = Quartz.CGImageSourceCreateImageAtIndex(src, 0, None)
    if img is None:
        return []

    # The accurate model occasionally fails on the Neural Engine
    # (e5rtError); the fast model still gives good line geometry, and the
    # text itself comes from LFM3 anyway.
    for level in (Vision.VNRequestTextRecognitionLevelAccurate,
                  Vision.VNRequestTextRecognitionLevelFast):
        req = Vision.VNRecognizeTextRequest.alloc().init()
        req.setRecognitionLevel_(level)
        req.setUsesLanguageCorrection_(True)
        req.setRecognitionLanguages_(["en-US"])
        handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(img, None)
        try:
            result = handler.performRequests_error_([req], None)
            if isinstance(result, tuple) and result and result[0] is False:
                raise RuntimeError(str(result[1]))
            out = []
            for obs in req.results() or []:
                cand = obs.topCandidates_(1)[0]
                b = obs.boundingBox()
                out.append({
                    "text": str(cand.string()),
                    "conf": float(cand.confidence()),
                    "box": [float(b.origin.x), float(b.origin.y),
                            float(b.size.width), float(b.size.height)],
                })
            return out
        except Exception:
            continue
    return []


VISION_LOCK = __import__("threading").Lock()


def vision_lines(path: Path) -> list[dict]:
    with VISION_LOCK:
        return _vision_via_subprocess(path)


def _vision_helper_main(argv: list[str]) -> int:
    """Run one Vision request in this child process and print JSON lines."""
    try:
        lines = _vision_lines(Path(argv[0]))
    except Exception:
        lines = []
    print(json.dumps(lines))
    return 0


def _vision_via_subprocess(path: Path) -> list[dict]:
    """Vision in a short-lived child, so a native Vision crash degrades to
    no line boxes instead of killing the reader."""
    try:
        proc = subprocess.run(
            [sys.executable, str(ROOT / "readalong.py"), VISION_HELPER_ARG, str(path)],
            capture_output=True, text=True, timeout=300,
        )
    except Exception:
        return _vision_lines(path)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip()[-300:]
        if tail:
            print(f"[ocr] Vision helper failed ({proc.returncode}): {tail}", file=sys.stderr)
        return []
    try:
        lines = json.loads(proc.stdout or "[]")
    except Exception:
        return []
    return lines if isinstance(lines, list) else []


def _vision_box(v: dict) -> list[float]:
    """Vision boxes are normalized bottom-left; return top-left [x,y,w,h]."""
    x, y, w, h = v["box"]
    return [x, 1.0 - y - h, w, h]


def reading_order(items: list, box) -> list:
    """Order lines using their geometry instead of a flat top-to-bottom sort.

    Two-column pages read down one column before the next. A recursive XY-cut
    first finds a clear vertical gutter; if a full-width heading blocks that, a
    horizontal whitespace band separates it and the columns beneath are cut on
    the next pass.
    """
    if len(items) < 2:
        return list(items)

    def split(items: list, horizontal: bool) -> list[list] | None:
        spans = []
        for item in items:
            x, y, w, h = box(item)
            spans.append((y, y + h) if horizontal else (x, x + w))
        spans.sort()
        merged = [list(spans[0])]
        for start, end in spans[1:]:
            if start <= merged[-1][1] + 0.025:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        if len(merged) < 2:
            return None
        gaps = [(merged[i][0] - merged[i - 1][1], i) for i in range(1, len(merged))]
        # Horizontal cuts are applied top-down so a full-width heading is
        # separated before the columns underneath are considered.
        candidates = gaps if horizontal else sorted(gaps, reverse=True)
        minimum_gap = 0.04 if horizontal else 0.025
        for size, i in candidates:
            if size < minimum_gap:
                continue
            boundary = (merged[i - 1][1] + merged[i][0]) / 2
            first, second = [], []
            for item in items:
                x, y, w, h = box(item)
                center = (y + h / 2) if horizontal else (x + w / 2)
                (first if center < boundary else second).append(item)
            minimum = 1 if horizontal else 2
            if len(first) >= minimum and len(second) >= minimum:
                return [first, second]
        return None

    def walk(items: list) -> list:
        if len(items) < 2:
            return list(items)
        groups = split(items, horizontal=False)
        if groups is None:
            groups = split(items, horizontal=True)
        if groups is None:
            # A leaf may still contain a label/value pair on one visual row.
            ordered = sorted(items, key=lambda item: box(item)[1])
            rows: list[list] = []
            anchor = None
            for item in ordered:
                x, y, w, h = box(item)
                if anchor is None or y > anchor + max(0.012, h * 0.6):
                    rows.append([item])
                    anchor = y
                else:
                    rows[-1].append(item)
            out = []
            for row in rows:
                out.extend(sorted(row, key=lambda item: box(item)[0]))
            return out
        out = []
        for group in groups:
            out.extend(walk(group))
        return out

    return walk(list(items))


def usable_lines(vlines: list[dict]) -> list[dict]:
    out = []
    for v in vlines:
        x, y, w, h = v["box"]
        if y < 0.08 or h < 0.006 or h > 0.14 or w < 0.03:
            continue
        if v.get("conf", 1.0) < 0.3:
            continue
        if len(re.findall(r"[A-Za-z0-9]", v["text"])) < 2:
            continue
        out.append(v)
    return reading_order(out, _vision_box)
