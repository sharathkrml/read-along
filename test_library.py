#!/usr/bin/env python3
"""Assert-based checks for isolated document workspaces and saved positions."""

import json
import tempfile
from pathlib import Path

from PIL import Image

from readalong import App, DocumentStore, load_cache, save_cache


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


def make_document(store, name, text):
    doc = store.create(name, ".pdf")
    source = store.source(doc["id"])
    source.write_bytes(b"%PDF-test")
    pages = store.path(doc["id"]) / "pages"
    pages.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (100, 100), "white").save(pages / "p000.png")
    save_cache(source, [{
        "image": "p000.png", "width": 100, "height": 100,
        "lines": [{"text": text, "box": None, "word_boxes": [None] * len(text.split())}],
    }])
    store.update(doc["id"], status="ready")
    return doc


with tempfile.TemporaryDirectory(prefix="readalong-library-") as tmp:
    root = Path(tmp)
    store = DocumentStore(root)
    first = make_document(store, "First talk.pdf", "one two three four")
    second = make_document(store, "Second notes.pdf", "five six seven eight")

    check("isolated sources", first["id"] != second["id"] and store.source(first["id"]) != store.source(second["id"]), True)
    app = App(store.active_source(), store)
    check("load second", app.load(), True)
    app.jump(3)
    check("position saved", store.get(second["id"])["position"], 3)

    app.open_document(first["id"])
    check("first text", app.model["words"][0]["text"], "one")
    app.jump(1)
    app.open_document(second["id"])
    check("position restored", app.aligner.pos, 3)
    check("second text intact", app.model["words"][0]["text"], "five")

    store.rename(first["id"], "  A   better title  ")
    check("rename normalized", store.get(first["id"])["title"], "A better title")
    try:
        store.rename(first["id"], "   ")
        raise AssertionError("empty rename should fail")
    except ValueError:
        print("ok  empty rename rejected")

    active = app.delete_document(second["id"])
    check("delete selects remaining", active, first["id"])
    check("deleted workspace removed", store.path(second["id"]).exists(), False)
    check("remaining workspace intact", store.source(first["id"]).exists(), True)
    app.delete_document(first["id"])
    check("empty library", app.library()["documents"], [])
    check("empty active document", app.source_path, None)

with tempfile.TemporaryDirectory(prefix="readalong-migration-") as tmp:
    root = Path(tmp)
    (root / "current.pdf").write_bytes(b"%PDF-legacy")
    store = DocumentStore(root)
    check("legacy document migrated", len(store.docs), 1)
    check("legacy source copied", store.active_source().read_bytes(), b"%PDF-legacy")
    check("legacy source preserved", (root / "current.pdf").exists(), True)

with tempfile.TemporaryDirectory(prefix="readalong-cache-") as tmp:
    root = Path(tmp)
    source = root / "source.pdf"
    source.write_bytes(b"%PDF-cache")
    (root / "pages").mkdir()
    Image.new("RGB", (100, 100), "white").save(root / "pages" / "p000.png")
    pages = [{"image": "p000.png", "width": 100, "height": 100,
              "lines": [{"text": "one two", "box": [0.1, 0.1, 0.2, 0.02],
                         "word_boxes": [[0.1, 0.1, 0.08, 0.02], [0.2, 0.1, 0.08, 0.02]]}]}]
    save_cache(source, pages)
    cache = root / "cache.json"
    old = json.loads(cache.read_text())
    old["version"] = 2
    cache.write_text(json.dumps(old))
    check("clean v2 cache upgrades", load_cache(source) is not None, True)
    check("upgraded cache version", json.loads(cache.read_text())["version"], 4)

    # A v3 cache predates the line-splitting fix; it reprocesses once.
    old = json.loads(cache.read_text())
    old["version"] = 3
    cache.write_text(json.dumps(old))
    check("stale v3 cache reprocesses", load_cache(source), None)

    old = json.loads(cache.read_text())
    old["version"] = 2
    old["pages"][0]["lines"][0]["box"] = None
    cache.write_text(json.dumps(old))
    check("unboxed v2 cache reprocesses", load_cache(source), None)

print("\nall library checks passed")
