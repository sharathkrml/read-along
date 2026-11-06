#!/usr/bin/env python3
"""
ReadAlong — OCR a handwritten page, then highlight the words on the source image
while you read it aloud.

    python readalong.py             # opens the reader
    python readalong.py --ocr-only  # OCR the current image and print the lines
"""

from __future__ import annotations

import argparse
import asyncio
import atexit
import base64
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
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
PAGES = DATA / "pages"
IMAGE = DATA / "current.jpg"
PDF = DATA / "current.pdf"
CACHE = DATA / "cache.json"

OCR_MODEL = "LiquidAI/LFM3-VL-2B-MLX-4bit"
ASR_MODEL = "phonon-2.5-en"
ASR_PORT = 8010
WEB_PORT = 8765

OCR_PROMPT = (
    "Transcribe every line of handwritten text in this image exactly as written, "
    "in reading order, one line of output per line of handwriting. Preserve the "
    "original spelling, punctuation, arrows, capitalization and line breaks. "
    "Faint text showing through from the back of the page is not part of this page: ignore it. "
    "Do not guess: write [illegible] for a word you cannot read. "
    "Output only the transcription, with no commentary and no markdown."
)


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
        })
        for line in page.get("lines", []):
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
    return model


def build_model(lines: list[dict]) -> dict:
    """Single-page convenience wrapper (used by the aligner tests)."""
    return build_pages_model([{"image": "", "width": 0, "height": 0, "lines": lines}])


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


class Aligner:
    """Aligns live ASR words to the script, snapping to nearby lines when the
    reader restarts or skips, and advancing monotonically otherwise."""

    def __init__(self, words: list[str]):
        self.words = words
        self.pos = 0
        self.conf = 0.0

    @staticmethod
    def _score(a: str, b: str) -> float:
        if a == b:
            return 1.0
        if difflib.SequenceMatcher(None, a, b).ratio() >= 0.62:
            return 0.3
        return -0.4

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
        for start in range(lo, hi):
            j = start
            exact = 0
            matched = 0
            first_ok = False
            for idx, a in enumerate(asr):
                found = -1
                for k in range(j, min(len(self.words), j + 4)):
                    if self.words[k] == a:
                        found = k
                        break
                if found >= 0:
                    exact += 1
                    matched += 1
                    j = found + 1
                    if idx == 0:
                        first_ok = True
                elif j < len(self.words) and self._score(a, self.words[j]) > 0:
                    matched += 1
                    j += 1
                    if idx == 0:
                        first_ok = True
            if not first_ok or exact < min_exact:
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

def vision_lines(path: Path) -> list[dict]:
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


def usable_lines(vlines: list[dict]) -> list[dict]:
    out = []
    for v in vlines:
        x, y, w, h = v["box"]
        if y < 0.08 or h < 0.008 or h > 0.09 or w < 0.12:
            continue
        if v.get("conf", 1.0) < 0.3:
            continue
        if len(re.findall(r"[A-Za-z0-9]", v["text"])) < 2:
            continue
        out.append(v)
    out.sort(key=lambda v: -v["box"][1])
    return out


