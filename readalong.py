#!/usr/bin/env python3
"""
Read Along — OCR a handwritten page, then highlight the words on the source image
while you read it aloud.

    python readalong.py             # opens the reader
    python readalong.py --ocr-only  # OCR the current image and print the lines
"""

from __future__ import annotations

import argparse
import asyncio
import atexit
import base64
import bisect
import difflib
import gc
import io
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.request
import uuid
from bisect import bisect_left
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent
# The .app is read-only, so it points this at Application Support.
DATA = Path(os.environ.get("READALONG_DATA") or ROOT / "data")
PAGES = DATA / "pages"
IMAGE = DATA / "current.jpg"
PDF = DATA / "current.pdf"
CACHE = DATA / "cache.json"

OCR_MODEL = "LiquidAI/LFM3-VL-2B-MLX-4bit"
ASR_MODEL = "phonon-2.5-en"
ASR_PORT = 8010
WEB_PORT = 8765

# Model setup. Weights are not in the .app; these paths are where they land.
SETUP_MARKER = DATA / "onboarded"
OCR_LOCAL = DATA / "models" / "ocr"
SPEECH_TOTAL = 157_616_598          # Phonon-2.5 English download bytes
OCR_TOTAL = 1_650_000_000           # LFM3-VL 4-bit, approximate

OCR_PROMPT = (
    "Transcribe the text in this image exactly as written, in natural visual reading order. "
    "If the page has columns, panels, sidebars, tables, or diagram labels, finish one column or "
    "panel from top to bottom before moving to the next; never read across a vertical gutter or "
    "join text from two columns onto one line. Read a full-width heading or title before the "
    "columns beneath it. Preserve each visual line as its own output line, and keep a label with "
    "its value only when they share a line. Preserve spelling, punctuation, arrows, capitalization, "
    "and meaningful line breaks. Faint text showing through from the back of the page is not part "
    "of this page: ignore it. Do not guess: write [illegible] for a word you cannot read. "
    "Output only the transcription, with no commentary and no markdown."
)


class ConflictError(ValueError):
    pass


class MissingModelError(ValueError):
    pass


class LockedPDFError(ValueError):
    pass


# --------------------------------------------------------------------------- #
# text model
# --------------------------------------------------------------------------- #

_NUM = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
    "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
    "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
    "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    "hundred": "100",
}


def norm_token(tok: str) -> str:
    t = unicodedata.normalize("NFKC", tok).lower().replace("\u2019", "'")
    t = re.sub(r"[^a-z0-9']", "", t).replace("'", "")
    return _NUM.get(t, t)


def norm_text(text: str) -> str:
    return " ".join(norm_token(t) for t in text.split() if norm_token(t))


def tokenize(text: str) -> list[dict]:
    return [{"text": raw, "norm": norm_token(raw), "w": -1} for raw in re.findall(r"\S+", text)]


def build_pages_model(pages: list[dict]) -> dict:
    """pages: [{'image','width','height','lines':[{'text','box','word_boxes'?}]}]
    -> one display + alignment model with page numbers on every line and word."""
    model: dict = {"pages": [], "lines": [], "words": [], "groups": []}
    for pi, page in enumerate(pages):
        model["pages"].append({
            "width": page.get("width", 0),
            "height": page.get("height", 0),
            "image": page.get("image", ""),
            "reading_status": page.get("reading_status") or (
                "ready" if any(norm_text(line.get("text", "")) for line in page.get("lines", [])) else "empty"
            ),
            **({"error": page["error"]} if page.get("error") else {}),
        })
        page_lines = page.get("lines", [])
        if len(page_lines) > 1 and all(line.get("box") for line in page_lines):
            page_lines = reading_order(page_lines, lambda line: line["box"])
        for line in page_lines:
            text = (line.get("text") or "").strip()
            if not text:
                continue
            li = len(model["lines"])
            toks = tokenize(text)
            wb = line.get("word_boxes")
            exact = bool(wb) and len(wb) == len(toks)
            if exact:
                for t, b in zip(toks, wb):
                    t["box"] = b
            for t in toks:
                if t["norm"]:
                    t["w"] = len(model["words"])
                    model["words"].append({
                        "text": t["text"], "norm": t["norm"],
                        "page": pi, "line": li, "box": t.get("box"),
                    })
            model["lines"].append({
                "page": pi, "text": text, "box": line.get("box"),
                "tokens": toks, "exact": exact,
            })

    groups: list[tuple[int, list[int]]] = []
    for line in model["lines"]:
        cur: list[int] = []
        for t in line["tokens"]:
            if t["w"] < 0:
                if cur:
                    groups.append((line["page"], cur))
                    cur = []
                continue
            cur.append(t["w"])
            if len(cur) >= 4 or re.search(r"[.,:;!?]$", t["text"]):
                groups.append((line["page"], cur))
                cur = []
        if cur:
            groups.append((line["page"], cur))
    model["groups"] = [
        {"page": p, "start": g[0], "end": g[-1] + 1} for p, g in groups
    ]
    annotate_blocks(model)
    return model


def build_model(lines: list[dict]) -> dict:
    """Single-page convenience wrapper (used by the aligner tests)."""
    return build_pages_model([{"image": "", "width": 0, "height": 0, "lines": lines}])


def rebase_position(old: dict | None, new: dict, pos: int) -> int:
    """Keep the page-local text anchor when earlier pages or lines are inserted."""
    old_words = old.get("words", []) if old else []
    if not old_words:
        return 0
    pos = max(0, min(pos, len(old_words)))
    page = old_words[min(pos, len(old_words) - 1)]["page"]
    before = [w["norm"] for w in old_words if w["page"] == page]
    after = [w["norm"] for w in new["words"] if w["page"] == page]
    offset = sum(w["page"] == page for w in old_words[:pos])
    mapped = len(after)
    for tag, a0, a1, b0, b1 in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes():
        if a0 <= offset < a1:
            mapped = b0 + (offset - a0 if tag == "equal" else min(offset - a0, b1 - b0))
            break
    start = sum(w["page"] < page for w in new["words"])
    return min(len(new["words"]), start + mapped)


def group_at(model: dict, pos: int) -> int:
    gs = model.get("groups") or []
    if not gs:
        return -1
    for i, g in enumerate(gs):
        if pos < g["end"]:
            return i
    return len(gs) - 1


