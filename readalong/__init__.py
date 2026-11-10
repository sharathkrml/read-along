"""Read Along — read a handwritten page, PDF, text file, or Markdown, then
highlight the words on the source page while you read it aloud.

The implementation is split into domain modules (see ``MODULE_MAP.md``). This
package's public API is re-exported below so the file layout stays decoupled
from the import surface: ``from readalong import App, Aligner, DocumentStore``
works regardless of which file a symbol lives in.

Run the backend:

    python -m readalong                # or: python readalong.py
    python -m readalong --ocr-only     # OCR and print, then exit
"""

from __future__ import annotations

# --- text model / alignment ----------------------------------------------
from .text_model import (  # noqa: F401
    annotate_blocks,
    build_model,
    build_pages_model,
    group_at,
    group_boxes,
    norm_token,
    norm_text,
    rebase_position,
    tokenize,
)
from .aligner import Aligner  # noqa: F401

# --- vision / mapping / segmentation -------------------------------------
from .vision import reading_order, usable_lines, vision_lines  # noqa: F401
from .mapping import clean_ocr, map_lines  # noqa: F401
from .segment import segment_line  # noqa: F401

# --- OCR / PDF / cache ----------------------------------------------------
from .ocr import ocr_lfm3, ocr_lfm3_many, run_ocr, run_ocr_many  # noqa: F401
from .pdf import image_pages, pdf_pages, pdf_lines, process_source  # noqa: F401
from .cache import attach_word_boxes, clear_pages, load_cache, save_cache  # noqa: F401
from .text import TEXT_SUFFIXES, decode_text, text_to_pdf  # noqa: F401

# --- speech / models / library -------------------------------------------
from .speech import ASR, fermion_cmd, tail  # noqa: F401
from .models import Models  # noqa: F401
from .library import DocumentStore  # noqa: F401

# --- app / export / web ---------------------------------------------------
from .app import App, _ensure_asr, _startup  # noqa: F401
from .export import export_image  # noqa: F401
from .web import APP, Handler  # noqa: F401

__all__ = [
    "App", "ASR", "DocumentStore", "Handler", "Models",
    "_ensure_asr", "_startup",
    "aligner",  # kept for backwards compatibility
    "annotate_blocks", "attach_word_boxes", "build_model", "build_pages_model",
    "clean_ocr", "clear_pages", "export_image", "fermion_cmd",
    "group_at", "group_boxes", "image_pages", "load_cache",
    "map_lines", "norm_token", "norm_text", "ocr_lfm3", "ocr_lfm3_many",
    "pdf_lines", "pdf_pages", "process_source", "reading_order",
    "rebase_position", "save_cache", "segment_line", "tail", "tokenize",
    "TEXT_SUFFIXES", "decode_text", "text_to_pdf",
    "usable_lines", "vision_lines",
]

# Names intentionally not re-exported here (use the submodule directly):
#   readalong.__main__   main, _startup, _ensure_asr
#   readalong._config    ROOT, DATA, OCR_MODEL, ASR_MODEL, ...
