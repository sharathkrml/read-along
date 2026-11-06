# ReadAlong

OCR a handwritten page or a PDF, then highlight the words **on the source page**
while you read it aloud. Amber box = the phrase you are on. Blue box = the next
phrase. The highlight follows your voice, and the page turns itself when you
cross a page boundary.

## macOS app

Download `ReadAlong-<version>.dmg`, open it, and drag **ReadAlong** onto
Applications. Apple Silicon, macOS 14 or newer.

The app carries its own Python runtime and packages, so users do not need
Python, Homebrew, or a terminal. Documents, the OCR cache and the speech log
live in `~/Library/Application Support/ReadAlong`; the backend log is at
`~/Library/Logs/ReadAlong/backend.log`.

The first launch downloads Phonon-2.5 English (~158 MB) for speech. OCR of an
image or a scanned PDF downloads LFM3-VL 4-bit (~1.6 GB) on first use; a PDF with
a text layer needs neither. macOS asks for microphone access on first launch.

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
python readalong.py
```

It opens <http://127.0.0.1:8765/>. The builder is at `/builder`.

```bash
python readalong.py --image page.jpg     # an image
python readalong.py --image report.pdf   # a PDF
python readalong.py --ocr-only           # process and print, then exit
python readalong.py --no-asr             # UI only, no speech server
```

## Use

- **Builder** — drop an image or PDF, press *Run OCR*, correct any misread words
  in the text box, press *Save text*. For a PDF, use `‹` / `›` to move between
  pages; the text box edits one page at a time. *Export JPEG* writes the current
  page with the amber/blue boxes.
- **Reader** — press *Start listening* (or Space) and read. Click any word to
  jump. `[` and `]` move one phrase back or forward. If you restart a line just
  above the cursor, or skip ahead and start a nearby line, the highlight snaps
  to it; the text pane and page follow automatically.
- Already-read words dim; the next four words are underlined.

## How it works

1. **PDFs with a text layer** are read directly with PyMuPDF: the words and
   their exact boxes come from the file, so there is no OCR step and no wait.
   **Scanned PDFs and images** go through LFM3-VL, macOS Vision line boxes, and
   an ink-gap word segmenter. A PDF of image-only pages is rendered once and
   OCR'd page by page with a single model load; the builder and reader show
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
  in the builder and the boxes are re-cut. PDF text boxes are exact.
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
