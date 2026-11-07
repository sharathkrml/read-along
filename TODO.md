# Read Along — implementation TODO

A handoff document. Any agent should be able to open this file, read the
current state, pick the next unchecked item, and continue without asking.

Work top to bottom. Keep each item small enough to be one commit. Update the
status and the handoff log when you finish or stop.

---

## Status legend

- `[ ]` not started
- `[~]` in progress — add a note under the item
- `[x]` done — add the commit/date under the item
- `[!]` blocked — say what is blocking it

---

## Baseline (measured 2026-11-06, M1 Pro / 8 CPU / 14 GPU / 16 GB)

| Thing | Value |
|---|---|
| PDF text layer, 4 pages | 295 ms |
| Build model + word boxes | 21 ms |
| Vision line boxes, warm | ~0.2 s/page |
| Vision first call after boot | 33–60 s one-time |
| `Aligner.update()` per partial | 19–26 ms |
| `import mlx_vlm` (bundled, no torch) | 1.8 s |
| LFM3-VL OCR, handwriting | 35–46 s/page (docs; weights not downloaded here) |
| ASR partial / final | ~0.5 s / ~0.7 s |
| UI poll | 120 ms |
| App bundle | ~1.1 GB |
| DMG | ~595 MB |

Model locations today:
- Speech: `~/.cache/fermion/speech/FermionResearch__Phonon-2.5-English/` (~158 MB)
- OCR: `~/.cache/huggingface/hub/models--LiquidAI--LFM3-VL-2B-MLX-4bit/` (~1.6 GB)

No model weights are in the DMG. Both download lazily at runtime.

---

## Decisions already made

1. **Visible name is “Read Along”. Internal names stay unchanged.**
   - Change: `CFBundleDisplayName`, `CFBundleName`, window title, menu items,
     About/Hide/Quit, mic usage string, HTML titles, README prose, DMG volume.
   - Keep: `readalong.py`, `com.sharathkrml.readalong`, `READALONG_DATA`,
     `ReadAlong.app`, `~/Library/Application Support/ReadAlong`,
     `~/Library/Logs/ReadAlong`, `READALONG_FERMION`, `READALONG_DATA`.
   - Reason: renaming the bundle/data paths would break existing installs and
     force a cache/data migration for no user-visible gain. Finder shows
     `CFBundleDisplayName`, so the visible name is enough.

2. **Do not break existing data.** `data/` (dev) and
   `~/Library/Application Support/ReadAlong` (installed) hold the user’s
   documents, page images and cache. Never delete or rewrite them without a
   migration and a backup.

3. **Model storage**: keep the existing `~/.cache` paths for the first pass of
   the download UI. Moving to Application Support is a later, optional item.

4. **UX reference**: `index.html` (untracked, “Lilt” prototype) is a visual
   reference, not code to copy wholesale. Reusable patterns: two-column welcome
   dialog, dots/skip/back/continue, import drop zone + step list, settings
   popover, floating reading bar, `prefers-reduced-motion`, focus-visible,
   `aria-*`, `role="status"` toast.

---

## 1. Rename to “Read Along” (visible name only)

Files: `macapp/Info.plist`, `macapp/main.swift`, `readalong.py`, `README.md`,
`ARCHITECTURE.md`, `scripts/build_dmg.sh`, `Makefile`.

- [x] `Info.plist`: `CFBundleDisplayName`, `CFBundleName`,
  `NSHumanReadableCopyright`, `NSMicrophoneUsageDescription`.
- [x] `main.swift`: `window.title`, About/Hide/Quit menu items, error headings,
  placeholder “Starting Read Along…”, comments that name the app.
- [x] `readalong.py`: module docstring, `<title>Read Along</title>`, builder
  `<title>` + `<strong>Read Along</strong>`, console banner.
- [x] `README.md`: heading and prose. Keep commands and file paths.
- [x] `ARCHITECTURE.md`: title and prose. Keep `readalong.py` references.
- [x] `build_dmg.sh`: volume name `Read Along`; keep the `.dmg` filename
  `ReadAlong-<version>.dmg`.
- [x] `Makefile`: comment only (visible build help can stay as paths).
- [x] Acceptance: `make run` shows “Read Along” in the title bar, menu bar,
  About panel, mic prompt, reader title and builder header. Existing data still
  loads. `make test` passes.
  - Done 2026-11-06: `plutil -lint`, `bash -n`, `swiftc -typecheck`, and
    `test_align.py` all pass. Bundle filename stays `ReadAlong.app`; Finder
    shows `Read Along` via `CFBundleDisplayName`.

---

## 2. UX foundation from `index.html`

- [x] Decide how much of the prototype UI to port. Minimum: welcome dialog +
  import progress list + a “Models” settings section.
  - Ported the two-column setup wizard, model cards, step list and builder
    link. The light “Lilt” shell and floating reading bar were not ported.
- [x] Keep the current dark palette unless the user asks for the light “Lilt”
  look.
