#!/usr/bin/env python3
"""Generate and verify small, reproducible PDF/model fixtures for Read Along checks.

Test-only helper: fixtures are written into a caller-provided temporary
workspace. Nothing here touches the live library, ~/.cache, model weights,
the network, or the microphone.

Usage:
  make_fixtures.py generate <dir>   write fixtures + summary.json into <dir>
  make_fixtures.py verify <dir>     assert semantic properties of the fixtures
"""

import json
import sys
from pathlib import Path

import pymupdf

PAGE_W, PAGE_H = 612, 792  # letter-ish points


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def _lines(page, lines):
    """Insert one text line per entry, top-down, and return nothing."""
    y = 72.0
    for line in lines:
        page.insert_text(pymupdf.Point(72, y), line, fontsize=14)
        y += 24


def _save(doc, path):
    doc.set_metadata({})  # keep semantics, drop producer/date noise
    doc.save(str(path), garbage=3, deflate=True)
    doc.close()


# ---------------------------------------------------------------- generators

def gen_rotations(out):
    for deg in (0, 90, 180, 270):
        doc = pymupdf.open()
        page = doc.new_page(width=PAGE_W, height=PAGE_H)
        _lines(page, [f"rotation {deg} degrees", "read along fixture"])
        page.draw_rect(pymupdf.Rect(72, 120, 200, 160), color=(0, 0, 0))
        page.set_rotation(deg)
        _save(doc, out / f"rot{deg}.pdf")


def gen_crop(out):
    doc = pymupdf.open()
    page = doc.new_page(width=400, height=300)
    page.set_mediabox(pymupdf.Rect(50, 60, 450, 360))  # non-origin crop offset
    page.insert_text(pymupdf.Point(80, 120), "crop offset fixture", fontsize=12)
    _save(doc, out / "crop.pdf")


def gen_mixed_dims(out):
    doc = pymupdf.open()
    for w, h in ((612, 792), (300, 300), (792, 612)):
        page = doc.new_page(width=w, height=h)
        page.insert_text(pymupdf.Point(36, 48), f"page {w}x{h}", fontsize=12)
    _save(doc, out / "mixed-dims.pdf")


def gen_blank(out):
    doc = pymupdf.open()
    doc.new_page(width=PAGE_W, height=PAGE_H)
    _save(doc, out / "blank.pdf")


EQUAL_A = [
    ["alpha bravo charlie delta", "echo foxtrot golf hotel", "india juliet kilo lima"],
    ["mike november oscar papa", "quebec romeo sierra tango", "uniform victor whiskey xray"],
]
EQUAL_B = [
    ["apple banana cherry dragon", "eagle falcon grape heron", "iris jasmine kiwi lotus"],
    ["maple nutmeg olive pepper", "quartz ribbon saffron topaz", "umbrella violet walnut xenon"],
]


def gen_equal_counts(out):
    for name, pages in (("equal-a", EQUAL_A), ("equal-b", EQUAL_B)):
        doc = pymupdf.open()
        for lines in pages:
            _lines(doc.new_page(width=PAGE_W, height=PAGE_H), lines)
        _save(doc, out / f"{name}.pdf")


MIXED_EARLIER = {0: "scan one recovered text", 1: "scan two more recovered words here"}


def _word_entries(page):
    """Group a PDF page's extracted words into backend-style lines/words."""
    rows = page.get_text("words")
    rows.sort(key=lambda w: (w[5], w[6], w[7]))  # block, line, word_no
    lines, words = [], []
    for x0, y0, x1, y1, text, block, line_no, _ in rows:
        if not lines or lines[-1]["key"] != (block, line_no):
            lines.append({"key": (block, line_no), "texts": [], "box": None})
        lines[-1]["texts"].append(text)
        words.append({
            "text": text, "norm": text.lower(), "page": 2,
            "line": len(lines) - 1, "box": [round(v, 2) for v in (x0, y0, x1, y1)],
        })
    return [{"page": 2, "text": " ".join(line["texts"]), "box": line["box"],
             "tokens": [{"text": t, "norm": t.lower(), "box": None} for t in line["texts"]]}
            for line in lines], words


