# Contributing to Read Along

Thanks for wanting to contribute. Read Along is a macOS-only (Apple Silicon)
reader that OCRs pages and highlights words on the source as you read aloud.

## Before you start

Open an issue to discuss the change first, especially for features. Small bug
fixes and documentation improvements are welcome without prior discussion.

## Repository layout

- `readalong/` — Python backend package (OCR, alignment, speech, HTTP server)
- `readalong.py` — thin executable shim -> `readalong.__main__`
- `macapp/` — native SwiftUI + AppKit shell
- `scripts/` — build (`build_app.sh`, `build_dmg.sh`), icon (`make_icon.py`)
- `tests/` — assert-based checks for the aligner and document library
- `ARCHITECTURE.md` — full backend reference (read this before touching the backend)
- `MODULE_MAP.md` (in `readalong/`) — per-module responsibility map

## Development setup

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
make dev   # backend-only: python readalong.py --port 8765
make test  # Python + native checks
```

Build the full app (Apple Silicon, Xcode CLI tools, `uv`):

```bash
make app   # build/ReadAlong.app
make dmg   # dist/ReadAlong-<version>.dmg
```

## Backend changes

The backend is split into single-domain modules (see `readalong/MODULE_MAP.md`).
Modules only import from their dependencies; `readalong/__init__.py` re-exports
the public API so layout stays decoupled from imports.

- Add tests in `tests/` for new aligner, mapping, or segment behavior.
- Run `make test` before opening a PR.
- Keep model download sizes in mind: the app bundles no model weights.

## Swift changes

The Swift shell talks to the Python backend over `http://127.0.0.1:<port>` via
`BackendClient`. The server is the source of truth; prefer adding backend
endpoints over duplicating logic in Swift.

- Build the native checks: `./scripts/test_native.sh`
- Follow macOS Human Interface Guidelines; keep the studio palette in
  `ReaderTheme.swift` rather than ad-hoc colors.

## Pull requests

- Describe the problem, not just the solution.
- Include before/after for UI changes (screenshot or screen recording).
- Run `make test` and make sure the app builds (`make app`).
- One PR per concern.

## Code of conduct

Be respectful. This is a solo POC-turned-reader; keep changes small and
well-documented.
