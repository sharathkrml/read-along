# Read Along

**Read a handwritten page or a PDF aloud — and follow along word by word, right
on the source page.**

<sup>macOS 14+ · Apple Silicon · SwiftUI + Python · 100% on-device · MIT</sup>

OCR a page, press **Follow me**, and read aloud. Amber box = the phrase you are
on. Blue box = the next phrase. The highlight moves with your voice, and the
page turns itself when you cross a page boundary. Or press **Read to me** and
let an installed macOS voice read while the same cursor follows the spoken word.

Everything runs on the Mac: OCR, speech, and your library never leave the
machine. No account, no cloud, no telemetry.

## Features

| | |
|---|---|
| **Follow your voice** | A local speech engine (Phonon-2.5) streams the microphone and a monotonic fuzzy aligner moves the cursor word by word. ASR mistakes and skipped lines don't throw it off — it re-anchors to a nearby line. |
| **Read to me** | Choose any installed macOS voice and speed. The highlight follows the actual spoken word; pause and resume without losing your place. |
| **Source-first highlighting** | Amber/blue boxes are drawn on the *real page* (PDF or photo), not on a reflowed copy. Click any word to jump; page arrows turn the page. |
| **Handwriting + print** | Scanned pages and handwriting use an on-device page-reading model (LFM3-VL); printed text and slides use macOS Vision. PDFs with a text layer skip OCR entirely. |
| **Text + Markdown** | Drop in a `.txt` or `.md` file. It is laid out into pages with exact word boxes and reads exactly like a PDF. |
| **A real reading app** | Multi-document library, per-document saved position, Original / Text / Split panes, full-screen Present, Find, OCR correction, and page export. |
| **Local-only** | After the one-time model download, the app needs no network at all. No account, no analytics, no crash reporting. |

## Get it