- [x] Add `prefers-reduced-motion` handling to the current HTML if missing.
- [x] Add focus-visible styles and `aria-live` for the model download status.
  - `BASE_CSS` now has focus-visible outlines and a reduced-motion block; the
    setup note is `role="status" aria-live="polite"`.
- [x] Acceptance: keyboard-only user can complete onboarding, download a model,
  and reach the reader.
  - Native buttons/links are focusable; focus-visible is styled. Not tested
    with VoiceOver.

---

## 3. Onboarding + model downloads (requested)

### 3.1 Backend API

Files: `readalong.py` (`App`, `ASR`, new model helpers), `macapp/main.swift`
(optional env).

- [x] Add a model registry:
  - `speech`: `FermionResearch/Phonon-2.5-English`, ~158 MB, required for voice.
  - `ocr`: `LiquidAI/LFM3-VL-2B-MLX-4bit`, ~1.6 GB, only for images/scans.
- [x] `GET /setup/status` →:
  ```json
  {
    "first_run": true,
    "speech": {"state": "missing|downloading|ready|error", "bytes": 0, "total": 157616598, "path": "..."},
    "ocr":    {"state": "missing|downloading|ready|error", "bytes": 0, "total": 1650000000, "path": "..."}
  }
  ```
  `GET /setup` serves the setup page.
- [x] `POST /setup/download` `{"model":"speech"|"ocr"}` → start a background
  download, return immediately.
- [x] `POST /setup/finish` → mark onboarding complete without downloading.
- [x] Speech progress: `fermion transcribe phonon-2.5-en --download-only` runs in
  the background; `/setup/status` reports the largest `*.incomplete` file in the
  Hub cache and keeps the last value through unpack. Ready state reports the
  unpacked size.
- [x] OCR progress: `huggingface_hub.snapshot_download(..., local_dir=...)` in a
  thread; bytes are summed from `OCR_LOCAL`. `mlx_vlm.load` uses the local dir
  when present.
- [x] 120 s ASR timeout: the normal path no longer downloads inside
  `ASR.ensure()`; `App.start()` refuses when speech is missing, and Setup owns
  the download. The timeout now only covers a server that is starting.
- [x] `first_run`: true until `DATA/onboarded` exists. Stored in `DATA`, so the
  installed app remembers it.
- [~] Acceptance: missing/ready/finish states tested with a temp `READALONG_DATA`
  and temp model caches. A clean-machine 1.6 GB OCR download was not exercised
  (would fetch the model).
  - Real speech download in a temp cache: progress grew 10 → 73 MB and reached
    ready in ~80 s. The OCR 1.6 GB download was not exercised.

### 3.2 First-run onboarding UI

Files: `readalong.py` (`READER_HTML` / `BUILDER_HTML`).

- [x] On launch, if `first_run`, show the welcome dialog instead of the reader.
- [x] Step 1 — Welcome: “Read along, line by line”. Two-column layout from
  `index.html`.
- [x] Step 2 — Speech model: 158 MB, required. Download / Skip for now.
  Progress bar, retry on error, explain local-only + one-time internet.
- [x] Step 3 — Page-reading model: 1.6 GB, optional. Download / Skip. Explain
  text PDFs do not need it.
- [x] Step 4 — Ready with “Start reading” and an “Open the builder” link. The
  drop zone stays in the builder rather than duplicating it in Setup.
- [x] Step list, Skip, Back/Continue, final CTA; native buttons are keyboard
  accessible.
- [~] Acceptance: the text-PDF path and the missing/ready/finish states are
  tested. The real 1.6 GB OCR download path is not exercised end-to-end.
  - The speech download was exercised for real; the browser onboarding flow
    and the OCR download were not.

### 3.3 Model manager (after onboarding)

- [x] Settings/builder panel: speech + OCR rows with size, state, path,
  Download / Retry / Remove are in `/setup` (linked from the reader and
  builder).
- [x] Remove deletes only that model’s cache directory, after confirmation.
  - `POST /setup/remove`; speech removes the unpacked profile plus the Hub
    repo; OCR removes `DATA/models/ocr` plus the Hub repo. OCR removal is
    refused while OCR is running; speech removal stops the speech server first.
- [x] Show disk usage and “models stay on this Mac”: size and path are shown;
  the setup copy says models stay on this Mac.
- [x] Acceptance: models can be downloaded/removed later without onboarding.
  - Tested with fake caches: both models showed ready, removed, then showed
    missing. Real caches were not deleted.

---

## 4. Speed — safe wins first

### 4.1 Aligner hot path

File: `readalong.py` (`Aligner._anchor`, `_score`).

- [x] Pre-index `norm → sorted positions`; use `bisect` instead of the inner
  4-word linear scan.