def map_lines(ocr_lines: list[str], vlines: list[dict]) -> list[dict]:
    """Attach a Vision line box to each OCR line, keeping reading order.

    A monotonic sequence alignment is used instead of a greedy best-match:
    one bad OCR line (a diagram label, say) can no longer steal a box and
    shift every line after it.
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

    out = []
    for i, text in enumerate(ocr_lines):
        box = None
        if i in pairs:
            b = vlines[pairs[i]]["box"]
            box = [b[0], 1.0 - b[1] - b[3], b[2], b[3]]
        out.append({"text": text, "box": box})
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


def ocr_lfm3(path: Path) -> list[str]:
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    model, processor = load(OCR_MODEL)
    try:
        config = load_config(OCR_MODEL)
        formatted = apply_chat_template(processor, config, OCR_PROMPT, num_images=1)
        out = generate(
            model, processor, formatted, [str(path)],
            max_tokens=2048, temperature=0.1, top_p=1.0, top_k=50,
            min_p=0.0, repetition_penalty=1.1, enable_thinking=False,
        )
        text = out.text if hasattr(out, "text") else str(out)
    finally:
        del model, processor
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:
            pass
    lines = clean_ocr(text)
    if len(lines) < 3:
        raise RuntimeError("the OCR model returned too little text")
    return lines


def run_ocr(path: Path) -> tuple[list[dict], int, int]:
    W, H = Image.open(path).size
    vlines: list[dict] = []
    try:
        vlines = vision_lines(path)
    except Exception:
        pass
    try:
        texts = ocr_lfm3(path)
    except Exception as e:
        if not vlines:
            raise
        texts = [v["text"] for v in usable_lines(vlines)]
        print(f"[ocr] LFM3 failed ({e}); using macOS Vision text", file=sys.stderr)
    return map_lines(texts, vlines), W, H


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
    ink = (crop < 140).astype(np.uint8)
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


def clear_pages() -> None:
    shutil.rmtree(PAGES, ignore_errors=True)
    PAGES.mkdir(parents=True, exist_ok=True)


def attach_word_boxes(model: dict) -> None:
    """Fill word boxes for every line that did not get exact boxes from a PDF."""
    for pi, page in enumerate(model["pages"]):
        path = PAGES / page["image"]
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
    lines.sort(key=lambda l: (l["box"][1], l["box"][0]))
    return lines


def pdf_pages(path: Path) -> list[dict]:
    import pymupdf

    clear_pages()
    doc = pymupdf.open(path)
    pages = []
    try:
        for i, page in enumerate(doc):
            pix = page.get_pixmap(dpi=150)
            img = PAGES / f"p{i:03d}.png"
            pix.save(img)
            W, H = Image.open(img).size
            words = page.get_text("words")
            if len(words) >= 10:
                lines = pdf_lines(words, page.rect.width, page.rect.height)
            else:
                # scanned page: fall back to the OCR pipeline
                lines, _, _ = run_ocr(img)
            pages.append({"image": img.name, "width": W, "height": H, "lines": lines})
    finally:
        doc.close()
    return pages


def image_pages(path: Path) -> list[dict]:
    clear_pages()
    out = PAGES / "p000.jpg"
    Image.open(path).convert("RGB").save(out, "JPEG", quality=95)
    lines, W, H = run_ocr(path)
    return [{"image": out.name, "width": W, "height": H, "lines": lines}]


def process_source(path: Path) -> tuple[dict, list[dict]]:
    if path.suffix.lower() == ".pdf":
        pages = pdf_pages(path)
    else:
        pages = image_pages(path)
    model = build_pages_model(pages)
    attach_word_boxes(model)
    save_cache(path, pages)
    return model, pages


def save_cache(path: Path, pages: list[dict]) -> None:
    st = os.stat(path)
    CACHE.parent.mkdir(exist_ok=True)
    CACHE.write_text(json.dumps({
        "version": 2, "mtime": st.st_mtime, "size": st.st_size, "pages": pages,
    }, indent=1))


def load_cache(path: Path) -> dict | None:
    try:
        d = json.loads(CACHE.read_text())
        st = os.stat(path)
        if abs(d.get("mtime", -1) - st.st_mtime) < 0.001 and d.get("size") == st.st_size:
            if d.get("version") == 2 and d.get("pages"):
                if all((PAGES / p["image"]).exists() for p in d["pages"]):
                    return d
            elif d.get("lines") and path.suffix.lower() != ".pdf":
                # migrate the original single-image cache
                clear_pages()
                shutil.copy(path, PAGES / "p000.jpg")
                d = {
                    "version": 2, "mtime": st.st_mtime, "size": st.st_size,
                    "pages": [{
                        "image": "p000.jpg", "width": d["width"],
                        "height": d["height"], "lines": d["lines"],
                    }],
                }
                CACHE.write_text(json.dumps(d, indent=1))
                return d
    except Exception:
        pass
    return None


# --------------------------------------------------------------------------- #
# speech
# --------------------------------------------------------------------------- #

class ASR:
    def __init__(self, on_text, on_status):
        self.on_text = on_text
        self.on_status = on_status
        self.proc: subprocess.Popen | None = None
        self.port: int | None = None
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
            bin_ = shutil.which("fermion") or str(Path(sys.executable).with_name("fermion"))
            if not Path(bin_).exists():
                raise RuntimeError("fermion not found — pip install 'fermion-research[mlx]'")
            DATA.mkdir(exist_ok=True)
            log = open(DATA / "asr.log", "ab")
            self.port = self._free_port(ASR_PORT)
            self.proc = subprocess.Popen(
                [bin_, "serve", ASR_MODEL, "--port", str(self.port)],
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


# --------------------------------------------------------------------------- #
# app
# --------------------------------------------------------------------------- #

class App:
    def __init__(self, source_path: Path):
        self.source_path = source_path
        self.lock = threading.RLock()
        self.model: dict | None = None
        self.pages: list[dict] | None = None
        self.aligner: Aligner | None = None
        self.status = "idle"
        self.error = ""
        self.partial = ""
        self.ocr_status = "idle"
        self.ocr_error = ""
        self._want_listen = False
        self.asr = ASR(self._on_text, self._on_status)

    def _on_text(self, text: str, final: bool) -> None:
        with self.lock:
            self.partial = text
            if self.aligner:
                self.aligner.update(text, final)

    def _on_status(self, status: str, msg: str = "") -> None:
        with self.lock:
            self.status = status
            if status == "error":
                self.error = msg
            elif status in ("loading", "listening"):
                self.error = ""

    def load(self) -> bool:
        d = load_cache(self.source_path)
        if not d:
            return False
        self.pages = d["pages"]
        model = build_pages_model(self.pages)
        attach_word_boxes(model)
        self.model = model
        self.aligner = Aligner([w["norm"] for w in model["words"]])
        self.ocr_status = "done"
        return True

    def ocr_now(self) -> None:
        with self.lock:
            if self.ocr_status == "running":
                return
            self.ocr_status = "running"
            self.ocr_error = ""
            path = self.source_path
        try:
            model, pages = process_source(path)
            with self.lock:
                self.model = model
                self.pages = pages
                self.aligner = Aligner([w["norm"] for w in model["words"]])
                self.ocr_status = "done"
        except Exception as e:
            with self.lock:
                self.ocr_status = "error"
                self.ocr_error = str(e)

    def state(self) -> dict:
        with self.lock:
            s = {
                "status": self.status, "error": self.error, "partial": self.partial,
                "rms": self.asr.rms, "ocr_status": self.ocr_status,
                "ocr_error": self.ocr_error, "model_ready": bool(self.model),
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

    def start(self) -> None:
        with self.lock:
            if self.status in ("listening", "loading"):
                return
            if not self.model:
                raise ValueError("the page is still being read — wait a moment")
            self.status = "loading"
            self.error = ""
            self._want_listen = True
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

    def stop(self) -> None:
        self._want_listen = False
        self.asr.stop()
        self._on_status("idle")

    def jump(self, word: int) -> None:
        with self.lock:
            if not self.aligner or not self.model:
                return
            self.aligner.pos = max(0, min(word, len(self.model["words"])))
            self.aligner.conf = 1.0
            self.partial = ""

    def set_script(self, page: int, text: str) -> dict:
        self.stop()
        with self.lock:
            if not self.pages:
                raise ValueError("no page loaded")
            page = max(0, min(page, len(self.pages) - 1))
            boxes = [line.get("box") for line in self.pages[page]["lines"]]
            lines = []
            for i, line in enumerate(text.splitlines()):
                if not line.strip():
                    continue
                lines.append({"text": line.strip(), "box": boxes[i] if i < len(boxes) else None})
            self.pages[page]["lines"] = lines
            model = build_pages_model(self.pages)
            attach_word_boxes(model)
            self.model = model
            self.aligner = Aligner([w["norm"] for w in model["words"]])
            self.partial = ""
            save_cache(self.source_path, self.pages)
            return model

    def upload(self, data_url: str, name: str = "") -> None:
        self.stop()
        raw = data_url.split(",", 1)[-1]
        data = base64.b64decode(raw)
        is_pdf = name.lower().endswith(".pdf") or data[:5] == b"%PDF-" or "application/pdf" in data_url[:40]
        DATA.mkdir(exist_ok=True)
        if is_pdf:
            source = PDF
            source.write_bytes(data)
            try:
                IMAGE.unlink()
            except FileNotFoundError:
                pass
        else:
            source = IMAGE
            Image.open(io.BytesIO(data)).convert("RGB").save(source, "JPEG", quality=95)
            try:
                PDF.unlink()
            except FileNotFoundError:
                pass
        try:
            CACHE.unlink()
        except FileNotFoundError:
            pass
        clear_pages()
        with self.lock:
            self.source_path = source
            self.model = None
            self.pages = None
            self.aligner = None
            self.ocr_status = "idle"
            self.ocr_error = ""
            self.status = "idle"
            self.partial = ""

    def shutdown(self) -> None:
        self.asr.shutdown()


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
    src = Image.open(PAGES / model["pages"][page]["image"]).convert("RGBA")
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

    def _html(self, text: str):
        self._send(200, text.encode(), "text/html; charset=utf-8")

    def do_GET(self):
        p = urlparse(self.path).path
        try:
            if p == "/":
                self._html(READER_HTML)
            elif p == "/builder":
                self._html(BUILDER_HTML)
            elif p == "/image":
                self._serve_page(0)
            elif p.startswith("/page/"):
                try:
                    self._serve_page(int(p.rsplit("/", 1)[1]))
                except ValueError:
                    self._send(404, b"bad page", "text/plain")
            elif p == "/model":
                model = APP.model or {"pages": [], "lines": [], "words": [], "groups": []}
                self._json(model)
            elif p == "/state":
                self._json(APP.state())
            elif p == "/export":
                q = parse_qs(urlparse(self.path).query)
                mode = q.get("mode", ["read"])[0]
                try:
                    page = int(q.get("page", ["-1"])[0])
                except ValueError:
                    page = -1
                data = export_image(APP, mode, page)
                self._send(200, data, "image/jpeg", {
                    "Content-Disposition": 'attachment; filename="readalong-highlighted.jpg"',
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
        f = PAGES / model["pages"][i]["image"]
        if not f.exists():
            self._send(404, b"no page", "text/plain")
            return
        ctype = "image/png" if f.suffix.lower() == ".png" else "image/jpeg"
        self._send(200, f.read_bytes(), ctype)

    def do_POST(self):
        p = urlparse(self.path).path
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            if p == "/upload":
                APP.upload(body["data"], body.get("name", ""))
                self._json({"ok": True})
            elif p == "/ocr":
                APP.ocr_now()
                if APP.ocr_status == "error":
                    self._json({"error": APP.ocr_error}, 500)
                else:
                    self._json({"ok": True, "model": APP.model})
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
                APP.jump(int(body.get("word", 0)))
                self._json({"ok": True})
            elif p == "/simulate":
                APP._on_text(str(body.get("text", "")), bool(body.get("final", True)))
                self._json(APP.state())
            else:
                self._send(404, b"not found", "text/plain")
        except Exception as e:
            self._json({"error": str(e)}, 400)


# --------------------------------------------------------------------------- #
# ui
# --------------------------------------------------------------------------- #

BASE_CSS = r"""
:root{--bg:#0f1115;--panel:#171a21;--line:#252a34;--ink:#e8e6e3;--dim:#8b93a1;
--amber:#f5b942;--blue:#5aa9ff;--red:#e53935;--ok:#4ecb8d}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif}
a{color:var(--blue);text-decoration:none}
button{font:inherit;color:var(--ink);background:#232936;border:1px solid #303849;
border-radius:10px;padding:8px 15px;cursor:pointer}
button:hover{background:#2b3342}
button.primary{background:var(--amber);color:#17140c;border-color:var(--amber);font-weight:650}
button:disabled{opacity:.45;cursor:default}
header{display:flex;gap:12px;align-items:center;height:57px;padding:0 18px;
border-bottom:1px solid var(--line);background:var(--panel)}
header .spacer{flex:1}
.chip{font-size:12px;color:var(--dim);border:1px solid var(--line);border-radius:999px;
padding:3px 10px;white-space:nowrap}
.chip.ok{color:var(--ok);border-color:#245a42}
.chip.bad{color:var(--red);border-color:#5a2424}
.meter{width:70px;height:6px;background:#232936;border-radius:99px;overflow:hidden}
.meter i{display:block;height:100%;width:0;background:var(--amber);transition:width .1s}
.partial{font-size:12px;color:var(--dim);max-width:46vw;overflow:hidden;
text-overflow:ellipsis;white-space:nowrap}
.partial.err{color:var(--red)}
"""

READER_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ReadAlong</title><style>""" + BASE_CSS + r"""
#stage{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(330px,.55fr);
height:calc(100vh - 57px)}
#imgbox{position:relative;justify-self:center;align-self:center;width:fit-content;
max-width:100%;max-height:100%;margin:14px}
#page{display:block;max-width:100%;max-height:calc(100vh - 85px);width:auto;height:auto;
border-radius:6px;box-shadow:0 18px 60px #0009}
#overlay{position:absolute;inset:0;width:100%;height:100%;pointer-events:none;overflow:visible}
#textpane{overflow-y:auto;border-left:1px solid var(--line);padding:26px 30px 46vh}
#text{font:26px/1.65 ui-serif,"New York",Georgia,serif}
.line{margin:0 0 8px}
.pbreak{font:600 11px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
color:var(--dim);letter-spacing:.1em;text-transform:uppercase;
margin:24px 0 6px;border-top:1px solid var(--line);padding-top:10px}
#text span{cursor:pointer;padding:1px 1px;border-radius:4px;transition:background .12s,opacity .12s}
#text span:hover{background:#ffffff10}
.read{opacity:.34}
.cur{background:rgba(245,185,66,.17)!important;box-shadow:0 0 0 2px rgba(245,185,66,.08)}
.nxt{background:rgba(90,169,255,.10)!important}
.look{text-decoration:underline;text-decoration-color:var(--blue);
text-underline-offset:6px;text-decoration-thickness:2px}
.curbox{fill:rgba(245,185,66,.15);stroke:#f5b942;stroke-width:3;vector-effect:non-scaling-stroke}
.nxtbox{fill:rgba(90,169,255,.09);stroke:#5aa9ff;stroke-width:3;vector-effect:non-scaling-stroke}
.proofbox{fill:none;stroke:rgba(245,185,66,.45);stroke-width:1.5;vector-effect:non-scaling-stroke}
@media(max-width:900px){#stage{grid-template-columns:1fr;height:auto}
#textpane{border-left:0;border-top:1px solid var(--line);height:52vh;padding-bottom:40vh}
#page{max-height:48vh}}
</style></head><body>
<header>
  <button id="toggle" class="primary">Start listening</button>
  <span id="status" class="chip">idle</span>
  <span class="meter"><i id="meter"></i></span>
  <span id="conf" class="chip">—</span>
  <span id="partial" class="partial"></span>
  <span class="spacer"></span>
  <a href="/builder">Builder</a>
</header>
<div id="stage">
  <div id="imgbox">
    <img id="page" src="/image" alt="page">
    <svg id="overlay" xmlns="http://www.w3.org/2000/svg">
      <g id="nextg"></g><g id="curg"></g>
    </svg>
  </div>
  <div id="textpane"><div id="text"></div></div>
</div>
<script>
const NS='http://www.w3.org/2000/svg';
const $=id=>document.getElementById(id);
let model=null, st=null, lastGroup=-1, polling=false, page=0;

async function boot(){
  try{
    const m=await (await fetch('/model')).json();
    if(m && m.lines && m.lines.length){ model=m; render(); }
    else setTimeout(boot,800);
  }catch(e){ setTimeout(boot,1200); }
  if(!polling){ polling=true; poll(); }
}

function pg(){ return (model && model.pages && model.pages[page]) || {width:0,height:0}; }

function render(){
  const svg=$('overlay');
  const p0=(model.pages&&model.pages[0])||{width:0,height:0};
  if(p0.width) svg.setAttribute('viewBox','0 0 '+p0.width+' '+p0.height);
  const t=$('text'); t.innerHTML='';
  let lastPage=-1;
  model.lines.forEach(line=>{
    if(model.pages.length>1 && line.page!==lastPage){
      lastPage=line.page;
      const h=document.createElement('div'); h.className='pbreak';
      h.textContent='Page '+(line.page+1);
      t.appendChild(h);
    }
    const d=document.createElement('div'); d.className='line';
    line.tokens.forEach(tok=>{
      const s=document.createElement('span');
      s.textContent=tok.text+' ';
      s.dataset.w=tok.w;
      if(tok.w>=0) s.addEventListener('click',()=>jump(tok.w));
      d.appendChild(s);
    });
    t.appendChild(d);
  });
  page=0;
  $('page').src='/page/0?t='+Date.now();
}

function px(b){
  const p=pg();
  return [b[0]*p.width,b[1]*p.height,b[2]*p.width,b[3]*p.height];
}

function draw(boxes,gid,cls){
  const g=$(gid); g.innerHTML='';
  (boxes||[]).forEach(b=>{
    const p=0.004;
    const q=px([b[0]-p,b[1]-p,b[2]+2*p,b[3]+2*p]);
    const r=document.createElementNS(NS,'rect');
    r.setAttribute('x',q[0]); r.setAttribute('y',q[1]);
    r.setAttribute('width',q[2]); r.setAttribute('height',q[3]);
    r.setAttribute('rx',pg().width*0.008);
    r.setAttribute('class',cls);
    g.appendChild(r);
  });
}

function paint(){
  const s=st; if(!s) return;
  $('status').textContent=s.status;
  $('status').className='chip '+(s.status==='listening'?'ok':s.status==='error'?'bad':'');
  $('status').title=s.error||'';
  $('conf').textContent=s.confidence?Math.round(s.confidence*100)+'%':'—';
  $('partial').textContent=s.error||s.partial||'';
  $('partial').className='partial'+(s.error?' err':'');
  $('meter').style.width=Math.min(100,(s.rms||0)*500)+'%';
  $('toggle').textContent=s.status==='listening'?'Stop':(s.status==='loading'?'Loading…':'Start listening');
  $('toggle').disabled=s.status==='loading';
  if(!model) return;
  if(s.page!=null && s.page!==page){
    page=s.page;
    const p=pg();
    $('overlay').setAttribute('viewBox','0 0 '+p.width+' '+p.height);
    $('page').src='/page/'+page+'?t='+Date.now();
  }
  const cur=s.current, nxt=s.next;
  document.querySelectorAll('#text span').forEach(el=>{
    const w=+el.dataset.w; if(w<0) return;
    el.classList.toggle('read',w<s.pos);
    el.classList.toggle('look',w>=s.pos&&w<s.pos+4);
    el.classList.toggle('cur',!!cur&&w>=cur[0]&&w<cur[1]);
    el.classList.toggle('nxt',!!nxt&&w>=nxt[0]&&w<nxt[1]);
  });
  draw(s.current_boxes,'curg','curbox');
  draw(s.next_boxes,'nextg','nxtbox');
  if(cur && cur[0]!==lastGroup){
    lastGroup=cur[0];
    const el=document.querySelector('#text .cur');
    if(el) el.scrollIntoView({block:'center',behavior:'smooth'});
  }
}

async function poll(){
  try{ st=await (await fetch('/state')).json(); paint(); }catch(e){}
  setTimeout(poll,120);
}

async function jump(w){
  await fetch('/jump',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({word:w})});
}

$('toggle').onclick=async()=>{
  const s=st||{};
  if(s.status==='listening') await fetch('/stop',{method:'POST'});
  else await fetch('/start',{method:'POST'});
};

addEventListener('keydown',e=>{
  if(e.code==='Space'&&e.target.tagName!=='TEXTAREA'){ e.preventDefault(); $('toggle').click(); }
  if((e.key==='['||e.key===']')&&model&&model.groups&&st&&st.current){
    const gi=model.groups.findIndex(g=>g.start===st.current[0]);
    const ni=Math.max(0,Math.min(model.groups.length-1,gi+(e.key===']'?1:-1)));
    jump(model.groups[ni].start);
  }
});

boot();
</script></body></html>
"""

BUILDER_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ReadAlong — Builder</title><style>""" + BASE_CSS + r"""
#stage{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(340px,.85fr);
height:calc(100vh - 57px)}
#left{position:relative;display:flex;align-items:center;justify-content:center;
padding:14px;min-width:0;overflow:hidden}
#imgbox{position:relative;width:fit-content;max-width:100%;max-height:100%}
#page{display:block;max-width:100%;max-height:calc(100vh - 85px);width:auto;height:auto;
border-radius:6px;box-shadow:0 18px 60px #0009}
#overlay{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
.proofbox{fill:none;stroke:rgba(245,185,66,.5);stroke-width:1.5;vector-effect:non-scaling-stroke}
#side{border-left:1px solid var(--line);padding:18px;display:flex;flex-direction:column;
gap:12px;min-height:0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
#script{flex:1;min-height:220px;resize:none;background:#12151b;color:var(--ink);
border:1px solid var(--line);border-radius:10px;padding:12px 14px;
font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}
#msg{font-size:12px;color:var(--dim);min-height:18px;white-space:pre-wrap}
#drop{border:1px dashed #303849;border-radius:12px;padding:14px;text-align:center;
color:var(--dim);font-size:13px}
#drop.over{border-color:var(--amber);color:var(--amber)}
input[type=file]{display:none}
@media(max-width:900px){#stage{grid-template-columns:1fr;height:auto}
#left{max-height:48vh}#side{border-left:0;border-top:1px solid var(--line)}}
</style></head><body>
<header>
  <strong>ReadAlong</strong><span class="chip">builder</span>
  <span class="spacer"></span>
  <a href="/">Open reader →</a>
</header>
<div id="stage">
  <div id="left">
    <div id="imgbox">
      <img id="page" src="/image" alt="page">
      <svg id="overlay" xmlns="http://www.w3.org/2000/svg"><g id="proof"></g></svg>
    </div>
  </div>
  <div id="side">
    <div id="drop">Drop an image or PDF here, or <u>choose a file</u><br>
      <span style="font-size:11px">JPEG / PNG / PDF</span></div>
    <input type="file" id="file" accept="image/*,.pdf,application/pdf">
    <div class="row" id="pagenav" style="display:none">
      <button id="prev">‹</button>
      <span id="pnum" class="chip">Page 1 / 1</span>
      <button id="next">›</button>
    </div>
    <div class="row">
      <button id="ocr">Run OCR</button>
      <button id="export">Export JPEG</button>
      <button id="save">Save text</button>
    </div>
    <div id="msg"></div>
    <textarea id="script" spellcheck="false" placeholder="The OCR text appears here, one line per line of handwriting. Correct it, then Save."></textarea>
    <div class="row"><a href="/"><button class="primary">Start reading</button></a></div>
  </div>
</div>
<script>
const NS='http://www.w3.org/2000/svg';
const $=id=>document.getElementById(id);
let model=null, page=0;

async function load(){
  try{
    const m=await (await fetch('/model')).json();
    if(m && m.lines && m.lines.length){ model=m; render(); }
    else setTimeout(load,800);
  }catch(e){ setTimeout(load,1200); }
  tick();
}

function pg(){ return (model && model.pages && model.pages[page]) || {width:0,height:0}; }

function render(){
  if(!model || !model.pages || !model.pages.length) return;
  page=Math.max(0,Math.min(page,model.pages.length-1));
  const p=pg();
  const svg=$('overlay');
  if(p.width) svg.setAttribute('viewBox','0 0 '+p.width+' '+p.height);
  const g=$('proof'); g.innerHTML='';
  model.words.forEach(w=>{
    if(w.page!==page || !w.box) return;
    const b=w.box, pad=0.003;
    const q=[(b[0]-pad)*p.width,(b[1]-pad)*p.height,
             (b[2]+2*pad)*p.width,(b[3]+2*pad)*p.height];
    const r=document.createElementNS(NS,'rect');
    r.setAttribute('x',q[0]); r.setAttribute('y',q[1]);
    r.setAttribute('width',q[2]); r.setAttribute('height',q[3]);
    r.setAttribute('rx',p.width*0.006);
    r.setAttribute('class','proofbox');
    g.appendChild(r);
  });
  $('script').value=model.lines.filter(l=>l.page===page).map(l=>l.text).join('\n');
  $('page').src='/page/'+page+'?t='+Date.now();
  $('pagenav').style.display=model.pages.length>1?'flex':'none';
  $('pnum').textContent='Page '+(page+1)+' / '+model.pages.length;
}

async function post(url,body){
  const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify(body||{})});
  return r.json();
}

async function runOCR(){
  $('msg').textContent='Reading the file… a scanned page can take a while; a text PDF is instant.';
  const j=await post('/ocr');
  if(j.error){ $('msg').textContent=j.error; return; }
  model=j.model; page=0; render(); $('msg').textContent='';
}

async function upload(file){
  const data=await new Promise((res,rej)=>{
    const fr=new FileReader(); fr.onload=()=>res(fr.result); fr.onerror=rej; fr.readAsDataURL(file);
  });
  $('msg').textContent='Uploading…';
  const j=await post('/upload',{name:file.name,data});
  if(j.error){ $('msg').textContent=j.error; return; }
  await runOCR();
}

async function tick(){
  try{
    const s=await (await fetch('/state')).json();
    if(s.ocr_status==='running') $('msg').textContent='Reading the page…';
    else if(s.ocr_status==='error') $('msg').textContent=s.ocr_error;
    else if(s.error) $('msg').textContent=s.error;
    else if(s.model_ready && (!model || !model.lines.length)){
      const m=await (await fetch('/model')).json();
      if(m.lines && m.lines.length){ model=m; render(); $('msg').textContent=''; }
    }
  }catch(e){}
  setTimeout(tick,700);
}

$('file').onchange=e=>{ if(e.target.files[0]) upload(e.target.files[0]); };
$('drop').onclick=()=>$('file').click();
$('drop').ondragover=e=>{ e.preventDefault(); $('drop').classList.add('over'); };
$('drop').ondragleave=()=>$('drop').classList.remove('over');
$('drop').ondrop=e=>{
  e.preventDefault(); $('drop').classList.remove('over');
  if(e.dataTransfer.files[0]) upload(e.dataTransfer.files[0]);
};
$('ocr').onclick=runOCR;
$('export').onclick=()=>{ location.href='/export?mode=proof&page='+page; };
$('prev').onclick=()=>{ if(page>0){ page--; render(); } };
$('next').onclick=()=>{ if(model && page<model.pages.length-1){ page++; render(); } };
$('save').onclick=async()=>{
  const j=await post('/script',{page:page,text:$('script').value});
  if(j.error){ $('msg').textContent=j.error; return; }
  model=j.model; render(); $('msg').textContent='Saved.';
  setTimeout(()=>{ if($('msg').textContent==='Saved.') $('msg').textContent=''; },1500);
};

load();
</script></body></html>
"""


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser(description="OCR a page or PDF and read along with it.")
    ap.add_argument("--image", help="image or PDF to open (copied into data/)")
    ap.add_argument("--port", type=int, default=WEB_PORT)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--no-asr", action="store_true", help="don't start the speech server")
    ap.add_argument("--ocr-only", action="store_true", help="run OCR, print, and exit")
    args = ap.parse_args()

    global APP
    DATA.mkdir(exist_ok=True)

    if args.image:
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
    elif PDF.exists():
        source = PDF
    elif IMAGE.exists():
        source = IMAGE
    elif (ROOT / "ocr.jpg").exists():
        shutil.copy(ROOT / "ocr.jpg", IMAGE)
        source = IMAGE
    elif (ROOT / "ocr.pdf").exists():
        shutil.copy(ROOT / "ocr.pdf", PDF)
        source = PDF
    else:
        sys.exit("no image or PDF: pass --image")

    if args.ocr_only:
        model, pages = process_source(source)
        for i, page in enumerate(pages):
            print(f"\n--- page {i + 1} ({len(page['lines'])} lines) ---")
            for line in page["lines"]:
                n = len(line["text"].split())
                print(f"[{n:2d} words] {'box' if line['box'] else '---'}  {line['text']}")
        print(f"\n{len(pages)} page(s), {len(model['words'])} words")
        return

    APP = App(source)
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
    print(f"ReadAlong → {url}")
    print(f"Builder   → {url}builder")
    if not args.no_browser:
        webbrowser.open(url)
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
        if not app.load():
            app.ocr_now()
    finally:
        if with_asr:
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