def group_boxes(group: dict, model: dict) -> list[list[float]]:
    by_line: dict[int, list] = {}
    for wi in range(group["start"], group["end"]):
        w = model["words"][wi]
        if w.get("box"):
            by_line.setdefault(w["line"], []).append(w["box"])
    out = []
    for boxes in by_line.values():
        x0 = min(b[0] for b in boxes)
        y0 = min(b[1] for b in boxes)
        x1 = max(b[0] + b[2] for b in boxes)
        y1 = max(b[1] + b[3] for b in boxes)
        out.append([x0, y0, x1 - x0, y1 - y0])
    return out


def annotate_blocks(model: dict) -> None:
    """Tag lines with presentation blocks without changing their words.

    The source boxes and tokens stay untouched, so highlighting and speech
    alignment still work. The UI uses these tags to render headings, bullets,
    labels, wrapped paragraphs, and same-row label/value pairs as readable
    blocks instead of one wall of text.
    """
    body_heights: dict[int, float] = {}
    title_heights: dict[int, float] = {}
    for page in range(len(model.get("pages", []))):
        heights = []
        for line in model["lines"]:
            box = line.get("box")
            if line["page"] == page and box and box[3] > 0.004:
                heights.append(float(box[3]))
        median = float(np.median(heights)) if heights else 0.025
        body_heights[page] = median
        title_heights[page] = max(heights) if heights else median

    page_lines: dict[int, list[dict]] = {}
    for line in model["lines"]:
        page_lines.setdefault(line["page"], []).append(line)

    def continues_below(line: dict) -> bool:
        """True when this line heads a column that has content immediately below."""
        box = line.get("box")
        if not box:
            return False
        for other in page_lines.get(line["page"], []):
            ob = other.get("box")
            if other is line or not ob:
                continue
            left = max(box[0], ob[0])
            right = min(box[0] + box[2], ob[0] + ob[2])
            overlap = max(0.0, right - left) / max(0.001, min(box[2], ob[2]))
            if overlap < 0.4 and abs(box[0] - ob[0]) > 0.035:
                continue
            gap = ob[1] - (box[1] + box[3])
            if 0.001 < gap <= 0.03:
                return True
        return False

    block = 0
    previous = None
    for line in model["lines"]:
        text = line.get("text", "").strip()
        box = line.get("box")
        page = line["page"]
        words = text.split()
        letters = [c for c in text if c.isalpha()]
        upper = len(letters) >= 2 and all(c.isupper() for c in letters)
        bullet = bool(re.match(r"^[•·▪◦*\-]\s+", text))
        height = float(box[3]) if box else body_heights[page]
        kind = "body"
        if (box and title_heights[page] >= body_heights[page] * 1.45
                and height >= title_heights[page] * 0.72):
            kind = "title"
        elif bullet:
            kind = "bullet"
        elif upper and len(words) <= 12 and (len(words) > 1 or not text.endswith((".", ",", ";", ":"))):
            kind = "label"

        new_block = True
        sep = "\n"
        if previous is not None and previous["page"] == page:
            pbox = previous.get("box")
            same_row = bool(
                box and pbox
                and abs(box[1] - pbox[1]) <= max(0.008, min(box[3], pbox[3]) * 0.55)
            )
            aligned = False
            wrapped = False
            if box and pbox:
                left = max(box[0], pbox[0])
                right = min(box[0] + box[2], pbox[0] + pbox[2])
                overlap = max(0.0, right - left) / max(0.001, min(box[2], pbox[2]))
                aligned = overlap >= 0.45 or abs(box[0] - pbox[0]) <= 0.035
                gap = box[1] - (pbox[1] + pbox[3])
                wrapped = gap <= max(0.012, min(box[3], pbox[3]) * 0.85)
            if (same_row and not continues_below(previous) and not continues_below(line)
                    and kind not in ("title", "bullet") and previous["kind"] not in ("title", "bullet")):
                new_block = False
                sep = " · "
                if kind == "label" and previous["kind"] == "label":
                    kind = "label"
                else:
                    kind = "row"
                    previous["kind"] = "row"
            elif wrapped and aligned and kind == "body" and previous["kind"] == "body":
                new_block = False
                sep = " "
            elif ((not box or not pbox) and kind == "body" and previous["kind"] == "body"
                  and not re.search(r"[.!?…][\"')\]]?$", previous.get("text", ""))):
                # Without reliable boxes, keep a wrapped OCR paragraph together
                # until the previous visual line ends a sentence.
                new_block = False
                sep = " "
            elif kind == "title" or previous["kind"] == "title":
                new_block = True
            elif kind == "bullet" or previous["kind"] == "bullet":
                new_block = True
            elif kind == "label" or previous["kind"] == "label":
                new_block = True

        if new_block:
            block += 1
        line["block"] = block
        line["kind"] = kind
        line["sep"] = sep if not new_block else "\n"
        previous = line


