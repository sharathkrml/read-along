"""Read Along — plain text and Markdown ingestion.

Text sources have no page rasters, so they are laid out into an internal PDF
(Letter pages, one column) and then read through the same extractor as a
text-layer PDF: exact word boxes, page images, and the existing viewer.
Markdown is reduced to readable text; headings keep a larger size so the text
model's title detection still applies.
"""

from __future__ import annotations

import re
from pathlib import Path

import pymupdf

TEXT_SUFFIXES = {".txt", ".md", ".markdown"}
MAX_CHARS = 1_000_000

PAGE_W, PAGE_H = 612, 792
LEFT = 72
TOP = 72
BOTTOM = 96  # keeps the last baseline above the page-number filter in pdf.py
WIDTH = PAGE_W - 2 * LEFT
# (font size, leading) per block kind.
STYLES = {"body": (11, 16), "h1": (20, 26), "h2": (16, 22), "h3": (13, 19)}

_FONT_FILES = (
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
)

_INLINE_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_INLINE_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_INLINE_CODE = re.compile(r"`([^`]*)`")
_INLINE_BOLD = re.compile(r"(\*\*|__)(.+?)\1")
_INLINE_ITALIC = re.compile(r"(\*|_)(.+?)\1")
_HTML_TAG = re.compile(r"<[^>]+>")
_ESCAPE = re.compile(r"\\([\\`*_{}\[\]()#+\-.!>])")
_HEADING = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
_BULLET = re.compile(r"^[-*+]\s+(.*)$")
_ORDERED = re.compile(r"^(\d+)[.)]\s+(.*)$")
_RULE = re.compile(r"([-*_])(\s*\1){2,}")


def decode_text(data: bytes) -> str:
    """Decode a text file; reject binary data and empty documents."""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16")
    else:
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            try:
                text = data.decode("cp1252")
            except UnicodeDecodeError:
                text = data.decode("latin-1")
    if "\x00" in text:
        raise ValueError("That looks like a binary file, not text")
    if len(text) > MAX_CHARS:
        raise ValueError("Text documents are limited to 1 million characters")
    if not any(c.isalnum() for c in text):
        raise ValueError("The text file is empty")
    return text


def _inline(text: str) -> str:
    text = _INLINE_IMAGE.sub(r"\1", text)
    text = _INLINE_LINK.sub(r"\1", text)
    text = _INLINE_CODE.sub(r"\1", text)
    text = _INLINE_BOLD.sub(r"\2", text)
    text = _INLINE_ITALIC.sub(r"\2", text)
    text = _HTML_TAG.sub("", text)
    return _ESCAPE.sub(r"\1", text).strip()


def plain_lines(text: str, markdown: bool) -> list[tuple[str, str]]:
    """Text -> (line, style) pairs. Markdown syntax is removed, content kept."""
    if not markdown:
        return [(line.strip(), "body") for line in text.splitlines()]

    out: list[tuple[str, str]] = []
    fenced = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith(("```", "~~~")):
            fenced = not fenced
            if out and out[-1][0]:
                out.append(("", "body"))
            continue
        if fenced:
            out.append((raw.rstrip(), "body"))
            continue
        if not stripped:
            out.append(("", "body"))
            continue

        heading = _HEADING.match(stripped)
        if heading:
            label = re.sub(r"\s+#+$", "", heading.group(2))
            out.append((_inline(label), f"h{min(len(heading.group(1)), 3)}"))
            continue

        # Setext headings: a text line underlined by === or ---.
        if out and out[-1][0] and re.fullmatch(r"=+", stripped):
            out[-1] = (out[-1][0], "h1")
            continue
        if out and out[-1][0] and re.fullmatch(r"-{3,}", stripped):
            out[-1] = (out[-1][0], "h2")
            continue
        if _RULE.fullmatch(stripped):
            out.append(("", "body"))
            continue

        line = re.sub(r"^>\s?", "", stripped)
        bullet = _BULLET.match(line)
        ordered = _ORDERED.match(line)
        if bullet:
            out.append(("• " + _inline(bullet.group(1)), "body"))
        elif ordered:
            out.append((ordered.group(1) + ". " + _inline(ordered.group(2)), "body"))
        else:
            # Table rows read as one line; separator rows are dropped.
            if re.fullmatch(r"\|?[\s:|-]+\|?", line) and "-" in line:
                continue
            if "|" in line:
                line = " ".join(cell.strip() for cell in line.strip("|").split("|") if cell.strip())
            cleaned = _inline(line)
            if cleaned:
                out.append((cleaned, "body"))
    return out