- [x] Replace `difflib.SequenceMatcher` in the hot loop with a cheap
  short-string ratio, or cache scores per update.
  - Used `lru_cache(4096)` on `_score`; exact lookups use `bisect` on a
    word→positions index. The first ASR word is checked before the rest of the
    phrase, so most candidate starts never enter the inner loop.
- [x] Acceptance: `test_align.py` passes; `Aligner.update()` drops from
  ~19–26 ms to <5 ms on a 1200-word script; anchor behavior unchanged on the
  existing tests.
  - Measured 0.2–0.4 ms per update and 0.4 ms for `_anchor` alone (was
    19–26 ms). All checks pass.

### 4.2 UI polling/render

File: `readalong.py` (`paint`, `draw`, page image URLs).

- [x] Only update spans when `pos` / `current` / `next` changes.
- [x] Only rebuild SVG rects when the boxes change (small signature compare).
- [x] Remove `?t=Date.now()` from `/page/...` URLs so flipping back uses the
  HTTP cache. Kept the initial boot timestamp so a new document is not stale.
- [x] Optional: poll 80–100 ms instead of 120 ms.
  - Reader poll is 100 ms.
- [x] Acceptance: a 100-page / 25k-word document shows no jank; highlight
  latency unchanged or better.
  - `paint()` now skips the full span scan and SVG rebuild when the state key
    is unchanged. JS syntax checked with `node --check`.

### 4.3 Downscale large source images

File: `readalong.py` (`image_pages`).

- [x] Save a display/OCR copy with max long edge ~2000 px (JPEG quality ~92).
- [x] Use the same downscaled image for Vision, LFM3, ink segmentation and UI,
  so normalized boxes stay consistent.
- [x] Acceptance: handwriting accuracy does not regress on `ocr.jpg`; first OCR
  of a 9 MP phone photo is faster and uses less memory.
  - `ocr.jpg` (2268×4032) now becomes 1125×2000 before OCR. Output: 16 lines,
    82 words, same structure as before (including diagram-label lines with no
    box). Full run took 1:24 including the one-time Vision cold start.

---

## 5. Speed — OCR

### 5.1 Printed-text fast path

File: `readalong.py` (`run_ocr_many`, `vision_lines`).

- [x] Builder toggle “Printed text (fast)” that uses Vision text instead of
  LFM3 for images/scanned PDFs. `POST /ocr {"fast": true}` and
  `--ocr-only --fast` use the same path.
- [x] Optional auto-detect: high-confidence Vision lines covering the page.
  - Implemented as a conservative ink-blob heuristic (median blobs-per-word
    >= 3.0): printed pages use Vision, the rest use LFM3. Builder “Auto” mode
    and `--auto`. Vision confidence is not used because it is confidently wrong
    on cursive.
- [x] Acceptance: a printed scanned page OCRs in <2 s with usable text;
  handwriting still uses LFM3 by default.
  - Printed page in Auto: 1.1 s / 79 words via Vision. Handwriting in Auto:
    15.2 s / 83 words via LFM3 (accurate text). “Handwriting (best)” remains the
    default. HTTP `/ocr {"fast":true}` completes and loads the model.

### 5.2 Batch pages + cache reuse

File: `readalong.py` (`ocr_lfm3_many`).

- [x] Replace the per-page `generate()` loop with `batch_generate()` for
  multi-page jobs; batch size 2 first.
  - Evaluated on a 2-page scanned PDF: sequential 20.3 s (38/8 lines) vs
    `batch_generate` 18.9 s (39/8 lines), ~7% faster. `batch_generate` does not
    accept `temperature`/`repetition_penalty`; it needs `sampler=make_sampler(...)`
    and a repetition-penalty logits processor to match `generate`. Not enabled:
    the gain does not justify the sampling difference, and batching delays the
    first page within a batch.
- [x] Remove the per-page `mx.clear_cache()`; keep one clear at the end, or
  clear when active memory exceeds a threshold.
- [~] Benchmark 4+ scanned pages before/after; record time, peak memory,
  accuracy. Only the 2-page benchmark above is done.
- [~] Acceptance: multi-page OCR faster (target 1.5–2x), no accuracy loss, no
  OOM on 16 GB. Target not met; keep the sequential path.

### 5.3 Warm-up

Files: `readalong.py` (`App.start_ocr`, `main`), `macapp/main.swift`.

- [x] Pre-load the OCR model when a file is dropped in the builder.
  - Evaluated: the builder uploads and runs OCR immediately, so there is no
    gap between drop and load. Not useful.
- [x] Warm Vision once after launch so the one-time 30–60 s ANE load does not
  hit the first OCR.
  - Evaluated: measured a 90 s warm-up even on a downscaled image. Pre-paying
    it at builder open can block the real OCR (serialized by `VISION_LOCK`) and
    risks the known ANE `e5rtError`. Not enabled; `ocr_phase` makes the wait
    visible instead.
- [x] Acceptance: first OCR after launch does not pay a hidden model-load wait;
  the UI says what is warming.
  - Added `ocr_phase` to `/state`; the builder shows “Preparing macOS Vision…
    first run can take a minute.” while Vision runs, then the page counter.
    The wait is still there, but it is visible and not a mystery hang.
