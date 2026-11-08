# Read Along — public announcement draft

This is copy you can paste to X/Twitter, Reddit (r/SideProject, r/ShowMeYourApps,
r/macOS, r/indiemacapps), Mastodon, etc. It reflects the repo as of the
cleanup pass (README, LICENSE, CONTRIBUTING added; scratch images removed).

## The one-liner

Read Along: read a handwritten page or PDF aloud, and a local voice follows
along word by word with amber/blue boxes right on the source page. Mac only,
Apple Silicon, everything runs on-device — no account, no cloud.

## X / Twitter draft (280-ish chars)

Built Read Along, a macOS app that reads your handwritten pages and PDFs aloud
with a live reading guide on the source page.

• Amber box = phrase you're on, blue = next
• Follow your voice (local speech) or read-to-me (macOS voices)
• Handwriting via LFM3-VL, print via Vision — all on-device
• No account, no cloud, Apple Silicon only

ReadAlong-1.0.0.dmg → github.com/<you>/read-along/releases

#macOS #indiedev #accessibility #ocr

## Reddit / Show HN draft

Title (r/SideProject or r/ShowMeYourApps): "Read Along — read handwritten pages
and PDFs aloud, with a local voice that follows word by word on the source
page (macOS, Apple Silicon, fully offline)"

Body:

> Hey everyone — I built Read Along, a macOS app for reading handwritten pages
> and PDFs aloud with a live reading guide.
>
> The hook: instead of reflowing OCR text into a plain list, the amber/blue
> highlight boxes are drawn on the real source page (photo or PDF). Press
> "Follow me" and read aloud; a local Phonon-2.5 speech engine streams the mic
> and a monotonic fuzzy aligner moves the cursor word by word — skipped lines
> and misread words don't throw it off, it re-anchors to a nearby line.
> "Read to me" uses an installed macOS voice instead.
>
> Everything runs on this Mac: OCR (LFM3-VL for handwriting, macOS Vision for
> print), speech, your library. No account, no cloud, nothing leaves the
> machine. Apple Silicon, macOS 14+, DMG download.
>
> It started because I wanted something that actually follows *your* voice on
> *the actual page* — there's a real gap for low-vision / dyslexic readers who
> need to see the source while it's read to them.
>
> Download: github.com/<you>/read-along/releases
> Source: github.com/<you>/read-along
>
> Feedback welcome — especially on handwriting accuracy and the mic feel.

Key angles that landed in similar launch threads (from research):
- Personal story ("I built this because…") performs better than a feature list.
- Name the constraint up front: macOS only, Apple Silicon, English-only.
- Lead with the differentiator: highlight on the source page, not reflowed text.
- Mention "no account / local-only" — it's a strong hook after cloud apps.
- Post to r/SideProject, r/ShowMeYourApps, r/macOS, r/indiemacapps; r/Blind and
  r/Dyslexia only if you frame it as an accessibility tool, not a promo.

## Where similar apps launch (researched)

- r/SideProject — Narro Reader, Texcerpt, ReadToMe, Audiory readalong mode
- r/ShowMeYourApps / r/ShowYourApp / r/Appstore — iOS/macOS app showcases
- r/macOS, r/indiemacapps — Mac-native audience
- r/Blind, r/Dyslexia — accessibility need ("apps to read aloud writing on paper")

## Naming note

"Read Along" collides with Google's Read Along (a children's literacy app).
The repo and bundle ID are `com.sharathkrml.readalong`, and the visible name is
"Read Along". Consider a disambiguating subtitle ("Read Along for Mac") or a
distinct App Store name before launch to avoid confusion.

## Release checklist

- [ ] `make dmg` builds cleanly on Apple Silicon
- [ ] DMG notarized + stapled (or document the Gatekeeper right-click→Open step)
- [ ] README screenshots added (library / original / split / follow me)
- [ ] LICENSE + CONTRIBUTING present ✓
- [ ] `make test` passes
- [ ] `ARCHITECTURE.md` matches the current code (it does after this pass)
