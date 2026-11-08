"""Read Along — handwriting word segmentation.

Splits an ink mask into one pixel box per word. Word spaces are the gaps
clearly wider than the rest, so a gap inside "heart|beats" cannot shift every
box after it (which is what a plain widest-gaps split does).
"""

from __future__ import annotations

import numpy as np


def _ink_mask(gray: np.ndarray) -> np.ndarray:
    """Dark ink on paper, or light ink on a dark slide background."""
    median = float(np.median(gray))
    if median < 128:
        return gray > median + 28
    return gray < min(140, median - 20)


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


def segment_line(gray: np.ndarray, box_px: tuple[int, int, int, int], words: list[str]) -> list[list[int] | None]:
    """Split a line crop into one pixel box per word."""
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
        a, b_ = blobs[p][0], blobs[j][1]
        rest = k - (len(groups) - 1)
        ws = weights[len(groups) - 1:]
        total = sum(ws) or 1.0
        acc = 0.0
        for i, w in enumerate(ws):
            xa = int(a + (b_ - a) * acc / total)
            acc += w
            xb = int(a + (b_ - a) * acc / total)
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