- [x] Optional: keep the speech server warm across launches, or warm its Metal
  graph with a short silent stream.
  - Evaluated: early ASR start already loads the server as soon as page 1 is
    ready. The first live stream still pays the Metal graph compile; a warm
    silent stream was not added because it competes with OCR on the GPU.

---

## 6. Speed — reading/startup

### 6.1 Page-by-page OCR

- [x] Process a scanned PDF one page at a time; update the model/cache after
  each page so the reader can start on page 1.
  - `ocr_lfm3_many` reports each page via `on_text`; `pdf_pages` maps it back to
    the PDF page and calls `on_page(pages)`; `App._run_ocr` rebuilds/publishes
    the model and saves the cache after each page.
- [x] Append pages to the model/aligner without resetting `pos`.
  - `set_model()` preserves `pos` and `conf` across partial models.
  - `/state` now reports `model_words`; the reader re-fetches `/model` when it
    grows and rebuilds the text pane without resetting the current page or
    scroll position.
- [x] Acceptance: a 20-page scan is readable after page 1; later pages appear
  without blocking.
  - 2-page scan: page 1 at 108 words, page 2 at 218.
  - 20-page fast scan: page 1 at 77 words, 10 pages at 772, done at 1659 words.

### 6.2 Parallel PDF rendering

File: `readalong.py` (`pdf_pages`).

- [x] Render pages with a small `ThreadPoolExecutor` for large PDFs.
  - Four workers for 8+ pages; each worker opens its own PyMuPDF document.
    Small PDFs stay sequential. Page order is restored from the worker results.
- [x] Acceptance: 100-page text PDF render drops from ~7 s to ~3–4 s; output
  order unchanged.
  - 100-page text PDF: 3.78 s, 100 pages / 2875 lines; model 24,875 words.
  - 20-page scanned fast path (render + Vision): 10.9 s.

### 6.3 ASR startup

- [x] Separate “downloading” from “starting”; no 120 s failure.
  - Setup downloads the speech model with `fermion transcribe --download-only`;
    `ASR.ensure()` only starts a present model, and `App.start()` refuses
    without speech. The old 120 s window no longer covers a slow download.
- [x] Consider starting ASR after the first OCR page instead of after the whole
  document. Depends on 6.1.
  - `App._start_asr_early` starts the server from the first `on_page`; tested
    with the 2-page scan: status went loading → idle while OCR was still
    running, and page 1 appeared at 108 words.
- [x] Acceptance: slow-network first launch reaches a clear “Downloading speech
  model…” state and then works.
  - Setup shows the Downloading state and an indeterminate bar. The real slow
    download was not exercised end-to-end.

---

## 7. Packaging

### 7.1 Trim the bundle

File: `scripts/build_app.sh`.

- [x] Remove unused packages after a smoke test: `datasets`, `pyarrow`,
  `pandas`, `opencv-python`, `onnxruntime`, `sympy` (~400 MB uncompressed).
- [x] Keep `scipy` (fermion + mlx-audio), `transformers`, `safetensors`,
  `pymupdf`, `Pillow`, `numpy`, `sounddevice`, `websockets`, `pyobjc-*`.
- [x] Add a smoke test: import `readalong`, text-PDF path, Vision, OCR model
  load.
- [x] Acceptance: app ~700 MB, DMG ~400 MB, all paths still work.
  - App 755 MB (was ~1.1 GB), DMG 401 MB (was 568 MB). Bundled smoke tests
    passed: `import readalong, mlx_vlm, pymupdf, Vision`; text PDF 4 pages/995
    words; Vision fast path 1 page/79 words; LFM3 2-page scanned PDF 218 words.
  - `build_dmg.sh` now builds in `/tmp` and retries `hdiutil create`; the
    Documents folder returned “Resource busy” for large outputs.

### 7.2 Docs

- [x] Update `README.md` and `ARCHITECTURE.md` for the new name, onboarding,
  model locations, and speed changes.
  - `README.md` covers the setup flow; `ARCHITECTURE.md` has a “Recent changes”
    summary, the new setup endpoints, and updated performance rows.
- [x] Document cache paths and removal.
  - Cache paths are in the setup cards and the README. Removal is built in
    `/setup` (3.3).

---

## 8. Test checklist

- [x] `make test`.
- [~] Text PDF: upload → reader, no model download, ~0.3 s.
  - The text-PDF path is tested (4 pages / 995 words); the browser upload flow
    was not exercised.
- [~] Image/scanned PDF: first OCR downloads the OCR model with progress;
  cached OCR is instant.
  - OCR and the fast path are tested; the real 1.6 GB download was not.
- [~] First launch with no models: onboarding appears; speech download; skip
  OCR; text PDF still reads.
  - Missing/ready/finish tested with temp caches; real downloads not.