class Aligner:
    """Aligns live ASR words to the script, snapping to nearby lines when the
    reader restarts or skips, and advancing monotonically otherwise."""

    def __init__(self, words: list[str]):
        self.words = words
        self.pos = 0
        self.conf = 0.0
        self._index: dict[str, list[int]] = {}
        for i, w in enumerate(words):
            self._index.setdefault(w, []).append(i)

    @staticmethod
    @lru_cache(maxsize=4096)
    def _score(a: str, b: str) -> float:
        if a == b:
            return 1.0
        if difflib.SequenceMatcher(None, a, b).ratio() >= 0.62:
            return 0.3
        return -0.4

    def _find(self, word: str, start: int) -> int:
        """First exact occurrence of word in [start, start+4), or -1."""
        pos = self._index.get(word)
        if not pos:
            return -1
        i = bisect_left(pos, start)
        if i < len(pos) and pos[i] < start + 4:
            return pos[i]
        return -1

    def _anchor(self, asr: list[str], final: bool):
        """Find the best nearby start for the spoken phrase.

        Returns (score, end_position, exact_words) or None. This is what lets a
        reader restart a line just above the cursor, or skip a paragraph and
        start a line just below it, without clicking.
        """
        n = len(asr)
        if n < 3:
            return None
        back = 400
        ahead = 400
        min_exact = 4
        lo = max(0, self.pos - back)
        hi = min(len(self.words), self.pos + ahead)
        if hi - lo < n:
            return None
        best = None
        words = self.words
        nwords = len(words)
        first = asr[0]
        for start in range(lo, hi):
            j = start
            exact = 0
            matched = 0
            found = self._find(first, j)
            if found >= 0:
                exact += 1
                matched += 1
                j = found + 1
            elif j < nwords and self._score(first, words[j]) > 0:
                matched += 1
                j += 1
            else:
                continue
            for a in asr[1:]:
                found = self._find(a, j)
                if found >= 0:
                    exact += 1
                    matched += 1
                    j = found + 1
                elif j < nwords and self._score(a, words[j]) > 0:
                    matched += 1
                    j += 1
            if exact < min_exact:
                continue
            score = exact - 0.6 * (n - matched) - 0.005 * abs(start - self.pos)
            if best is None or score > best[0]:
                best = (score, j, exact)
        return best

    def update(self, text: str, final: bool = False) -> int:
        asr = [norm_token(t) for t in text.split()]
        asr = [t for t in asr if t][-14:]
        if not asr:
            return self.pos

        # A nearby line wins immediately, in either direction. This is the
        # "I messed up, let me start this line again" and "skip ahead a bit"
        # path; the monotonic DP below handles normal reading.
        anchor = self._anchor(asr, final)
        if anchor:
            score, end, exact = anchor
            if abs(end - self.pos) >= 2 and score >= 2.0:
                self.pos = max(0, min(len(self.words), end))
                self.conf = min(1.0, exact / max(1, len(asr)))
                return self.pos

        lo = max(0, self.pos - 3)
        hi = len(self.words) if final else min(len(self.words), self.pos + 32)
        if hi <= lo:
            return self.pos
        script = self.words[lo:hi]
        n, m = len(asr), len(script)
        neg = -1e9
        dp = [[neg] * (m + 1) for _ in range(n + 1)]
        dp[0][0] = 0.0
        for j in range(1, m + 1):
            dp[0][j] = dp[0][j - 1] - 0.10
        for i in range(1, n + 1):
            dp[i][0] = dp[i - 1][0] - 0.50
        for i in range(1, n + 1):
            for j in range(1, m + 1):
                sc = self._score(asr[i - 1], script[j - 1])
                dp[i][j] = max(dp[i - 1][j - 1] + sc, dp[i][j - 1] - 0.10, dp[i - 1][j] - 0.50)
        best_j, best = 0, neg
        for j in range(1, m + 1):
            if dp[n][j] > best:
                best, best_j = dp[n][j], j
        if best_j == 0:
            return self.pos
        conf = best / max(1, n)
        self.conf = max(0.0, min(1.0, conf))

        # Only advance to the last *exact* match in the alignment. A fuzzy
        # substitution is enough to keep reading, but not enough to move the
        # cursor past a word the reader may not have said yet.
        i, j, last_exact = n, best_j, -1
        while i > 0 and j > 0:
            sc = self._score(asr[i - 1], script[j - 1])
            if abs(dp[i][j] - (dp[i - 1][j - 1] + sc)) < 1e-9:
                if sc >= 1.0:
                    last_exact = j - 1
                    break
                i -= 1
                j -= 1
            elif abs(dp[i][j] - (dp[i][j - 1] - 0.10)) < 1e-9:
                j -= 1
            else:
                i -= 1
        if last_exact < 0:
            return self.pos

        new_pos = min(len(self.words), lo + last_exact + 1)
        if new_pos <= self.pos:
            return self.pos
        if not final and n < 2:
            return self.pos
        if conf < (0.25 if final else 0.15):
            return self.pos
        if not final and new_pos - self.pos > 8:
            return self.pos
        if final and new_pos - self.pos > 6 and n < 3:
            return self.pos
        self.pos = new_pos
        return self.pos


# --------------------------------------------------------------------------- #
# OCR + word boxes
# --------------------------------------------------------------------------- #

VISION_LOCK = threading.Lock()


def vision_lines(path: Path) -> list[dict]:
    with VISION_LOCK:
        return _vision_lines(path)


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


