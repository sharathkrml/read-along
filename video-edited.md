# Video Editing Context

This document records every action taken in this chat session to edit the raw demo recording into TikTok/YouTube-ready videos. It is kept for reference so this work does not need to be re-derived. All generated video assets and intermediate files are intentionally left **untracked / deleted** and must not be committed to GitHub.

---

## Source material

| File | Notes |
|------|-------|
| `video-without-subs.mov` | Raw demo recording, 37.7 s, 3462×2160 HEVC (yuv420p, bt709) + AAC stereo 44.1 kHz, ~18 Mbps |
| `STUDIO-AI-Video-Editor-Guide.pdf` | Mnday Labs × @AIwithAkram "The AI Video Editor" free guide — 3-prompt workflow (setup → taste → draft) |

Models referenced in the demo:
- **LFM3-VL 2B** (LiquidAI) — character recognition / OCR (handwriting + scans)
- **Phonon-2.5** (FermionResearch) — speech recognition (voice following)

Local STT model used for transcription:
- `/Users/sharath/.cache/fermion/speech/FermionResearch__Phonon-2.5-English/model_phonon25_en_pen2u1125_int6`

---

## Step 1 — Transcription (Phonon-2.5, word-level timestamps)

1. Extracted 16 kHz mono WAV from the source:
   ```
   ffmpeg -i video-without-subs.mov -vn -ac 1 -ar 16000 -acodec pcm_s16le work/audio.wav
   ```
2. Ran Phonon-2.5 transcription locally via the `fermion` CLI (repo `.venv`):
   ```
   .venv/bin/python3.12 -m fermion.cli transcribe <model-dir> work/audio.wav --json --verbose
   ```
   Output: `work/transcript.json` — 9 segments, 37.66 s audio, 0.54 s decode, word-level start/end for every word.

3. Draft transcript (raw, before corrections):
   > "Whenever I try to read something off the screen, I sewn out and I forget the line I just read. So I build this app, it supports PDF text files, images of writings such as this, and it keeps track of whatever you are reading, the line you are reading and the next line you are supposed to read. It uses LFM3VL by Liquid A for character recognition and phone on 2.5 by Fermion Research for speech recognition and it's fully private, none of your documents ever leave the system. And if you want to try it out, the link is in the description."

4. Reviewed likely STT errors with the user (guide flags names/numbers for checking). All three confirmed:
   | Raw | Corrected | Reason |
   |-----|-----------|--------|
   | "sewn out" | "zone out" | Context: losing place while reading on screen |
   | "Liquid A" | "LiquidAI" | Company behind LFM3-VL is LiquidAI |
   | "phone on 2.5" | "Phonon-2.5" | FermionResearch speech model name |
   | "Fermion Research" | "FermionResearch" | Brand styling |

5. Produced corrected caption files:
   - `work/subs_corrected.srt` (segment timing)
   - `work/subs_corrected.ass` (styled: Arial 44, white, black outline, bottom-safe)
   - `work/segments.json` (machine-readable segment list used by later scripts)

---

## Step 2 — First export: soft-captions MP4

Burned subs were not possible with this ffmpeg build (no libass/`drawtext`/`subtitles` filters), so soft captions were used instead:

```
ffmpeg -i video-without-subs.mov -i work/subs_corrected.srt \
  -map 0:v -map 0:a -map 1 \
  -c:v libx264 -crf 23 -preset fast -pix_fmt yuv420p \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
  -c:a aac -b:a 192k -c:s mov_text -movflags +faststart -shortest \
  exports/video-with-subs.mp4
```

Result: `exports/video-with-subs.mp4` — 1920×1080, H.264 + AAC + embedded `mov_text` soft-caption track, faststart, ~37 s, 3.4 MB. Verified by round-tripping the subtitle track back to SRT.

---

## Step 3 — Tighter cut (jump-cut dead air)

Trimmed each spoken segment, removing inter-segment gaps/filler (per guide: cut dead air, keep natural pauses), then concat:

- Per-segment trim: `-ss <start> -to <end>` with 1920×1080 letterbox/pad → `work/seg_00.mp4` … `seg_08.mp4`
- Concat with `-f concat -safe 0 -c copy` → `work/cut.mp4`
- Result: 37.7 s → **36.3 s**, audio synced (`-c copy`), 16:9 @1080p

---

## Step 4 — Burned-in subs + TikTok style (PIL pipeline)

Since ffmpeg lacks text-rendering filters, wrote `work/burn_subs.py`: a Python/PIL frame pipeline that decodes `work/cut.mp4`, draws each caption + model callout chip, and re-encodes only video (audio copied unchanged via `-c:a copy`).

- Captions: bold Arial/Verdana ~60 px, white with black outline/stroke, bottom-center, word-synced per segment
- Model callout chips (dark rounded rect, white text) appearing when each model is mentioned:
  - `LFM3-VL · LiquidAI — character recognition`
  - `Phonon-2.5 · FermionResearch — speech recognition`
- Output: `exports/video-tiktok.mp4` — 1920×1080, H.264 + AAC, 36.3 s, faststart, ~4.3 MB. Aspect ratio kept at 16:9 (not forced vertical) per user request.

No music/SFX added — no rights-cleared track provided; per the guide, kept voice-only rather than risk unlicensed/distracting audio.

---

## Step 5 — HyperFrames variations (5 styles)

Built `work/build_hf.py` generating 5 HyperFrames projects under `hf/v1` … `hf/v5`, rendered with `npx hyperframes render --quality looks`:

| Version | Style | File | Size | Duration |
|---------|-------|------|------|----------|
| v1 | CLEAN PRODUCT | `exports/read-along-v1.mp4` | 30 MB | 35.7 s |
| v2 | TIKTOK PUNCH | `exports/read-along-v2.mp4` | 32 MB | 35.7 s |
| v3 | CINEMATIC | `exports/read-along-v3.mp4` | 31.5 MB | 35.7 s |
| v4 | TECH HUD | `exports/read-along-v4.mp4` | 34.4 MB | 35.7 s |
| v5 | HYPE | `exports/read-along-v5.mp4` | 31.4 MB | 35.7 s |

Also produced a comparison contact sheet: `exports/read-along-variations.jpg` (4 timestamps × 5 variants).

Timing patches were applied to `build_hf.py` for caption sync (`data-start`/`data-duration` adjustments, tighter fade-out).

---

## Step 6 — X (Twitter) launch post

Drafted an X post + 4-tweet thread for the Read Along launch. Main post (279 chars, under limit):

> I zone out reading on screens and lose my place. So I built Read Along — a Mac app that follows your voice and highlights the line you're on + the next.
>
> PDFs, text files, handwriting photos. 100% on-device: LFM3-VL 2B (LiquidAI) + Phonon-2.5 (FermionResearch).
>
> Link in reply ↓

Recommended attaching `exports/read-along-v2.mp4` (TikTok Punch) and putting the link in the first reply. Hashtags and model-lab tagging left out pending correct handles.

---

## Files intentionally NOT committed (all deleted/untracked)

The following were generated during this session and removed so nothing video-related lands in Git:

- `exports/` — all MP4 exports, JPG contact sheet, SRT
- `hf/` — HyperFrames project variants v1–v5
- `work/` — all intermediate scripts, audio, cuts, segments, frames, snaps
- `video-without-subs.mov` — 85 MB source recording

None of the above were ever `git add`ed. `git status` shows them as untracked only.

---

## How to re-create

1. Place a new source at `video-without-subs.mov`.
2. Extract audio → `work/audio.wav` (ffmpeg, 16 kHz mono).
3. Transcribe with Phonon-2.5 (`fermion transcribe <model> work/audio.wav --json`).
4. Correct names/numbers in the transcript.
5. Build captions (SRT/ASS) and/or burn in with PIL (`work/burn_subs.py` pattern) or HyperFrames (`work/build_hf.py` + `npx hyperframes render`).
6. Export 1920×1080 H.264 + AAC with `-movflags +faststart`; upload MP4 + SRT to YouTube/TikTok.