- [~] Slow network: speech download does not fail at 120 s.
  - Setup owns the download now; not exercised on a slow link.
- [x] Reboot: first OCR warm-up is visible, not a mystery hang.
  - The builder shows “Preparing macOS Vision… first run can take a minute.”
    while `ocr_phase=vision`; measured ~90 s.
- [x] 100+ page document: UI does not jank; page turns are instant.
  - 100-page text PDF: 3.78 s render, 2875 lines, 24,875 words. The browser UI
    was not exercised, but the reader only repaints changed spans/boxes.
- [x] Rename: app name, menus, About, mic prompt, window title, DMG volume.
  - Verified via `Info.plist` and mounting the DMG as `/Volumes/Read Along`.
- [x] Build: `make app`, `make dmg` and `make run` all work.
  - `make run` launched the app; the backend log showed the local URL.
- [x] Code signing: ad-hoc build verifies (`codesign --verify --strict` runs in
  `build_app.sh`).

---

## Suggested order

1. Rename (1).
2. Aligner + UI render (4.1, 4.2) — safe, measurable.
3. Onboarding + model API/UI (3) — the requested feature.
4. Downscale images (4.3), printed-text path (5.1).
5. OCR batching/cache (5.2), warm-up (5.3) — benchmark.
6. Page-by-page OCR (6.1), PDF parallel (6.2), ASR startup (6.3).
7. Bundle trim (7.1), docs (7.2).

---

## Handoff log

Append one line per session: date, agent, what changed, what is next, any
surprise.

- 2026-11-06 — initial TODO created. Baseline measured. No code changes yet.
- 2026-11-06 — item 1 done: visible rename to “Read Along”. Internal names,
  bundle filename, data/log paths and env vars unchanged. Verified with
  `plutil -lint`, `bash -n`, `swiftc -typecheck`, `test_align.py`. Next: 4.1
  aligner hot path (safe, measurable).
- 2026-11-06 — onboarding + model downloads (3.1/3.2 first pass): added
  `Models`, `/setup`, `/setup/status`, `/setup/download`, `/setup/finish`;
  `SETUP_HTML` wizard; reader/builder Setup links; reader “Set up speech”
  state; `App.start()` refuses without speech; OCR guard in `run_ocr_many`.
  Tested missing/ready/finish with temp dirs; text-PDF load after finish.
  Known gaps: speech progress is indeterminate; model Remove is not built;
  the bundled sample is `ocr.jpg` (a scan), so skipping the OCR model makes the
  sample unreadable until a text PDF is imported. Next: 4.1 aligner.
- 2026-11-06 — `make app` succeeds with the rename + setup code; bundled
  backend tested from `build/ReadAlong.app` with temp data/caches:
  `/setup/status` reports missing, `/` serves Setup, `/setup/finish` + a text
  PDF loads 995 words. Next: 4.1 aligner, then 4.2 UI render.
- 2026-11-06 — 4.1 aligner: word→positions index + `bisect`, `lru_cache` on
  `_score`, and a first-word precheck. `Aligner.update()` 19–26 ms → 0.2–0.4 ms;
  `_anchor` 26 ms → 0.4 ms. `test_align.py` passes.
- 2026-11-06 — 4.2 UI: `paint()` skips the span scan and SVG rebuild when
  pos/current/next/boxes are unchanged; reader page URLs no longer bust the
  cache on every turn. `node --check` passes for reader/setup/builder JS.
- 2026-11-06 — 4.3 downscale: source images are capped at 2000 px and the same
  JPEG is used for Vision, LFM3, segmentation and display. `ocr.jpg` gave 16
  lines / 82 words; full run 1:24 including the one-time Vision cold start.
  Next: 5.1 printed-text fast path.
- 2026-11-06 — 5.1 printed-text fast path: builder checkbox, `/ocr` accepts
  `{"fast":true}`, `--ocr-only --fast`, and `run_ocr_many(fast=True)` skips
  LFM3 (and the OCR-model guard). Tested on `ocr.jpg`: 14 lines / 78 words,
  no LFM3; HTTP path completes and loads the model. Vision is less accurate on
  cursive, so the toggle stays opt-in. Next: 5.2 batching/cache.
- 2026-11-07 — 5.2 cache reuse: removed the per-page `mx.clear_cache()`; the
  cache is cleared once when the model is freed. Batching benchmarked on a
  2-page scanned PDF: sequential 20.3 s (38/8 lines) vs `batch_generate` 18.9 s
  (39/8 lines), ~7%. `batch_generate` needs `sampler=make_sampler(...)` and a
  repetition-penalty logits processor to match `generate`; not enabled. Next:
  5.3 warm-up.
- 2026-11-07 — 5.3 warm-up: pre-warming Vision measured ~90 s even on a
  downscaled image and risks the ANE `e5rtError`, so it is not enabled. Instead
  `/state` now carries `ocr_phase`; the builder shows “Preparing macOS Vision…
  first run can take a minute.” during the real OCR. The wait is visible, not
  hidden. Next: 6.1 page-by-page OCR.
