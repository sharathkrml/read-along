"""Read Along — OCR-line to Vision-box mapping.

Attaches a Vision line box to each OCR line while keeping reading order, using
a monotonic sequence alignment (one bad OCR line can no longer steal a box and
shift every line after it). Merged OCR lines are split across the stacked
Vision boxes they span so text and boxes cover the same ink.
"""

from __future__ import annotations

import bisect
import difflib
import re

from .text_model import norm_text
from .vision import _vision_box, usable_lines


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


def _word_start_spans(ocr_words: list[str], ref_words: list[str]) -> list[int] | None:
    """Map the start of every ref word to an ocr word index.

    Sequence-align the two normalized strings char by char; replace blocks map
    proportionally. Returns one index per ref word, weakly increasing, or None
    when the two texts are too unlike to align.
    """
    from .text_model import norm_token

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
