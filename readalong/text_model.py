"""Read Along — text model.

Turns OCR lines into the shared display + alignment model: one model with page
numbers on every line and word, plus readable presentation blocks (headings,
bullets, wrapped paragraphs, label/value rows) while the original source boxes
and tokens stay untouched for highlighting and speech alignment.
"""

from __future__ import annotations

import difflib
import re
import unicodedata

import numpy as np

from .vision import reading_order

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