def _word_start_spans(ocr_words: list[str], ref_words: list[str]) -> list[int] | None:
    """Map the start of every ref word to an ocr word index.

    Sequence-align the two normalized strings char by char; replace blocks map
    proportionally. Returns one index per ref word, weakly increasing, or None
    when the two texts are too unlike to align.
    """
    n_ref = len(ref_words)

    def bounds(words: list[str]) -> tuple[str, list[int]]:
        parts, starts, pos = [], [], 0
        for w in words:
            norm = norm_token(w)
            if not norm:
                norm = "0"
            starts.append(pos)
            parts.append(norm)
            pos += len(norm) + 1
        return " ".join(parts), starts

    a, a_starts = bounds(ocr_words)
    b, b_starts = bounds(ref_words)
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    lay = []
    for tag, a0, a1, b0, b1 in sm.get_opcodes():
        sa, sb = a1 - a0, b1 - b0
        if tag == "equal":
            for p in range(b1 - b0):
                lay.append(a0 + p)
        else:
            for p in range(b1 - b0):
                lay.append(a0 + (p * sa // max(1, sb)))
    idx = -1
    out = []
    for start in b_starts:
        if start >= len(lay):
            start = len(lay) - 1
        q = bisect.bisect_right(a_starts, lay[start]) - 1
        if q < 0:
            q = 0
        if q <= idx:
            q = idx + 1
        idx = q
        out.append(q)
    if out[-1] >= len(ocr_words):
        return None
    return out


def _stacked_run(j: int, claimed: set[int], vlines: list[dict]) -> list[int]:
    """Vision boxes stacked as the visual lines one OCR line may span.

    LFM3 sometimes returns one merged line where Vision saw several visual
    lines; the neighbours often stay unmatched. The run is the consecutive
    unmatched-and-stacked boxes reaching out above and below box j.
    """
    def stackable(a: dict, b: dict) -> bool:
        ax, ay, aw, ah = _vision_box(a)
        bx, by, bw, bh = _vision_box(b)
        pitch = abs(ay - by)
        overlap = min(ax + aw, bx + bw) - max(ax, bx)
        return overlap > 0.2 * min(aw, bw) and 0.5 * min(ah, bh) < pitch < 1.7 * max(ah, bh)

    run = [j]
    while run[0] > 0 and run[0] - 1 not in claimed and stackable(vlines[run[0] - 1], vlines[run[0]]):
        run.insert(0, run[0] - 1)
    while run[-1] + 1 < len(vlines) and run[-1] + 1 not in claimed and stackable(vlines[run[-1]], vlines[run[-1] + 1]):
        run.append(run[-1] + 1)
    return run


def map_lines(ocr_lines: list[str], vlines: list[dict]) -> list[dict]:
    """Attach a Vision line box to each OCR line, keeping reading order.

    A monotonic sequence alignment is used instead of a greedy best-match:
    one bad OCR line (a diagram label, say) can no longer steal a box and
    shift every line after it.

    When an OCR line spans two or more stacked, unmatched Vision boxes (the
    model merged a wrapped paragraph into one line), its words are shared
    across those boxes so text and boxes cover the same ink.
    """
    vlines = usable_lines(vlines)
    n, m = len(ocr_lines), len(vlines)
    if not n:
        return []
    if not m:
        return [{"text": t, "box": None} for t in ocr_lines]

    sim = [
        [difflib.SequenceMatcher(None, norm_text(a), norm_text(b["text"])).ratio() for b in vlines]
        for a in ocr_lines
    ]
    gap = 0.15
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        dp[i][0] = dp[i - 1][0] - gap
    for j in range(1, m + 1):
        dp[0][j] = dp[0][j - 1] - gap

    def match_score(i, j):
        s = sim[i][j]
        return s - 0.20 if s >= 0.35 else -1.0

    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = max(
                dp[i - 1][j - 1] + match_score(i - 1, j - 1),
                dp[i - 1][j] - gap,
                dp[i][j - 1] - gap,
            )

    pairs: dict[int, int] = {}
    i, j = n, m
    while i > 0 and j > 0:
        if abs(dp[i][j] - (dp[i - 1][j - 1] + match_score(i - 1, j - 1))) < 1e-9:
            if sim[i - 1][j - 1] >= 0.35:
                pairs[i - 1] = j - 1
            i -= 1
            j -= 1
        elif abs(dp[i][j] - (dp[i - 1][j] - gap)) < 1e-9:
            i -= 1
        else:
            j -= 1

    claimed = set(pairs.values())
    out = []
    for i, text in enumerate(ocr_lines):
        j = pairs.get(i)
        if j is not None:
            n_ocr = len(text.split())
            n_ref = max(1, len(vlines[j]["text"].split()))
            if n_ocr > 1.5 * n_ref + 1:
                run = _stacked_run(j, claimed, vlines)
                if len(run) > 1:
                    ref_words = [w for k in run for w in vlines[k]["text"].split()]
                    starts = _word_start_spans(text.split(), ref_words)
                    if starts:
                        # One ocr word span per Vision box: the ref word that
                        # starts each box's text.
                        counts = [len(vlines[k]["text"].split()) for k in run]
                        bounds = [0]
                        acc = 0
                        for c in counts:
                            acc += c
                            bounds.append(min(acc, len(starts)))
                        chunks = []
                        ok = True
                        for pos, (c0, c1) in enumerate(zip(bounds, bounds[1:])):
                            k = run[pos]
                            lo = starts[c0] if c0 < len(starts) else n_ocr
                            hi = starts[c1] if c1 < len(starts) else n_ocr
                            lo = min(lo, n_ocr)
                            hi = min(max(hi, lo), n_ocr)
                            if hi < lo:
                                ok = False
                                break
                            chunks.append((k, " ".join(text.split()[lo:hi])))
                        if ok and any(norm_text(c) for _, c in chunks):
                            placed_any = False
                            pending = ""
                            for k, chunk in chunks:
                                if pending:
                                    chunk = (pending + " " + chunk).strip()
                                    pending = ""
                                bb = vlines[k]["box"]
                                if norm_text(chunk):
                                    out.append({"text": chunk, "box": [bb[0], 1.0 - bb[1] - bb[3], bb[2], bb[3]]})
                                    placed_any = True
                                else:
                                    # Words Vision never boxed travel to the next chunk.
                                    pending = chunk
                            if placed_any:
                                continue
            b = vlines[j]["box"]
            out.append({"text": text, "box": [b[0], 1.0 - b[1] - b[3], b[2], b[3]]})
            continue
        out.append({"text": text, "box": None})
    return out


def clean_ocr(text: str) -> list[str]:
    lines = []
    for line in text.replace("\r", "").splitlines():
        line = line.strip()
        if not line or line.startswith("```"):
            continue
        if re.match(r"^(here is|the transcription|transcription:)", line, re.I):
            continue
        lines.append(line)
    return lines


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


def _ink_mask(gray: np.ndarray) -> np.ndarray:
    """Dark ink on paper, or light ink on a dark slide background."""
    median = float(np.median(gray))
    if median < 128:
        return gray > median + 28
    return gray < min(140, median - 20)


def _looks_printed(path: Path, vlines: list[dict]) -> bool:
    """Conservative printed-text hint: separate letter blobs vs connected ink.

    Vision is confidently wrong on cursive, so confidence is not used. A page
    is called printed only when the median blobs-per-word is high; otherwise
    the caller uses LFM3. Dark slide pages need light-on-dark ink detection.
    """
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


def _char_width(c: str) -> float:
    if c in "ilI.,:;'!|`":
        return 0.45
    if c in "mwMW":
        return 1.45
    if c in "fjrt":
        return 0.75
    if c == "\u2192":
        return 1.2
    return 1.0


def segment_line(gray: np.ndarray, box_px: tuple[int, int, int, int], words: list[str]) -> list[list[int] | None]:
    """Split a line crop into one pixel box per word.

    Ink columns become blobs. Word spaces are the gaps clearly wider than the
    rest; a word is one or more blobs. This keeps a gap inside "heart|beats"
    from shifting every box after it, which is what a plain "widest gaps"
    split does.
    """
    l, t, r, b = box_px
    l, t = max(0, l), max(0, t)
    r, b = min(gray.shape[1], r), min(gray.shape[0], b)
    crop = gray[t:b, l:r]
    if crop.size == 0 or not words:
        return [None] * len(words)
    ink = _ink_mask(crop).astype(np.uint8)
    col = ink.sum(0)
    if col.max() == 0:
        return [None] * len(words)

    blobs: list[tuple[int, int]] = []
    start = None
    for i, v in enumerate(col > 0):
        if v and start is None:
            start = i
        if not v and start is not None:
            if i - start >= 2:
                blobs.append((start, i))
            start = None
    if start is not None and len(col) - start >= 2:
        blobs.append((start, len(col)))
    if not blobs:
        return [None] * len(words)
    if len(blobs) > 2:
        blobs = [bb for bb in blobs if bb[1] - bb[0] >= 3] or blobs

    k = len(words)
    x0, x1 = blobs[0][0], blobs[-1][1]
    available = max(1, x1 - x0)
    weights = [max(0.6, sum(_char_width(c) for c in w)) for w in words]

    if k == 1:
        groups = [(0, len(blobs) - 1)]
    else:
        gaps = [blobs[i][0] - blobs[i - 1][1] for i in range(1, len(blobs))]
        top = sorted(gaps, reverse=True)[: k - 1]
        threshold = max(8.0, 0.4 * float(np.median(top))) if top else 8.0
        cuts = [i for i, g in enumerate(gaps) if g >= threshold]
        groups: list[tuple[int, int]] = []
        s = 0
        for c in cuts:
            groups.append((s, c))
            s = c + 1
        groups.append((s, len(blobs) - 1))

        # too many groups: merge the pair with the narrowest gap
        while len(groups) > k:
            best_gap, best_i = None, 0
            for i in range(len(groups) - 1):
                g = blobs[groups[i + 1][0]][0] - blobs[groups[i][1]][1]
                if best_gap is None or g < best_gap:
                    best_gap, best_i = g, i
            groups[best_i] = (groups[best_i][0], groups[best_i + 1][1])
            del groups[best_i + 1]

    # one box per word; if there are fewer groups than words, the extra words
    # share the last group (a correction written below the end of the line)
    spans: list[tuple[int, int]] = []
    if len(groups) == k:
        for p, j in groups:
            spans.append((blobs[p][0], blobs[j][1]))
    elif len(groups) < k:
        for p, j in groups[:-1]:
            spans.append((blobs[p][0], blobs[j][1]))
        p, j = groups[-1]
        a, b = blobs[p][0], blobs[j][1]
        rest = k - (len(groups) - 1)
        ws = weights[len(groups) - 1:]
        total = sum(ws) or 1.0
        acc = 0.0
        for i, w in enumerate(ws):
            xa = int(a + (b - a) * acc / total)
            acc += w
            xb = int(a + (b - a) * acc / total)
            spans.append((xa, max(xa + 1, xb)))
    else:
        # merged groups should have made this impossible; proportional fallback
        spans = [(int(x0 + i * available / k), int(x0 + (i + 1) * available / k)) for i in range(k)]

    return _boxes(ink, l, t, spans, k, _text_band(ink))


def _boxes(
    ink: np.ndarray, l: int, t: int, spans: list[tuple[int, int]], n: int,
    band: tuple[int, int] | None = None,
) -> list[list[int] | None]:
    out: list[list[int] | None] = []
    for xa, xb in spans[:n]:
        sub = ink[:, xa:xb]
        rows = np.where(sub.sum(1) > 0)[0]
        cols = np.where(sub.sum(0) > 0)[0]
        if len(rows) == 0 or len(cols) == 0:
            out.append(None)
            continue
        y0, y1 = int(rows.min()), int(rows.max()) + 1
        if band is not None:
            y0 = max(y0, band[0])
            y1 = min(y1, band[1])
            if y1 - y0 < 6:
                y0, y1 = int(rows.min()), int(rows.max()) + 1
        px0 = l + xa + int(cols.min())
        px1 = l + xa + int(cols.max()) + 1
        py0 = t + y0
        py1 = t + y1
        out.append([px0, py0, px1 - px0, py1 - py0])
    while len(out) < n:
        out.append(None)
    return out


def _text_band(ink: np.ndarray) -> tuple[int, int] | None:
    """The densest horizontal band of ink: the handwritten line itself,
    excluding ascenders from the line below."""
    rows = ink.sum(1)
    if rows.max() == 0:
        return None
    smooth = np.convolve(rows, np.ones(5) / 5, mode="same")
    on = smooth > 0.2 * smooth.max()
    runs: list[tuple[int, int]] = []
    start = None
    for i, v in enumerate(on):
        if v and start is None:
            start = i
        if not v and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(on)))
    if not runs:
        return None
    band = max(runs, key=lambda ab: rows[ab[0]:ab[1]].sum())
    margin = max(4, int((band[1] - band[0]) * 0.28))
    return (max(0, band[0] - margin), min(len(rows), band[1] + margin))


