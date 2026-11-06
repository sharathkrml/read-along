#!/usr/bin/env python3
"""Assert-based checks for the read-along aligner and text model."""

from readalong import Aligner, build_model, build_pages_model, group_at, group_boxes, norm_token


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

print("\nall checks passed")
