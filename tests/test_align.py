#!/usr/bin/env python3
"""Assert-based checks for the read-along aligner and text model."""

from readalong import (
    Aligner, build_model, build_pages_model, group_at, group_boxes, map_lines,
    norm_token, reading_order,
)


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def words(text):
    return [norm_token(w) for w in text.split()]


def run(text, final=True, start=0):
    a = Aligner(words("the cat sat on the mat"))
    a.pos = start
    a.update(text, final)
    return a.pos


# normalisation
check("number word", norm_token("nine"), "9")
check("digit", norm_token("9"), "9")
check("time", norm_token("a.m."), "am")
check("punctuation only", norm_token("→"), "")

# alignment
check("exact", run("the cat sat on the mat"), 6)
check("substitution", run("the bat sat on the mat"), 6)
check("skipped script word", run("the sat on the mat"), 6)
check("repeated word", run("the cat cat sat on the mat"), 6)
check("prefix only", run("the cat", final=False), 2)
check("partial revision grows", run("the cat sat", final=False), 3)
check("noise does not advance", run("zzz qqq", final=False), 0)
check("repeat does not go backwards", run("the cat", start=4) >= 4, True)
check("repeat at end stays", run("the cat", start=6), 6)

# a far jump on a final should re-anchor
script = " ".join(f"w{i}" for i in range(40))
a = Aligner(script.split())
a.update("w25 w26 w27 w28", final=True)
check("far jump", a.pos, 29)

# nearby re-anchor: restart a line above, or skip a line below
def run_script(text, start, final=True):
    a = Aligner(script.split())
    a.pos = start
    a.update(text, final)
    return a.pos

check("normal advance", run_script("w20 w21 w22 w23", 20), 24)
check("restart line above", run_script("w14 w15 w16 w17", 20), 18)
check("skip line below", run_script("w30 w31 w32 w33", 20), 34)
check("restart partial", run_script("w14 w15 w16 w17", 20, final=False), 18)
check("skip partial", run_script("w30 w31 w32 w33", 20, final=False), 34)

# groups
model = build_model([{"text": "Heartbeats: times by default fires every 30 secs", "box": None}])
check("group count", len(model["groups"]), 3)
check("colon group", [model["groups"][0]["start"], model["groups"][0]["end"]], [0, 1])
check("four word group", [model["groups"][1]["start"], model["groups"][1]["end"]], [1, 5])
check("last group", [model["groups"][2]["start"], model["groups"][2]["end"]], [5, 8])
check("group at start", group_at(model, 0), 0)
check("group at boundary", group_at(model, 1), 1)
check("group at end", group_at(model, 8), 2)

# box union
model["words"][0]["box"] = [0.10, 0.10, 0.05, 0.02]
model["words"][1]["box"] = [0.20, 0.10, 0.05, 0.02]
box = group_boxes(model["groups"][1], model)
check("box union count", len(box), 1)
check("box union x", round(box[0][0], 3), 0.2)
check("box union right", round(box[0][0] + box[0][2], 3), 0.25)

# pages
mp = build_pages_model([
    {"image": "a", "width": 100, "height": 100, "lines": [{"text": "one two", "box": None}]},
    {"image": "b", "width": 100, "height": 100, "lines": [{"text": "three four", "box": None}]},
])
check("page count", len(mp["pages"]), 2)
check("line pages", [l["page"] for l in mp["lines"]], [0, 1])
check("word pages", [w["page"] for w in mp["words"]], [0, 0, 1, 1])
check("group pages", [g["page"] for g in mp["groups"]], [0, 1])

# two-column reading order: finish the left column before the right
columns = [
    {"text": "right top", "box": [0.58, 0.20, 0.30, 0.03]},
    {"text": "left top", "box": [0.08, 0.20, 0.30, 0.03]},
    {"text": "right bottom", "box": [0.58, 0.40, 0.30, 0.03]},
    {"text": "left bottom", "box": [0.08, 0.40, 0.30, 0.03]},
]
ordered = reading_order(columns, lambda line: line["box"])
check("column order", [line["text"] for line in ordered],
      ["left top", "left bottom", "right top", "right bottom"])