def clear_pages(workspace: Path = DATA) -> None:
    pages = workspace / "pages"
    shutil.rmtree(pages, ignore_errors=True)
    pages.mkdir(parents=True, exist_ok=True)


def attach_word_boxes(model: dict, workspace: Path = DATA) -> None:
    """Fill word boxes for every line that did not get exact boxes from a PDF."""
    for pi, page in enumerate(model["pages"]):
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


# --------------------------------------------------------------------------- #
# speech
# --------------------------------------------------------------------------- #

def fermion_cmd() -> list[str]:
    """The command prefix that runs the bundled fermion CLI."""
    helper = os.environ.get("READALONG_FERMION")
    if helper:
        return [sys.executable, helper]
    bin_ = shutil.which("fermion") or str(Path(sys.executable).with_name("fermion"))
    if Path(bin_).exists():
        try:
            head = Path(bin_).read_bytes()[:200].decode("utf-8", "replace")
            if not head.startswith("#!"):
                return [bin_]
            interp = head.splitlines()[0][2:].strip().split()[0]
            if Path(interp).exists():
                return [bin_]
        except (OSError, IndexError):
            pass
    # A renamed venv leaves console-script shebangs pointing at the old path.
    return [sys.executable, "-c", "from fermion.cli import main; raise SystemExit(main())"]


