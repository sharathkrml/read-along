# Read Along

OCR a handwritten page or a PDF, then highlight the words **on the source page**
while you read it aloud. Amber box = the phrase you are on. Blue box = the next
phrase. The highlight follows your voice, and the page turns itself when you
cross a page boundary.

## macOS app

Download `ReadAlong-<version>.dmg`, open it, and drag **Read Along** onto
Applications. Apple Silicon, macOS 14 or newer.

The app carries its own Python runtime and packages, so users do not need
Python, Homebrew, or a terminal. Documents, the OCR cache and the speech log
live in `~/Library/Application Support/ReadAlong`; the backend log is at
`~/Library/Logs/ReadAlong/backend.log`.

On first launch, Setup asks before downloading anything. The speech model
(Phonon-2.5 English, ~158 MB) is required for voice following. The page-reading
model (LFM3-VL 4-bit, ~1.6 GB) is needed for photos, scanned PDFs, and the
bundled sample; a PDF with a text layer needs neither. Both run locally and are cached after the first
download. macOS asks for microphone access on first launch. Models can be
managed later from **Settings → Models on this Mac**.

The build is ad-hoc signed, not notarized. If Gatekeeper refuses the first
launch, right-click the app and choose **Open**, or remove the download flag:

```bash
xattr -dr com.apple.quarantine /Applications/ReadAlong.app
```

### Build the app

Requirements: Apple Silicon Mac, Xcode command line tools, and
[uv](https://docs.astral.sh/uv/).

```bash
make dmg             # dist/ReadAlong-1.0.0.dmg
make run             # build and open build/ReadAlong.app
make dev             # run the Python app from .venv
make test            # run test_align.py
make clean           # remove build/ and dist/
make help            # all targets
```

`make dmg VERSION=1.1.0` builds a differently versioned DMG. To sign and
notarize for distribution, pass a Developer ID identity and a `notarytool`
keychain profile:

```bash
make dmg \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  NOTARY_PROFILE=readalong
```

`scripts/requirements.lock.txt` pins the packages baked into the app. Refresh it
after changing `requirements.txt`:

```bash
make lock
```

The scripts remain usable directly: `./scripts/build_app.sh` and
`./scripts/build_dmg.sh`.

## Development setup (macOS, Apple Silicon)

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The first run downloads Phonon-2.5 English (~158 MB) for speech. OCR of an
image or a scanned PDF downloads LFM3-VL 4-bit (~1.6 GB) on first use; a PDF
with a text layer needs neither. macOS will ask for microphone access the first
time you press Start.

## Run from source

```bash
make app && open build/ReadAlong.app
```

The native app wants the bundled Python runtime, so build the shell first.
Backend-only run for iterating on the UI (point the app at it with
`READALONG_URL=http://127.0.0.1:8765` when launching the Swift binary):

```bash
python readalong.py --image page.jpg     # an image
python readalong.py --image report.pdf   # a PDF
python readalong.py --ocr-only           # process and print, then exit
python readalong.py --no-asr             # backend only, no speech server
```

## Use

- **Library** — import a PDF or image from the sidebar, or drop it anywhere in
  the window. Documents keep their own source, reading cache, and saved
  position. Use the row menu to rename or delete one.
- **Views** — *Text* reflows the recovered words, *Original* shows the real
  source page with current/next boxes, and *Split* keeps both in sync.
  Click any word to jump. Page arrows move to the next or previous source page.
- **Read to me** — choose an installed macOS voice and speed, then press Play.
  The highlight follows the actual spoken word. Pause and resume without losing
  your place.
- **Follow me** — press Play and read aloud; the existing microphone tracking
  follows your voice. Both modes share one cursor and saved position.
- **Present** — a full-screen reading stage. `Esc` returns to the exact phrase.
- **Edit text** — correct OCR line by line and export a proof JPEG when needed.
- **Presentation-ready text** — multi-column slides are read down each column,
  not across gutters. Headings, bullets, wrapped paragraphs, tags, and
  label/value rows become distinct readable blocks while the original source
  boxes and voice alignment remain intact.
- **Auto OCR** — printed dark slides use macOS Vision; handwriting still uses
  the page-reading model. Older jumbled OCR caches are upgraded once, and pages
  that needed the old handwriting mapping are reprocessed automatically.

Keyboard: `Space` toggles play/listen in reader or source canvas (never while typing), `[` / `]` move one
phrase, arrow keys browse source pages only when the source canvas owns input, `Cmd+F` finds text,
`Cmd+1/2/3` switch panes, `Shift+Cmd+F` enters Focus, `Cmd+Plus/Minus/Equals` zooms the focused pane,
and `Cmd+O` imports a document.

## How it works

1. **PDFs with a text layer** are read directly with PyMuPDF: the words and
   their exact boxes come from the file, so there is no OCR step and no wait.
   **Scanned PDFs and images** go through LFM3-VL, macOS Vision line boxes, and
   an ink-gap word segmenter. A PDF of image-only pages is rendered once and
   OCR'd page by page with a single model load; the import card and reader show
   which page is being read.
2. `fermion serve phonon-2.5-en` streams partial transcripts over a local
   WebSocket.
3. A monotonic fuzzy alignment moves the cursor through the script. It only
   advances on exact word matches, so ASR errors and OCR mistakes do not throw
   it off, and a final phrase can re-anchor after a skipped line.

## Reference

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full pipeline, data model,
alignment math, HTTP API, measured performance, failure modes, and a detailed
guide to porting this POC to a native Mac app.

## Limits

- Word boxes on handwriting are heuristic. If a line is misread, fix the text
  with **Edit text** and the boxes are re-cut. PDF text boxes are exact.
- A scanned PDF is OCR'd page by page. A long PDF can take a few minutes the
  first time; the result is cached, so later opens are instant.
- macOS Vision supplies the line geometry for images. If its accurate model
  fails on the Neural Engine, the app falls back to the fast model and some
  boxes may be missing; a reboot restores the accurate one. PDFs are unaffected.
- The blue box marks the next words on the page, not a diagram elsewhere.
  When the next phrase is on the following page, the page turns and the next
  phrase becomes current.
- Export is one page at a time.
- macOS / Apple Silicon only (MLX). Phonon-2.5 English is English-only.
- LFM3-VL is under the LFM Open License v1.0; Phonon-2.5 English weights are
  CC-BY-4.0.
