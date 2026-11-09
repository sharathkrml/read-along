# Read Along

<sup>[macOS · Apple Silicon · SwiftUI + Python · MIT License](#)</sup>

OCR a handwritten page or a PDF, then highlight the words **on the source page**
while you read it aloud. Amber box = the phrase you are on. Blue box = the next
phrase. The highlight follows your voice, and the page turns itself when you
cross a page boundary.

<table>
  <tr>
    <td><b>Follow your voice</b></td>
    <td>Press Play and read aloud; a local speech engine (Phonon-2.5) streams the
    microphone and a monotonic fuzzy aligner moves the cursor word by word.
    ASR mistakes and skipped lines don't throw it off — it re-anchors to a
    nearby line instead.</td>
  </tr>
  <tr>
    <td><b>Read to me</b></td>
    <td>Choose an installed macOS voice and speed; the highlight follows the
    actual spoken word. Pause and resume without losing your place.</td>
  </tr>
  <tr>
    <td><b>Source-first highlighting</b></td>
    <td>Amber/blue boxes are drawn on the <i>real page</i> (PDF or photo), not
    on a reflowed copy. Click any word to jump; page arrows turn the page.</td>
  </tr>
  <tr>
    <td><b>Handwriting + print</b></td>
    <td>Scanned pages and handwriting use an on-device page-reading model
    (LFM3-VL); printed text layers and slides use macOS Vision — no OCR wait
    for text PDFs.</td>
  </tr>
  <tr>
    <td><b>Local-only</b></td>
    <td>Everything runs on this Mac: OCR, speech, and your documents never
    leave the machine. No account, no cloud, no telemetry.</td>
  </tr>
</table>

---

## Get it

Download `ReadAlong-<version>.dmg`, open it, and drag **Read Along** into
Applications. Apple Silicon Mac, macOS 14 or newer.

> The app carries its own Python runtime and packages, so you do not need
> Python, Homebrew, or a terminal. Models are ~1.7 GB in total and download
> on first use (speech ~158 MB, handwriting ~1.6 GB); they are cached after
> that. The build is ad-hoc signed and not notarized, so Gatekeeper may ask
> you to right-click → **Open** on first launch.

On first launch the app asks before downloading anything. macOS asks for
microphone access when you first press **Follow me** — Python never opens the
microphone itself, so the permission is attributed to Read Along.

### Build from source

Requirements: Apple Silicon Mac, Xcode command line tools, and
[uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/<you>/read-along.git
cd read-along
make setup        # python3.12 venv + requirements
make app          # build build/ReadAlong.app
make run          # build and open the app
make dmg          # dist/ReadAlong-1.0.0.dmg
make test         # run the aligner + library checks
make clean        # remove build/ and dist/
make help         # all targets
```

Backend-only run for iterating on the UI:

```bash
make dev                  # python readalong.py --port 8765
python readalong.py --image page.jpg
python readalong.py --ocr-only   # OCR and print, then exit
```

`make dmg VERSION=1.1.0` builds a differently versioned DMG. To sign and
notarize for distribution, pass a Developer ID identity and a `notarytool`
keychain profile:

```bash
make dmg \
  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  NOTARY_PROFILE=readalong
```

`scripts/requirements.lock.txt` pins the packages baked into the app. Refresh
it after changing `requirements.txt`:

```bash
make lock
```

---

## Use

**Library** — import a PDF, plain text, Markdown, or image from the sidebar, or
drop it anywhere in the window (one file at a time, up to 25 MB). Documents
keep their own source, reading cache, and saved position. Use the row menu to
rename or delete one.

**Views** — *Text* reflows the recovered words, *Original* shows the real
source page with current/next boxes, and *Split* keeps both in sync. Click any
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

**Edit text** — correct OCR line by line and export a proof JPEG when needed.

Keyboard: `Space` toggles play/listen (never while typing), `[` / `]` move one
phrase, arrow keys browse source pages only when the source canvas owns input,
`Cmd+F` finds text, `Cmd+1/2/3` switch panes, `Shift+Cmd+F` enters Focus,
`Cmd+Plus/Minus/Equals` zooms the focused pane, and `Cmd+O` imports a document.

---

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

---

## Tech stack

| Layer | Technology |
|-------|------------|
| UI | SwiftUI + AppKit (native macOS), custom title bar, `NSTextView` reading pane |
| Backend | Python 3.12, ThreadingHTTPServer, WebSocket (mic relay) |
| Speech | Phonon-2.5 English via fermion (MLX), partial transcripts over WebSocket |
| OCR | LFM3-VL 2B (MLX) for handwriting, macOS Vision for print + line boxes |
| PDF | PyMuPDF (text layer) + inline page rendering (scanned); text/Markdown layout |
| Packaging | bundled CPython runtime, `uv pip` site-packages, ad-hoc signed `.app` + DMG |

---

## Limits

- macOS / Apple Silicon only (MLX). Phonon-2.5 English is English-only.
- Word boxes on handwriting are heuristic. If a line is misread, fix the text
  with **Edit text** and the boxes are re-cut. PDF text boxes are exact.
- A scanned PDF is OCR'd page by page; a long PDF can take a few minutes the
  first time (result is cached, later opens are instant).
- macOS Vision's accurate model can fail on the Neural Engine; the app falls
  back to the fast model and some boxes may be missing (a reboot restores it).
- The blue box marks the next words on the page, not a diagram elsewhere.
- Export is one page at a time.
- LFM3-VL is under the LFM Open License v1.0; Phonon-2.5 English weights are
  CC-BY-4.0.

---

## License

MIT. See `LICENSE` (to add).

---

## Roadmap

- Notarized DMG + Sparkle auto-updates
- iOS / iPadOS companion
- More languages beyond English
- Batch import and folder watching

See **[TODO.md](TODO.md)** for the current work list and acceptance criteria.

---

Built as a weekend POC that grew into a daily reader. If it's useful to you,
star the repo, open an issue, or send a PR.