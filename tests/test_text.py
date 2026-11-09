#!/usr/bin/env python3
"""Assert-based checks for plain text and Markdown ingestion."""

import base64
import tempfile
from pathlib import Path

from readalong import App, DocumentStore, process_source


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


with tempfile.TemporaryDirectory(prefix="readalong-text-") as tmp:
    root = Path(tmp)
    source = root / "notes.txt"
    source.write_text(
        "First line of plain text.\n\n"
        "Second paragraph — with “quotes” and café.\n",
        encoding="utf-8",
    )
    model, pages = process_source(source)
    check("text has one page", len(pages), 1)
    check("text page is ready", pages[0]["reading_status"], "ready")
    check("text page rendered", (root / "pages" / pages[0]["image"]).exists(), True)
    check("text viewer pdf", (root / "notes.txt.pdf").read_bytes()[:5], b"%PDF-")
    check("text every word boxed", all(w.get("box") for w in model["words"]), True)
    check("text lines exact", all(line["exact"] for line in model["lines"]), True)
    text = " ".join(line["text"] for line in model["lines"])
    check("text unicode preserved", "— with “quotes” and café." in text, True)
    check("text words intact", [w["text"] for w in model["words"]][:4],
          ["First", "line", "of", "plain"])

    markdown = root / "notes.md"
    markdown.write_text(
        "# Chapter One\n\n"
        "**Bold** and *italic* with [a link](https://example.com).\n\n"
        "- first bullet\n- second bullet\n\n"
        "```\ncode line\n```\n\n"
        "## Section Two\n\n" + "word " * 1200,
        encoding="utf-8",
    )
    model, pages = process_source(markdown)
    lines = [line["text"] for line in model["lines"]]
    joined = " ".join(lines)
    check("markdown strips heading markers", "#" not in joined, True)
    check("markdown strips emphasis", "**" not in joined and "*" not in joined, True)
    check("markdown link text kept", "a link" in joined, True)
    check("markdown bullets", sum(line.startswith("• ") for line in lines), 2)
    check("markdown code kept", "code line" in joined, True)
    check("markdown headings detected", any(line["kind"] == "title" for line in model["lines"]), True)
    check("markdown wraps to pages", len(pages) > 1, True)
    check("text pdfs do not collide", (root / "notes.md.pdf").exists(), True)

with tempfile.TemporaryDirectory(prefix="readalong-text-import-") as tmp:
    store = DocumentStore(Path(tmp))
    app = App(None, store)
    raw = "# My Notes\n\nHello world. This is a test of the reading pipeline.\n"
    doc = app.import_document(
        "data:text/markdown;base64," + base64.b64encode(raw.encode()).decode(),
        "My Notes.md",
    )
    check("import title", doc["title"], "My Notes")
    check("import source name", store.source(doc["id"]).name, "source.md")
    check("import ready", doc["status"], "ready")
    check("import model", len(app.model["words"]) > 0, True)
    check("import viewer pdf", (store.path(doc["id"]) / "source.pdf").exists(), True)
    check("import saved position", store.get(doc["id"])["position"], 0)

    reopened = App(store.active_source(), store)
    check("text reloads from cache", reopened.load(), True)
    check("text cache keeps words", reopened.model["words"][0]["text"], "My")

    try:
        app.import_document("data:text/plain;base64,IA==", "empty.txt")
        raise AssertionError("empty text should be rejected")
    except ValueError:
        print("ok  empty text rejected")

    try:
        app.import_document("data:text/plain;base64,AAEC", "binary.txt")
        raise AssertionError("binary text should be rejected")
    except ValueError:
        print("ok  binary text rejected")

with tempfile.TemporaryDirectory(prefix="readalong-migration-text-") as tmp:
    root = Path(tmp)
    legacy = root / "current.md"
    legacy.write_text("# Legacy\n\nSome words to read.\n", encoding="utf-8")
    process_source(legacy)
    store = DocumentStore(root)
    doc = store.get(store.active_id())
    check("legacy text migrated", store.source(doc["id"]).name, "source.md")
    check("legacy text viewer pdf", (store.path(doc["id"]) / "source.pdf").exists(), True)
    check("legacy text cache copied", (store.path(doc["id"]) / "cache.json").exists(), True)

print("\nall text checks passed")