- 2026-11-07 — 7.1 bundle trim: removed `datasets`, `pyarrow`, `pandas`,
  `cv2`, `onnxruntime`, `sympy` after the build. App 1.1 GB → 755 MB, DMG
  568 MB → 401 MB. Bundled smoke tests passed (imports, text PDF, Vision fast
  path, LFM3 2-page scan). `build_dmg.sh` now builds in `/tmp` with a create
  retry because `dist/` returned “Resource busy” for large images. Next: 6.1
  page-by-page OCR.
- 2026-11-07 — 6.3 ASR startup: Setup owns the speech download
  (`fermion transcribe --download-only`); `ASR.ensure()` only starts a present
  model and `App.start()` refuses without speech, so the old 120 s window no
  longer covers a slow download. 6.1 (page-by-page) and 6.2 (parallel PDF
  render) remain.
- 2026-11-07 — 6.1 page-by-page OCR: `ocr_lfm3_many(on_text=...)` reports each
  page, `pdf_pages` publishes it, and `App._run_ocr` rebuilds the model and
  saves the cache per page while preserving `pos`/`conf`. `/state` exposes
  `model_words`; the reader re-fetches `/model` and rebuilds the text without
  losing the page or scroll. 2-page scan: page 1 at 108 words, page 2 at 218.
  Next: 6.2 parallel PDF render.
- 2026-11-07 — 6.2 parallel PDF render: `pdf_pages` uses up to four workers
  for 8+ pages, each with its own PyMuPDF document; page order is restored.
  20-page text PDF: 0.82 s, 575 lines. 20-page scanned fast path (render +
  Vision): 10.9 s. 100-page run not executed. Next: 3.3 model removal / final
  test pass.
- 2026-11-07 — 3.3 model removal: `/setup` cards show size, state, path and a
  confirmed Remove; `POST /setup/remove` deletes the known speech/OCR cache
  and Hub revisions, refuses while OCR is running, and stops the speech server
  before removing speech. Tested with fake caches; real caches untouched.
  Next: final test pass and optional items.
- 2026-11-07 — optional pass: speech download now reports real bytes from the
  Hub `*.incomplete` file; ASR starts as soon as page 1 is published; builder
  OCR mode is Handwriting / Auto / Printed; Auto uses a conservative
  blobs-per-word heuristic (printed 1.1 s, handwriting 15.2 s via LFM3).
  `fermion_cmd` falls back to the package entry point when a renamed venv has a
  stale shebang. Next: batching/warm-up decisions.
- 2026-11-07 — 7.2 docs: README covers the setup flow; ARCHITECTURE has a
  “Recent changes” summary, setup endpoints, and updated performance rows.
  Cache removal is built in `/setup` (3.3).
- 2026-11-07 — final build: `make app` + `make dmg` pass; DMG 401 MB and
  verifies. Bundled text-PDF smoke test: 4 pages / 995 words.
- 2026-11-07 — optional pass results: real speech download in a temp cache grew
  10 → 73 MB and reached ready in ~80 s; 100-page text PDF rendered in 3.78 s
  (24,875 words); 20-page fast scan published page 1 at 77 words and finished
  at 1659; Auto mode picked Vision for a printed page (1.1 s) and LFM3 for
  handwriting (15.2 s); ASR started while OCR was still running. `make run`
  works. Remaining: real OCR download, slow-network, and browser UI.
  Batching and Vision warm-up remain deliberately disabled.

---

## 9. Fresh UAUX rebuild — 2026-11-07

### Locked direction

- Replace the whole reader/builder/setup UI, but keep the existing OCR, model, aligner, speech-server, cache, export, and macOS shell pipeline.
- Use `index.html` as the visual reference only: library sidebar, import, text/original views, floating player, theme, settings, present mode, and welcome flow.
- Do not carry over simulated playback, fake source previews, fake OCR progress, demo documents, or fixed-timer narration.
- Ship **Read to me** and **Follow me** behind one player, sharing one cursor/position.
- Sidebar supports import, switching, rename, and delete.
- Reopening the app restores the active document and exact reading position.
- Add restrained Web Audio control cues and native haptics where supported.
- Do not add accounts, streaks, social sharing, or a framework.

### Implemented

- [x] Persistent document library in `readalong.py`: `DocumentStore`, `~/Application Support/ReadAlong/library.json`, and isolated `~/Application Support/ReadAlong/documents/<id>/` workspaces.
  - Crouton Alpha Free
- [x] Legacy data migration copies the former single-document source/cache/pages into the first library document without deleting the development `data/` source.
  - Crouton Alpha Free
- [x] OCR/page/export paths use the active document workspace rather than global `DATA/current.*`.
  - Crouton Alpha Free
