"""Read Along — shared constants, paths, and error classes.

Owns everything that names the world: where data lives, which models are used,
which ports the servers bind to, and the errors the rest of the backend raises.
No module in this package imports from another one here, so this is the safe
root of the dependency graph.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

# This file lives at <repo>/readalong/_config.py, so its grandparent is the
# directory that contains the readalong package. In a dev checkout that is the
# repository root; inside the .app bundle the whole package is copied into
# backend/readalong/, so this resolves to backend/. Either way DATA ends up in
# the right place (dev: <repo>/data ; bundled: <backend>/data).
ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("READALONG_DATA") or ROOT / "data")
PAGES = DATA / "pages"
IMAGE = DATA / "current.jpg"
PDF = DATA / "current.pdf"
CACHE = DATA / "cache.json"

# Models.
OCR_MODEL = "LiquidAI/LFM3-VL-2B-MLX-4bit"
ASR_MODEL = "phonon-2.5-en"
ASR_PORT = 8010
WEB_PORT = 8765

# Model setup. Weights are not in the .app; these paths are where they land.
SETUP_MARKER = DATA / "onboarded"
OCR_LOCAL = DATA / "models" / "ocr"
SPEECH_TOTAL = 157_616_598          # Phonon-2.5 English download bytes
OCR_TOTAL = 1_650_000_000           # LFM3-VL 4-bit, approximate

OCR_PROMPT = (
    "Transcribe the text in this image exactly as written, in natural visual reading order. "
    "If the page has columns, panels, sidebars, tables, or diagram labels, finish one column or "
    "panel from top to bottom before moving to the next; never read across a vertical gutter or "
    "join text from two columns onto one line. Read a full-width heading or title before the "
    "columns beneath it. Preserve each visual line as its own output line, and keep a label with "
    "its value only when they share a line. Preserve spelling, punctuation, arrows, capitalization, "
    "and meaningful line breaks. Faint text showing through from the back of the page is not part "
    "of this page: ignore it. Do not guess: write [illegible] for a word you cannot read. "
    "Output only the transcription, with no commentary and no markdown."
)


class ConflictError(ValueError):
    pass


class MissingModelError(ValueError):
    pass


class LockedPDFError(ValueError):
    pass


def _valid_ocr_dir(path: Path) -> bool:
    try:
        for name in ("config.json", "tokenizer.json", "tokenizer_config.json", "processor_config.json"):
            if not json.loads((path / name).read_text()):
                return False
        index = path / "model.safetensors.index.json"
        files = set(json.loads(index.read_text())["weight_map"].values()) if index.exists() else {p.name for p in path.glob("*.safetensors")}
        if not files or any(Path(name).name != name for name in files):
            return False
        from safetensors import safe_open
        for name in files:
            with safe_open(str(path / name), framework="np") as tensors:
                if not list(tensors.keys()):
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError, ImportError):
        return False
    except Exception:
        return False  # safetensors rejects truncated/incomplete payloads.


def _ocr_dir() -> Path | None:
    if _valid_ocr_dir(OCR_LOCAL):
        return OCR_LOCAL
    override = os.environ.get("HF_HUB_CACHE")
    if override:
        root = Path(override).expanduser()
    else:
        hf_home = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
        root = Path(hf_home).expanduser() / "hub"
    root = root / "models--LiquidAI--LFM3-VL-2B-MLX-4bit"
    for snap in (root / "snapshots").glob("*"):
        try:
            if _valid_ocr_dir(snap):
                return snap
        except OSError:
            pass
    return None


def _ocr_source() -> str:
    """A local model directory if Setup downloaded one, else the Hub id."""
    path = _ocr_dir()
    if path is None:
        raise MissingModelError("The handwriting model is not installed. Download it in Settings.")
    return str(path)