def gen_mixed_readiness(out):
    """Text layer only on the last page: earlier pages stand in for pending OCR."""
    doc = pymupdf.open()
    doc.new_page(width=PAGE_W, height=PAGE_H)  # page 0: blank scan (pending)
    doc.new_page(width=PAGE_W, height=PAGE_H)  # page 1: blank scan (pending)
    _lines(doc.new_page(width=PAGE_W, height=PAGE_H),
           ["later page becomes ready first", "while earlier scans wait"])
    path = out / "mixed-readiness.pdf"
    _save(doc, path)

    doc = pymupdf.open(str(path))
    lines, words = _word_entries(doc[2])
    doc.close()

    pages = [{"width": PAGE_W, "height": PAGE_H, "image": "", "reading_status": s}
             for s in ("pending", "pending", "ready")]
    partial = {
        "doc_id": "fixture-mixed-readiness", "model_revision": 1,
        "pages": pages, "lines": lines, "words": words,
        "groups": [{"page": 2, "start": 0, "end": len(words)}],
    }
    (out / "mixed_readiness_model.json").write_text(json.dumps(partial, indent=1))

    # The same document after earlier-page OCR completes: new words shift the
    # global indices of the page-2 text the user may already be reading.
    full_pages = [dict(p, reading_status="ready") for p in pages]
    full_lines, full_words, groups = [], [], []
    for page_no in (0, 1):
        start = len(full_words)
        toks = MIXED_EARLIER[page_no].split()
        full_lines.append({"page": page_no, "text": MIXED_EARLIER[page_no],
                           "box": None, "tokens": [{"text": t, "norm": t, "box": None} for t in toks]})
        full_words += [{"text": t, "norm": t, "page": page_no, "line": page_no, "box": None} for t in toks]
        groups.append({"page": page_no, "start": start, "end": start + len(toks)})
    shift_lines = len(full_lines)
    full_lines += [dict(line) for line in lines]
    start = len(full_words)
    full_words += [dict(w, line=w["line"] + shift_lines) for w in words]
    groups.append({"page": 2, "start": start, "end": start + len(words)})
    completed = {
        "doc_id": "fixture-mixed-readiness", "model_revision": 2,
        "pages": full_pages, "lines": full_lines, "words": full_words, "groups": groups,
    }
    (out / "mixed_readiness_completed_model.json").write_text(json.dumps(completed, indent=1))


GENERATORS = (gen_rotations, gen_crop, gen_mixed_dims, gen_blank, gen_equal_counts, gen_mixed_readiness)


def generate(out):
    out.mkdir(parents=True, exist_ok=True)
    for gen in GENERATORS:
        gen(out)
    (out / "summary.json").write_text(json.dumps(summarize(out), sort_keys=True, indent=1) + "\n")


# ------------------------------------------------------------------ summary

def summarize(out):
    result = {}
    for path in sorted(out.glob("*.pdf")):
        doc = pymupdf.open(str(path))
        pages = []
        for page in doc:
            words = page.get_text("words")
            mb, r = page.mediabox, page.rect
            pages.append({
                "rotation": page.rotation,
                "mediabox": [round(v, 2) for v in (mb.x0, mb.y0, mb.x1, mb.y1)],
                "rect": [round(v, 2) for v in (r.x0, r.y0, r.x1, r.y1)],
                "word_count": len(words),
                "first_words": " ".join(w[4] for w in sorted(words, key=lambda w: (w[5], w[6], w[7]))[:8]),
            })
        result[path.name] = pages
        doc.close()
    return result


# ------------------------------------------------------------------- verify

def verify(out):
    summary = json.loads((out / "summary.json").read_text())

    for deg in (0, 90, 180, 270):
        pages = summary[f"rot{deg}.pdf"]
        check(f"rot{deg} rotation", (len(pages), pages[0]["rotation"]), (1, deg))
        check(f"rot{deg} text", pages[0]["word_count"] > 0, True)

    crop = summary["crop.pdf"][0]
    check("crop mediabox origin", crop["mediabox"][:2], [50.0, 60.0])
    check("crop text present", crop["first_words"].startswith("crop offset"), True)

    dims = [(p["mediabox"][2] - p["mediabox"][0], p["mediabox"][3] - p["mediabox"][1])
            for p in summary["mixed-dims.pdf"]]
    check("mixed page dimensions", dims, [(612.0, 792.0), (300.0, 300.0), (792.0, 612.0)])

    blank = summary["blank.pdf"]
    check("blank page", (len(blank), blank[0]["word_count"]), (1, 0))

    counts = {}
    for name in ("equal-a.pdf", "equal-b.pdf"):
        pages = summary[name]
        counts[name] = (len(pages), sum(p["word_count"] for p in pages))
    check("equal-count variants match", counts["equal-a.pdf"], counts["equal-b.pdf"])
    check("equal-count variants match", counts["equal-a.pdf"], (2, 24))
    check("equal-count variants differ",
          summary["equal-a.pdf"][0]["first_words"] != summary["equal-b.pdf"][0]["first_words"], True)

    mixed = summary["mixed-readiness.pdf"]
    check("mixed readiness pages", len(mixed), 3)
    check("earlier pages unready", (mixed[0]["word_count"], mixed[1]["word_count"]), (0, 0))
    check("later page has text", mixed[2]["word_count"] > 0, True)

    partial = json.loads((out / "mixed_readiness_model.json").read_text())
    completed = json.loads((out / "mixed_readiness_completed_model.json").read_text())
    check("partial statuses", [p["reading_status"] for p in partial["pages"]],
          ["pending", "pending", "ready"])
    check("completed statuses", [p["reading_status"] for p in completed["pages"]], ["ready"] * 3)
    check("revision bumps", completed["model_revision"] > partial["model_revision"], True)
    later = [w["text"] for w in partial["words"] if w["page"] == 2]
    moved = [w["text"] for w in completed["words"] if w["page"] == 2]
    check("later-page words preserved", moved, later)
    check("earlier words inserted", len(completed["words"]) - len(partial["words"]) > 0, True)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("generate", "verify"):
        sys.exit(__doc__)
    if sys.argv[1] == "generate":
        generate(Path(sys.argv[2]))
    else:
        verify(Path(sys.argv[2]))
        print("all fixture checks passed")