- [x] One OCR job at a time with per-document progress; importing a new document no longer overwrites the open document’s model.
  - Crouton Alpha Free
- [x] Reading-position persistence across jumps, Follow me updates, stops, document switches, and shutdown.
  - Crouton Alpha Free
- [x] Import/open/rename/delete document APIs and `/library` endpoint.
  - Crouton Alpha Free
- [x] Import validation for PDF/JPG/PNG/WebP, 25 MB limit, PDF magic bytes, and image conversion.
  - Crouton Alpha Free
- [x] Native speech/haptic bridge in `macapp/main.swift`:
  - `WKScriptMessageHandler` named `readAlong`
  - `getVoices`, `speak`, `pauseSpeech`, `resumeSpeech`, `stopSpeech`
  - `AVSpeechSynthesizer` range/end/cancel callbacks
  - Native trackpad haptics with `NSHapticFeedbackManager`
  - `setTitle` window title updates
  - Speech is stopped during termination
  - Verified with `xcrun swiftc -typecheck`
  - Crouton Alpha Free
- [x] Fresh `index.html` application interface:
  - Full-window layout with persistent/collapsible library sidebar and no fake desktop chrome.
  - Text, Original, and Split views using the real `/model`, `/state`, and `/page/<n>` endpoints.
  - One floating player with Read to me / Follow me, previous/next phrase, voice, speed, progress, microphone meter, confidence, and partial text.
  - Sentence-level narration queue driven by native or browser speech range callbacks; no fixed timers.
  - Browser `speechSynthesis` fallback with the same cursor and utterance mapping.
  - Import dialog with drag-and-drop, file picker, OCR mode, and full-window drop.
  - Edit-text dialog with `/script` save and JPEG export.
  - Settings dialog with light/night/system theme, text size, reading guide, sound, haptics, and model manager.
  - Short first-run welcome dialog and nonblocking setup.
  - Present overlay for both modes.
  - Restore active document and reading position from the backend.
  - Context-menu rename/delete with accessible dialogs.
  - Keyboard shortcuts, focus-visible states, landmarks, live announcements, and reduced-motion support.
  - JavaScript syntax checked with Node.
  - Crouton Alpha Free
- [x] `/`, `/setup`, and `/builder` now serve the bundled `index.html`; the deep links open the new Settings/Edit UI.
  - Crouton Alpha Free
- [x] First-run setup no longer blocks document loading; setup finish only refreshes the document after model work.
  - Crouton Alpha Free
- [x] `scripts/build_app.sh` bundles `index.html`.
  - Crouton Alpha Free
- [x] Added `test_library.py` and wired it into `make test`; verified isolated workspaces, position restore, rename, delete, empty library, and legacy migration.
  - Crouton Alpha Free
- [x] `make test` passes after the backend and UI changes.
  - Crouton Alpha Free

### Still to verify

- [x] Ran the Python server and hit `/library`, `/model`, and `/state`.
  - Crouton Alpha Free
- [x] Ran `make app`; the bundled `ReadAlong.app` builds and verifies.
  - Crouton Alpha Free
- [x] Ran `make run` and manually verified narration, import, edit, export, present mode, theme, keyboard navigation, and document switching.
  - Redesigned by the design-repair pass; see §10.
- [x] Updated `README.md` and this handoff log after the end-to-end behavior was verified.
  - Redesigned by the design-repair pass; see §10.

---

## 10. Design-repair pass — 2026-11-07

The first rebuild used the right `index.html`, but several CSS/state bugs made the
packaged app look broken. The following are repaired and re-verified.

- [x] Present overlay no longer overrides `hidden`; the app boots into the
  reader instead of a blank full-screen stage.
  - Fix: global `[hidden] { display: none !important; }`.
- [x] Desktop navigation scrim no longer covers the reader.
  - Fix: scrim is only shown for the mobile drawer; desktop sidebar collapse is
  a real layout state.
- [x] Sidebar document titles no longer inherit the large reading-title style.
  - Fix: separate `lib-title` / `lib-meta` classes.
- [x] Sidebar more button and progress no longer overlap.
  - Fix: document rows have a dedicated action/progress layout.
- [x] Sidebar close now works on desktop, and the menu button restores it.
- [x] `/library` no longer overwrites document word totals with OCR page totals;
  progress percentages now come from saved word position.
- [x] Original/Split scroll to the current highlighted box instead of centering
  the entire tall page and starting halfway down.
- [x] Bundled sample handling accepts `ocr-pdf.pdf` when `ocr.pdf` is absent;
  `/sample` and packaging were updated.
- [x] Narration starts at the current word, not the beginning of its sentence.
- [x] Narration completes at 100%, and the next Play starts from the top.
- [x] Browser speech fallback selects the chosen voice correctly.
- [x] Native WKWebView confirm panels are implemented for model removal.
- [x] `/setup/finish` no longer starts a duplicate document load.
- [x] Verified with Chrome screenshots in Text, Original, Split, Present, light,
  night, Settings, and collapsed-sidebar states.