# a full-width heading must stay above the two columns beneath it
with_heading = columns + [{"text": "full width heading", "box": [0.08, 0.08, 0.84, 0.04]}]
ordered = reading_order(with_heading, lambda line: line["box"])
check("heading above columns", [line["text"] for line in ordered],
      ["full width heading", "left top", "left bottom", "right top", "right bottom"])

# a label and its value on the same row read left-to-right
row = [
    {"text": "Payment status", "box": [0.60, 0.60, 0.10, 0.03]},
    {"text": "Paid / Unpaid", "box": [0.83, 0.605, 0.10, 0.03]},
    {"text": "next row", "box": [0.60, 0.68, 0.10, 0.03]},
]
ordered = reading_order(row, lambda line: line["box"])
check("label before value", [line["text"] for line in ordered],
      ["Payment status", "Paid / Unpaid", "next row"])

# presentation blocks keep words and boxes but expose readable structure
presentation = build_pages_model([{
    "image": "page.png", "width": 1000, "height": 700, "lines": [
        {"text": "MY TALK", "box": [0.08, 0.05, 0.18, 0.02]},
        {"text": "A clear title", "box": [0.08, 0.10, 0.50, 0.08]},
        {"text": "This is a line of", "box": [0.08, 0.30, 0.50, 0.025]},
        {"text": "wrapped body text.", "box": [0.08, 0.33, 0.42, 0.025]},
        {"text": "• first point", "box": [0.08, 0.40, 0.40, 0.025]},
        {"text": "• second point", "box": [0.08, 0.44, 0.40, 0.025]},
        {"text": "Cost label", "box": [0.60, 0.52, 0.10, 0.025]},
        {"text": "Value here", "box": [0.74, 0.525, 0.12, 0.025]},
    ],
}])
by_text = {line["text"]: line for line in presentation["lines"]}
check("title block", by_text["A clear title"]["kind"], "title")
check("body lines share block", by_text["This is a line of"]["block"], by_text["wrapped body text."]["block"])
check("bullet blocks stay separate", by_text["• first point"]["block"] != by_text["• second point"]["block"], True)
check("label/value row", by_text["Cost label"]["block"], by_text["Value here"]["block"])
check("label kind", by_text["MY TALK"]["kind"], "label")

# A merged OCR line (LFM3 wrapped a paragraph into one line) splits across the
# stacked Vision boxes it spans, so text and boxes cover the same ink.
vboxes = [
    {"text": "computer repair requests, customer details,"},
    {"text": "service costs and repair status."},
]
merged = map_lines(
    ["A simple desktop application to manage computer repair requests, customer details, service costs and repair status."],
    [
        {"text": "A simple desktop application to manage",
         "box": [0.05, 0.5556, 0.3333, 0.037], "conf": 0.9},
        {"text": vboxes[0]["text"],
         "box": [0.0538, 0.5103, 0.3488, 0.0387], "conf": 0.9},
        {"text": vboxes[1]["text"],
         "box": [0.0521, 0.4661, 0.2505, 0.0435], "conf": 0.9},
    ],
)
check("merged line split count", len(merged), 3)
check("split line 1", merged[0]["text"], "A simple desktop application to manage")
check("split line 2", merged[1]["text"], "computer repair requests, customer details,")
check("split line 3", merged[2]["text"], "service costs and repair status.")
check("split boxes distinct", merged[0]["box"] != merged[1]["box"] != merged[2]["box"], True)
# A short OCR line never splits; sentiment: chip rows stay whole.
check("short line untouched", map_lines(["FixIt"], [
    {"text": "FixIt", "box": [0.05, 0.6, 0.1, 0.1], "conf": 0.9},
    {"text": "v2.0", "box": [0.05, 0.5, 0.1, 0.03], "conf": 0.9},
])[0]["text"], "FixIt")

print("\nall checks passed")