Download the latest `ReadAlong-<version>.dmg` from
[**Releases**](https://github.com/sharathkrml/read-along/releases), open it, and
drag **Read Along** into Applications.

- Apple Silicon Mac, macOS 14 or newer.
- The app carries its own Python runtime and packages — no Python, Homebrew, or
  terminal required.
- The build is **ad-hoc signed and not notarized**, so Gatekeeper may ask you to
  right-click → **Open** on first launch.
- Models are ~1.7 GB in total and download on first use (speech ~158 MB,
  handwriting ~1.6 GB), then stay cached. The app asks before downloading.
- macOS asks for microphone access when you first press **Follow me**. Python
  never opens the microphone itself, so the permission is attributed to Read
  Along.

### Build from source

Requirements: Apple Silicon Mac, macOS 14+, Xcode command line tools, Python
3.12, and [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/sharathkrml/read-along.git
cd read-along
make setup        # Python 3.12 venv + requirements
make app          # build build/ReadAlong.app
make run          # build and open the app
make dmg          # dist/ReadAlong-1.0.0.dmg
make test         # Python checks + native Swift checks
make clean        # remove build/ and dist/
make help         # all targets
```

Backend-only run for iterating on the UI:

```bash
make dev                      # serves http://127.0.0.1:8765
python readalong.py --image page.jpg
python readalong.py --ocr-only          # OCR, print, exit
python readalong.py --ocr-only --fast   # force macOS Vision
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

## Use

**Library** — import a PDF, plain text, Markdown, JPEG, or PNG from the
sidebar, or drop one file anywhere in the window (up to 25 MB). Each document
keeps its own source, reading cache, and saved position. Use the row menu to
rename or delete one; ⌘-click and shift-click select several at once.

**Views** — *Original* shows the real source page with current/next boxes,
*Text* reflows the recovered words, and *Split* keeps both in sync. Click any
word to jump. Page arrows move to the next or previous source page.

**Read to me** — choose an installed macOS voice and speed, then press Play.
The highlight follows the actual spoken word. Pause and resume without losing
your place.

**Follow me** — press Play and read aloud; the microphone tracking follows your
voice. Both modes share one cursor and saved position.

**Live dock** — the strip below the transport shows the phrase you are reading,
or the live transcript while listening. The microphone menu on its right
switches input devices without leaving the page.

**Present** — a full-screen reading stage. `Esc` returns to the exact phrase.

**Edit text** — correct OCR line by line and export the current page as a JPEG
proof when needed.

### Keyboard

| Shortcut | Action |
|---|---|
| `Space` | Start/stop the current mode (not while typing) |
| `[` / `]`, or `Cmd+[` / `Cmd+]` | Previous / next phrase |
| `←` / `→` | Previous / next source page (when the source pane has focus) |
| `Cmd+O` | Import a document |
| `Cmd+E` | Edit the current page's OCR text |
| `Shift+Cmd+E` | Export the page as JPEG |
| `Cmd+1` / `Cmd+2` / `Cmd+3` | Original / Text / Split |
| `Shift+Cmd+F` | Focus mode |
| `Cmd+F` | Find in text |
| `Cmd+Plus` / `Cmd+Minus` / `Cmd+=` | Zoom the focused pane |
| `Cmd+A` / `Ctrl+A` | Select all documents in the library |
| `Delete` | Delete selected documents |
| `Esc` | Leave Present |

## How it works

1. **PDFs with a text layer** are read directly with PyMuPDF: the words and
   their exact boxes come from the file, so there is no OCR step and no wait.
   **Text and Markdown files** are laid out into a paged PDF beside the source,
   then read the same way. **Scanned PDFs and images** go through LFM3-VL,
   macOS Vision line boxes, and an ink-gap word segmenter. A PDF of image-only
   pages is rendered once and OCR'd page by page with a single model load.
2. `fermion serve phonon-2.5-en` streams partial transcripts over a local
   WebSocket.
3. A monotonic fuzzy alignment moves the cursor through the script. It only
   advances on exact word matches, so ASR errors and OCR mistakes do not throw
   it off, and a final phrase can re-anchor after a skipped line.

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full pipeline, data model,
alignment math, HTTP API, measured performance, failure modes, and a detailed
guide to porting this POC to a native Mac app.

## Privacy

The library, page images, caches, and speech all stay under the app's data
folder on this Mac. The only network request the app makes is the one-time
model download. There is no account, no telemetry, and no cloud OCR or TTS.

## Tech stack

| Layer | Technology |
|---|---|
| UI | SwiftUI + AppKit (native macOS), custom title bar, `NSTextView` reading pane |
| Backend | Python 3.12, ThreadingHTTPServer, WebSocket (mic relay) |
| Speech | Phonon-2.5 English via fermion (MLX), partial transcripts over WebSocket |
| OCR | LFM3-VL 2B (MLX) for handwriting, macOS Vision for print + line boxes |
| PDF | PyMuPDF (text layer) + inline page rendering (scanned); text/Markdown layout |
| Packaging | bundled CPython runtime, `uv pip` site-packages, ad-hoc signed `.app` + DMG |

## Limits

- macOS / Apple Silicon only (MLX). Phonon-2.5 English is English-only.
- Word boxes on handwriting are heuristic. If a line is misread, fix the text
  with **Edit text** and the boxes are re-cut. PDF text boxes are exact.
- A scanned PDF is OCR'd page by page; a long PDF can take a few minutes the
  first time (the result is cached, so later opens are instant).
- macOS Vision's accurate model can fail on the Neural Engine; the app falls
  back to the fast model and some boxes may be missing (a reboot restores it).
- The blue box marks the next words on the page, not a diagram elsewhere.
- Export is one page at a time.
- LFM3-VL is under the LFM Open License v1.0; Phonon-2.5 English weights are
  CC-BY-4.0. Neither is bundled in the DMG.

## Roadmap

- Notarized DMG + Sparkle auto-updates
- iOS / iPadOS companion
- More languages beyond English
- Batch import and folder watching

See **[TODO.md](TODO.md)** for the current work list and acceptance criteria.

## Contributing

Issues and PRs are welcome. Read **[CONTRIBUTING.md](CONTRIBUTING.md)** first;
back-end changes should start with **[ARCHITECTURE.md](ARCHITECTURE.md)**. Run
`make test` before opening a PR.

## Thanks

Thanks to everyone who tested early builds and sent notes on handwriting
accuracy and the microphone feel. This stands on the work of the MLX, fermion /
Phonon-2.5, LFM3-VL, PyMuPDF, and macOS Vision teams.

## License

MIT — see **[LICENSE](LICENSE)**. © 2026 Sharath Krishnamurthy.

Third-party model weights are downloaded separately and keep their own
licenses (see **Limits**).