class ASR:
    def __init__(self, on_text, on_status):
        self.on_text = on_text
        self.on_status = on_status
        self.proc: subprocess.Popen | None = None
        self.port: int | None = None
        self.device: int | None = None  # macOS input device (None = system default)
        self.thread: threading.Thread | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.ws = None
        self.q: queue.Queue = queue.Queue()
        self.running = False
        self.stream = None
        self.rms = 0.0
        self._lock = threading.Lock()

    @staticmethod
    def healthy(port: int) -> bool:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1.5) as r:
                d = json.loads(r.read())
            return d.get("kind") == "speech"
        except Exception:
            return False

    @staticmethod
    def _free_port(start: int) -> int:
        for p in range(start, start + 20):
            with socket.socket() as s:
                try:
                    s.bind(("127.0.0.1", p))
                    return p
                except OSError:
                    continue
        raise RuntimeError("no free port for the speech server")

    def ensure(self) -> None:
        with self._lock:
            if self.port and self.healthy(self.port):
                return
            for p in range(ASR_PORT, ASR_PORT + 10):
                if self.healthy(p):
                    self.port = p
                    return
            cmd = fermion_cmd()
            DATA.mkdir(parents=True, exist_ok=True)
            log = open(DATA / "asr.log", "ab")
            self.port = self._free_port(ASR_PORT)
            self.proc = subprocess.Popen(
                cmd + ["serve", ASR_MODEL, "--port", str(self.port)],
                stdout=log, stderr=log, start_new_session=True,
            )
            self.on_status("loading")
            for _ in range(120):
                if self.healthy(self.port):
                    return
                if self.proc.poll() is not None:
                    raise RuntimeError("speech server exited: " + tail(DATA / "asr.log"))
                time.sleep(1)
            raise RuntimeError("speech server did not start within 120s")

    def start(self) -> None:
        if self.running:
            return
        self.running = True
        self.q = queue.Queue()
        self._open_mic()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _open_mic(self) -> None:
        import sounddevice as sd

        def cb(indata, frames, t, status):
            if not self.running:
                return
            self.q.put(bytes(indata))
            a = np.frombuffer(indata, dtype=np.float32)
            if a.size:
                self.rms = float(np.sqrt(np.mean(a * a)))

        try:
            self.stream = sd.RawInputStream(
                samplerate=16000, channels=1, dtype="float32",
                blocksize=1600, callback=cb,
                device=self.device,
            )
            self.stream.start()
        except Exception as e:
            self.running = False
            raise RuntimeError(
                f"microphone unavailable ({e}). System Settings → Privacy & Security → Microphone."
            )

    def _run(self) -> None:
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        err = False
        try:
            self.loop.run_until_complete(self._session())
        except Exception as e:
            err = True
            self.on_status("error", str(e))
        finally:
            self._close_mic()
            if not err:
                self.on_status("idle")
            try:
                self.loop.close()
            except Exception:
                pass
            self.loop = None

    async def _session(self) -> None:
        import websockets

        uri = f"ws://127.0.0.1:{self.port}/v1/audio/stream"
        async with websockets.connect(uri, max_size=None) as ws:
            self.ws = ws
            await ws.send(json.dumps({"sample_rate": 16000, "format": "pcm_f32le"}))
            self.on_status("listening")
            sender = asyncio.create_task(self._send(ws))
            try:
                async for msg in ws:
                    d = json.loads(msg)
                    t = d.get("type")
                    if t in ("partial", "final"):
                        self.on_text(d.get("text", ""), t == "final")
                    elif t == "error":
                        raise RuntimeError(d.get("message", "speech error"))
                    elif t == "done":
                        break
            finally:
                self.running = False
                sender.cancel()
                try:
                    await sender
                except Exception:
                    pass
                self.ws = None

    async def _send(self, ws) -> None:
        while self.running:
            try:
                chunk = self.q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.01)
                continue
            await ws.send(chunk)
        try:
            await ws.send(json.dumps({"type": "end"}))
        except Exception:
            pass

    def _close_mic(self) -> None:
        try:
            if self.stream:
                self.stream.stop()
                self.stream.close()
        except Exception:
            pass
        self.stream = None

    def stop(self) -> None:
        self.running = False
        self._close_mic()
        ws, loop = self.ws, self.loop
        if ws is not None and loop is not None:
            try:
                asyncio.run_coroutine_threadsafe(ws.close(), loop)
            except Exception:
                pass

    def shutdown(self) -> None:
        self.stop()
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                pass


def tail(path: Path, n: int = 800) -> str:
    try:
        data = path.read_bytes()[-n:]
        return data.decode("utf-8", "replace").strip()
    except Exception:
        return ""


def list_mics() -> dict:
    """macOS input devices the Follow me picker can choose from."""
    import sounddevice as sd

    payload = {"default": None, "devices": []}
    try:
        devices = sd.query_devices()
        default = sd.default.device[0]
        try:
            default = int(default)
        except Exception:
            default = None
        payload["default"] = default
        for i, d in enumerate(devices):
            ins = int(d.get("max_input_channels") or 0)
            if ins <= 0:
                continue
            payload["devices"].append({
                "id": i,
                "name": str(d.get("name", "")),
                "channels": ins,
            })
    except Exception as e:
        payload["error"] = str(e)
    return payload


# --------------------------------------------------------------------------- #
# models
# --------------------------------------------------------------------------- #

def _dir_size(path: Path) -> int:
    total = 0
    try:
        for p in path.rglob("*"):
            try:
                if p.is_file():
                    total += p.stat().st_size
            except OSError:
                pass
    except OSError:
        pass
    return total


def _speech_cache_repo() -> Path:
    override = os.environ.get("FERMION_CACHE_DIR") or os.environ.get("HF_HUB_CACHE")
    if override:
        root = Path(override).expanduser()
    else:
        hf_home = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
        root = Path(hf_home).expanduser() / "hub"
    return root / "models--FermionResearch--Phonon-2.5-English"


def _incomplete_size() -> int:
    """Largest in-flight Hub download, used for the speech progress bar."""
    best = 0
    try:
        for p in _speech_cache_repo().rglob("*.incomplete"):
            try:
                best = max(best, p.stat().st_size)
            except OSError:
                pass
    except OSError:
        pass
    return best


def _speech_root() -> Path:
    override = os.environ.get("FERMION_CACHE_DIR")
    if override:
        return Path(override).expanduser() / "speech"
    return Path.home() / ".cache" / "fermion" / "speech"


def _speech_dir() -> Path | None:
    for p in _speech_root().glob("*Phonon-2.5-English*"):
        try:
            for config in p.rglob("config.json"):
                directory = config.parent
                if any(part.endswith(".partial") for part in directory.parts):
                    continue
                manifest = json.loads((directory / "packed_manifest.json").read_text())
                if not manifest or not json.loads(config.read_text()):
                    continue
                container = directory / "model.fermion"
                with container.open("rb") as stream:
                    size = int.from_bytes(stream.read(8), "little")
                    if not 0 < size <= min(container.stat().st_size - 8, 16 * 1024 * 1024):
                        continue
                    header = json.loads(stream.read(size))
                if (header.get("format") == "fermion-five-value-parakeet-v1"
                        and header.get("index")
                        and 8 + size + sum(e["b"] for e in header["index"]) == container.stat().st_size):
                    return directory
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return None


def _valid_ocr_dir(path: Path) -> bool:
    try:
        for name in ("config.json", "tokenizer.json", "tokenizer_config.json", "processor_config.json"):
            if not json.loads((path / name).read_text()):
                return False
        index = path / "model.safetensors.index.json"
        files = set(json.loads(index.read_text())["weight_map"].values()) if index.exists() else {p.name for p in path.glob("*.safetensors")}
        if not files or any(Path(name).name != name for name in files):
            return False
        from safetensors import safe_open
        for name in files:
            with safe_open(str(path / name), framework="np") as tensors:
                if not list(tensors.keys()):
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError, ImportError):
        return False
    except Exception:
        return False  # safetensors rejects truncated/incomplete payloads.


