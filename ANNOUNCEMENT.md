# Read Along — public announcement kit

Repo: https://github.com/sharathkrml/read-along

This is the copy to paste when the repo goes public: GitHub metadata, one post
per platform, and a short thank-you to send after launch. Every claim below is
true of the current build.

## GitHub repository description

**Primary (250 chars, under GitHub's 350 limit):**

> Read handwritten pages and PDFs aloud with a local voice that follows along
> word by word, highlighting the words on the real page. macOS, Apple Silicon,
> fully on-device. No account, no cloud, no telemetry.

**Short alternative:**

> A macOS reader that follows your voice word by word on the real page. On-device
> OCR and speech, no account, MIT.

## GitHub topics

Paste these into the repo's **About → Topics** (GitHub allows 20):

```
macos, macos-app, swiftui, python, apple-silicon, mlx, ocr,
handwriting-recognition, speech-recognition, text-to-speech, tts, pdf,
pdf-reader, accessibility, on-device, local-first, offline, privacy,
read-along, dyslexia
```

## The one-liner

Read Along: read a handwritten page or PDF aloud, and a local voice follows
along word by word with amber/blue boxes right on the source page. macOS, Apple
Silicon, everything on-device — no account, no cloud.

## X / Twitter

> Read Along is open source: a macOS reader that follows your voice word by
> word — on the real page, not a reflowed copy.
>
> Amber = now, blue = next. Handwriting OCR and speech run on-device.
> MIT, Apple Silicon, no account.
>
> github.com/sharathkrml/read-along

Hashtags, if you want them: `#macOS #indiedev #accessibility #OCR`

## Show HN

**Title (79 chars):**

> Show HN: Read Along – a macOS reader that follows your voice on the source page

**Body:**

> I built Read Along because I kept losing my place while reading. It imports a
> PDF or a photo of a page, and as you read aloud a local speech model tracks
> where you are, word by word.
>
> The differentiator: the highlight is drawn on the original page — the real
> photo or PDF page, not reflowed text. An amber box is the phrase you're on, a
> blue box is the next one, and the page turns itself at a page boundary. There
> is also a "Read to me" mode that uses an installed macOS voice.
>
> The alignment is a monotonic fuzzy match over the script. It only advances on
> exact word matches, so OCR mistakes and misheard words don't derail it; if you
> skip a line it re-anchors to a nearby one. Handwriting OCR is LFM3-VL;
> printed text uses macOS Vision, and text-layer PDFs skip OCR entirely.
>
> Everything runs on the Mac. The models download once (~1.7 GB); after that
> there is no network use, no account, and no telemetry. It is Apple Silicon
> only because the models run on MLX.
>
> It is MIT, native SwiftUI, with a Python backend. Known limits: English-only
> speech, heuristic word boxes on handwriting, and no notarized build yet.
>
> Repo and DMG: https://github.com/sharathkrml/read-along
>
> Feedback welcome, especially on handwriting accuracy and how the mic tracking
> feels while reading.

## Reddit (r/SideProject, r/ShowMeYourApps, r/macOS, r/indiemacapps)

**Title:**

> Read Along — read handwritten pages and PDFs aloud, with a local voice that
> follows word by word on the source page (macOS, Apple Silicon, fully offline)

**Body:**

> Hey everyone — I built Read Along, a macOS app for reading handwritten pages
> and PDFs aloud with a live reading guide.
>
> The hook: instead of reflowing OCR text into a plain list, the amber/blue
> highlight boxes are drawn on the real source page (photo or PDF). Press
> "Follow me" and read aloud; a local Phonon-2.5 speech engine streams the mic
> and a fuzzy aligner moves the cursor word by word — skipped lines and misread
> words don't throw it off, it re-anchors to a nearby line. "Read to me" uses an
> installed macOS voice instead.
>
> Everything runs on this Mac: OCR (LFM3-VL for handwriting, macOS Vision for
> print), speech, and the library. The models download once, then nothing
> leaves the machine. No account, no cloud. Apple Silicon, macOS 14+, DMG
> download, MIT source.
>
> It started because I wanted something that actually follows *your* voice on
> *the actual page* — there's a real gap for low-vision and dyslexic readers who
> need to see the source while it is read to them.
>
> Download and source: https://github.com/sharathkrml/read-along
>
> Feedback welcome — especially on handwriting accuracy and the mic feel.

If you post to r/Blind or r/Dyslexia, frame it as an accessibility tool and ask
for feedback rather than dropping a promo link.

## Mastodon / LinkedIn

> Read Along is now open source (MIT). It reads handwritten pages and PDFs aloud
> and follows your voice word by word — amber box for the phrase you're on, blue
> for the next — drawn on the real page, not a reflowed copy.
>
> Handwriting OCR, speech, and your library all stay on the Mac. Apple Silicon,
> macOS 14+. No account, no cloud, no telemetry.
>
> https://github.com/sharathkrml/read-along

## Thank-you post (after launch)

> Thank you to everyone who downloaded Read Along, filed an issue, or sent notes
> on handwriting accuracy and the microphone feel. The first release is out, the
> repo is open, and the feedback is already shaping what comes next.
>
> If you tried it: the most useful thing you can send is a page it misread, plus
> what the highlight did. Issues are open:
> https://github.com/sharathkrml/read-along/issues

## Before you post

- [ ] **Publish a release.** There is no DMG on the Releases page yet, and the
      README's download link points there. Run `make dmg` and upload
      `dist/ReadAlong-1.0.0.dmg`.
- [ ] **Add screenshots.** Take four (library, Original, Split, Follow me) and
      put them in `docs/`; `.gitignore` now allows `docs/*.png`. Add a
      `## Screenshots` section near the top of the README.
- [ ] **Decide on repo clutter.** `ocr-pdf.pdf` (12.7 MB), the internal
      `UI-style-remap.md` / `UI-remap-handoffs.md` notes, and tracked
      `macapp/.build/` artifacts are all in the public repo today.
- [ ] **Notarize** the DMG, or keep the README's Gatekeeper right-click → Open
      instructions and say "not notarized yet" in the post.
- [ ] **Set the About panel** with the description and topics above.
- [ ] Run `make test` and `make dmg` once more on a clean checkout.

## Naming note

"Read Along" collides with Google's Read Along (a children's literacy app). The
repo and bundle ID are `com.sharathkrml.readalong`, and the visible name is
"Read Along". Consider a disambiguating subtitle ("Read Along for Mac") or a
distinct App Store name before launch to avoid confusion.