def _load_font() -> tuple[pymupdf.Font, str | None]:
    for path in _FONT_FILES:
        try:
            if Path(path).exists():
                return pymupdf.Font(fontfile=path), path
        except Exception:
            pass
    return pymupdf.Font("helv"), None


def _chunks(word: str, size: float, font: pymupdf.Font) -> list[str]:
    """Split a word too wide for the column so it cannot overflow the page."""
    out: list[str] = []
    chunk = ""
    for char in word:
        if chunk and font.text_length(chunk + char, size) > WIDTH:
            out.append(chunk)
            chunk = char
        else:
            chunk += char
    if chunk:
        out.append(chunk)
    return out


def _blocks(lines: list[tuple[str, str]], font: pymupdf.Font) -> list[tuple]:
    blocks: list[tuple] = []
    for text, style in lines:
        if not text:
            if blocks and blocks[-1][0] != "gap":
                blocks.append(("gap",))
            continue
        size, leading = STYLES[style]
        space = font.text_length(" ", size)
        row: list[str] = []
        used = 0.0
        for word in text.split():
            parts = _chunks(word, size, font) if font.text_length(word, size) > WIDTH else [word]
            for part in parts:
                width = font.text_length(part, size)
                if row and used + space + width > WIDTH:
                    blocks.append(("words", row, size, leading))
                    row, used = [], 0.0
                row.append(part)
                used += (space if len(row) > 1 else 0) + width
        if row:
            blocks.append(("words", row, size, leading))
        if style != "body":
            blocks.append(("gap",))
    return blocks


def build_pdf(text: str, markdown: bool, out: Path) -> None:
    font, fontfile = _load_font()
    name = "RA" if fontfile else "helv"
    doc = pymupdf.open()
    page = None
    y = 0.0
    for block in _blocks(plain_lines(text, markdown), font):
        if block[0] == "gap":
            if page is not None:
                y += STYLES["body"][1]
            continue
        _, words, size, leading = block
        if page is None or y > PAGE_H - BOTTOM:
            page = doc.new_page(width=PAGE_W, height=PAGE_H)
            if fontfile:
                page.insert_font(fontname=name, fontfile=fontfile)
            y = TOP + size
        space = font.text_length(" ", size)
        x = LEFT
        for word in words:
            page.insert_text((x, y), word, fontsize=size, fontname=name)
            x += font.text_length(word, size) + space
        y += leading
    if page is None:
        doc.new_page(width=PAGE_W, height=PAGE_H)
    # Embedding Arial Unicode whole costs ~15 MB per document; keep only the
    # glyphs this text actually uses.
    doc.subset_fonts()
    tmp = out.with_name(out.name + ".tmp")
    doc.save(str(tmp), garbage=3, deflate=True)
    doc.close()
    tmp.replace(out)


def text_to_pdf(source: Path) -> Path:
    """Lay the text source beside it as a PDF and return that path."""
    # Managed library sources are named source.<ext>, so their generated PDF
    # backs GET /source. A CLI file gets its own name: two text files in one
    # folder must not share (and reuse) a single PDF.
    name = "source.pdf" if source.stem == "source" else source.name + ".pdf"
    out = source.parent / name
    if out.exists() and out.stat().st_mtime >= source.stat().st_mtime:
        return out
    text = decode_text(source.read_bytes())
    build_pdf(text, source.suffix.lower() in (".md", ".markdown"), out)
    return out