def _ocr_dir() -> Path | None:
    if _valid_ocr_dir(OCR_LOCAL):
        return OCR_LOCAL
    override = os.environ.get("HF_HUB_CACHE")
    if override:
        root = Path(override).expanduser()
    else:
        hf_home = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
        root = Path(hf_home).expanduser() / "hub"
    root = root / "models--LiquidAI--LFM3-VL-2B-MLX-4bit"
    for snap in (root / "snapshots").glob("*"):
        try:
            if _valid_ocr_dir(snap):
                return snap
        except OSError:
            pass
    return None


def _ocr_source() -> str:
    """A local model directory if Setup downloaded one, else the Hub id."""
    path = _ocr_dir()
    if path is None:
        raise MissingModelError("The handwriting model is not installed. Download it in Settings.")
    return str(path)


class Models:
    """Download and report the two local models without blocking the UI."""

    def __init__(self):
        self.lock = threading.RLock()
        self.downloads: dict[str, dict] = {}
        self.procs: dict[str, subprocess.Popen] = {}
        self._ready = {"speech": False, "ocr": False}
        self.refresh()

    def refresh(self) -> None:
        self._ready["speech"] = _speech_dir() is not None
        self._ready["ocr"] = _ocr_dir() is not None

    def ready(self, name: str) -> bool:
        return bool(self._ready.get(name))

    def needs_setup(self) -> bool:
        return not SETUP_MARKER.exists()

    def finish(self) -> None:
        DATA.mkdir(parents=True, exist_ok=True)
        SETUP_MARKER.write_text("1\n")

    def any_downloading(self) -> bool:
        with self.lock:
            return any(v.get("state") in ("preparing", "downloading", "verifying", "removing") for v in self.downloads.values())

    def status(self, name: str) -> dict:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        self.refresh()
        total = SPEECH_TOTAL if name == "speech" else OCR_TOTAL
        path = _speech_dir() if name == "speech" else _ocr_dir()
        with self.lock:
            info = dict(self.downloads.get(name) or {})
        state = info.get("state", "missing")
        base = {"bytes": 0, "total": total,
                "path": str(OCR_LOCAL if name == "ocr" else _speech_root()),
                "can_cancel": state in ("preparing", "downloading"),
                "progress_is_approximate": True}
        if path and state not in ("preparing", "downloading", "verifying", "removing"):
            return {**base, "state": "ready", "bytes": _dir_size(path), "path": str(path), "can_cancel": False}
        if state == "downloading":
            if name == "ocr":
                bytes_ = _dir_size(OCR_LOCAL)
            else:
                bytes_ = _incomplete_size()
            return {**base, "state": state, "bytes": bytes_, "phase": "Downloading and installing"}
        return {**base, "state": state if state != "ready" else "missing", "error": info.get("error", "")}

    def status_all(self) -> dict:
        return {
            "first_run": self.needs_setup(),
            "speech": self.status("speech"),
            "ocr": self.status("ocr"),
        }

    def start(self, name: str) -> None:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        with self.lock:
            if self.status(name)["state"] in ("ready", "preparing", "downloading", "verifying", "removing"):
                return
            root = OCR_LOCAL if name == "ocr" else _speech_root()
            while not root.exists():
                root = root.parent
            total = SPEECH_TOTAL if name == "speech" else OCR_TOTAL
            if shutil.disk_usage(root).free < total * 3:
                raise ValueError("Not enough free storage. Allow approximately three times the download size for installation.")
            self.downloads[name] = {"state": "preparing", "error": "", "bytes": 0}
        target = self._download_speech if name == "speech" else self._download_ocr
        threading.Thread(target=target, daemon=True).start()

    def _set(self, name: str, state: str, error: str = "") -> None:
        with self.lock:
            if (self.downloads.get(name) or {}).get("state") == "canceled":
                return
            self.downloads[name] = {"state": state, "error": error}
        self.refresh()

    def _download_speech(self) -> None:
        self._download("speech", fermion_cmd() + ["transcribe", ASR_MODEL, "--download-only"])

    def _download_ocr(self) -> None:
        self._download("ocr", [sys.executable, "-c",
            "from huggingface_hub import snapshot_download; import sys; snapshot_download(sys.argv[1], local_dir=sys.argv[2])",
            OCR_MODEL, str(OCR_LOCAL)])

    def _download(self, name: str, command: list[str]) -> None:
        try:
            DATA.mkdir(parents=True, exist_ok=True)
            log_path = DATA / f"setup-{name}.log"
            with open(log_path, "ab") as log:
                with self.lock:
                    if self.downloads[name]["state"] == "canceled":
                        return
                    proc = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True,
                                            env={**os.environ, "HF_HUB_DISABLE_XET": "1"})
                    self.procs[name] = proc
                    self.downloads[name]["state"] = "downloading"
                rc = proc.wait()
            with self.lock:
                if self.downloads[name]["state"] == "canceled":
                    return
                self.downloads[name]["state"] = "verifying"
            if rc != 0:
                raise RuntimeError(tail(log_path) or "Download was interrupted. Retry the download.")
            if (_speech_dir() if name == "speech" else _ocr_dir()) is None:
                raise RuntimeError("Installation is incomplete. Retry the download to finish it.")
            self._set(name, "ready")
        except Exception as e:
            self._set(name, "error", str(e))
        finally:
            with self.lock:
                self.procs.pop(name, None)

    def cancel(self, name: str) -> None:
        if name not in ("speech", "ocr"):
            raise ValueError("unknown model")
        with self.lock:
            state = (self.downloads.get(name) or {}).get("state")
            if state not in ("preparing", "downloading"):
                raise ConflictError("This model has no cancellable download")
            proc = self.procs.get(name)
            if proc is not None and proc.poll() is not None:
                raise ConflictError("The download has finished; installation is being verified")
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
            self.downloads[name] = {"state": "canceled", "error": "Download canceled. Partial files were kept for retry."}

    @staticmethod
    def _remove_hf_repo(repo_id: str) -> None:
        """Delete the Hub revisions (and unshared blobs) for one repo."""
        try:
            from huggingface_hub import scan_cache_dir
            info = scan_cache_dir()
            repo = next((r for r in info.repos if r.repo_id == repo_id), None)
            if repo:
                info.delete_revisions(*[rev.commit_hash for rev in repo.revisions]).execute()
        except Exception:
            pass

    def remove(self, name: str) -> None:
        """Delete one model's cache. Only known model paths are touched."""
        with self.lock:
            if self.any_downloading():
                raise ConflictError("Wait for model installation to finish before removing a model")
        if name == "speech":
            path = _speech_dir()
            if path and _speech_root().resolve() in path.resolve().parents:
                shutil.rmtree(path)
            self._remove_hf_repo("FermionResearch/Phonon-2.5-English")
        elif name == "ocr":
            if OCR_LOCAL.exists():
                shutil.rmtree(OCR_LOCAL)
            self._remove_hf_repo(OCR_MODEL)
        else:
            raise ValueError("unknown model")
        with self.lock:
            self.downloads.pop(name, None)
        self.refresh()

    def shutdown(self) -> None:
        with self.lock:
            procs = list(self.procs.values())
        for proc in procs:
            if proc.poll() is None:
                try:
                    proc.terminate()
                except Exception:
                    pass