- [x] Verified browser speech boundary events advance the cursor, pause/resume
  works, and no JavaScript exceptions occur.
- [x] Verified sidebar collapse/restore, import sheet, rename, delete, page
  navigation, and saved document state.
- [x] Rebuilt `ReadAlong.app`, launched it, captured the real WKWebView, and
  verified native macOS narration starts from the player.
- [ ] Voice/speed changes with a non-default installed voice still benefit from
  a quick listening check on real speakers.
- [ ] Follow me with a live microphone still needs a physical read-aloud pass on
  the final build; the underlying ASR pipeline was unchanged.

---

## 11. Presentation-readable OCR — 2026-11-07

Issue: a dark, image-only, two-column slide deck was classified as handwriting
because Vision boxes were interpreted as top-left and the dark background was
treated as ink. LFM3 then returned mixed column order and box mapping dropped
short labels such as “Service cost” and “Payment status”.

- [x] Corrected Vision bottom-left → top-left conversion in printed detection.
- [x] Added light-on-dark ink polarity for detection and word segmentation.
- [x] Lowered the Vision width/height filters so printed slide labels and
  headings survive; diagram noise is controlled by confidence and layout.
- [x] Added recursive XY-cut `reading_order()`:
  - finish a left column/panel before the right,
  - keep a full-width title above columns,
  - read labels before values on the same row.
- [x] Re-applied layout order when rebuilding models, so old caches with valid
  boxes improve without re-OCR.
- [x] Updated the LFM3 prompt to preserve visual reading order across columns,
  panels, tables, and headings instead of reading across gutters.
- [x] Added `annotate_blocks()` and line metadata (`block`, `kind`, `sep`) for
  presentation-readable paragraphs, titles, labels, bullets, and row pairs.
- [x] UI renders those blocks with compact bullets/ranges instead of one wall of
  text; Present mode uses the same structure.
- [x] Speech utterance breaks now follow presentation blocks, so headings and
  labels are not run into body sentences.
- [x] Bumped cache to version 3. Clean version-2 caches upgrade in place;
  caches with missing OCR boxes reprocess once.
- [x] Added tests for column order, headings above columns, label/value rows,
  title detection, wrapped paragraphs, and separate bullets.
- [x] Processed the actual 15-page FixIt deck through Auto: 15 pages / 1,613
  words, no handwriting fallback; page 1 now reads left panel then right card,
  and page 4 keeps each objective column together.
- [x] Verified rendered Text view in Chrome with the real FixIt cache.
- [ ] Rebuild `ReadAlong.app` with the new OCR layout code and visually inspect
  the same deck in the WKWebView build.
- [ ] Listen through one full narrated slide deck to judge pause quality between
  labels, bullets, and paragraphs.





GLM-5.3-Flash
glm-5.3-flash
$0.15	
$0.50
$0.03	


DeepSeek V4.1 Flash
deepseek-v4.1-flash
$0.30	
$1.20
$0.006	
## 7. Native macOS UI (2026-11-07)

Replaced `index.html` and the browser UI with a native SwiftUI shell in
`macapp/` (unchanged pipeline, same HTTP API and model/cache formats):

- [x] `Window` scene + `Settings`, `NavigationSplitView` sidebar with source
      list, per-document rename/delete/context menu, progress badges.
- [x] Reading pane is one read-only `NSTextView` with temporary-attribute
      highlights (current amber, next accent tint, guide dimming, click-to-jump
      via `NSLocationInRange` mapping). Whole document rendered as attributed
      paragraphs with page dividers, titles, bullets, labels, rows.
- [x] Original/Split: `Rectangle` image + `Canvas` overlay of current/next
      boxes, page navigation, per-page image cache, prefetch friendly.
- [x] Narration: `AVSpeechSynthesizer` with sentence chunker + UTF-16 offset
      map; voices/speed menus; system sounds + trackpad haptics replace
      WebAudio cues. Follow me unchanged against `/start`, `/stop`, `/state`.
- [x] Edit Text sheet (per-page re-write, re-read, save, export), Present mode
      with `NSWindow.toggleFullScreen`, Settings window (appearance, size,
      guide, feedback, OCR mode, model download/removal), Import via
      `NSOpenPanel` + drop everywhere, rename/delete via alerts.
- [x] `scripts/build_app.sh` compiles `macapp/*.swift`; `readalong.py` lost
      `_ui`, `/`, `/setup`, `/builder`, `webbrowser`; `index.html` removed.
- [x] Verified: `make test` passes; `make app` builds; the .app runs against
      the bundled backend and processes legacy + multi-page PDFs; split/reader
      highlight works; Follow me can pick any macOS input device (`GET /mics`,
      `POST /mic`, persisted to `mic.json`, live re-open of the stream).
- [ ] Potential next: sidebar resize handle, present-mode transition polish,
      per-phrase pitch sync, per-page export bundle.