# --------------------------------------------------------------------------- #
# document library
# --------------------------------------------------------------------------- #

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
            tmp.write_text(json.dumps(payload, indent=1))
            tmp.replace(self.index)

    def _migrate_legacy(self) -> None:
        if self.index.exists() or self.docs:
            return
        legacy_pdf = self.data / "current.pdf"
        legacy_image = self.data / "current.jpg"
        legacy_cache = self.data / "cache.json"
        legacy_pages = self.data / "pages"
        source = legacy_pdf if legacy_pdf.exists() else legacy_image if legacy_image.exists() else None
        if not source:
            return
        doc = self.create(source.name, source.suffix)
        target = self.path(doc["id"])
        shutil.copy2(source, target / doc["source"])
        if legacy_cache.exists():
            shutil.copy2(legacy_cache, target / "cache.json")
            doc["status"] = "ready"
        if legacy_pages.exists():
            shutil.copytree(legacy_pages, target / "pages", dirs_exist_ok=True)
        self._save()

    def create(self, file_name: str, suffix: str) -> dict:
        title = Path(file_name).stem.replace("_", " ").replace("-", " ").strip() or "Untitled document"
        doc = {
            "id": uuid.uuid4().hex,
            "title": title[:100],
            "file_name": Path(file_name).name or "Document",
            "source": "source.pdf" if suffix.lower() == ".pdf" else "source.jpg",
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
        if name not in ("source.pdf", "source.jpg"):
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


# --------------------------------------------------------------------------- #
# app
# --------------------------------------------------------------------------- #

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
        attach_word_boxes(model, self.workspace)
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
            if doc_id == self.doc_id:
                self._start_asr_early()

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
            if self.status in ("listening", "loading"):
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
            self.asr.start()
        except Exception as e:
            self._on_status("error", str(e))

    def stop(self, doc_id: str | None = None) -> None:
        with self.lock:
            self.require_snapshot(doc_id)
            self._persist_position(force=True)
            self._want_listen = False
            self.asr.stop()
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
            attach_word_boxes(model, self.workspace)
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
        with self.lock:
            self._persist_position(force=True)
        self.models.shutdown()
        self.asr.shutdown()

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


# --------------------------------------------------------------------------- #
# export
# --------------------------------------------------------------------------- #

def export_image(app: App, mode: str, page: int = -1) -> bytes:
    from PIL import ImageDraw

    st = app.state()
    model = app.model
    if not model or not model.get("pages"):
        raise ValueError("no page loaded")
    if page < 0 or page >= len(model["pages"]):
        page = st.get("page", 0)
    src = Image.open(app.workspace / "pages" / model["pages"][page]["image"]).convert("RGBA")
    W, H = src.size
    layer = Image.new("RGBA", src.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    amber = (245, 185, 66, 255)
    blue = (90, 169, 255, 255)
    lw = max(3, int(W * 0.0035))

    def draw_box(b, color, fill, width):
        x, y, w, h = b
        pad = W * 0.006
        d.rounded_rectangle(
            [x * W - pad, y * H - pad, (x + w) * W + pad, (y + h) * H + pad],
            radius=int(W * 0.012), outline=color, width=width, fill=fill,
        )

    if mode == "proof" or page != st.get("page", 0):
        for word in model["words"]:
            if word.get("page") == page and word.get("box"):
                draw_box(word["box"], (245, 185, 66, 150), None, max(2, lw // 2))
    else:
        for b in st["current_boxes"]:
            draw_box(b, amber, (245, 185, 66, 40), lw)
        for b in st["next_boxes"]:
            draw_box(b, blue, (90, 169, 255, 30), lw)

    out = Image.alpha_composite(src, layer).convert("RGB")
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=92)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# web
# --------------------------------------------------------------------------- #

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
                sample = next((p for p in (ROOT / "ocr.pdf", ROOT / "ocr-pdf.pdf")
                               if p.exists()), None)
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


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main() -> None:
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
        model, pages = process_source(source, fast=args.fast, auto=args.auto)
        for i, page in enumerate(pages):
            print(f"\n--- page {i + 1} ({len(page['lines'])} lines) ---")
            for line in page["lines"]:
                n = len(line["text"].split())
                print(f"[{n:2d} words] {'box' if line['box'] else '---'}  {line['text']}")
        print(f"\n{len(pages)} page(s), {len(model['words'])} words")
        return

    documents = DocumentStore()
    if args.image and library_exists:
        doc = documents.create(src.name, src.suffix)
        target = documents.source(doc["id"])
        if src.suffix.lower() == ".pdf":
            shutil.copy2(src, target)
        else:
            with Image.open(src) as image:
                image.convert("RGB").save(target, "JPEG", quality=95)
        documents.open(doc["id"])
    APP = App(documents.active_source(), documents)
    APP.with_asr = not args.no_asr
    threading.Thread(target=_startup, args=(APP, not args.no_asr), daemon=True).start()

    server = None
    port = args.port
    for p in range(args.port, args.port + 10):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", p), Handler)
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


def _sigterm(signum, frame):
    raise KeyboardInterrupt


def _startup(app: App, with_asr: bool) -> None:
    try:
        # Setup is nonblocking: Read to me and text PDFs work without models.
        if not app.load():
            app.ocr_now()
    finally:
        if with_asr and app.source_path and app.models.ready("speech"):
            _ensure_asr(app)


def _ensure_asr(app: App) -> None:
    try:
        app.asr.ensure()
        with app.lock:
            if app.status == "loading" and not app.asr.running:
                app.status = "idle"
    except Exception as e:
        app._on_status("error", str(e))


if __name__ == "__main__":
    main()
