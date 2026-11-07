# UI style remap — Read Along

> A complete visual and interaction redesign, with an executable handoff for smaller coding models.

**Date:** 7 November 2026  
**Status:** Plan only. No application changes have been implemented or verified by this document.  
**Repository:** `/Users/sharath/Documents/Github/read-along`  
**Audit baseline:** working tree based on `0c19a12`, including the current uncommitted native SwiftUI implementation.  
**Audience:** an implementing engineer or a coding model such as DeepSeek or GLM. Read the execution contract before taking a task.

## Contents

1. [Outcome and locked decisions](#1-outcome-and-locked-decisions)
2. [Execution contract for implementation agents](#2-execution-contract-for-implementation-agents)
3. [Current-state audit](#3-current-state-audit)
4. [Visual design system](#4-visual-design-system)
5. [Application layout and information hierarchy](#5-application-layout-and-information-hierarchy)
6. [First launch, onboarding, and model downloads](#6-first-launch-onboarding-and-model-downloads)
7. [Import, processing, and library](#7-import-processing-and-library)
8. [Reading, playback, and pointer behavior](#8-reading-playback-and-pointer-behavior)
9. [PDF and image viewer specification](#9-pdf-and-image-viewer-specification)
10. [Text, split, focus, correction, and export](#10-text-split-focus-correction-and-export)
11. [Settings, commands, accessibility, and feedback](#11-settings-commands-accessibility-and-feedback)
12. [Performance targets](#12-performance-targets)
13. [Shared implementation contracts](#13-shared-implementation-contracts)
14. [File map and test strategy](#14-file-map-and-test-strategy)
15. [Implementation task cards](#15-implementation-task-cards)
16. [End-to-end acceptance matrix](#16-end-to-end-acceptance-matrix)
17. [Release gates, exclusions, and handoff template](#17-release-gates-exclusions-and-handoff-template)

---

## 1. Outcome and locked decisions

### 1.1 Product direction

Make Read Along feel like a **calm, premium reading instrument**, not an OCR debugging utility or a collection of default macOS controls.

The recommended direction is **Paper & Ink**: warm, quiet reading surfaces; deep graphite dark mode; excellent typography; an amber reading marker; compact, deliberately composed controls; and restrained native materials around the content. Modernity should come from hierarchy, proportion, precision, and dependable interaction—not glass on every surface or decorative animation.

The experience must answer four questions immediately:

1. What can I open, and what will happen to my file?
2. Do I want the app to read to me, follow my voice, or simply let me read quietly?
3. Where am I in this document, and how do I get somewhere else?
4. If the app is waiting or cannot continue, what exactly can I do next?

### 1.2 Required outcomes

- A recognizable, cohesive design in light and dark appearances, across the main window, setup, settings, sheets, errors, and focus mode.
- A useful first session without compulsory model downloads or a microphone permission prompt.
- Truthful, contextual model setup with live progress, retry, cancellation where supported, and clear consequences when removing a model.
- A proper PDF/image viewer: zoom in/out, zoom percentage, fit page, fit width, actual size, trackpad magnification, panning, previous/next page, go to page, and page thumbnails.
- Arrow-key page navigation that works in the viewer without breaking typing, text selection, or standard Mac keyboard behavior.
- A reading marker that follows actual speech/narration events, in both the recovered text and original document.
- Manual browsing that does not secretly move the reading position or fight automatic following.
- Reliable seeking, pause/resume, voice/speed changes, page transitions, partial-document processing, and end-of-document behavior.
- Safe text correction and honest export feedback; no lost drafts, silent file-write failures, or unnecessary position resets.
- Keyboard access, VoiceOver support, readable contrast, reduced-motion/transparency support, and performance verified on real Mac hardware.

### 1.3 Locked architectural decisions

| Decision | Required implementation direction |
| --- | --- |
| Application platform | Stay native: SwiftUI shell, AppKit text/scrolling, AVSpeechSynthesizer, PDFKit for PDFs when the geometry verification gate passes. |
| Processing | Keep the existing Python OCR, alignment, document workspaces, model cache, and local speech pipeline. This is not a native-engine rewrite. |
| Reading cursor | Keep one authoritative logical reading position. Browsed pages, zoom, and scroll positions are separate viewport state. |
| Narration timing | Continue using actual AVSpeechSynthesizer UTF-16 range callbacks. Never advance words on a timer. |
| Voice following | Continue using the existing speech aligner. Do not replace its algorithm as part of a visual redesign. |
| Pointer meaning | “Pointer” means the in-document word/phrase marker. Never move or hijack the operating-system mouse pointer. |
| Quiet reading | Reading with playback stopped requires no third audio engine or speculative eye tracking. Explicit clicks/commands move the marker. |
| Downloads | Do not download either model without a clear user action. Do not claim every scan needs the large model. |
| Persistence | Preserve bundle ID, data locations, managed documents, corrected text, model caches, and existing preferences. |
| Dependencies | Use installed dependencies and Apple frameworks. No web wrapper, animation package, UI kit, database, or downloader package is required. |
| Compatibility | Keep Apple Silicon and macOS 14 as the baseline. macOS 26 visual enhancements must be availability-guarded and optional. |
| Scope | No accounts, cloud sync, telemetry, gamification, generic plugin architecture, or unrelated rewrite. |

---

## 2. Execution contract for implementation agents

This section is mandatory context for every task card. An agent may read only this section, the shared contracts in section 13, and its assigned card plus referenced design sections; it must not need the preceding conversation.

**Path shorthand in task cards:** Swift file basenames refer to `macapp/`, native checks to `macapp/Tests/`, Python test basenames/`readalong.py`/`Makefile` to the repository root, and `scripts/...` paths are literal. Use heading searches to read just the relevant sections/cards rather than loading this entire long handoff into every small-model context.

### 2.1 Before editing

1. Confirm that the session is in an implementation-capable agent/mode. **If still in Plan mode, do not implement; ask the user to switch agents.**
2. Read `git status --short`. The audit baseline already contains substantial user work, including untracked `macapp/*.swift` files and a deleted historical `macapp/main.swift`. Do not restore the old file, reset the tree, or overwrite unfamiliar changes.
3. Read the named source files and grep all callers of any function whose behavior changes. Symbol names are more reliable than the line numbers in an old audit.
4. Check the card's dependencies by inspecting code and running the relevant checks. An unchecked card is not magically implemented because this plan describes it.
5. Identify data and compatibility effects before editing: saved position, corrected text, source geometry, preferences, background tasks, and existing API callers.
6. If the repository has evolved beyond this plan, preserve the newer working behavior and record the discrepancy. Do not reconstruct the audit snapshot.

### 2.2 How to execute a card

- Work on **one card at a time**. Keep the change bounded to its goal and listed files; add a narrowly related file only when necessary and explain it.
- Reuse the existing application layers. Do not create a repository/service/coordinator/protocol hierarchy to implement a small view change.
- Each new nontrivial branch, state transition, parser, geometry transform, or cancellation path needs a focused test or assert-based self-check.
- Do not add dead buttons, simulated processing, timer-driven narration, fake document thumbnails, fabricated confidence, or unsupported “Pause download” controls.
- Do not claim a command passed unless it was actually run. Distinguish source review, automated checks, visual inspection, listening, and hardware validation.
- Do not run real model downloads, remove real models, overwrite user documents, or start the microphone merely to make a test pass. Use isolated fixtures; get user authorization for physical interaction or expensive network tests.
- Finish the shared behavior and every caller the task changes. Updating just the main player while leaving focus mode or menu commands inconsistent is incomplete.
- End the handoff with changed files, checks run, unresolved issues, and the next safe card.

### 2.3 Independent execution does not mean unsafe parallel edits

The cards are independently understandable, **not all concurrently executable**. Many touch `ReaderModel.swift` or `readalong.py` and must be integrated in dependency order. Do not have two agents independently replace those files. Parallel work, branches, worktrees, or subagents should be used only when the user authorizes them and file ownership is explicit.

### 2.4 Definition of done for a card

- Its acceptance criteria pass, including the failure/edge cases.
- No unrelated features or broad formatting changes are bundled into the diff.
- Existing document data and existing preferences still load.
- New UI labels, menu commands, accessibility labels, and shortcuts agree.
- Automated checks are run where available; unrun physical checks are clearly listed.
- The handoff records any deliberate limitation. A known code limitation uses `shortcut: <limit>, <when to upgrade>` where relevant.

---

## 3. Current-state audit

### 3.1 What was inspected

All current application Swift files in `macapp/` were read, including the app lifecycle, sidebar, content layout, page viewer, AppKit reader, player, presentation view, setup card, settings, editor, speech controller, API client, state model, and backend process owner.

The audit also inspected the relevant parts of `readalong.py`: ingestion, PDF rendering, OCR selection, partial publication, model downloads/removal, library persistence, reading state, microphone lifecycle, correction, export, HTTP routes, and startup. `test_align.py`, `test_library.py`, `Makefile`, packaging scripts, `Info.plist`, entitlements, the icon source, and both repository screenshots were reviewed.

**Evidence limit:** this is a source-and-existing-assets audit, not a fresh interactive run. The screenshots capture different revisions. The older light screenshot is not proof of the latest native layout. The dark `pdf-text-mismatch.png` is useful evidence of crowding, viewport clipping, and a historical text/box mismatch; the latest OCR fixes must be checked before declaring that exact mismatch still present.

`README.md`, `ARCHITECTURE.md`, and `TODO.md` contain historical browser/WKWebView/wizard descriptions that no longer match all current behavior. The current `macapp/*.swift` and Python routes take precedence. Do not port a nonexistent `index.html` or resurrect the removed browser UI.

### 3.2 Before / after audit

Priority definitions: **P0** = correctness, safety, or trust blocker; **P1** = required redesign behavior; **P2** = optional refinement after the requested experience works. Accessibility and data safety are never optional polish.

| ID / priority | Before: current implementation or source-derived risk | After: required outcome | Evidence / owner |
| --- | --- | --- | --- |
| A01 / P1 | System backgrounds, standard toolbars, dense rows, and unrelated surface treatments have no shared design vocabulary. | One token-driven Paper & Ink design, consistent spacing, typography, contours, and control states. | All views; new `ReaderTheme.swift`. |
| A02 / P1 | Toolbar exposes view switching, Present, Edit, Export, Import, and Settings together. | Prioritize document identity, view choice, find, reading appearance, and Focus; move secondary document actions into a labeled menu. | `ContentView.swift`, `ReadAlongApp.swift`. |
| A03 / P0 | Startup copies a bundled sample into the legacy workspace; `DocumentStore` can migrate it immediately. The setup card requires an empty library, making a genuine first-run welcome unreliable. | A new installation opens a real welcome/empty state. Sample import happens only after “Try a sample.” | `readalong.py: main`, `DocumentStore._migrate_legacy`; `PlaceholderView.needsSetup`. |
| A04 / P0 | `primeMicrophone()` requests permission during application launch. | Explain and request permission only after the user chooses to start Follow me; still ask from the native host, not the Python helper. | `ReadAlongApp.swift`, `BackendService.swift`. |
| A05 / P0 | Continuous setup polling exists in `SettingsView`, not in the initial `SetupCard`. | A single model-status owner supplies live progress everywhere, including contextual setup and the sidebar activity indicator. | `SettingsView.swift`, `SetupCard.swift`, `ReaderModel.swift`. |
| A06 / P0 | Model-removal copy says Read to me and Follow me keep working without the model; both cards observe any nonnil removal key. | Model-specific consequences and one correctly targeted confirmation. Removing speech explicitly disables Follow me until reinstalled. | `SettingsView.swift: ModelCard`. |
| A07 / P0 | Model readiness is inferred from a few files; progress is estimated from cache files; no cancellation route exists. | Verify complete usable artifacts before Ready, label approximate progress honestly, and expose cancellation only after a real backend implementation exists. | `readalong.py: Models`, `_speech_dir`, `_ocr_dir`, `Handler`. |
| A08 / P1 | `PageView` is a fitted raster inside SwiftUI scrolling; it has no explicit magnification, zoom percentage, fit modes, or panning affordance. | A native zoomable source viewer with persistent, discoverable controls. PDFs remain crisp through vector rendering when feasible. | `PageView.swift`, new source viewer adapter. |
| A09 / P0 | `setPage()` changes the reading cursor while browsing. `manualPage` can remain pinned as speech advances. | Separate browsing from seeking. Automatic following can advance pages, while manual browsing holds only the viewport until “Return to reading.” | `ReaderModel.swift: setPage`, `displayPage`, `jump`. |
| A10 / P1 | There are page arrow buttons but no native responder implementation for the expected bare arrow-key page navigation. Historical README instructions describe different behavior. | Focus-aware Left/Right page switching in the source viewer, with documented phrase shortcuts and no interference with editors. | `ReadAlongApp.swift`, `PageView.swift`; no key handler found in native views. |
| A11 / P1 | Original-page highlights are not hit-testable; text supports click-to-jump. | Click a real word box in either representation to seek. Blank whitespace, dragging, and text selection must not accidentally seek. | `PageView.swift: overlayCanvas`, `ReaderTextView.swift: JumpTextView`. |
| A12 / P0 | Source scrolling recenters on every highlight-identity change. Text scrolls on every update, with no manual-browsing policy. | Keep the marker in a comfortable band; suspend following on manual scrolling and provide a clear return action. | `PageView.swift`, `ReaderTextView.Coordinator`. |
| A13 / P0 | Text render identity uses counts, font, and size—not document identity or content revision. Same-count documents/edits can leave stale content. Rebuilds do not consistently invalidate highlight signatures. | Render keys include document identity and revision; all content rebuilds reapply highlights and preserve sensible viewport/selection state. | `ReaderTextView.swift: ReaderContent.renderKey`, `Coordinator.rebuild`. |
| A14 / P0 | Quiet library refresh replaces rows only when IDs/order/active ID change, so progress/status/title metadata can remain stale. | Compare the payload's actual metadata and update only changed rows without disruptive resorting. | `ReaderModel.swift: refreshLibrary(quiet:)`. |
| A15 / P0 | Reader progress uses `cursor + 1`; completed state can exceed 100%. Sidebar caps at 99%. Partially available words can appear to be the whole document. | A single bounded progress calculation; exact 0%/100%; explicit completion only after the document is fully ready. | `ReaderModel.swift: progressPercent`; `SidebarRow.progressPercent`. |
| A16 / P0 | Clicking a word or changing pages can leave the old narration queue running. Backward seek can conflict with the monotonic callback guard. | One shared seek operation invalidates stale callbacks, persists the intended position in order, and resumes only the correct active engine. | `jump`, `setPage`, `handleSpeechRange`, `movePhrase`. |
| A17 / P0 | Voice and speed changes stop narration, rather than applying the new choice at the same place. Focus-mode play icon treats paused narration as playing. | Predictable update/resume policy and one derived transport presentation shared by dock, focus mode, and menus. | `PlayerBar.swift`, `PresentView.swift`, `ReaderModel.swift`. |
| A18 / P0 | Partial OCR publication preserves a numeric global index. In mixed PDFs, adding an earlier page can shift the indices of text the user is already reading. | Rebase cursor and callback mappings through a page-local anchor; never jump to unrelated words when preceding pages become ready. | `readalong.py: App._run_ocr.set_model`; native narration mapping. |
| A19 / P1 | Once any words exist, processing detail largely disappears from the reader; blank, pending, failed, and unboxed pages have little distinct treatment. | Source preview remains available, page readiness is explicit, and processing/recovery remains visible without hiding readable content. | `ContentView.swift`, `ReaderState`, `PageInfo`, Python OCR jobs. |
| A20 / P0 | File data loading/base64 encoding occur from a main-actor model; multi-file drop silently takes the first URL; image picker accepts more types than the error copy promises. | Immediate import feedback, bounded supported types, preflight size validation, truthful single-file handling, and no heavy synchronous work on the UI path. | `ContentView.dropDestination`, `ReaderModel.importFile`. |
| A21 / P1 | Main player is a crowded full-width control strip. Source navigation floats separately above it. Only Text reserves explicit player clearance. | One composed reading dock, stable geometry, and layout-reserved space in every pane; document controls live beside the document. | `ContentView.swift`, `PlayerBar.swift`, `PageView.swift`. |
| A22 / P0 | Editor starts at page 0, reloads drafts on model changes, changes pages without protecting edits, and labels whole-document OCR as “Re-read Page.” | Open at the displayed page, protect drafts, make reprocessing scope truthful, and preserve reading location on save. | `EditSheet.swift`, `ReaderModel.reOCR`, `App.set_script`. |
| A23 / P0 | Correction resets the backend position to 0 and assigns old line boxes by ordinal, which can misplace boxes after line changes. | Preserve unchanged geometry; anchor corrected text safely; mark new/unmapped lines as unboxed rather than attaching incorrect geometry. | `readalong.py: App.set_script`. |
| A24 / P0 | Export paths use `try?` for file writing and can report success after a failed write. Native export is always a proof JPEG despite generic naming. | Explicit proof/current-highlight choices, propagated errors, atomic write where appropriate, and success only after the file exists. | `ReadAlongApp.exportPage`, `EditSheet.export`, `BackendClient.exportJPEG`. |
| A25 / P1 | Focus view nests a SwiftUI ScrollView around an AppKit scroll view; its apparent auto-hide behavior is hover-based, and black background does not explicitly establish dark text appearance. | One scroll owner, explicit stage colors, true idle-hide behavior, keyboard-safe controls, and exact restoration on exit. | `PresentView.swift`. |
| A26 / P0 | Backend errors can replace the whole app with raw log text; failed polls are silently ignored; Help opens the GitHub homepage. | Recoverable connection state with Retry, preserved context, optional sanitized details, and actual app help. | `BackendService.swift`, `FatalView`, `pollLoop`, app commands. |
| A27 / P0 | Custom icon controls have limited explicit accessibility, and native motion/transparency preference handling is absent from the custom views. | Named actions, logical focus, accessible reading controls, and complete appearance/accessibility variants. | All custom views and AppKit adapters. |
| A28 / P1 | Image refresh forces reload checks every poll; full text highlighting scans all spans per update; no native UI test harness exists. | Revision-keyed, bounded caching; incremental highlight updates; focused native assertions and visual/hardware regression coverage. | `ReaderModel.loadPageImage`, `ReaderTextView.applyHighlight`, `Makefile`. |

### 3.3 What should be retained

- Native text layout and selection instead of rebuilding a reader from thousands of SwiftUI word views.
- AVSpeechSynthesizer range events and the existing UTF-16 mapping.
- Existing alignment rules, normalization tests, page/word boxes, and layout-aware block metadata.
- Document workspaces and atomic library/cache writes.
- Existing local-only processing and optional downloads.
- Source-list navigation, native open/save panels, menu bar, traffic lights, and fullscreen behavior.
- The current model cache locations; do not force users to download weights again for a UI change.

---

## 4. Visual design system

### 4.1 Visual character

**Keywords:** editorial, quiet, precise, tactile, lightweight.  
**Avoid:** utility-panel gray everywhere, oversized serif headlines, microscopic metadata, gratuitous pills, double floating bars, neon gradients, repeated heavy shadows, custom traffic lights, and permanent glass behind reading text.

Use depth sparingly: app canvas → reading/source surface → transient controls. Content stays opaque and stable. Materials belong to sidebar/chrome/popovers/dock, not the text column itself.

### 4.2 Color tokens

Create a single small `ReaderTheme.swift` with semantic dynamic colors usable from both SwiftUI and AppKit. Do not scatter hex literals through views. Respect Increase Contrast and Reduce Transparency; native control selection should continue respecting the user's system accent.

The following are the recommended normal-contrast starting values, **not a substitute for native screenshot/contrast QA**:

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `canvas` | `#F3F2EE` | `#15171A` | Window reading workspace. |
| `surface` | `#FCFBF8` | `#1D2024` | Opaque reading surface/cards. |
| `surfaceRaised` | `#FFFFFF` | `#272B31` | Popovers, menus, elevated controls where material is not used. |
| `textPrimary` | `#22252A` | `#F1F0EB` | Reading text and primary labels. |
| `textSecondary` | `#62666F` | `#A6ADB7` | Metadata, read text, secondary labels. |
| `separatorDecorative` | `#DCDDD8` | `#3E444C` | Nonessential surface boundaries; not the sole indication of a control. |
| `readingFill` | `#F5DFA5` | `#554322` | Current phrase wash. |
| `readingInk` | `#50370A` | `#FFE4A4` | Text inside current phrase. |
| `readingStroke` | `#9A650B` | `#E8B95B` | Current marker edge/underline. |
| `nextPhrase` | Semantic system accent at low opacity | Same semantic treatment | Optional, subordinate next-phrase hint. |
| `success` / `warning` / `error` | Semantic system colors with labels | Adaptive equivalents | Status, never color-only meaning. |

Calculated sRGB contrast for the opaque starting pairs: primary/surface approximately **14.9:1 light / 14.3:1 dark**; secondary/surface **5.6:1 / 7.2:1**; reading ink/fill **8.5:1 / 7.6:1**. These numbers do not cover alpha compositing, PDF imagery, materials, disabled controls, or OS vibrancy.

Rules:

- Reading text remains at least 4.5:1 even when “past” or outside the guide. Do not make unread paragraphs illegibly faint to emphasize the current phrase.
- Active controls/focus indicators need a distinguishable shape/boundary, not just the low-contrast decorative separator.
- Increase Contrast strengthens control edges and removes reliance on translucent washes.
- PDFs/photos retain their original colors. Dark mode darkens the viewer surround, not the user's document pixels.
- The amber marker is a semantic reading color. It is not permission to recolor every native selection/toggle amber.

### 4.3 Typography

| Role | Recommended specification |
| --- | --- |
| Interface | SF Pro/system font; semantic text styles; 13–14 pt normal labels. |
| Document identity | 14–15 pt semibold in the toolbar; secondary metadata 12–13 pt. |
| Welcome title | 30–34 pt, restrained semibold, no giant marketing headline. |
| Reading body | 20 pt SF Pro for new users; comfortable 1.45–1.6 line height. Retain existing saved font/size choices. |
| Book style | New York/system serif as an optional reading choice, not a mandatory app-wide face. |
| Monospaced style | Preserve SF Mono for users who prefer it; do not use it as the default reader. |
| Recovered headings | Approximately 1.35–1.45× body size, capped around 36 pt in the ordinary reader. |
| Labels / rows / bullets | Respect block hierarchy, but scale with reading size. Do not leave label/value content fixed at 11/13 pt when body size grows. |
| Focus stage | Adaptive body around 32–44 pt, with explicit high-contrast colors and a restrained heading scale. |
| Numeric metadata | Monospaced digits for page number, percentage, and download bytes to prevent layout jitter. |

Provide a 16–32 pt reader range initially. Use `pt`, not `px`, in macOS settings. Size changes should preserve the current word's visual neighborhood and text selection where possible.

### 4.4 Spacing, contours, and depth

- Spacing scale: **4, 8, 12, 16, 24, 32, 48 pt**.
- Main pane gutters: 24–32 pt, reduced deliberately in narrow windows.
- Text measure: approximately 60–75 characters per line; usually a 640–720 pt column, not a hard cap that breaks split resizing.
- Sidebar: preferred width 256 pt; practical bounds approximately 208–320 pt; resizable and collapsible.
- Native compact controls: approximately 24–28 pt tall. Primary play control: approximately 32–36 pt, not an oversized mobile FAB.
- Corner family: 6–8 pt controls, 12 pt popovers, 14–16 pt cards, 18 pt dock. Original paper uses only a subtle 2–4 pt contour and must not clip document content.
- Hairlines align to display scale; avoid doubled separator borders where adjacent panes meet.
- One subtle shadow for genuinely elevated surfaces. No shadow around every row/button.
- Use SF Symbols at consistent size/weight. Supply labels, tooltips, and accessibility names; do not rely on unexplained glyphs.

### 4.5 Required component states

| Component | Normal | Hover / focus | Press / active | Disabled / unavailable | Error / busy |
| --- | --- | --- | --- | --- | --- |
| Toolbar action | Quiet icon/label. | Subtle backing; visible keyboard focus. | Immediate feedback, no delayed action animation. | Visible reason in help where useful. | Stable-sized progress/label; no jumping width. |
| Document row | Thumbnail/type + title + metadata. | Row backing and visible overflow action. | Clear system-accent selection. | Processing still selectable for preview. | Inline status/retry, not just an orange icon. |
| Play/listen | Clear primary action. | Label communicates Play/Resume/Listen. | Actual state reflected immediately. | A contextual setup action replaces a dead disabled button. | Preparing is cancellable; failures remain actionable. |
| Source control | Visible zoom/page affordance. | Tooltips explain shortcut. | Direct manipulation. | First/last page bounds are clear. | Page-load error includes Retry. |
| Model row | Capability + approximate size. | Details reveal location/licensing. | Download/Retry/Cancel as appropriate. | Removal disabled while unsafe, with explanation. | Honest phase, bytes, and persistent error. |

### 4.6 Motion policy

- Speech-driven word/phrase updates and repeated keyboard navigation are immediate. Do not bounce or animate a marker flying between lines/pages.
- Manual viewport-follow scrolling: short, interruptible 120–180 ms adjustment only when the marker leaves the comfort band.
- Popovers/inline panels: approximately 120–180 ms; native behavior first.
- Mouse-initiated larger pane transitions: at most approximately 180–220 ms; never block input.
- Page replacement: immediate when cached; optional very short opacity transition only if it does not flash during repeated navigation.
- Reduce Motion removes movement; color/static feedback remains. Reduce Transparency replaces materials with opaque semantic surfaces.
- Do not apply one broad `.animation` to the entire observable reading model.

---

## 5. Application layout and information hierarchy

### 5.1 Main reader

```text
┌ Native traffic lights / sidebar toggle ─ Document title ────────────────┐
│ Library                         │ Text  Original  Split   Find  Aa     │
│ Search documents                │                         Focus  More │
├─────────────────────────────────┼─────────────────────────────────────┤
│ Recent documents                │ Optional processing / recovery strip │
│ thumbnail  Title                ├─────────────────────────────────────┤
│            Page 3 · 24%          │                                     │
│ thumbnail  Another document     │    Comfortable text or source page   │
│            Recovering page 4    │                                     │
│                                 │    Source toolbar when applicable:   │
│                                 │    Pages ‹ 4 / 15 ›  − 125% +  Fit  │
│                                 │                                     │
│                                 │    [Return to reading] when browsing │
│                                 ├─────────────────────────────────────┤
│ Downloads · 1 active             │  Inset reading dock; space reserved  │
│ + Import Document                │  Mode  Previous  Play  Next  Options │
└─────────────────────────────────┴─────────────────────────────────────┘
```

This is structural, not an instruction to draw a second fake title bar. Use the actual native unified toolbar and traffic lights.

### 5.2 Toolbar hierarchy

1. Sidebar toggle and current document identity.
2. Text / Original / Split view choice, visible and labeled enough to discover.
3. Find and `Aa` reading-appearance popover.
4. Focus entry.
5. A labeled More/document menu containing Edit text, export choices, rename, and document details.

Import remains prominent in the sidebar/empty state and File menu. Settings remains in the app menu with `⌘,`; an additional quiet access point is acceptable, but it must not compete with core reading controls.

### 5.3 Reading dock

- Visually inset, with a restrained surface/material and a clear primary play/listen action.
- Structurally inserted using a layout inset, not painted over the last lines of text. Every reading pane, including Original and Split, must reserve its actual measured height.
- Mode at the leading edge; phrase transport centrally grouped; voice/speed or microphone settings placed in a compact options surface.
- A slim progress track and succinct position/time summary. Detailed word counts and diagnostics belong in an expanded view, not the permanent primary row.
- At compact widths, collapse secondary options into a popover before truncating primary actions. Do not horizontally squeeze every picker into the bottom strip.

### 5.4 Window and split behavior

- Keep a usable minimum around the existing 900 × 600 pt until verified otherwise.
- Prefer a default around 1280 × 820 pt, clamped to the current display's visible frame; restore a user's saved window frame instead of forcing this size every launch.
- Test at 900 × 600, 1100 × 700, 1280 × 800, and 1440 × 900 pt, plus fullscreen and macOS tiling.
- Split starts near 45% text / 55% source, with a visible, usable divider and remembered ratio.
- If the available detail width cannot support both panes, temporarily show the last focused pane and explain the width requirement. Do not silently overwrite the user's saved Split preference.
- Do not auto-collapse a user-chosen sidebar every time the window changes by a few pixels.
- Retain the current single active-reading-session architecture. Multiple independent playback windows are outside this redesign; do not introduce them without replacing the singleton/backend-active-document assumptions deliberately.

---

## 6. First launch, onboarding, and model downloads

### 6.1 Installation and launch

- The DMG, app icon, app name, welcome, and About screen use the same identity.
- Keep standard drag-to-Applications installation; avoid adding a custom installer.
- Public release should use the existing Developer ID/notarization path. Treat Gatekeeper workarounds as developer troubleshooting, not the intended onboarding experience.
- Show the native shell promptly while the backend starts. It must not be a full-window spinner for an unexplained minute.
- Startup copy: **“Opening your library…”** or **“Preparing the reading engine…”**, followed by actionable recovery if the engine fails.
- Restore the last document and reading position without automatically speaking or activating the microphone.
- If a file is opened from Finder, resolve that explicit intent before showing generic welcome content. File-open integration must go through the same validation/import path as the UI.
- If that explicit open arrives before backend readiness, retain one cancellable pending-open intent and consume it after readiness. Do not silently discard the URL because the client is still nil, and do not turn this into a batch queue.

### 6.2 One useful welcome, not a mandatory wizard

Suggested content:

> **Your words. Your pace.**  
> Open a PDF or photo. Listen with a moving reading guide, or read aloud and let the guide follow you.  
> **Import a document** · Try a sample  
> Your documents and voice are processed on this Mac. No account required.

- A small, honest two-mode explanation can sit beside a real sample preview: **Read to me** / **Follow me**.
- Do not show a large list of model names before the user chooses a task.
- Do not automatically insert sample documents into a new library. The sample must be a bundled text-layer PDF that works without model downloads.
- Welcome is dismissible; keyboard focus starts on the useful primary action, not a decorative carousel.
- Existing libraries do not get blocked by a new onboarding experience. Preserve the existing onboarding marker and treat a populated library as an experienced-user path.
- After the first successful document open, at most two dismissible inline hints explain the reading marker and “Return to reading.” Never repeatedly interrupt subsequent sessions.

### 6.3 Capability / download truth table

| User task | Large page-reading model | Speech-following model | Microphone permission | Internet after setup |
| --- | --- | --- | --- | --- |
| Open/read a PDF with usable text | No. | No. | No. | No. |
| Read to me from available text | No. | No. Uses an installed macOS voice. | No. | No, if the selected voice is already installed. |
| Recover a printed photo/scan through Vision | No, when Auto/Printed uses the existing Vision path successfully. | No. | No. | Normally no; account for a possible system model warm-up/resource requirement honestly. |
| Recover handwriting or a page requiring LFM3 | Yes, approximately 1.6 GB. | No. | No. | Required for the one-time download unless already cached. |
| Follow me on any readable document | Only if needed to obtain its text first. | Yes, approximately 158 MB, English-only currently. | Yes, at explicit start. | No after the required model is installed. |

Do not promise that all photos/scanned PDFs need 1.6 GB. Do not promise that a macOS voice not installed on the machine is available offline.

### 6.4 Contextual model setup

Show setup at the point of need:

- Starting Follow me without speech weights opens **“Set up voice following”**, not a disappearing error toast.
- A handwriting import that needs LFM3 opens **“Read handwriting on this Mac”**, while retaining the original-page preview and imported document.
- The user can continue reading other ready documents while a model downloads.
- Finishing a long download must not unexpectedly start the microphone. Offer **Start listening** as an explicit action.
- A pending import can continue after its dependency becomes ready only for the same document/job generation. It must not reopen a document the user has since left.

### 6.5 Model card anatomy

1. Human capability name: **Voice following** / **Handwriting recognition**.
2. One-line explanation of when it is needed.
3. Approximate download size and current status.
4. Primary action appropriate to that status.
5. Progress/phase and actionable failure, when applicable.
6. Secondary disclosure for technical model name, license, installation path, disk usage, and Reveal in Finder.

Technical model names remain available, but are not the primary vocabulary of onboarding.

Use a standard byte formatter with a consistent unit convention. The advertised 158 MB / 1.6 GB sizes are approximate decimal download sizes; do not silently mix MB/MiB, downloaded bytes, and installed disk usage in one supposedly exact number.

### 6.6 Download state table

| State | Visible treatment | Actions / rules |
| --- | --- | --- |
| Missing | “Not installed · about 158 MB” or “about 1.6 GB.” | Download; Not now. |
| Preparing | Explain connecting/checking storage without inventing a percentage. | Cancel only if real cancellation is available. |
| Downloading | Bytes and a determinate bar only when the measurement is meaningful; label approximate totals. | Continue using the app; Cancel if supported. No fake Pause button. |
| Verifying / installing | Separate phase; do not leave “100% downloading” frozen for a long unpack/load. | Keep work visible; do not declare Ready prematurely. |
| Ready | “Installed on this Mac” and installed size. | Use capability; Remove in secondary actions. |
| Interrupted / canceled | State that the app stopped the job and retained safe partial download data. | Retry; call it Resume only after resume behavior is tested. |
| Error | Plain-language reason with technical details disclosed separately. | Retry; storage/network recovery guidance; Not now. |
| Removing | Busy treatment scoped to this model. | Avoid duplicate actions; refuse while the model is actively needed. |

Implementation constraints:

- The speech downloader is a subprocess today; OCR download is a background thread. A Cancel label cannot simply hide UI while that thread keeps downloading.
- Prefer the installed library's supported cancellation/resume behavior. If it cannot interrupt safely, run only the download operation in a narrowly owned worker process, not a new download service/framework.
- Cancellation must stop the intended worker, retain resumable temporary artifacts, and never delete another model or unrelated Hugging Face cache.
- Check available storage with a conservative estimate that accounts for temporary/unpacked data. Present an estimate, not an invented exact space requirement.
- Verify the complete expected artifact set using the installed downloader/model metadata before Ready; a config and one partially written weight file are insufficient.
- Do not relocate caches in this redesign. Keep environment-variable overrides working.
- Use one status-poll owner while relevant UI/activity is visible; Settings and onboarding must not create independent perpetual loops.

### 6.7 Removing a model

- Speech removal: **“Remove voice-following model? Follow me will need another download. Read to me and your saved documents are not removed.”**
- Handwriting removal: **“Remove handwriting model? Saved recovered text remains available. Recovering handwriting again may require another download.”**
- Show the actual selected model name and estimated disk space freed.
- Refuse unsafe removal while a download or dependent job is active; explain how to stop that operation first.
- Scope confirmation to the selected model key. Two model cards must never simultaneously present the same global confirmation binding.

---

## 7. Import, processing, and library

### 7.1 Import entry points

Support the existing native picker, `⌘O`, a clear sidebar action, the empty-state action, and window-wide drag/drop. Add Finder Open With/file-open handling only through the same import function, not another ingestion pipeline.

- Display supported types and the current **25 MB** limit before the file fails.
- Match the picker and drop validator to actually supported file formats. Do not advertise HEIC, TIFF, or other ImageIO formats until that route is verified.
- Normalize photo EXIF orientation once at ingestion using existing image facilities, then use that same canonical orientation for managed source, OCR, preview, and hit testing. Do not rotate only the visible preview and leave word boxes behind.
- A locked/encrypted PDF needs a specific explanation. For the initial redesign, request an unlocked copy rather than inventing a password-storage/unlocking workflow or calling it a corrupt file.
- Highlight the drop target while dragging; explain rejection instead of accepting unsupported items and silently doing nothing.
- A multiple-file drop gets a clear “Choose one file at a time” response in this release. Do not silently drop every file except the first or invent a batch queue.
- Preflight size from file metadata, then validate content again at the backend trust boundary. A filename extension is not validation.
- Move potentially expensive file reads/base64 encoding off the immediate main-thread input path, without introducing a general concurrency rewrite.
- Stop/persist the old active playback deliberately before replacing the active document. Never let the old narrator continue controlling the new document's highlight.
- Preserve the user's original file; explain that Read Along keeps a managed copy.

### 7.2 Processing options

Expose a compact **Text recovery: Auto / Printed / Handwriting** choice in the import/details surface, with Auto recommended. Keep a global default in Processing settings, not Appearance settings.

- **Auto:** use the existing conservative printed-page detection and request the handwriting model only for pages that need it.
- **Printed:** fast Vision path; describe the handwriting accuracy tradeoff.
- **Handwriting:** existing LFM3 path; explain the optional model requirement.

Do not silently switch a failed handwriting page to a worse engine while calling it “best accuracy.” If the backend falls back, disclose reduced-quality recovery without blocking access to useful text.

### 7.3 Processing presentation

The source preview must remain accessible before OCR finishes. Text is not the only valid document state.

Suggested stage list, derived from real events:

1. Checking file.
2. Preparing pages.
3. Recovering text / preparing the selected engine.
4. Preparing reading positions.
5. Ready, or partially ready with continuing page work.

- Use an indeterminate indicator for stages without measurable totals.
- Show an actual physical page number when available: “Recovering page 8 of 20.” Existing `ocr_done/ocr_total` count OCR jobs, which is not always the same as physical pages in a mixed PDF; do not relabel those counters inaccurately.
- First-run Vision warm-up needs specific copy: **“Preparing Apple's text reader. The first use can take longer.”** Do not advertise an unconditional subsecond first run.
- Once a page is readable, let the user start there. Keep a compact processing strip visible while other pages finish.
- One OCR job at a time remains the initial limit. Another ready document can still be opened and read; a second import receives an explained busy state rather than an unimplemented queue.
- If cancellation is offered, distinguish Cancel import before processing from Stop after current page during a noninterruptible model call. Preserve already-ready pages and the managed source.

### 7.4 Page readiness

Represent **pending**, **ready with text**, **ready but no readable text**, and **failed** pages distinctly. “No words” is not enough to distinguish a blank illustration page from one still processing.

- Blank/image-only pages are viewable and navigable even if the reading cursor has no word on them.
- A pending page has a source preview and status; it is not a broken document.
- A failed page allows useful other pages to remain readable.
- Never draw invented word boxes where geometry is unavailable. Offer the recovered Text view and explain the limitation.
- Do not announce the end of the whole document merely because the available partial text currently ends.

### 7.5 Library anatomy

Each row contains:

- A real first-page thumbnail where inexpensive, with a type-icon fallback.
- Readable document title; long titles truncate with full-title help.
- Secondary line such as “15 pages · Last read today,” “Page 4 · 24%,” “Recovering page 4,” or a concise failure.
- A quiet completion/progress treatment, not several competing badges.
- A discoverable overflow action on hover/focus, plus the native contextual menu.

Required behaviors:

- Search titles/file names locally. No semantic search service.
- Stable recent-document ordering; do not reorder the list under the pointer on every progress poll.
- Current-row metadata updates when progress, processing, title, or status changes even if IDs are unchanged.
- Rename is validated inline for empty/overlong names, preserves the document ID, and does not discard the edit before an API error can be displayed.
- Deletion identifies the managed copy/cache being removed and clearly states that the external original is unaffected. Preserve confirmation unless a real recoverable Trash/undo implementation is added.
- Deleting the active document stops its playback and selects the next document safely; deleting an inactive one does not disturb current reading.
- A completed document shows **Completed**, not 99%. Reopening it does not automatically restart playback.
- No-files and no-search-results are different empty states with different actions.

---

## 8. Reading, playback, and pointer behavior

### 8.1 Three user intents, two audio modes

| Intent | Experience | What moves the marker |
| --- | --- | --- |
| Read quietly | Open content, adjust typography/zoom, browse freely, no active audio. | Explicit word click, phrase command, or reading-position scrub. The app does not guess silent reading speed. |
| Read to me | Chosen installed macOS voice reads from the current position. | Actual speech range callbacks, mapped through UTF-16 offsets to words. |
| Follow me | User explicitly starts listening and reads aloud. | Confirmed aligner updates from microphone speech. No animation clock predicts unheard words. |

Keep the existing Read to me / Follow me mode names throughout the app. “Read quietly” is the stopped/paused experience, not a third audio engine.

### 8.2 Marker hierarchy

- Current phrase: soft amber band/wash with a refined contour.
- Active spoken word: stronger underline/ink emphasis in Read to me, where an actual word boundary is available.
- Follow me: show the most recently confirmed position/phrase; do not imply exact per-word timing the ASR did not supply.
- Next phrase: subtle optional cue, weaker than the current phrase. Avoid equally loud amber and blue blocks competing for attention.
- Previously read text: readable secondary ink, not near-invisible gray.
- Missing source geometry: no fake precision; highlight recovered text and explain the original-page limitation.
- Completed state: clear the active speaking indication; do not leave the final phrase appearing permanently active.

### 8.3 One shared seek operation

Every path that intentionally changes the reading position must call the same model operation: text word click, source word click, previous/next phrase, Read from this page, progress scrub, find-result “Read from here,” and restart after completion.

Required sequence:

1. Capture the current document ID, model revision, audio mode, and actual active/paused state.
2. Invalidate the current narration generation before stopping/replacing an utterance; old callbacks must not modify the cursor.
3. Stop the active engine when needed, including a pending Follow me start. Keep paused sessions paused.
4. Apply the requested position locally for immediate response; reset any stale partial transcript/re-anchor context appropriately.
5. Persist the newest seek in order for that document. A late earlier request must not overwrite a later click.
6. Resume only if the user had an active run and the same document/mode/generation is still current. An idle click must not unexpectedly start speaking or recording.
7. Re-enable following for the explicitly selected reading destination. Do not conflate this with plain page browsing.

Do not duplicate this sequence independently in each view. Preserve the existing aligner's matching rules.

### 8.4 Automatic following versus manual browsing

Maintain independent following flags for the Text and Source panes, but one reading cursor.

- While following, keep the active line/box in a comfort band around 30–60% down the visible reading area, accounting for the dock. Do not recenter on every word.
- Manual wheel/trackpad scroll, panning, page browsing, or thumbnail navigation suspends following **for that pane**. Playback/listening may continue.
- In Split, browsing the source does not stop the text pane from following, and vice versa.
- Display a quiet **Return to reading** chip in the pane that was detached. Its action goes to the live reading location, not the previously browsed page.
- A deliberate seek from a word/phrase command updates the shared cursor and returns both panes to the chosen reading location.
- Programmatic scrolling must not be mistaken for manual input and disable itself.
- Resizing, zooming, or changing font must preserve a meaningful visual anchor rather than jumping to document origin.
- Manual browsing never writes a different reading position to the backend.

### 8.5 Read to me requirements

- Play begins at the exact selected word, not automatically at the start of its phrase/sentence. Existing stored positions must not be silently reinterpreted.
- Pause/resume retains position, selected voice, speed, and viewport.
- Coalescing position updates during speech is acceptable, but pause, stop, document switch, and application termination flush the exact current word before the backend is shut down. Do not rely on a fire-and-forget termination task to save the final position.
- Voice/speed changes while actively reading stop the old utterance safely, rebuild only the necessary remainder, and resume from the current word. If paused, remain paused with the new options ready.
- Show only installed voices as immediately usable. Provide a native route to manage/download system voices without claiming those downloads are app model downloads.
- A short voice preview is user-initiated and cannot speak over the active document; restore the prior paused/active state deliberately.
- Keep block-aware pauses for titles, bullets, paragraphs, and label/value rows. Do not regress layout-aware narration into one undifferentiated string.
- Mode change stops the previous engine before enabling the next one; no simultaneous app narration and microphone recognition of that narration.
- Late range/end/cancel callbacks from an older utterance or document are ignored.

### 8.6 Follow me requirements

The UI distinguishes:

1. Speech model unavailable.
2. Speech engine warming, without recording.
3. Permission explanation / permission request.
4. Ready to listen.
5. Starting microphone/stream.
6. Listening with actual level and recognized text.
7. Listening but not currently matching.
8. Stopping.
9. Recoverable error / permission denied / missing device.

- Permission is requested natively only after explicit intent; no prompt on ordinary launch/import.
- Show an unambiguous microphone-active indicator throughout capture, including while the app is waiting for matching words.
- Start-up must be cancellable. The existing `_want_listen` behavior can support cancellation; ensure the UI actually reaches it while preparing.
- Replace a permanent numeric confidence percentage with human guidance such as **Listening**, **Following your voice**, or **Can't find your place—click a word to continue**. Raw transcript/confidence belongs in expandable details.
- Quiet/no input, low alignment confidence, and disconnected microphone are different conditions. Do not label all three “Error.”
- A selected input device can disappear. Explain fallback and let the user pick another; never leave a stale selected ID pretending to be live.
- Refresh devices at meaningful times and on native device-change notifications where practical, not through an expensive permanent scan.
- Stop capture on explicit Stop, active-document deletion/switch, mode switch, and app termination. Sleep/interruption must leave a safe resumable state, not hidden recording.
- Speech following remains English-only until the engine changes; disclose this before download/use.

### 8.7 Partial documents and the end

- Global word indices can change when earlier scanned pages become ready. Preserve a `(document, page, page-local word offset)` anchor through model publication, then resolve to the new global index.
- Narration callbacks must resolve against the correct snapshot/revision. Appending pages must not cause words from an old queue to point at unrelated new content.
- Read to me proceeds through the next physically ordered ready pages. It must not silently skip an unprocessed page to read a later text-layer page.
- At a pending frontier, show **“Waiting for page 3…”**, not **“End of document.”** Keep the user's active-play intent cancellable. Resume only if the same explicit run remains active when the page becomes ready.
- Follow me may hold its marker at the known text boundary while displaying the pending-page condition; it must not fabricate progress. The user can stop listening or browse the source.
- Blank pages can be passed over for audio only when confirmed blank/without readable text, not while pending.
- Completion requires the full document to be in a final usable state and playback/alignment to reach the real end. Progress is bounded to 0–100%; partial-word availability is labeled provisional rather than shown as a finished document.

Completion UI:

> **Finished reading**  
> Your place is saved.  
> **Read again** · Back to library

Use a compact in-context state, not a celebratory full-screen takeover. No automatic next document or autoplay. Persist completion and show it consistently in the dock, title metadata, library, and next launch.

---

## 9. PDF and image viewer specification

### 9.1 Surface ownership

Use one `NSViewRepresentable` source-viewer seam. The public view consumes document identity, model revision, page/zoom/follow state, and action closures. SwiftUI chrome must not contain the coordinate math or independently drive a second scroll view.

Recommended backing:

- **PDF:** `PDFView` / `PDFDocument` for vector rendering, native page geometry, selection where appropriate, and thumbnails. OCR/alignment still comes from the existing backend; PDFKit does not replace extraction/reading order in this project.
- **Image:** `NSScrollView` with a magnifiable document view containing the managed high-resolution source plus the same normalized overlay geometry.
- Read the managed source through a narrowly scoped document-source route; do not ask for arbitrary filesystem paths or fetch it every poll.

**Geometry gate before adoption:** verify the same OCR boxes on normal, cropped, rotated, landscape, and mixed-size PDF pages. If PDFKit cannot be integrated without breaking those fixtures, keep the existing raster source for the first viewer release but put it in the same proper AppKit magnification surface. Record this fallback, retain all requested controls, and use on-demand higher-resolution rendering for zoom if needed. Do not ship blurred zoom as an undisclosed permanent limitation or rewrite the OCR engine to avoid the test.

### 9.2 Visible controls

Place source controls in a compact, persistent bar associated with the source pane:

`Pages` · `Previous` · editable `4 / 15` · `Next` · `Zoom out` · `125%` · `Zoom in` · `Fit` menu

- Previous/Next use labeled accessibility actions and disabled first/last states.
- Page field accepts a 1-based physical page number, validates bounds inline, commits on Return, and reverts on Escape.
- `Fit` includes Fit page, Fit width, and Actual size. The current mode is checkmarked.
- Zoom uses approximately 1.2× steps, clamped to a first-release 25–400% range. Clamp at both ends; do not accumulate floating-point drift in the displayed percentage.
- Define Actual size consistently: PDF 100% maps one PDF point to one AppKit point; image 100% maps one source pixel to one backing-display pixel, accounting for the display scale factor. A fitted view is labeled Fit page/width plus its computed percentage, not automatically “100%.”
- Fit page/width recompute on pane resize. Custom zoom preserves scale and the same content point under the viewport anchor.
- In Source-only, Fit page is the default; in Split, Fit width is usually more useful. Persist a user's later explicit choice per document.
- A one-page image hides or disables irrelevant page-switching chrome without removing zoom controls.
- Do not stack another floating page-navigation card over the reading dock.

### 9.3 Input behavior

| Input | When Source canvas has focus | Exceptions |
| --- | --- | --- |
| Left / Right | Previous/next physical page, without changing reading position. | Do not intercept in text fields, editors, menus, or text-selection responder contexts. |
| Page Up / Page Down | Native viewport scrolling within a zoomed/tall page. | Do not silently convert normal scrolling into page skipping. |
| `⌥⌘G` | Go to page. | Respect an already-open dialog/editor. |
| `⌘+` / `⌘-` | Zoom source in/out. Accept the keyboard's `=` variant for plus. | In text-only view, the View menu may route these to text size; in Split use the focused pane. |
| `⌘0` | Actual size. | Explicitly label the active target in View commands. |
| `⌘9` | Fit page. | No hidden keyboard-only fit feature. |
| Trackpad pinch | Continuous magnification around the gesture anchor. | Does not move reading position or repeatedly recenter to a word. |
| Two-finger scroll / wheel | Native smooth panning/scrolling. | Preserve elastic edges; no fake swipe-page gesture that steals horizontal panning. |
| Drag to pan | Only in a clearly indicated hand/pan mode, or equivalent native behavior. | Text selection remains available; do not make one drag both pan and select. |
| Word click | Explicit seek through the shared reading operation. | Drag, whitespace, or plain nontext image areas must not seek. |

There are always visible alternatives to gestures and shortcuts.

### 9.4 Page thumbnails and outline

- Pages toggles a compact rail/popover of real page thumbnails, lazy-loaded and keyboard navigable.
- Current browsed page and live reading page can differ; make the distinction clear without a forest of badges.
- Selecting a thumbnail browses. A separate **Read from this page** action seeks to its first readable word.
- Empty/pending pages remain selectable for viewing; Read from this page is unavailable with an explanation until words exist.
- Show PDF outline/bookmarks only if already embedded and straightforward to surface through PDFKit. Creating/editing outlines is not required.
- Do not load every full-resolution page into memory to build the thumbnail rail.

### 9.5 Geometry contract

The backend's boxes are `[x, y, width, height]`, normalized 0–1, **top-left origin relative to the displayed canonical page image**. Preserve this contract.

For an image/raster surface:

1. Determine the actual drawn image rectangle, excluding letterboxing and margins.
2. Map normalized boxes into that rectangle, not the entire enclosing SwiftUI frame.
3. Apply image and overlay pan/magnification together in the same document coordinate system.
4. Invert that exact transform for hit testing.
5. Keep overlay stroke/radius visually consistent in screen points rather than multiplying a thick stroke with zoom.

For an unrotated PDF page, the basic conversion into PDF page coordinates uses crop-box bounds and a Y flip. Rotated/cropped pages additionally require a canonical-display-to-PDF-page transform before `PDFView.convert(_:from:)`. Apply rotation/Y inversion exactly once; do not guess from the apparent thumbnail orientation.

Additional rules:

- Record/derive the canonical display box and rotation needed to match PyMuPDF rendering. Add optional metadata only if necessary; preserve old caches.
- Test all four page rotations, nonzero crop-box origins, Retina/non-Retina display scales, and landscape slides.
- Group envelopes are deterministic: order by page/visual line, then position. Do not depend on dictionary iteration order for the scroll anchor.
- Prefer a phrase contour around the correct word union, with small screen-space padding and a thin rounded edge. Keep an active-word underline subordinate to legibility.
- Source hit testing chooses the actual word box containing the point. A small screen-space tolerance is acceptable; “nearest word anywhere on the page” is not.
- Missing/invalid boxes are skipped and disclosed, not extrapolated into confident-looking slivers.
- Test the supplied FixIt slide deck and historical mismatch case against current cache-v4 geometry; a style change must not mask a still-wrong source/text mapping.

### 9.6 Viewer loading and persistence

- Retain source/load state per document generation; never briefly show the previous document's page under a new title.
- Display a stable placeholder sized to the incoming page; failed loads offer Retry rather than an endless spinner.
- Cache source PDFs once per document revision and only a bounded set of raster pages/decoded images; prefetch adjacent pages.
- Persist explicit zoom mode/custom scale and Split ratio per document. Restore around the saved reading location, not a stale detached browsing page.
- Never persist every pinch/scroll frame; save preferences at interaction completion or a modest coalesced boundary.

---

## 10. Text, split, focus, correction, and export

### 10.1 Recovered Text view

- Keep `NSTextView` as the rendering/selection engine.
- Use the shared theme/font/spacing tokens and the existing `kind`, `block`, and `sep` metadata.
- Preserve multi-column reading order, headings, bullets, wrapped paragraphs, tags, and label/value groups. Do not turn every source line into a separate oversized paragraph.
- Avoid huge empty space before the first page/heading. Page boundaries are quiet navigational markers, not large posters inside the text.
- Preserve copy/select-all, native contextual actions, text selection, and find. A click-to-seek must not fire after a drag selection or on whitespace far beyond text.
- Word maps use UTF-16 `NSRange` consistently, including emoji, smart quotes, composed characters, punctuation-only tokens, and line separators.
- Content identity includes document ID and content revision, not just word/line counts. Theme/font rebuilds reapply the current highlight immediately.
- Incremental highlight updates touch old/current/next affected spans rather than repainting every span on each microphone level update.
- The `Aa` popover gives immediate size/font/guide controls with a small live sample. Keep advanced defaults in Settings.

### 10.2 Find

- `⌘F` finds in recovered document text, with next/previous and a result count.
- In Original/Split, a result can reveal the matching word boxes/page through the existing word mapping; OCR-only pages must remain searchable through recovered text.
- Finding/browsing a result does not itself start audio or rewrite saved reading position. **Read from here** is the explicit seek action.
- Search highlights and reading highlights are distinct but readable together.
- Escape closes Find and restores prior focus. Typing Space/arrows in the search field must not trigger playback/page navigation.

### 10.3 Split

- Both panes share reading position and model revision, but have independent scroll/follow state.
- Zoom affects only the source; text size affects only recovered text.
- One dock controls the shared audio session; do not render a player inside each pane.
- Preserve split ratio and focused pane across temporary switches where practical.
- Processed pages may appear without resetting the other pane's selection/viewport.
- Use clear pane headings when space permits: **Reading text** and **Original**.

### 10.4 Focus mode

Use the user-facing name **Focus** consistently; the internal `PresentView`/`enterPresent` symbols may remain initially to reduce churn.

- A distraction-free reading stage, not a duplicate nested reader.
- One AppKit scroll owner; explicitly styled graphite/ink stage in both system appearances.
- Same text model, same cursor, same audio session, same seeking semantics, same accessibility.
- Enter/exit native fullscreen only if needed. If the window was already fullscreen, exiting Focus must not force it out of fullscreen.
- Capture the prior pane, sidebar/split state, viewport anchors, and fullscreen ownership; restore them exactly on exit.
- Idle-hide nonessential chrome after approximately 2–3 seconds of pointer inactivity while playing. Pointer movement or keyboard focus restores it.
- Never hide a focused control, an active popover, or an error. Keep a discoverable exit action; Escape exits Focus before any broader window action.
- Keep a small unambiguous microphone-active indicator visible during capture even when nonessential Focus controls are hidden.
- Do not let a background tap handler consume word seeking or text selection.
- Play/paused/preparing/listening indicators are derived from the same presentation model as the main dock.

### 10.5 Correct text

Open correction on the currently displayed page, with a small source preview beside editable recovered lines. Keep the page context and visible line association.

- Separate source text from a working draft; incoming OCR/model refreshes must not replace a dirty draft.
- Native undo/redo works within editing.
- Save is enabled for a valid changed draft; show saving state and inline failure without dismissing it.
- On page switch, sheet dismissal, document switch, and application quit, ask Save / Discard / Cancel when a draft is dirty.
- Do not use a Return default action that steals newlines from a multiline editor; use an explicit Save shortcut such as `⌘S` while editing.
- Replace misleading **Re-read Page** with **Reprocess document** unless an actual page-scoped backend operation is implemented and tested.
- Reprocessing warns that corrected text may be replaced, preserves a recoverable copy of the affected cache/draft, and never deletes the original source.
- Saving during active OCR must either merge against the latest page safely or be blocked with a clear wait/stop explanation while the draft remains intact. Do not let a later OCR callback silently overwrite a successful correction.
- Preserve unchanged line/word boxes. Match changed lines to source lines safely; inserted/unmapped lines get `box: nil` and an honest limitation, not the next old line's geometry.
- After save, remap the reading anchor to the closest valid location on that page. Do not reset the whole document to zero.
- Pause/stop the active engine deliberately during editing; leaving the editor does not unexpectedly activate the microphone.

Manual box dragging, arbitrary page-layout editing, and a full desktop publishing editor are not part of this redesign.

### 10.6 Export

Offer explicit native actions:

1. **Export current reading highlight…** — the shown page with current/next reading markers when they belong to it.
2. **Export word-box proof…** — the diagnostic all-word-box JPEG, clearly labeled as a proof.

- State that export is one page and JPEG in this release. Do not imply a full PDF export or silently export a different page.
- If the browsed page differs from the live reading page, explain why a current-reading highlight is unavailable rather than silently switching to proof mode.
- Capture document ID, revision, page, and export mode before the save panel/request; switching documents while the panel is open must not export the wrong source.
- Use `NSSavePanel`, sensible document/page-based names, and ordinary overwrite confirmation.
- Propagate HTTP/decoding/file-write errors. Never show “Exported” after `try?` discarded a write failure.
- Write atomically where appropriate, report success only after the destination is written, and offer Reveal in Finder as an optional follow-up.
- Preserve the current proof export capability. No bulk ZIP, PDF annotation writer, or cloud sharing backend is required.

---

## 11. Settings, commands, accessibility, and feedback

### 11.1 Settings structure

Replace the dense fixed 460 pt form with a well-proportioned native settings surface, approximately 700 × 560 pt with sensible resizing/minimums. A compact sidebar/detail layout is appropriate for these categories:

| Category | Contents |
| --- | --- |
| Reading | Font, size, line spacing within the approved range, reading guide, follow behavior explanation. |
| Voice & microphone | Installed voice, speed, explicit voice preview, input device, permission status/help. |
| Appearance & feedback | System/Light/Dark, visual preview, optional sounds/haptics. |
| Processing & models | Default Auto/Printed/Handwriting recovery, shared model cards, actual disk usage/location. |
| About & privacy | Version/build, local-processing explanation, model licenses, help, optional sanitized diagnostics access. |

Implementation rules:

- Keep the standard app Settings command and `⌘,`; do not create competing settings windows.
- Use grouped forms, hidden opaque form backgrounds where appropriate, native materials/chrome, and availability-guarded macOS 26 scroll-edge treatment.
- Reuse the existing Settings host when it provides the needed behavior. If a verified native-window style/lifecycle limitation requires `NSWindowController`, introduce one focused controller and route all Settings entry points to it; do not maintain two hosts.
- Settings follows the same appearance choice as the reader, including AppKit representables and Focus.
- Change defaults for new users without wiping existing saved preferences. New optional persisted fields must decode older preferences safely.
- Use an explicit preview/reset for a relevant group, not a destructive global Reset Everything button.

### 11.2 Command and shortcut contract

All menu items must enable/disable from current capability and focus. Do not advertise commands that act on a different document or hidden pane.

| Command | Shortcut / input | Scope |
| --- | --- | --- |
| Import | `⌘O` | Main window; one validated import path. |
| Settings | `⌘,` | Standard app command. |
| Text / Original / Split | `⌘1` / `⌘2` / `⌘3` | Current document. |
| Play / Pause / Listen / Stop | Space | Reader/canvas context only; never ordinary typing/editing/search. |
| Previous / Next phrase | `⌘[` / `⌘]` | Reader context, consistent with actual menu shortcuts. |
| Previous / Next physical page | Left / Right | Focused source canvas only. |
| Find / next / previous | `⌘F` / `⌘G` / `⇧⌘G` | Native reading/find context. |
| Go to page | `⌥⌘G` | Source/page navigation context. |
| Zoom / text size | `⌘+` / `⌘-` | Active reading pane; display the target in the View menu. |
| Actual size / Fit page | `⌘0` / `⌘9` | Source context. |
| Focus | `⇧⌘F` | Readable document. |
| Edit text | `⌘E` | Current document/page. |
| Save draft | `⌘S` | Correction editor only. |
| Remove selected library document | Delete | Library-row focus only; use the same safe confirmation, never delete text or a document from the wrong focus context. |
| Export | `⇧⌘E` | Opens explicit export choice or the last clearly labeled export action. |
| Escape | Context-dependent | Close popover/find/sheet safely; exit Focus; do not discard dirty edits. |

Retain standard File/Edit/View/Window/Help/App menus. Standard copy/paste/select-all/undo must keep working. Avoid raw global event monitors when the responder chain or focused SwiftUI commands can do the job. If a local monitor is necessary, scope and remove it correctly.

### 11.3 Accessibility acceptance

- Icon-only controls have action-specific labels and helpful values/hints.
- Full Keyboard Access reaches the sidebar, document controls, dock, model setup, and editor without traps.
- Keyboard focus remains visible in both appearances and through custom materials.
- Page controls expose “Page 4 of 15”; zoom exposes the percentage and fit mode; reading progress exposes a meaningful bounded value.
- VoiceOver can read the recovered document normally. Do not flood it with announcements for every ASR partial or highlighted word.
- Announce meaningful transitions politely: import ready, download failed, microphone denied, reading finished. The reading engine and VoiceOver must not automatically speak over each other on app launch.
- A Canvas overlay alone is not an accessible document interface; provide readable text/current-phrase context and keyboard alternatives.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, and Bold Text/legibility preferences in custom components.
- Scale labels/rows with reading size; do not truncate required actions at the maximum supported size.
- Colors are paired with shape/text; amber/blue distinction cannot be the only signal.
- Touch Bar or Force Touch availability is not assumed. Haptics are optional, hardware-dependent, and never the sole feedback.

### 11.4 Feedback policy

- Routine actions update their own surface. Do not toast “Opened…” on every document switch or emit a sound on every navigation click.
- Success toasts are brief, nonblocking, and do not cover the document title or keyboard focus.
- Errors requiring action persist inline until resolved/dismissed; a 3.6-second toast is not sufficient for a failed model setup or export.
- Sounds/haptics default off for new users in a reading app; preserve existing explicit preferences. Do not add sounds to per-word updates or microphone detection.
- Do not describe a sound as good/soft/premium without an actual listening check. No custom soundtrack is needed.
- Destructive decisions use native confirmations. Routine successful operations do not use modal alerts.

### 11.5 Recovery matrix

| Condition | User-facing treatment | Safe action |
| --- | --- | --- |
| Backend starting slowly | Named preparation state; shell stays responsive. | Wait, show details, Retry when failed. |
| Backend connection lost | “Reading engine disconnected”; preserve title, view, position, and draft. | Reconnect/restart the owned helper; never silently discard content. |
| Model missing | Explain the capability that requires it. | Download / Not now / use an available mode. |
| Offline download | Keep useful local reading accessible. | Retry when online; no repeated modal spam. |
| Insufficient storage | Explain approximate need and available space. | Open storage guidance / Retry / Cancel. |
| Permission denied | Inline explanation with native System Settings route. | Open Microphone settings; Read to me still available. |
| Microphone unavailable | Name the missing device and capture state truthfully. | Choose another device / Stop. |
| Listening without a match | Marker stays on last confirmed place; low-key guidance. | Click a word / choose microphone; no fake confidence. |
| No readable text | Show the source, not an empty reader. | Try another recovery mode / correct text where supported. |
| Pending/failed page | Page-specific state; other pages remain usable. | Wait / Retry appropriate job; browse source. |
| Unsupported/oversized/corrupt file | Specific validation error before losing current context. | Choose another file; original library stays intact. |
| Correction save failed | Draft remains open and unchanged. | Retry / copy draft / cancel safely. |
| Export write failed | No success toast. Keep chosen context. | Choose another destination / Retry. |
| Missing managed source/cache | Distinguish source missing from regenerable cache. | Recover/reimport with consent; never erase the library entry automatically. |

### 11.6 Loading and readiness response contract — mandatory

**This is a required part of the redesign, not a final cosmetic pass.** Every potentially slow operation needs an immediate visible acknowledgement, a truthful ongoing state, a clear scope, and a way to recover. A generic full-window spinner or a button that appears dead is not acceptable.

#### Shared loading presentation rules

1. **Acknowledge immediately:** update the initiating button/row/status synchronously before waiting for file I/O, a network request, model loading, or speech callbacks. Target visible acknowledgement within 50–100 ms.
2. **Name the operation:** use “Opening ‘Report’…”, “Loading handwriting model…”, or “Preparing voice…” rather than “Loading…” everywhere.
3. **Place feedback beside the affected content:** a document-row indicator and detail placeholder for a document switch, a model card for a download, and the reading dock for TTS preparation. Do not replace the whole library for a single voice warm-up.
4. **Choose honest progress:** bytes for a measurable download; physical page progress for measurable processing; an indeterminate indicator for model initialization/voice preparation. Never invent a countdown or advance a bar on a timer.
5. **Keep useful work available:** library navigation, reading already-ready text, and unrelated settings remain usable unless there is a real conflict. Disable only conflicting actions and explain why.
6. **Prevent duplicate work:** repeated Play/Open/Download clicks do not create duplicate utterances, workers, imports, or source loads.
7. **Offer the real escape:** Cancel, Stop preparing, Stop after current page, Not now, or continue using another document—whichever the implementation can honestly perform.
8. **Handle the slow tail:** after a meaningful wait, provide phase-specific reassurance and available recovery. A long first-use warm-up must not look like a frozen app.
9. **End on an actual readiness signal:** a verified model, decoded document/source snapshot, or native speech-start callback. Do not show “Ready” merely because a request was accepted.
10. **Do not add an artificial minimum wait:** a fast cached operation can finish immediately. A very short indicator may be visually suppressed to avoid flashing, but the action still acknowledges immediately.

#### Required loading journeys

| Journey | Immediate response | Ongoing / slow state | Actual ready signal | Failure / exit |
| --- | --- | --- | --- | --- |
| Cold app launch | Responsive native shell; “Opening your library…” | Named engine preparation state; technical details disclosed, not dumped into the main view. | Backend healthy plus initial library snapshot, with document readiness shown independently. | Retry engine / open diagnostics; preserve existing data. |
| Open an existing document | Select an opening row and show “Opening ‘Title’…”; stop prior audio safely. | Source/text placeholders of stable size; “Loading saved text…” or “Preparing page preview…” as appropriate. | Matching document ID/revision decoded and viewable; text and preview can become ready separately. | Retry this document; retain the prior safe selection/context if opening fails. |
| Import a new document | “Checking file…” immediately on accepted drop/picker result. | Validating → preparing pages → recovering text → preparing reading positions; show a real source preview as early as possible. | A page's text/geometry or source is actually available; later pages can remain pending. | Specific validation/model/storage error; cancel safely; original file untouched. |
| Switch physical page | Page control updates immediately; bounded source placeholder if uncached. | “Preparing page 4…” if not quickly available; other controls stay stable. | The requested page of the requested document is rendered, not the previous page image. | Retry page; keep valid reading cursor and zoom state. |
| Download an AI model | Download button becomes a scoped preparation state. | Connecting / downloading bytes / verifying / installing. Explain estimated totals and first-use nature. | Complete usable artifacts verified; model is Installed, not necessarily loaded in memory yet. | Retry / Cancel supported worker / storage guidance / Not now. |
| Load OCR weights into memory | “Loading handwriting model…” separate from downloading. | “Preparing the recognition engine…” when the backend reports that phase; model download status remains Installed. | Model load succeeded and real recognition begins. | Retry recovery engine / use another mode / stop at a safe boundary. Do not delete installed weights automatically. |
| Warm speech-following engine | Dock/status says “Preparing voice following…”; show whether microphone is still off. | Distinguish loading weights/initial compilation from starting capture. Stop remains reachable. | Engine healthy; only an explicit current listening intent may open the mic. | Stop preparation/listening intent / Retry engine / use Read to me. |
| Prepare TTS voice | Play becomes “Preparing voice…” with a real stop/cancel action; do not falsely show active spoken-word progress. | First utterance/voice initialization uses indeterminate preparation. Do not flash this state between every sentence. | `AVSpeechSynthesizer` didStart or the first valid range callback for the current utterance generation. | Stop / Retry / choose another installed voice; never spin forever on a missing callback. |
| Select unavailable system voice | Explain that this is a macOS voice resource, not the app's speech-following model. | Open native voice management if the user chooses; do not invent app-owned download bytes/progress. | Voice is available through the supported native voice API and narration can start. | Choose an available voice; leave current document/position unchanged. |
| Reopen cached text while a model is busy | Show the cached reading surface; small scoped background activity indicator. | Never block cached text behind an unrelated AI warm-up. | Cached document is ready independently of model initialization. | Cancel unrelated work or continue reading. |

#### TTS implementation detail

`SpeechController` currently reports range/end/cancel callbacks, but no explicit start callback. Add a narrowly scoped `onStart` bridge from the synthesizer delegate when implementing the TTS card. Use it to leave Preparing; retain first-range fallback for supported voice behavior. Native utterance identity/generation is mandatory for start, range, finish, cancellation, and timeout handling.

The present app has no separately downloaded TTS neural model. Do not relabel the 158 MB microphone/ASR model as a TTS model, force its download before Read to me, or pretend to observe an OS voice download that the API does not report.

#### Slow-operation and timeout rules

- Use a lightweight elapsed-time watchdog for **recovery messaging**, not fake progress or word timing.
- For an unexpected TTS start delay, show a more helpful message after roughly 8 seconds; by a bounded threshold such as 30 seconds without a valid current-generation start/range event, stop the stale request and offer Retry / Choose voice. Validate the final thresholds on actual supported voices.
- Model/Vision first-use preparation may legitimately take tens of seconds or more. Do not reuse the short TTS threshold to fail it. Retain the backend's legitimate startup limits and show accurate stage-specific guidance during the wait.
- A lost backend connection terminates an indefinite document/model waiting UI into a reconnectable state. Do not erase progress or claim completion.
- Cancellation, timeout, retry, and completion race through the same operation/document generation: only the currently intended result can change the UI.
- Announce major loading-stage changes to VoiceOver politely; do not announce every byte, RMS sample, or elapsed second.

#### Loading-specific acceptance checks

- Simulate 0 ms, 300 ms, 5 s, and prolonged operations. The UI never feels unresponsive, never adds an artificial delay, and never lies about measurable progress.
- Open A then B before A completes: no A text/preview appears under B's title, and A cannot start audio afterward.
- Start TTS then Stop before didStart: a late start/range callback cannot change the marker or resurrect playing state.
- Start Follow me then Stop during warm-up: recording does not begin when the model eventually becomes ready.
- Close Settings during a download: the download continues as intended and any other visible status remains live.
- Load a cached PDF without either app model: ordinary Text/Original/Read to me remain available.
- Fail document/voice/model preparation: recovery is visible inline, not only in a disappearing toast.

---

## 12. Performance targets

These are **targets for implementation measurement**, not results established by this planning audit. Use the documented M1 Pro / 16 GB class machine as one baseline and record actual hardware/build settings.

| Interaction | Target / measurement boundary |
| --- | --- |
| Input acknowledgement | Visible press/selection/state feedback within 50 ms at p95; no arbitrary animation delay before the action begins. |
| Main-thread responsiveness | No avoidable >100 ms UI-thread stalls during import, model publication, zoom, or text rebuild. Profile before adding concurrency. |
| Cached page switch | Approximately ≤100 ms p95 after adjacent-page/source preparation; report uncached rendering separately. |
| Word callback → marker | Within approximately 50 ms p95 after the app receives a native speech/state event. Do not include imaginary ASR improvements in this number. |
| Follow me end-to-end | Record the existing approximately 0.5–1 s speech/partial cadence separately; a skin cannot eliminate model latency. |
| Zoom / pan / scroll | Maintain display-rate interaction on a 60 Hz baseline without repeated full text/model rebuilds. |
| Cold launch | Render a responsive native shell before backend/model readiness; measure shell and engine readiness independently. |
| Cached document restore | Aim for visible usable text/source within approximately 1 s after backend readiness on the baseline fixture. |
| Model progress | Update visible progress about once per second from one owner; stop redundant polling when irrelevant. |
| Large document | 100 pages / approximately 25,000 words remains navigable and readable without unbounded image retention or repainting every word on each RMS update. |

Implementation guardrails:

- Keep OCR/ASR work and expensive source preparation off the UI actor's synchronous input path.
- Retain polling unless measurements justify an event transport. Do not add WebSockets/SSE solely for style.
- Compare actual state before publishing changes; RMS/transcript changes must not rebuild the whole attributed document.
- Cache by document ID, content/source revision, page, and required scale. Bound cache memory; do not clear all pages on every appended OCR page.
- Dedupe in-flight loads. Do not cancel/restart the same page request every 120 ms because polling called a force-refresh method.
- Prefetch only nearby pages/thumbnails and discard stale results after document/generation changes.
- Use existing native scrolling/magnification instead of rebuilding trackpad physics in SwiftUI gestures.
- Do not keep the large OCR model warm solely for a smooth-looking spinner; preserve the existing memory/resource discipline.

---

## 13. Shared implementation contracts

This section prevents independently executed cards from inventing incompatible state or API designs. Keep names unless existing newer code already provides an equivalent; record deviations before dependent tasks proceed.

### 13.1 State ownership

| State | Owner / persistence |
| --- | --- |
| Managed source, recovered text, word geometry, library identity, saved reading position | Existing Python `DocumentStore` / `App`, existing workspace/cache files. |
| Active audio session, seek generation, rendered model snapshot, UI transport state | Existing `ReaderModel`, using the current `SpeechController` and `BackendClient`. |
| Opening document / loading text / preparing preview | Document-scoped native load state, with captured request generation; not a single app-global `isLoading`. |
| TTS preparation / speech-engine warm-up / OCR model load | Separate scoped phase information; the dock, model cards, and processing strip display the same actual producer state. |
| Source page browsing, text/source follow flags, zoom, focused pane | Small native session/viewer state, not the backend reading cursor. |
| Font/theme/default recovery/voice/speed/feedback | Existing preferences, decoded backward-compatibly. |
| Per-document zoom choice / Split ratio | Small versioned dictionary keyed by document ID in native preferences; no library-schema migration required. |
| Editor draft / dirty flag / editor undo | Editor-local state tied to captured document/page/revision. |
| Model download workers / status / cancellation | Existing backend `Models`; UI only requests and presents. |

### 13.2 Minimal shared native values

Put small common values/pure calculations in `macapp/ReadingSession.swift` if needed for isolated testing. Do not create a general reducer/event-store framework.

```swift
enum TransportState: Equatable {
    case idle, preparing, playing, paused, listening, stopping, waitingForText, failed
}

enum ZoomMode: String, Codable {
    case fitPage, fitWidth, actualSize, custom
}

struct PageWordAnchor: Equatable {
    var documentID: String
    var page: Int               // zero-based physical page
    var wordOffset: Int         // alignable-word offset within that page
}

struct ViewerState: Equatable {
    var browsedPage: Int?       // nil means use the live reading page
    var sourceFollows = true
    var textFollows = true
    var zoomMode: ZoomMode = .fitPage
    var customScale: Double = 1
}
```

These are the intended concepts, not a requirement to duplicate a newer equivalent type. Additional associated state should be added only for a behavior specified in this document. The permission state and raw backend availability are not inferred from a single `isPlaying` Boolean.

Use one canonical native transport presentation state. Existing `narrationActive`/`narrationPaused` flags may remain only as derived compatibility values or be changed together through one transition path; views must not independently mutate contradictory Boolean/enum states. Preparing, paused, and actively producing audio are not interchangeable meanings of “playing.”

Keep a small preparation reason where necessary (`voice`, `speechEngine`, `permission`, `nextPage`) so Preparing has specific copy and cancellation semantics. Document opening/source rendering has separate document-scoped state. Do not add one Boolean that makes model download, document loading, and audio preparation indistinguishable.

### 13.3 Cursor/progress contract

- Existing persisted reading position remains a zero-based integer in `0...N`, where `N` is the terminal sentinel for the current complete model.
- Do not migrate or reinterpret old positions merely to change the display.
- Progress is clamped to `[0, 1]`; empty text is not a divide-by-zero case; position 0 displays 0%; final confirmed completion displays 100%.
- TTS's active spoken word is a presentation mapping from a callback, not evidence that every later word has been consumed.
- During incomplete processing, show physical page/available-text context and suppress definitive 100%/Completed treatment.
- A model re-publication captures the old page-local anchor, rebuilds, and resolves that anchor into the new global index. If a line was edited, use nearby unchanged text/page context rather than blindly retaining a now-unrelated numeric index.
- Explicit completion is distinct from an active highlight at the last group. Focus/dock/sidebar must derive from the same completion condition.

### 13.4 Identity and revision contract

Add backward-compatible optional fields to native decoders and additive backend responses:

- `/state`: `doc_id` already exists; add `model_revision`.
- `/model`: add `doc_id` and `model_revision` alongside the existing pages/lines/words/groups.
- Increment the revision whenever model content/geometry changes, including same-word-count corrections and partial-page publication.
- Document identity plus model revision plus a native connection/request generation identifies a usable snapshot. Counts alone do not.
- Capture the intended document/generation before asynchronous loads/actions; ignore stale results after an await.
- For mutations that could otherwise target the newly active document, send the expected `doc_id` and reject a mismatch server-side. Existing callers without this field may keep compatibility behavior.
- Serialize/coalesce position persistence through one path; canceled HTTP tasks alone do not prove the server did not apply an earlier seek.

### 13.5 Page-readiness contract

Add optional per-page `reading_status` values: `pending`, `ready`, `empty`, `error`; optional page error/canonical-display metadata only where required.

- Old complete caches without this metadata remain readable. Derive their complete-page status from the known finished document, not from a missing field meaning “pending forever.”
- New partial jobs explicitly mark pending pages. A page with no words after successful processing is `empty`, not pending.
- Keep current cache version 4 readable; do not invalidate every user's cache for UI-only metadata. Bump/migrate only when a real schema/geometry change requires it.
- Expose a real physical OCR page index where needed. Existing OCR-job counters retain their original meaning.
- Report actual preparation detail for loading OCR weights, recognition, mapping, and saving where the backend can observe it. Existing broad `vision`/`ocr` phases remain compatible; unknown detailed progress is indeterminate.
- A pending model dependency is not a corrupt-document error; represent it so downloading the model can resume the intended job safely.

### 13.6 Focused API additions

Prefer additive changes to the existing server/client. Do not create a replacement server or expose arbitrary file access.

| Route / change | Contract |
| --- | --- |
| `GET /documents/<id>/source` | Validate managed document ID with the existing store, resolve only its registered source, serve correct PDF/image content type. No caller-supplied filesystem path. Fetch once per source revision. |
| `/model`, `/state` identity/revision | Fields specified above. Preserve existing payload fields and compatibility clients. |
| Existing `/jump`, `/script`, `/ocr`, `/export` | Include/validate expected document identity for new native callers; capture mode/page/revision where needed. Export GET can use validated query values. |
| `POST /setup/cancel` | Body `{ "model": "speech" | "ocr" }`; cancel only the owned worker for that key. Unsupported cancellation must not be advertised as successful. |
| `/setup/status` | Keep existing `state`, `bytes`, `total`, `path`, `error`; allow truthful extra phases and optional `can_cancel` / `progress_is_approximate`. All UI surfaces interpret the same states. |
| Optional OCR stop action | Add only when cooperative cancellation is implemented: target document/job generation; stop at a safe boundary and retain ready pages. Never claim an active GPU call stopped instantly. |

Successful decoding is part of success. `BackendClient` must not convert a malformed successful response into `nil`/an empty model and proceed as if import/save succeeded.

### 13.7 Event and cancellation rules

- A document switch invalidates pending native source loads, narration callbacks, deferred playback restarts, and pending contextual setup actions for the old selection.
- Late ASR transcript/status callbacks also belong to a captured listening run/document generation; a stopped old stream must not advance the newly opened document. This is lifecycle scoping, not an aligner-algorithm rewrite.
- Switching away does not delete or accidentally cancel a valid backend import job; it only detaches UI intent.
- Starting/stopping Follow me is serialized; pressing Stop during warm-up clears the listening intent before the engine becomes ready.
- Source browsing is not a seek. Find reveal is not a seek. Only explicit reading-position actions persist a new position.
- Worker cancellation is cooperative/owned. Never terminate the whole backend to implement Cancel download or stop an unrelated speech server reused from another process.
- Model/view updates must not overwrite a dirty correction draft.
- File writes preserve error propagation and atomicity; success feedback is downstream of the successful write.

---

## 14. File map and test strategy

### 14.1 Existing files and responsibility

| File | Planned responsibility |
| --- | --- |
| `macapp/ReadAlongApp.swift` | Native window/commands/settings entry; launch permission deferral; safe export entry. |
| `macapp/ContentView.swift` | Shell/layout, welcome/loading/recovery surfaces, reader toolbar, dock inset, sheets/drop state. |
| `macapp/SidebarView.swift` | Library search/rows/status/rename/delete and activity access. |
| `macapp/ReaderModel.swift` | Shared session behavior, seek/transport ownership, revisions, async identity, model status, view preferences. |
| `macapp/Models.swift` | Backward-compatible API decoder additions. |
| `macapp/ReaderTextView.swift` | Editorial text, mapping/find/follow behavior, incremental highlighting, selection. |
| `macapp/PageView.swift` | SwiftUI source chrome; host the native viewer rather than own coordinate/gesture logic. |
| `macapp/PlayerBar.swift` | Adaptive reading dock and options; derived transport presentation. |
| `macapp/PresentView.swift` | Focus stage, restored state, one scroll owner, safe chrome visibility. |
| `macapp/SetupCard.swift` | Welcome/contextual setup entry; shared model UI. |
| `macapp/SettingsView.swift` | Organized settings and reusable model-card presentation. |
| `macapp/EditSheet.swift` | Captured-page draft, dirty protection, correction/export UI. |
| `macapp/SpeechController.swift` | Existing native voice/range lifecycle; only focused improvements for voice availability and stale callbacks. |
| `macapp/BackendClient.swift` | Typed errors, identity-aware mutations, source/cancel/export helpers. |
| `macapp/BackendService.swift` | Engine startup/reconnect/shutdown; native permission helper; sanitized diagnostics entry. |
| `readalong.py` | Additive contracts, contextual dependency state, model-worker integrity/cancel, safe position/correction/export handling. Keep OCR/aligner core. |
| `test_align.py`, `test_library.py` | Preserve and extend algorithm/library regressions. |
| `Makefile` | Include focused new checks in `make test`; keep build workflow. |
| `scripts/build_app.sh` | Link PDFKit when adopted; keep `macapp/*.swift` compilation and bundled resources intact. |
| `macapp/Info.plist` | Native document-open declarations if implemented; preserve bundle identity/minimum OS. |
| `scripts/make_icon.py`, icon assets | Optional final identity refinement; not a prerequisite for viewer correctness. |
| `README.md`, `ARCHITECTURE.md`, `TODO.md` | Update actual behavior/shortcuts after implementation. Preserve historical work; do not replace the entire documents. |

### 14.2 Justified small new files

- `macapp/ReaderTheme.swift`: shared dynamic colors/type/spacing constants.
- `macapp/ReadingSession.swift`: small shared values and testable calculations, only if not already present.
- `macapp/SourceViewer.swift`: the focused AppKit/PDFKit representable seam.
- `macapp/LoadingStatusView.swift`, only if repeated presentation warrants it: a small shared loading/error view, not a generic operation framework.
- `macapp/Tests/NativeChecks.swift` plus `scripts/test_native.sh`: an assert-based native test executable, consistent with the current lightweight build. A new Xcode project is not required just to test math/state.
- `test_models.py` and/or `test_workflow.py`: isolated backend contract/download/correction checks when existing test files would become unrelated dumping grounds.
- Small welcome/error subviews may stay in current files until size/reuse actually justifies a file. Do not pre-create empty component directories.

### 14.3 Automated checks

Retain existing Python assertions. Add focused tests for:

- Empty/one-word/multi-page/completed progress, pending-page frontier, and page-local anchor rebasing.
- Same-count document switch and same-count edit invalidating native text/render identity.
- Old preferences/cache payloads decoding with added optional fields.
- Zoom limits/fit calculations and normalized box round trips, including crop/rotation transforms.
- Focus-aware navigation policy; page browsing does not post `/jump`.
- Seek ordering, stale TTS callbacks, active/paused/idle voice changes, and Stop during a pending Follow me start.
- Changed library metadata with unchanged IDs.
- Model state transitions/cancel/removal using fake temporary caches and workers, never real model paths.
- Incomplete model artifacts never becoming Ready.
- Dirty drafts surviving model refresh/page-switch cancellation; corrected-text saves preserving anchor and safe boxes.
- Export request identity/mode and simulated destination-write failures not showing success.
- Invalid document IDs/source traversal requests rejected at the API boundary.

The native test executable should compile only the needed non-app-entry Swift files and use a separate test entry point. Tests live below `macapp/Tests/` so the current top-level `macapp/*.swift` bundle glob does not accidentally include another `@main`.

Use standard-library assertions/mocks or existing Apple testing facilities. Do not add a large mock framework or convert the build system as a side effect of this plan.

### 14.4 Future verification commands

These are commands for the implementing agent **after changes**; they were not run as part of this planning audit:

```sh
git status --short
make test
scripts/test_native.sh
make app
plutil -lint macapp/Info.plist
```

Run `make dmg` only for the final packaging/release task. Build scripts write/replace generated app output, so inspect their scope first. Real downloads, live microphone, physical gestures, VoiceOver, and listening checks are separate from a successful build.

### 14.5 Fixture set

Use copies in isolated test workspaces, never overwrite the user's live library:

1. Existing bundled text PDF: `ocr-pdf.pdf` (or `ocr.pdf` where present).
2. Existing handwriting image: `ocr.jpg`.
3. Existing dark two-column slides: `FixIt-slides-dark-plum.pdf`.
4. Generated small PDFs for 0/90/180/270° rotation, crop offsets, different page sizes, blank pages, and text on only later pages.
5. Two documents with equal word/line/page counts but different words.
6. A correction that changes words without changing counts; another that inserts/removes a line.
7. A mixed text/scan PDF where an earlier OCR page completes after the user starts reading a later ready page.
8. A generated approximately 100-page / 25,000-word fixture for performance; generated fixtures should be small/reproducible rather than committing huge binaries.
9. Fake model directories for missing/partial/ready/interrupted/error/remove tests.
10. Failure responses for disk write, lost backend connection, missing microphone, and unsupported import.

---

## 15. Implementation task cards

All boxes are intentionally unchecked. Numerical order is a safe integration order; the dependency column allows a bounded task to be picked independently once its prerequisites exist.

### 15.1 Task index

| Task | Deliverable | Depends on | Primary owners |
| --- | --- | --- | --- |
| R01 | Isolated regression fixtures and lightweight native checks | None | Tests, Makefile |
| R02 | Shared identity/revision/progress/session contracts | R01 | ReaderModel, Models, Python App |
| R03 | Unified seek, stop, and stale-result protection | R02 | ReaderModel, BackendClient, Python mutation handlers |
| R04 | Design tokens, window shell, toolbar, and dock layout | R02 | ReaderTheme, ContentView, app window |
| R05 | First-class loading/readiness presentation | R02, R04 | ContentView, ReaderModel, loading subviews |
| R06 | Native zoomable source surface and source access | R02, R04, R05 | SourceViewer, PageView, BackendClient, source route |
| R07 | Page/zoom controls, thumbnails, and source hit testing | R03, R06 | PageView, SourceViewer |
| R08 | Manual browsing, automatic following, and Split policy | R03, R06, R07 | Viewer state, text/source scroll owners |
| R09 | Editorial text, correct render identity, and Find | R02, R04, R08 | ReaderTextView |
| R10 | TTS preparation, adaptive dock, voice/speed, and scrubbing | R03, R04, R05, R09 | SpeechController, ReaderModel, PlayerBar |
| R11 | Follow me permission, warm-up, microphone, and recovery | R03, R05, R10 | Native permission, ReaderModel, Python ASR lifecycle |
| R12 | Real welcome/empty state and deliberate sample import | R04, R05 | SetupCard, ContentView, Python startup |
| R13 | Truthful model-worker readiness, progress, and cancellation | R01, R02 | Python Models, model tests, API decoders |
| R14 | Contextual model setup and shared live manager | R05, R12, R13 | SetupCard, SettingsView, ReaderModel |
| R15 | Responsive document opening/import and partial-page processing | R02, R03, R05, R06, R10, R13, R14 | Ingestion/jobs, native document lifecycle |
| R16 | Polished library, metadata refresh, and safe row actions | R02, R04, R05, R15 | SidebarView, ReaderModel |
| R17 | Safe page-context correction and preserved reading anchor | R02, R03, R09, R15 | EditSheet, script API |
| R18 | Correct export modes and reliable file feedback | R03, R06, R17 | Export callers, client, Python export |
| R19 | Focus stage and exact restoration | R03, R08, R09, R10, R11 | PresentView, ReaderModel |
| R20 | Organized native Settings and backward-compatible preferences | R04, R10, R11, R14 | SettingsView, preference decoding |
| R21 | Focus-aware menus, keyboard navigation, and real Help | R07, R09, R17, R18, R19, R20 | App commands, responder behavior, docs |
| R22 | Engine reconnect, durable errors, and safe recovery | R05, R11, R13, R15, R17, R18 | BackendService, client/model, error surfaces |
| R23 | Accessibility and appearance compliance | R04–R22 UI work integrated | All custom controls/representables |
| R24 | Measured native performance and cache/load deduplication | R06, R08–R11, R15, R16, R19, R22 | Hot paths and performance checks |
| R25 | Full-journey QA, documentation, and packaging gate | All required cards | Tests, docs, final app/DMG |

**Smallest complete visible slice:** R01–R10 produce a themed, useful reader with real source navigation, follow/browse separation, and honest TTS loading. It is not permission to omit R11–R25 from the requested full-experience redesign. Onboarding/model/import safety remains a release requirement.

### R01 — Establish isolated fixtures and a native check harness

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** none.

**Goal:** create a cheap repeatable safety net before modifying session semantics. Do not change application behavior in this card.

**Read:** sections 2, 3, 13, and 14; `Makefile`, `test_align.py`, `test_library.py`, `scripts/build_app.sh`, `macapp/Models.swift`.

**Files:** existing test files as needed; new `macapp/Tests/NativeChecks.swift`, `scripts/test_native.sh`, small reproducible fixture helpers under a test-only location; `Makefile`.

**Implementation steps:**

1. Run and record the existing checks before changing them. Do not replace them with a new testing framework.
2. Add a native executable with its own test entry point; compile selected non-App application files, never both it and `ReadAlongApp` as two `@main` entries.
3. Add initial decoder assertions for current model/library/preferences examples and safe empty payloads. Later cards add their own logic cases here.
4. Generate small PDF fixtures using the already-installed PyMuPDF: rotations, crop offsets, mixed page dimensions, blank page, and equal-count text variants. Keep generation independent of live OCR weights.
5. Add a mixed-readiness fixture with text on a later page and pending earlier-page OCR; it must be usable to test index rebasing without running an AI model.
6. Ensure tests use temporary workspaces and fake cache roots. Never point deletion/model tests at `~/.cache` or the installed library.
7. Wire the native script into the existing test workflow once it can run reliably; keep its output concise and fail nonzero on an assertion/compiler failure.

**Checks:** existing `make test`; native script; regenerate fixtures twice and compare their semantic properties rather than requiring timestamp-identical PDF bytes.

**Acceptance:** no app behavior changed; test files cannot be accidentally compiled into the app; no network/model/microphone activity occurs; fixture generation and all initial checks are reproducible.

**Handoff:** record selected Swift inputs/frameworks for the native harness so the next card can add tests without rediscovering the build.

### R02 — Establish shared session, revision, progress, and readiness values

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R01.

**Goal:** remove ambiguous identity/progress assumptions before restyling or adding controls.

**Read:** section 13 completely; `ReaderModel` derived values/load/apply-state paths; `Models.swift`; Python `App.load`, `_run_ocr`, `state`, `set_script`; all progress/render-key callers.

**Files:** `macapp/ReadingSession.swift` if needed; `ReaderModel.swift`, `Models.swift`, relevant native checks; `readalong.py`, relevant Python tests.

**Implementation steps:**

1. Introduce the minimal shared transport/viewport/zoom/page-anchor concepts from section 13, reusing equivalent types if already present.
2. Add document ID and monotonic model revision to model/state responses. Increment on load/publication/correction even if counts are unchanged.
3. Decode added fields optionally so older payloads and existing persisted data remain usable. Swift stored-property defaults alone do not make synthesized `Decodable` tolerate a new required missing key; use optional fields or explicit `decodeIfPresent` where necessary.
4. Centralize bounded progress/completion derivation. Keep `0...N` persisted semantics; 0 is not 1%, `N` is not 101%, and partial documents cannot be Completed.
5. Add page-local anchor capture/resolve calculations and page readiness metadata/fallback behavior. Test numeric indices shifting when earlier page words are inserted.
6. Keep engine availability/preparation separate from microphone-active/audio-playing state. Define a specific preparation reason without creating a generic operation framework.
7. Add document-scoped request/generation identifiers for later asynchronous actions; do not use counts as identity.

**Checks:** zero/one-word/last-word/end-sentinel/empty/partial progress; old JSON/prefs decoding; same-count revisions; anchor rebase after preceding-page insertion; all existing Python tests.

**Acceptance:** UI consumers have one correct progress/completion source; no source/cache migration or forced redownload; complete old caches do not remain pending forever.

**Do not:** rewrite the aligner, introduce a new persistence layer, or change stored positions to one-based indexing.

### R03 — Unify explicit seeking and protect session intent

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02.

**Goal:** every intentional seek behaves correctly under active, paused, idle, and preparing states, with no late callback/request rollback.

**Read:** sections 8.3, 8.7, and 13; grep callers of `jump`, `setPage`, `movePhrase`, `startNarration`, `stopNarration`, `toggleFollow`, and `setMode`.

**Files:** `ReaderModel.swift`, `BackendClient.swift`, `ReadingSession.swift` if needed, termination/position-flush coordination in `ReadAlongApp.swift`, Python `App.jump`/relevant mutation routes, focused native/backend checks; callers only where required to adopt the shared operation.

**Implementation steps:**

1. Create one explicit seek entry that accepts the word/page-anchor target and obeys section 8.3's stop/invalidate/persist/resume sequence.
2. Separate explicit seeks from internal speech-progress persistence. A range callback must not call an operation that stops/restarts the engine on every word.
3. Invalidate old utterance/run IDs before calling native Stop. Handle callbacks arriving after Stop, after a backward seek, after mode change, and after document change.
4. Route phrase buttons and text word clicks through the shared entry. Reserve plain page browsing for R07/R08; do not preserve `setPage`'s hidden `/jump` side effect.
5. Serialize position writes or use one in-flight/latest-target pump. Ignore an old acknowledgement in UI while a newer seek is pending. Canceled URLSession tasks are not sufficient ordering protection.
6. Add expected document ID to new native mutation requests; validate it inside the backend's appropriate lock before acting. Return a matching acknowledgement/current state rather than silently mutating a newly selected document.
7. Keep an idle click idle, a paused seek paused, and an active seek active only if its captured document/mode/generation is still current.
8. Stop during a pending Follow me start must cancel listening intent even if engine initialization continues safely in the background. Ignore old-run ASR transcript/status callbacks after stop/seek/document switch as well as old TTS callbacks.
9. Flush exact current native reading position at pause/stop/document switch/quit before shutting down its backend. Use bounded lifecycle coordination rather than a fire-and-forget task in `applicationWillTerminate`; ordinary automatic progress updates can remain coalesced.

**Checks:** forward/backward seeks while speaking; two rapid seeks with delayed acknowledgements; stale range/end/cancel callbacks; mode/document switch during await; Stop before microphone startup; no per-word engine restart.

**Acceptance:** no cursor rollback, unrelated-word jump, surprise audio/mic start, or wrong-document mutation in the scripted race tests.

### R04 — Apply the shared visual language and native shell composition

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02.

**Goal:** establish a coherent modern native frame without hiding unfinished behavior behind decoration.

**Read:** sections 4 and 5; `ContentView`, `DetailView`, `SidebarView`, `PlayerBar`, app window configuration.

**Files:** new `ReaderTheme.swift`; `ContentView.swift`, `ReadAlongApp.swift`, small style adoption in `SidebarView.swift`, `PageView.swift`, and `PlayerBar.swift`; no broad business-logic edits.

**Implementation steps:**

1. Implement semantic dynamic colors shared by SwiftUI/AppKit, plus the small spacing/radius/type vocabulary. Include solid/high-contrast variants.
2. Apply canvas/surface hierarchy and consistent margins to the shell. Retain native traffic lights, sidebar splitter, window resizing, and unified toolbar.
3. Recompose toolbar actions according to section 5.2. Keep secondary actions reachable through a labeled menu and the menu bar.
4. Reserve the dock's measured layout height in all panes using one shared inset; remove fixed duplicate 60/78 pt compensations where the new layout owns the space.
5. Set a sensible clamped initial window size and restore existing frame state rather than reapplying the default on every show.
6. Establish responsive control priorities at the minimum width; hide secondary choices into appropriate popovers before truncating core transport.
7. Do not restyle every native control into a new custom control if native interaction already works.

**Checks:** screenshots/manual inspection at the specified window sizes in light/dark; bottom-line/page visibility; sidebar collapse/restore; menu discoverability; Reduce Transparency and Increase Contrast variants.

**Acceptance:** the shell no longer reads as an undifferentiated gray control panel; no content is hidden behind the dock; all current actions remain reachable.

**Note:** visual checks must be marked unrun when no interactive capture/inspection occurred. Token contrast math alone is not visual QA.

### R05 — Make loading and readiness first-class UX

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02, R04.

**Goal:** give document loading, AI preparation, and TTS preparation distinct, responsive, reusable presentations before their producer tasks are completed.

**Read:** section 11.6 in full, recovery matrix, sections 12 and 13; current startup/placeholder/toast paths.

**Files:** `ContentView.swift`, `ReaderModel.swift`, focused loading subviews or `LoadingStatusView.swift` only when reused, `Models.swift`/session values as necessary, native state/presentation checks.

**Implementation steps:**

1. Add document-scoped opening/text-load/preview-load states. Keep them distinct from download and audio preparation states.
2. Set immediate acknowledgement before awaiting Open/Load requests. Show stable scoped placeholders, not old content under a new title.
3. Implement small consistent busy/phase/error anatomy: title, one useful sentence, actual progress when available, and real actions.
4. Map unknown progress to indeterminate presentation. Never map estimated elapsed time to a fake percentage.
5. Define dock presentation for Preparing voice, Preparing voice following, Waiting for next page, and Stopping, using the shared transport/reason contract.
6. Implement lightweight generation-scoped slow-wait messaging/cancellation presentation. Wire only real cancellation actions; R10/R11/R13/R15 provide the remaining producer events.
7. Provide controlled test/preview inputs for immediate, short, long, failed, canceled, and completed operations without making demo state part of production behavior.
8. Ensure VoiceOver announces meaningful phase transitions, not every timer tick.

**Checks:** inject 0 ms/300 ms/5 s/prolonged states; rapid A→B opening; error remains visible; loading one operation does not disable unrelated reading; repeated initiating clicks dedupe.

**Acceptance:** all three categories—documents, AI engines/models, and TTS—have specific agreed presentation and recovery, with no app-global `isLoading` shortcut.

**Handoff boundary:** this card verifies the presentation/state seam. Final end-to-end readiness must also be verified when R10, R11, R13, and R15 wire real producer signals.

### R06 — Build the native zoomable source surface

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02, R04, R05.

**Goal:** replace the passive fitted image with a real native document surface while preserving exact source geometry.

**Read:** section 9 completely; `PageView.swift`, page image loading/cache paths, existing source storage/validation/routes; source fixture generators.

**Files:** `SourceViewer.swift`, `PageView.swift`, source-readiness gating in `ContentView.swift`, `ReaderModel.swift`, `BackendClient.swift`, relevant `Models.swift`; Python document-source route; `scripts/build_app.sh` for PDFKit linking; geometry/source-access tests.

**Implementation steps:**

1. Add the managed document-source route using existing document ID validation. Serve only the registered source and correct content type; test path traversal and invalid IDs.
2. Capture document/revision/generation when fetching source. Cache it once per source revision and dedupe in-flight requests.
3. Prove PDFKit rendering plus normalized overlay placement on all geometry fixtures before moving the production PDF path.
4. Use one AppKit/PDFKit scroll/magnification owner. For images, host high-resolution managed source and overlay in a shared magnifiable document coordinate system.
5. Implement the canonical-page transform and its inverse; use PDFView's conversions after correct crop/rotation mapping. Keep source selection and transient overlays separate from permanent PDF annotations.
6. Keep visible overlay stroke/radius consistent in screen points. Do not scale a 2 pt border into a 12 pt marker at high zoom.
7. Provide stable-sized loading/failed/retry surfaces and clear stale page content on identity changes. Allow Original whenever a source exists; do not keep the current all-pane `hasWords` gate that hides previews until OCR finishes.
8. If the geometry gate fails, use the documented raster/AppKit fallback with the same public viewer seam, requested controls, and an explicit sharpness follow-up. Do not leave two unrelated production coordinate systems undocumented.

**Checks:** 25/100/200/400% rendering, all rotations/crops/page sizes, Retina scale, source loading A→B races, invalid source requests, overlay forward/inverse round trips.

**Acceptance:** native continuous zoom/pan works; source and marker remain aligned; source preview is not gated on readable words; no OCR/aligner replacement.

**Stop condition:** if the proposed PDF conversion cannot be explained and tested, do not approximate it by eyeballing the FixIt screenshot. Use the explicit fallback and record the blocker.

### R07 — Add useful source controls, page browsing, and word interaction

- [x] Implement and verify. (2026-11-07: complete functional pass; see `UI-remap-handoffs.md`)

**Depends on:** R03, R06.

**Goal:** make the viewer discoverable and fully operable by mouse, keyboard, and trackpad.

**Read:** sections 9.2–9.5, shortcut contract, and shared seek/browsing distinction; current page-button callers.

**Files:** `PageView.swift`, `SourceViewer.swift`, `ReaderModel.swift`, small native geometry/navigation checks; no new document processing engine.

**Implementation steps:**

1. Add the visible source toolbar: Pages, Previous, editable current/total page, Next, zoom out, percentage, zoom in, Fit menu.
2. Implement the bounded ~1.2× zoom steps, fit modes, 1-based page validation, Return commit, and Escape revert.
3. Previous/Next/page-field/thumbnail actions update browsed page only. They must not post `/jump` or restart narration.
4. Handle Left/Right only in the focused source canvas; preserve native scrolling and text-field/editor behavior. Expose the same actions in View/navigation menus when R21 integrates them.
5. Add lazy real page thumbnails; distinguish browsed page from live reading page. Avoid decoding all full-size pages.
6. Add source-word hit testing through the inverse canonical transform. Seek only on a genuine non-drag word click; skip whitespace/unmapped areas.
7. Offer Read from this page separately. If the page has no ready words, explain why this action is unavailable while viewing remains possible.
8. Keep single-image controls appropriate: zoom stays; irrelevant multipage navigation does not dominate.

**Checks:** first/last/blank/pending pages; invalid page input; keyboard focus inside page field/search/editor; click vs drag/pan/selection; word hit at multiple zooms; thumbnails on large PDFs.

**Acceptance:** the user's explicit zoom-in/out and arrow-key page-switching requirements work; no invisible side effect changes saved reading position.

### R08 — Separate manual browsing from automatic following

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R03, R06, R07.

**Goal:** remove scroll fighting, sticky manual pages, and cross-pane surprises.

**Read:** sections 8.4, 9.6, 10.3, and 13; `PageView`/native viewer scroll behavior; `ReaderTextView.Coordinator.scrollToCurrent`; all `manualPage` references.

**Files:** `ReaderModel.swift`, `ReadingSession.swift`, `PageView.swift`, `SourceViewer.swift`, `ReaderTextView.swift`, Split layout in `ContentView.swift`; native following-policy tests.

**Implementation steps:**

1. Give Text and Source independent follow flags and a separate browsed source page; remove legacy sticky-page behavior.
2. Detect manual input at the scroll/gesture owner, distinguishing it from programmatic follow scroll. Do not infer every bounds change is manual.
3. Keep the current marker inside the comfort band only when following and only when it leaves that band. Respect the dock/insets.
4. Add Return to reading in the detached pane; it resolves the current live cursor at click time and clears browsing detachment.
5. Explicit seeks return both panes to the chosen reading location; plain page browsing/find reveal does not.
6. Source zoom/pan preserves content anchor and does not trigger immediate unwanted recentering.
7. Restore Split ratio/focused pane and handle narrow detail width without destroying saved view choice.
8. Order phrase/group geometry deterministically before selecting a scroll anchor.

**Checks:** text manual scroll during TTS; source browsing during Follow me; automatic page crossings; return after several page advances; resizing/zooming while following; programmatic scroll not detaching itself.

**Acceptance:** reading continues correctly while the user browses, both panes have predictable independence, and no scroll operation writes an unrelated reading position.

### R09 — Refine recovered text and correct rendering/search behavior

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R02, R04, R08.

**Goal:** create an editorial reader that remains correct across identity, theme, formatting, and selection changes.

**Read:** sections 4.3, 8.2, 10.1–10.3; all of `ReaderTextView.swift`; existing presentation-block metadata/tests.

**Files:** `ReaderTextView.swift`, `ReaderTheme.swift`, `ReaderModel.swift` only for needed state/actions, Find/Aa hosting in `ContentView.swift`, native rendering/mapping tests.

**Implementation steps:**

1. Replace count-only content signatures with document/revision/layout signatures. Reapply highlight attributes after every content rebuild, including same-count edits, font changes, and appearance changes.
2. Apply approved reading typography and block-aware spacing. Scale rows/labels with body size and avoid huge page-heading gaps.
3. Keep original token text and existing word IDs; do not lose punctuation-only display tokens or normalize displayed text destructively.
4. Preserve UTF-16 span mapping; check composed/emoji/smart-quote cases. A selected range/drag must not become an accidental seek.
5. Update only old/current/next affected highlight ranges in ordinary cursor movement. A guide/theme change may do a deliberate full update once.
6. Enable native/find-compatible document search, count/navigation, and distinct search highlight; reveal results without auto-playing or silently seeking.
7. Provide an explicit Read from here action for search results and useful contextual actions for selected text.
8. Add the compact Aa popover using existing saved font choices, with live size/guide preview.

**Checks:** equal-count A/B documents; equal-count edits; font/theme changes with stationary cursor; all block kinds; Unicode range maps; selection/copy; search in OCR-only text; 25,000-word fixture.

**Acceptance:** no stale document text/highlight; modern readable typography; native selection/find still work; no thousand-word full repaint caused by RMS-only changes.

### R10 — Finish TTS preparation and the adaptive reading dock

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R03, R04, R05, R09.

**Goal:** narration feels responsive before speech begins, follows real words, and behaves predictably when paused/seeking/changing voice.

**Read:** sections 5.3, 8, 11.6, 12, and 13; `SpeechController.swift`, narration construction/callbacks in `ReaderModel`, `PlayerBar` bindings.

**Files:** `SpeechController.swift`, `ReaderModel.swift`, `PlayerBar.swift`, small shared presentation/session values, relevant native tests; focus consumers only to adopt the shared presentation.

**Implementation steps:**

1. Bridge the native synthesizer didStart event to `onStart`, preserving utterance/run identity; use the first valid range as a supported fallback.
2. Acknowledge Play immediately as Preparing voice. Leave that state only on a valid event, not `speak()` returning. Do not flash Preparing between every sentence.
3. Add generation-scoped delayed-start recovery and a bounded no-start failure path as specified in 11.6. Stop before didStart must remain stopped after any late event.
4. Start at the exact selected word; preserve range-driven UTF-16 highlighting and block-aware chunks. Never replace range callbacks with a speed timer.
5. Use one transport presentation for label/icon/enabled/busy state across the dock, menu, and Focus. Paused narration shows Resume, not Pause.
6. Recompose the adaptive dock; move long voice catalog, detailed word counts, and diagnostics into appropriate options/details.
7. Voice/speed changes resume from the current word only when previously active; paused remains paused. Guard preview speech so it does not overlap document narration.
8. Scrubbing previews the destination locally without posting per drag frame. Capture prior active state, pause/stop the engine for the gesture, commit through shared seek, and resume only the same active run. Escape/cancel restores the previous position/intent; document/mode changes invalidate the scrub.
9. Display time remaining as an estimate (“About 4 min left”), not a falsely exact timer derived from a fixed 175 WPM assumption.
10. Handle incomplete next-page text through Waiting for page, not premature completion; preserve the run's cancellable intent for R15 integration.

**Checks:** actual start/range/end/cancel mapping; callback never arrives; Stop before start; pause/resume; active vs paused voice/speed change; backward word seek; scrub cancel/document switch; exact 0/100%; pending frontier.

**Acceptance:** no false playing state while a voice is initializing; no fake word timing; no surprise restart; controls fit minimum window width and preserve all needed actions.

**Physical follow-up:** listen with at least two installed voices, including one non-default voice. Automated callback injection is not a listening test.

### R11 — Make Follow me setup, warm-up, and live capture trustworthy

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R03, R05, R10.

**Goal:** users always know whether the app is downloading, loading, listening, matching, or stopped.

**Read:** sections 6.3–6.4, 8.6, 11.6, and 13; launch permission helper; `toggleFollow`/`setMode`; Python `ASR`/`App.start`/`stop`/warm-up paths; microphone selection code.

**Files:** `ReadAlongApp.swift`, `BackendService.swift`, `ReaderModel.swift`, `PlayerBar.swift`, `SpeechController.swift` only if needed for engine exclusivity; Python ASR/App status paths; microphone/state tests.

**Implementation steps:**

1. Remove the launch-time permission request. Keep a native helper that is called only after the user's current explicit Follow me intent.
2. Explain permission before requesting it; handle already-authorized, denied, restricted, and not-determined states separately.
3. Separate engine warming without capture from actual listening. Starting the backend early must not make the dock claim the microphone is active.
4. Keep Stop reachable during warm-up/permission/start; cancellation clears current listening intent before the engine becomes ready.
5. Surface real microphone levels with a display mapping calibrated to actual hardware; raw 0–1 RMS is not necessarily a useful visible meter. Do not animate fake input while silent/preparing.
6. Present humane matching status and expandable transcript/confidence. Low signal, no match, and disconnected device get distinct guidance.
7. Handle selected-device disappearance and failure to apply a selection; do not show a success toast if `/mic` failed. Refresh by stable device identity/name as appropriate to current APIs.
8. Ensure mode/document changes and shutdown stop capture; handle sleep/interruption safely. Reused external speech servers must not be terminated as if owned.
9. Preserve English-only disclosure and route missing speech-model state into contextual setup, not a transient error.

**Checks:** permission-state injection; Stop during delayed engine start; late permission completion after document/mode switch; no simultaneous app narration/listening; device list changes; failed `/mic`; no match without fake cursor advance.

**Acceptance:** warm-up is visibly different from recording; no first-launch prompt; no late hidden microphone start; actionable recovery remains available.

**Mandatory physical QA:** built-in mic, at least one alternate input when available, quiet/noisy speech, restart/skip lines, denied permission, device removal. Record untested devices explicitly.

### R12 — Restore a genuinely useful first-run and empty-library experience

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R04, R05.

**Goal:** new users begin with a stylish useful choice, not an accidentally migrated sample or a wall of model downloads.

**Read:** sections 5, 6.1–6.4, 7.1, and 11.6; Python `main`/`DocumentStore._migrate_legacy`; current setup visibility conditions.

**Files:** `SetupCard.swift`, `ContentView.swift`, relevant `SidebarView` empty state, `ReaderModel.importSample`/setup intent; Python startup/sample selection; isolated startup/library tests.

**Implementation steps:**

1. Separate fresh GUI startup from deliberate `--image`/CLI processing. Do not populate fresh GUI data with a sample just to ensure a source exists.
2. Preserve migration of real preexisting `current.pdf`/`current.jpg` user work. Distinguish it from a newly auto-copied sample; do not delete legacy user files.
3. Allow the backend to start with no source and an empty library instead of exiting or forcing OCR.
4. Build the single useful welcome from section 6.2 using real actions and shared visual tokens.
5. Make Try a sample explicitly import the bundled text-layer PDF, without requiring either app model or the microphone.
6. Keep setup dismissible and existing libraries unblocked. Mark completion on a deliberate user action/successful first-use milestone, not merely view appearance.
7. Explain Read to me vs Follow me briefly; let model requirements appear contextually through R14 rather than downloading both in advance.
8. Reconcile all empty cases: no library, no active selection, empty search, no readable text, and loading are not the same state.

**Checks:** fresh empty temp data, existing real legacy document, existing library with onboarding marker absent/present, repeated launch, sample route unavailable, explicit CLI `--image`, no model caches.

**Acceptance:** first launch is usable offline with a sample/text PDF; no automatic sample insertion, prompt, or model download; actual legacy work still loads.

### R13 — Make model downloads/readiness/cancellation real

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R01, R02.

**Goal:** backend model state is truthful enough for the polished setup UI to rely on it.

**Read:** sections 6.5–6.7, 11.6, and 13.6–13.7; all `Models` helpers and downloader paths; existing Hugging Face/fermion integration and environment overrides.

**Files:** `readalong.py`, `test_models.py` or focused existing tests, `Models.swift`, `BackendClient.swift`, `Makefile` test wiring if necessary; one narrowly scoped downloader worker helper only if required.

**Implementation steps:**

1. Derive usable artifact requirements from the installed downloader/model metadata. Do not guess a single weight filename or declare any directory with config.json complete.
2. Separate Missing, Downloading, Verifying/Installing, Installed, Interrupted/Canceled, and Error states. File installation and in-memory engine preparation remain different facts.
3. Report bytes only with their actual meaning; flag approximate totals/progress. Never mix unpacked disk size into a precise network percentage without labeling it.
4. Add per-model owned cancellation. Use library support if reliable; otherwise place just the noninterruptible OCR download in an owned worker process. Stop only that worker and keep resumable temporary files.
5. Implement `/setup/cancel` with allowlisted model keys and `can_cancel` truthfulness. Test cancellation-vs-completion races and duplicate starts.
6. Check storage conservatively and provide specific error information without deleting a usable installed model on failure.
7. Prevent unsafe removal during download/dependent use. Keep known-path deletion bounds and all cache environment overrides.
8. Cache/throttle expensive directory status scans when safe; update readiness on actual job completion/removal/explicit refresh.
9. Report current worker/model load phases where observable. Do not fake “compiling” if the backend cannot know that distinction.

**Checks:** fake partial and complete artifacts; invalid key; duplicate Download; Cancel before worker assignment; Cancel at completion; retained partial files; remove with another job active; storage/download failure; ready state from preexisting cache.

**Acceptance:** no premature Ready, no unsupported Cancel success, no arbitrary path deletion, no forced redownload of an existing usable model.

**Do not:** perform a real 1.6 GB download or remove a real model as part of ordinary automated tests. Record clean-machine/slow-network trials as separate authorized QA.

### R14 — Build contextual setup and a single live model manager

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R05, R12, R13.

**Goal:** users can understand, start, observe, leave, retry, and remove the right model without losing their reading flow.

**Read:** sections 6 and 11.6; current `ModelCard`, setup refresh methods, Settings polling loop, missing-model Follow me/recovery errors.

**Files:** `SetupCard.swift`, `SettingsView.swift`, `ReaderModel.swift`, `ContentView.swift` contextual setup hosting, `BackendClient.swift` only for adopted methods; native state/presentation tests.

**Implementation steps:**

1. Refactor/reuse one ModelCard presentation across onboarding/contextual setup/Settings, driven by the R13 contract.
2. Use capability-first names, size, privacy/local explanation, truthful phase/progress, and an advanced disclosure for IDs/paths/licenses.
3. Move model-status refresh ownership to one model/task lifecycle. Multiple visible surfaces must not spawn redundant loops; progress stays live when Settings closes and another interested surface remains.
4. Missing speech model opens Set up voice following; missing handwriting model retains the document preview and offers its specific setup.
5. Keep the user's document/job intent bound to identity/generation. A completed download cannot reopen a document or start a mic after the user left that intent.
6. Implement Not now/continue elsewhere, Retry, real Cancel, and post-download Start listening/continue recovery choices.
7. Replace the incorrect removal explanation and global confirmation binding with one model-specific target and accurate consequences.
8. Show installed disk usage and Reveal in Finder only for validated known model paths. Treat backend remove/download failure as persistent card feedback.

**Checks:** progress in first-run card, Settings, and contextual setup; opening/closing multiple surfaces; skipped setup; speech-only/handwriting-only machines; two cards with one Remove; model completion after document switch; canceled/failed operations.

**Acceptance:** setup never implies Read to me needs the ASR model; no stale progress or wrong-model confirmation; useful local reading remains accessible throughout.

### R15 — Complete document opening/import and incremental processing UX

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R02, R03, R05, R06, R10, R13, R14.

**Goal:** every document operation is responsive, truthful, and safe, including scans that become ready page by page.

**Read:** sections 7, 8.7, 11.6, and 13; `importFile`, `openDocument`, `loadModel`, drop handler; Python `import_document`, `pdf_pages`, `run_ocr_many`, `_run_ocr`, and readiness state.

**Files:** `ReaderModel.swift`, `BackendClient.swift`, `ContentView.swift`, `Models.swift`; Python ingestion/jobs/publication; targeted `test_workflow.py`/library tests/native checks. Finder-open integration may also touch `ReadAlongApp.swift`/`Info.plist`.

**Implementation steps:**

1. Acknowledge Open/Import immediately; stop/save previous playback before changing session identity. Preserve a recoverable previous selection if the new open fails.
2. Preflight type/size, read/encode without avoidable main-thread stalls, validate again server-side, and reject multiple drops explicitly. Normalize image orientation once and give locked PDFs an explicit unlocked-copy explanation.
3. Narrow advertised types to verified support. Add per-import recovery choice without moving the global default out of existing preferences.
4. Expose actual validating/rendering/engine-load/recognition/mapping/saving phase events and physical page information where available. Unknown progress remains indeterminate.
5. Show original preview independently of recovered text. Publish per-page pending/ready/empty/error status and keep the processing strip once any words exist.
6. Treat missing model as an actionable dependency state, not corruption. Resume only the same intended job after setup; do not recreate or duplicate the document.
7. Preserve a page-local cursor anchor on partial model publication. Test an earlier scanned page inserting words before a currently narrated later text page.
8. Keep range callback mappings tied to their snapshot and resolve to the current model safely. Unchanged appended pages should not unnecessarily interrupt speech; changed current content must pause/rebuild deliberately rather than map to random words.
9. Enforce physically ordered reading frontiers: pending is not blank or finished; skip only confirmed nonreadable pages. Extend/continue narration when the same active run is still waiting for text.
10. Offer only a real safe stop/cancel path. A noninterruptible OCR call may finish its current page; retain ready pages/source and reject duplicate jobs.
11. Opening another ready document while OCR runs remains supported; a second import is an explained busy state, not an invented queue.
12. If implementing Finder Open With, register verified types and route through the same validated import path. Do not create a second source-management codepath.

**Checks:** cached open, text PDF without models, printed scan without LFM3, handwriting dependency, mixed partial PDF, empty/blank pages, corrupt/oversize/unsupported file, multi-drop, A→B races, import while job busy, interrupted restart.

**Acceptance:** clear UX throughout document loading, real preview before OCR, safe partial reading and correct eventual completion, no original-file loss or hidden model download.

### R16 — Refine library navigation, metadata freshness, and row safety

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02, R04, R05, R15.

**Goal:** the library is attractive, fast to scan, and truthful while background work and reading progress change.

**Read:** sections 5.1, 7.5, and 11; `SidebarView.swift`, `refreshLibrary(quiet:)`, rename/delete model actions, Python public library payload.

**Files:** `SidebarView.swift`, `ReaderModel.swift`, small thumbnail support from source viewer/cache, native/library tests.

**Implementation steps:**

1. Build well-proportioned rows with real bounded thumbnails/type fallback, title, useful metadata, and clear selected/hover/focus states.
2. Add local title/file-name search and a distinct no-results state.
3. Replace ID-only quiet refresh comparison with metadata-aware updates. Keep row order stable during reading/progress so clicks do not move underneath users.
4. Adopt central progress/completion and processing status. A completed row is Completed, never capped at 99%.
5. Keep row actions discoverable from hover/focus and native context menu. Provide accessible names scoped to the document.
6. Keep rename draft/validation until success; preserve the sheet on backend failure.
7. Guard deletion of processing/in-use data, clearly describe managed-copy deletion, and stop only the affected active session.
8. Add the quiet shared activity/download entry without turning the sidebar into a model dashboard.

**Checks:** unchanged IDs with new title/progress/error/status; long names; filtered current selection; rename error/limit; active/inactive deletion; last-document removal; thumbnail loading failure; huge library scroll without full-page decode.

**Acceptance:** metadata stays current, navigation does not jitter, and destructive actions do not disturb unrelated reading or the original external file.

### R17 — Protect correction drafts and preserve source/reading integrity

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R02, R03, R09, R15.

**Goal:** correcting OCR feels safe and contextual rather than a risky raw-text rewrite.

**Read:** sections 10.5 and 13; all `EditSheet.swift`, native save/reprocess calls, Python `set_script`, cache write/line-box mapping helpers.

**Files:** `EditSheet.swift`, `ReaderModel.swift`, `BackendClient.swift`, dirty-draft close/quit coordination in `ContentView.swift`/`ReadAlongApp.swift`, Python script/correction path; focused workflow/native tests.

**Implementation steps:**

1. Capture document ID, visible page, model revision, and reading anchor on editor entry; initialize on that page, not 0.
2. Add a source preview and line-associated editing while retaining native text editing/undo. Keep draft separate from incoming model snapshots.
3. Track dirty state; guard page change, dismiss, document change, and quit with Save/Discard/Cancel. Do not reload a dirty draft in `onChange(pageModel)`.
4. Use Save/`⌘S` and retain normal newlines in the editor. Keep errors inline and do not dismiss until save succeeds.
5. Make reprocessing scope truthful. Preserve a bounded recoverable previous correction/cache before replacing it; warn before overwriting manual corrections.
6. Change the backend correction operation to validate intended document/revision, preserve unchanged line geometry, and safely map changed lines. Inserted/unmapped lines receive no fake box.
7. Reuse existing line-matching helpers only after checking their coordinate conventions; do not pass top-left data into a helper expecting Vision bottom-left observations.
8. Remap the cursor through page/text context on save; preserve other pages and documents. Empty-text replacement requires explicit intent and keeps the source viewable.
9. Stop/pause the active engine deliberately before editing; exit does not unexpectedly resume microphone capture.
10. Handle Save while OCR is still publishing explicitly: merge safely or defer with a visible explanation and a preserved draft. Test that later job publication cannot overwrite a successful correction.

**Checks:** dirty page switch Cancel/Discard/Save; background OCR update; save network failure; same-count edit; line insertion/deletion; all-text removal; current document changed mid-request; saved reading anchor; untouched page boxes.

**Acceptance:** no silent draft loss, no whole-document position reset, no incorrect ordinal box reassignment, and correction failures leave recoverable user work intact.

### R18 — Make export choices and success/failure truthful

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R03, R06, R17.

**Goal:** users export the intended page/overlay and can trust the result feedback.

**Read:** section 10.6 and the identity contract; grep every export caller; Python `export_image` and `/export`.

**Files:** `ReadAlongApp.swift` export helper, `EditSheet.swift`, `BackendClient.swift`, document menu in `ContentView.swift`, `ReaderModel.swift`; Python export validation; tests.

**Implementation steps:**

1. Define explicit current-reading-highlight and all-word-box-proof actions; keep the existing proof use case.
2. Capture document/revision/page/mode before opening the panel and before awaiting the export. Reject stale or unavailable live-highlight context clearly.
3. Pass the selected mode to the backend. Do not silently export proof because a browsed page is not the current reading page.
4. Validate mode/page/document server-side for new native calls and preserve compatibility callers deliberately.
5. Remove silent `try?` export decoding/write handling; return/throw actionable errors.
6. Write safely, show success only after destination write completes, and leave cancellation quiet.
7. Use sensible document/page/mode file names and optional Reveal in Finder, with no cloud upload or bulk-export scope creep.

**Checks:** correct page/mode pixels; browser/source page differs from live cursor; document switch while save panel open; canceled panel; invalid destination/write failure; backend error/malformed response; existing proof export.

**Acceptance:** an exported file matches its action label and captured document; failures never produce a success toast.

### R19 — Build a coherent Focus stage with exact restoration

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R03, R08, R09, R10, R11.

**Goal:** full-screen reading is a polished continuation of the same session, not a separate fragile overlay.

**Read:** section 10.4; `PresentView.swift`, enter/exit methods, text-stage styles, shared transport and viewport state.

**Files:** `PresentView.swift`, `ReaderModel.swift`, `ReaderTextView.swift`, relevant shell/command labels; native restoration/presentation tests.

**Implementation steps:**

1. Use Focus in user-facing labels while avoiding unnecessary internal symbol renames.
2. Remove nested scroll ownership; apply explicit stage text/background/highlight colors independent of light system appearance.
3. Capture prior pane/sidebar/split/viewport and whether Focus itself entered fullscreen. Restore exactly; do not exit user-owned preexisting fullscreen.
4. Use the same seek and audio presentation model as the dock/menu. Pause/preparing/listening are not all a generic Pause icon.
5. Add true pointer-idle chrome hiding with a short delay, canceled by pointer movement, focus, open popover, or error; keep essential microphone-active indication visible throughout capture.
6. Keep exit discoverable and Escape reliable; do not consume text selection/word click through background tap handlers.
7. Preserve active audio and cursor through enter/exit without a new utterance or microphone stream unless the user explicitly changes transport.

**Checks:** enter from all panes, both appearances, active/paused/idle/listening/preparing; already-fullscreen window; Escape with popover; selected text; pointer idle vs keyboard focus; repeated enter/exit.

**Acceptance:** no black-on-black/light-mode stage, double scrollbars, wrong play icon, lost position, or unexpected fullscreen transition.

### R20 — Organize Settings without breaking saved preferences

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R04, R10, R11, R14.

**Goal:** settings are attractive, understandable, and consistent with the rest of the app.

**Read:** section 11.1, visual/accessibility tokens, preference decoding and all Settings entry points.

**Files:** `SettingsView.swift`, settings host in `ReadAlongApp.swift`, `ReaderModel.swift` preferences, shared model components; one focused settings controller only if verified necessary; decoder tests.

**Implementation steps:**

1. Organize the five specified categories in a proportioned native sidebar/detail or equally clear native form layout.
2. Keep a single Settings host and standard `⌘,` command; no parallel custom and SwiftUI windows.
3. Apply shared theme, grouped forms, correct background/scroll-edge treatment, and macOS 14 fallback. Never raise minimum OS for cosmetic APIs.
4. Put OCR defaults under Processing, voice/mic under Voice & microphone, and local/privacy/license information where discoverable.
5. Show live reading/appearance previews without changing a playing engine unexpectedly.
6. Add new preferences with backward-compatible decoding and deliberate defaulting. Preserve every existing valid saved preference.
7. New-user sound/haptic defaults can be quiet; do not overwrite existing choices or play cues while simply opening settings.
8. Validate actual installed voice/device availability when entering relevant panes; explain missing choices instead of retaining stale selection labels.

**Checks:** old preference blobs, new optional fields, invalid single-field fallback without wiping unrelated choices, one settings window from all entry points, dark/light/system consistency, minimum sizing, model progress while another surface is visible.

**Acceptance:** settings are not an overcrowded fixed form; no lost preferences, duplicate hosts, or unsupported new APIs on macOS 14.

### R21 — Finish menus, focus-aware keyboard behavior, and Help

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R07, R09, R17, R18, R19, R20.

**Goal:** all visible behavior has consistent discoverable Mac commands without stealing ordinary text input.

**Read:** sections 9.3 and 11.2; `ReadAlongApp` commands; every view-specific shortcut/handler; old README keyboard claims.

**Files:** `ReadAlongApp.swift`, focused responder handling in text/source/editor/search, relevant `ContentView` helpers, lightweight Help content, README shortcut section; native key-policy checks.

**Implementation steps:**

1. Implement the agreed shortcut table using current focus/capability, with dynamic labels/enabled state.
2. Space toggles transport only in reader/canvas context; it inserts spaces in editors/search. Left/Right browse pages only when Source owns that input.
3. Preserve native text selection, caret navigation, copy/paste/find, undo/redo, and menu handling.
4. Route menu commands through the same operations as buttons, not direct singleton mutation that bypasses validation/session intent.
5. Make zoom commands identify/apply to the focused pane in Split, including plus/equals keyboard variants.
6. Keep standard native menus and sidebar/fullscreen operations. Any local key monitor has explicit lifecycle cleanup.
7. Replace the GitHub-homepage Help link with real app help/shortcuts and a verified project/documentation destination when external help is offered. Do not guess a repository URL.
8. Update shortcut copy/tooltips together; do not leave README claiming bare brackets/arrows mean something else.

**Checks:** keyboard-only open/setup/read/seek/zoom/page/find/edit/export/focus/settings; text fields and multiline editor consume normal keys; disabled state with no source/words; shortcut labels match actual commands.

**Acceptance:** no keyboard traps, accidental playback while typing, source-page jumps while selecting text, or misleading help/shortcut documentation.

### R22 — Provide durable recovery and owned-engine reconnection

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R05, R11, R13, R15, R17, R18.

**Goal:** failures remain understandable and recoverable without abandoning the document or user work.

**Read:** sections 11.4–11.6 and 13.7; `BackendService`, `BackendClient`, poll failure handling, FatalView/toasts, import/save/export error paths.

**Files:** `BackendService.swift`, `BackendClient.swift`, `ReaderModel.swift`, `ContentView.swift` recovery/status surfaces; focused backend error handling and failure tests as necessary.

**Implementation steps:**

1. Distinguish engine startup, disconnected/reconnecting, recoverable operation failure, and unrecoverable incomplete-bundle failure.
2. Preserve last valid document identity/view/cursor and any draft while reconnecting; do not keep showing a permanently live mic/play indicator after connection loss.
3. Add Retry/restart for the owned helper, with reset readiness/base URL/request generation and no duplicate process launch.
4. Treat unexpected clean backend exit as disconnection too; do not handle only nonzero exits.
5. Make ongoing poll failures visible after a sensible threshold instead of silently ignoring them forever. Recovery acknowledgements cannot roll back a newer document selection.
6. Keep technical logs collapsed and optional. Copy diagnostics must avoid exporting raw document text/transcripts/private paths without explicit consent.
7. Propagate malformed success responses as failures for import/save/export; do not replace good content with an empty decoded fallback.
8. Replace ephemeral-only errors with durable inline actions appropriate to the operation. Routine opens/navigation no longer flood success toasts.
9. Avoid main-thread blocking waits during an ordinary retry/shutdown path; terminate only processes actually owned by the app.

**Checks:** slow startup, missing interpreter, backend killed/nonzero/clean exit, failed polls then reconnect, draft open during disconnect, failed save/export/import, duplicate Retry, stale old-session response.

**Acceptance:** the user can tell what failed and what to do next; the app never claims saved/exported/recording when the corresponding operation failed or vanished.

### R23 — Complete accessibility and appearance validation

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R04–R22 UI work integrated; inspect every intervening UI producer, not just the range endpoints.

**Goal:** styling never trades away readability, keyboard operation, or assistive technology support.

**Read:** section 11.3, all component-state tables, native design guidance; inspect every custom control and AppKit adapter, not just SwiftUI buttons.

**Files:** only the relevant current view/theme/adapter files and focused checks; avoid unrelated refactoring.

**Implementation steps:**

1. Audit every icon-only control for action label/value/hint and logical enabled state.
2. Audit focus order and visibility through library, source controls, dock, setup, editor, settings, and Focus.
3. Provide accessible reading/page/zoom/transport values without announcing every word/ASR update.
4. Verify custom Canvas/source overlays have text/keyboard alternatives; selection and VoiceOver reading remain independent of visual auto-follow.
5. Apply Reduce Motion/Transparency, Increase Contrast, and Bold Text to every custom surface/marker.
6. Measure composed contrast, including actual highlights, muted text, busy source imagery, and materials—not just palette pairs.
7. Inspect largest reading size, long labels, localization expansion where practical, minimum window width, and disabled controls.
8. Fix only observed accessibility issues; do not add a parallel accessibility-only application flow.

**Checks:** Full Keyboard Access; actual VoiceOver pass; both appearances; high contrast; reduced transparency/motion; largest reader size; keyboard focus while chrome might hide.

**Acceptance:** all critical reading/setup/navigation actions are accessible; assistive settings do not produce invisible text, lost focus, or motion-heavy following.

**Reporting:** a source inspection of accessibility labels does not count as a VoiceOver test. Mark physical assistive-technology checks unrun if not exercised.

### R24 — Measure and remove native loading/rendering bottlenecks

- [x] Implement and verify. (2026-11-07: verified existing; see `UI-remap-handoffs.md`)

**Depends on:** R06, R08, R09, R10, R11, R15, R16, R19, R22.

**Goal:** make “snappy” an observed property while avoiding speculative architecture work.

**Read:** section 12 and the final integrated code; current cache refresh and attributed-text update paths; documented baseline caveats.

**Files:** only measured hot paths in `ReaderModel`, `ReaderTextView`, source viewer/cache, backend status/ingestion if implicated; focused performance checks/documented results.

**Implementation steps:**

1. Profile the 100-page fixture while loading, scrolling, zooming, searching, narrating, and receiving simulated Follow me state.
2. Measure input acknowledgement, callback-to-draw delay, warm cached page switching, document restore, and memory separately from AI/model latency.
3. Remove same-key force reload/cancel loops and dedupe source/page requests.
4. Bound full-size page/source/thumbnails caches and prefetch adjacent content. Invalidate only changed document/revision content, not every page on each publication.
5. Verify that RMS/transcript/progress updates do not rebuild the full attributed text or animate the entire root tree.
6. Move only measured expensive file/decode/format work off the synchronous UI actor path, respecting the actual compiler/toolchain. No blanket actor/protocol migration.
7. Coalesce preference saves to interaction boundaries; do not write UserDefaults every pinch frame.
8. Confirm canceled/closed views release polling, timers, observers, image loads, and idle-hide work.
9. Record baseline and final measurements, machine, build mode, fixture, and any unmet target honestly.

**Checks:** section 12 budgets; warm/cold separation; sustained navigation memory; repeated open/close/settings/focus cycles; inactive-window reading behavior; all correctness checks still pass.

**Acceptance:** no measured avoidable UI stalls or unbounded retention; optimization did not alter the aligner/reading semantics merely to improve a benchmark.

### R25 — Verify the whole journey, update docs, and package the result

- [x] Implement and verify. (2026-11-07: complete; see `UI-remap-handoffs.md`)

**Depends on:** R01–R24 required implementation integrated; unresolved failures remain release blockers.

**Goal:** ship one coherent redesign rather than a set of individually attractive but incompatible screens.

**Read:** the acceptance matrix/release gates below, all unresolved task handoffs, current README/architecture/history, packaging scripts.

**Files:** tests/final targeted fixes as needed; `README.md`, relevant `ARCHITECTURE.md`/`TODO.md` updates, packaging resources/scripts only when required by the integrated app.

**Implementation steps:**

1. Run every automated check and a fresh native build; inspect the actual app, not just static SwiftUI previews or the old browser screenshots.
2. Execute the matrix below with a clean isolated data/cache environment and again with a preserved existing library.
3. Capture the actual integrated screens/states at representative sizes in light/dark and accessibility variants. Compare every surface with the design spec.
4. Perform authorized real microphone, TTS listening, trackpad, VoiceOver, and slow-network/model-download checks; record unrun cases without claiming them passed.
5. Verify loading feedback for AI download, installed-weight loading, speech warm-up, TTS preparation, cached document opening, scan import, uncached page rendering, failure, cancellation, and retry.
6. Update docs to the actual native architecture/commands/capabilities; clearly separate historical browser notes rather than erasing user history wholesale.
7. Preserve internal app/bundle/data names, cache reuse, licenses, and minimum OS; verify bundled sample and PDFKit linkage/resources.
8. Build/verify the DMG using the existing pipeline. Use Developer ID/notarization only with the user's available credentials/profile and authorization; do not publish/push a release automatically.
9. Provide a short final report listing implemented outcomes, actual tests/measurements, remaining limitations, and any release blocker.

**Checks:** `make test`, `scripts/test_native.sh`, `make app`, `plutil -lint macapp/Info.plist`, final `make dmg`/bundle verification, and the 49 scenarios in section 16. Mark network/hardware/OS-version cases Not run when the required environment or authorization is unavailable; a missing physical check is not a passing result.

**Acceptance:** all release-critical matrix cases pass; the app is visibly cohesive and behaviorally safe; no real-user data was sacrificed to obtain a clean demo.

**Do not:** mark the redesign complete because `make app` succeeds. Compilation is one gate, not the UX result.

---

## 16. End-to-end acceptance matrix

Every case below is **planned / not yet executed** in this document. The implementing agent records Pass / Fail / Not run, environment, evidence, and the blocking card if applicable.

### 16.1 First launch, models, and loading

| Case | Procedure | Required result | Verification |
| --- | --- | --- | --- |
| F01 | Start with isolated empty data and no app models. | Useful welcome, empty library, no auto sample, no microphone prompt/download. | Backend/native checks + actual app. |
| F02 | Choose Try a sample offline. | Bundled text PDF opens; Text/Original and installed-voice Read to me work without ASR/LFM3. | Actual app; no model network traffic. |
| F03 | Open an existing real legacy workspace. | Managed library migration preserves source/cache/corrected text; no forced onboarding reset. | Isolated migration test. |
| F04 | Choose Follow me with speech weights missing. | Contextual capability explanation, size, Download/Not now; Read to me stays available. | State tests + actual app. |
| F05 | Import handwriting without LFM3. | Source preview remains available; specific model requirement; no generic corrupt-document error. | Fake dependency test + actual app. |
| F06 | Download, then close Settings and open another model-status surface. | Real progress remains live from one owner; job is not duplicated or accidentally canceled. | Worker/status tests + actual app. |
| F07 | Cancel a download at start/middle/near completion. | Only the owned worker stops; UI reaches a truthful final state; partials remain safe; unrelated caches untouched. | Fake worker race tests; authorized real trial. |
| F08 | Simulate offline/storage/partial-artifact failure. | No false Ready or indefinite spinner; persistent Retry/guidance; useful local reading remains possible. | Automated failure injection. |
| F09 | Remove speech versus handwriting from the two cards. | Exactly one correct confirmation; consequences named; saved documents remain. | Fake caches + actual app. |
| F10 | Trigger cached-weight OCR/speech first load without download. | Installed and Loading are distinct; actual phase visible; preparing is not shown as active microphone capture. | Event/state test + physical warm-up. |
| F11 | Start TTS with delayed didStart/first range. | Immediate Preparing voice; no fake marker advancement; bounded recovery if no event arrives. | Native callback injection + installed voices. |
| F12 | Stop TTS/Follow me before preparation finishes. | Late completion cannot speak, record, or resurrect active state. | Deterministic race tests + physical check. |
| F13 | Use a missing/unavailable system voice. | Clear native-voice recovery; no misleading 158 MB “TTS model” download. | Availability injection + native UI. |

### 16.2 Document loading, processing, and navigation

| Case | Procedure | Required result | Verification |
| --- | --- | --- | --- |
| D01 | Open a cached document with immediate/300 ms/5 s/delayed responses. | Immediate acknowledgement, named scoped load state, stable layout, no artificial minimum wait. | Delay injection + app. |
| D02 | Open A then B with A completing last. | No A text/image under B title; A cannot start audio or overwrite B position. | Identity/race test. |
| D03 | Switch between equal-count documents. | Correct content/highlights every time; render identity not count-based. | Native assertions + visual check. |
| D04 | Import text-layer PDF without app models. | No unnecessary setup/download; real page/source preparation feedback; usable reader. | Fixture integration test. |
| D05 | Import a printed scan in Auto/Printed without LFM3. | Vision route when appropriate; honest first-use warm-up; no blanket large-model requirement. | Isolated route test + app. |
| D06 | Import mixed text/scanned pages and read later ready text while earlier OCR finishes. | Cursor/callback anchors rebase correctly; no unrelated-word jumps. | Controlled incremental fixture. |
| D07 | Reach pending next page while reading. | Waiting for page, not Finished; same active intent can continue; Stop remains effective. | State integration + actual playback. |
| D08 | Browse blank, pending, failed, and unboxed pages. | Source stays viewable; state distinctions are clear; no invented boxes or forced seek. | Fixture/app inspection. |
| D09 | Drop unsupported, corrupt, empty, oversized, or multiple files. | Specific validation; no silent first-file-only import; original/current library intact. | Trust-boundary tests + drag/drop. |
| D10 | Start another import while one OCR job runs; open another ready document. | Explained one-job limit; ready document remains readable; no fake queue. | Workflow tests + app. |
| D11 | Pinch/zoom 25–400%, fit page/width, actual size, and resize. | Anchored magnification, correct percentages, sharp PDF rendering or documented verified fallback, no overlay drift. | Geometry assertions + real trackpad. |
| D12 | Use Left/Right in source, then in page field/search/editor/text selection. | Page switching only when appropriate; normal typing/caret/selection behavior elsewhere. | Key-policy tests + keyboard-only pass. |
| D13 | Enter invalid page number; navigate first/last page; choose thumbnail. | Bounds/disabled states correct; browse changes no saved reading position. | Navigation tests. |
| D14 | Click a source word at several zooms; drag/select/pan/whitespace-click. | Genuine word seeks; other gestures do not accidentally seek. | Hit-test assertions + mouse/trackpad. |
| D15 | Check rotated/cropped/mixed-size PDF and FixIt slides. | Text/source markers align to actual intended words; thin consistent contours. | Geometry fixtures + screenshots. |

### 16.3 Reading, correction, and completion

| Case | Procedure | Required result | Verification |
| --- | --- | --- | --- |
| P01 | Play, pause, resume, seek backward/forward, change speed/voice. | Exact selected-word start, preserved position, proper active/paused policy; no stale callback takeover. | Native checks + listening. |
| P02 | Scrub while active, cancel scrub, switch document mid-scrub. | Preview is not repeated persistence; commit/cancel follows captured intent; old doc cannot restart. | State/race tests + app. |
| P03 | Manually scroll Text or browse Original while reading. | Only that pane detaches; playback continues; Return to reading uses live position. | Scroll-policy tests + actual app. |
| P04 | Cross page boundaries in automatic following. | Correct next page/marker without sticky manual-page lock or repeated recentering. | Playback + controlled state updates. |
| P05 | Read quietly with playback stopped. | No microphone/audio; explicit actions move marker; no fake silent-reading timer. | Actual app. |
| P06 | Use Follow me with silence, misrecognized text, restart/skip line, and alternate mic. | Marker reflects confirmed aligner position; truthful meter/match/device status; recovery usable. | Existing aligner tests + live read-aloud. |
| P07 | Change font/theme/size without moving cursor; edit same number of words. | Content/highlight refresh correctly; no stale signatures; viewport stays meaningful. | Render checks + screenshots. |
| P08 | Find text on an OCR page; navigate results; choose Read from here. | Search browse and reading seek are distinct; no audio starts merely on Find. | Search tests + app. |
| P09 | Enter/exit Focus from Text/Original/Split and already-fullscreen window. | Same session; correct dark stage; exact restoration; no nested scroll or paused-icon bug. | State checks + native fullscreen. |
| P10 | Edit current page, switch pages/dismiss during dirty draft, receive model refresh. | Save/Discard/Cancel; draft remains safe; no reset to page 0 or discarded changes. | Editor integration tests. |
| P11 | Insert/delete corrected lines and save. | Safe box mapping, unchanged pages intact, reading anchor retained, unmapped geometry disclosed. | Backend/native regression tests. |
| P12 | Export proof/current highlight; simulate write failure/document switch. | Correct captured page/mode; no silent fallback or false success. | Export tests + destination inspection. |
| P13 | Reach the actual end, relaunch, then explicitly Read again. | Exact bounded 100%, Completed everywhere, saved terminal position, no autoplay; Read again restarts intentionally. | Persistence + playback. |

### 16.4 System, accessibility, and performance

| Case | Procedure | Required result | Verification |
| --- | --- | --- | --- |
| S01 | Compare all major screens at minimum/default/large sizes in light/dark. | One coherent style; no clipped dock, unreadable metadata, misplaced controls, or old default-only surfaces. | Actual native screenshots. |
| S02 | Enable Reduce Motion/Transparency/Increase Contrast/Bold Text. | All custom UI adapts; reading remains clear and following non-disorienting. | Actual OS settings + inspection. |
| S03 | Complete first-use/read/zoom/page/find/edit/export/settings using keyboard only. | Logical focus, no traps, visible focus, no shortcuts stealing text input. | Full Keyboard Access. |
| S04 | Traverse library/setup/reader/player/source with VoiceOver. | Meaningful labels/values, ordinary text reading, restrained status announcements. | Physical VoiceOver pass. |
| S05 | Kill/restart backend, including clean exit, with a draft open. | Durable recovery, owned-helper restart, no lost draft/context or false active mic. | Failure injection + actual app. |
| S06 | Deny mic; unplug/switch input; sleep/wake. | Explicit safe capture state, actionable device/permission recovery, no hidden auto-recording. | Physical Mac/input checks. |
| S07 | Navigate/zoom/read the 100-page fixture repeatedly. | Meets measured responsiveness/cache bounds or records a specific remaining blocker. | Instruments + native timing. |
| S08 | Build/install final app/DMG with existing library/caches. | Correct name/resources/frameworks, minimum OS retained, no forced cache redownload or data migration loss. | Fresh build/package/install check. |

### 16.5 Screenshot review set

Capture the actual app for: welcome; empty library; cached document opening; scan processing with source preview; missing-model context; downloading/verifying/error/installed model cards; TTS preparing; speech warming with mic off; listening; Text; Original at fit and 200%; Split; detached browsing; Find; correction with dirty draft/error; export failure; Focus; Settings; completed document; disconnected engine.

At minimum, review Text/Original/Split/Settings/Focus in both appearances. Record OS version, window size, and accessibility variants. Do not use generated mockups as proof that the native app works.

---

## 17. Release gates, exclusions, and handoff template

### 17.1 Release gates

The redesign is ready only when all of these are true:

- [ ] Visual language is applied across the entire journey, not just the reader canvas.
- [ ] Fresh first launch works without forced sample insertion, downloads, or microphone permission.
- [ ] AI download, installed-model load/warm-up, TTS voice preparation, document opening/import, and page rendering each have truthful responsive UX.
- [ ] Zoom, fit modes, panning, page arrows, keyboard page navigation, page input, and thumbnails work on the source viewer.
- [ ] Reading marker follows real events; manual browsing and automatic following do not fight.
- [ ] One shared seek/session policy covers every caller, including Focus and menus.
- [ ] Partial processing cannot corrupt reading position, skip pending pages, or announce false completion.
- [ ] Corrections, saved positions, cache reuse, and original files survive the change.
- [ ] Export/save failures do not masquerade as success; dirty drafts are protected.
- [ ] Keyboard/accessibility/appearance requirements pass; unrun physical checks are called out as release risks, not silently checked.
- [ ] Native performance is measured on representative data and hardware, with AI latency reported separately.
- [ ] Tests and actual native build pass; final app/DMG resources/frameworks are verified.
- [ ] Documentation matches implemented commands and capabilities; no stale browser UI instructions masquerade as current design.

### 17.2 Explicit non-goals and scope boundaries

Do not add these merely because the redesign touches nearby code:

- New OCR/ASR/TTS model families, cloud AI, translation, multilingual following, or eye tracking.
- Accounts, analytics/telemetry, subscription screens, streaks, social features, or reading recommendations.
- A web/Electron/WKWebView rewrite, a full Swift-engine port, or an app-wide architecture migration.
- A general-purpose model/download manager, plugin system, event bus, database, state-management framework, or new dependency for a few lines.
- Automatic model relocation/redownload, broad cache cleanup, or resetting the user's library/preferences.
- Batch import queues, bulk export/ZIP, editable PDF annotations, manual bounding-box drawing, or full page-layout editing.
- Multiple independent playback windows before replacing the current singleton/active-backend-document assumptions.
- Custom window chrome, page-curl animations, decorative equalizers, or audio/haptics on every action.
- A mandatory app icon redesign before the reading/navigation/loading experience is correct.

A useful later enhancement can be recorded as a separate follow-up. It must not delay or destabilize the requested core experience.

### 17.3 Known constraints to retain honestly

1. Handwriting word boxes remain heuristic. A refined stroke cannot make incorrect OCR geometry exact; verify the underlying mapping and disclose missing boxes.
2. Speech following has real recognition latency and is currently English-only. Do not hide latency with invented cursor animation.
3. First-use Vision/Metal/model initialization can be slow on actual hardware. Clear preparation feedback is required even when total execution time cannot yet improve.
4. Native voice availability/download behavior is controlled partly by macOS. Do not promise an app-owned TTS-model progress bar the app cannot observe.
5. Some operations cannot be interrupted in the middle of an active inference safely; cancellation copy must match the true boundary.
6. macOS 26 visual APIs must not compromise the macOS 14 baseline.
7. Existing tests mostly cover Python logic; native/hardware/visual assertions added by this work are necessary, and a build alone does not replace them.
8. This plan was written against an actively modified working tree. Re-read source before applying a card and preserve newer user work.

### 17.4 Copy deck for consistent implementation

| Situation | Preferred copy |
| --- | --- |
| Welcome | “Your words. Your pace.” |
| Empty library | “Open a PDF or photo to begin.” |
| Cached open | “Opening ‘{title}’…” |
| Saved text loading | “Loading saved text…” |
| Page render | “Preparing page {page}…” |
| Initial scan work | “Preparing pages…” |
| Physical OCR progress | “Recovering page {page} of {total}…” |
| Vision first use | “Preparing Apple's text reader. The first use can take longer.” |
| Weight load | “Loading handwriting model…” |
| TTS before start | “Preparing voice…” |
| TTS unusually slow | “This voice is taking longer to start. You can stop or choose another voice.” |
| ASR warm-up, no capture | “Preparing voice following. Microphone is off.” |
| Starting capture | “Starting microphone…” |
| Active capture | “Listening” / “Following your voice” |
| No alignment | “Can't find your place—click a word to continue.” |
| Pending frontier | “Waiting for page {page}…” |
| Detached viewport | “Return to reading” |
| Model installed | “Installed on this Mac” |
| Model download error | “Couldn't finish the download. Your documents are unchanged.” plus the actionable reason. |
| Backend disconnected | “Reading engine disconnected. Your place is kept.” |
| Finished | “Finished reading. Your place is saved.” |
| Proof export | “Export word-box proof…” |
| Reprocess scope | “Reprocess document…” unless actual page-scoped processing exists. |

Copy is concise, but must remain truthful. For example, say “Your place is kept” only when a valid local/saved anchor really exists, and never say “saved” when persistence failed.

### 17.5 Pasteable task prompt for DeepSeek / GLM / another implementation agent

```text
Implement task Rxx from /Users/sharath/.opencode/plan/UI-style-remap.md.

Read section 2 (execution contract), section 13 (shared contracts), the Rxx task
card, and the design sections/files that card names. The plan is self-contained;
do not assume access to the conversation that produced it.

First check the current agent mode and git status. If this is still Plan mode,
do not implement: ask the user to switch agents. Preserve all existing user work.

Verify prerequisite cards in the actual code. If a required contract is missing,
report that blocker instead of inventing an incompatible substitute.

Make the smallest complete implementation of this card, including all affected
callers and focused regression checks. Keep the native UI/Python pipeline and
existing data/cache/position semantics. No fake progress, timer-driven reading,
silent error swallowing, surprise downloads, or microphone activation.

Do not delegate or spawn other agents unless the user separately authorizes it.
Do not run real model deletion/downloads or touch the user's live library for a
test. Use isolated fixtures. Run the relevant prescribed checks where possible.

Finish with changed files, checks actually run, acceptance evidence, unrun
physical/visual checks, risks, and the next safe task. Do not claim the whole
redesign complete after implementing just one card.
```

### 17.6 Per-task handoff record

Record this in the agreed handoff location when the user authorizes plan/status updates; do not rewrite the user's existing TODO history to create a clean-looking ledger.

```text
Task: Rxx — title
Status: complete / partial / blocked
Baseline inspected: commit plus relevant uncommitted changes
Files changed:
Shared contracts adopted or deliberately adjusted:
Behavior delivered:
Checks actually run and results:
Visual / listening / microphone / gesture / VoiceOver checks:
Not run and why:
Data / compatibility considerations:
Known limitation or blocker:
Next safe task:
```

### 17.7 Initial planning-session verification record

- Source and existing screenshot/icon inspection: completed for the files described in section 3.
- Suggested palette's opaque sRGB contrast arithmetic: calculated; results listed in section 4.2.
- Planning-document checks: passed for 25 ordered task cards and their dependencies, required card fields, 49 unique acceptance cases, section links, code fences, and absence of placeholder sections.
- Fresh interactive app inspection, compilation, application automated tests, model downloads, microphone use, TTS listening, real gestures, VoiceOver, and packaging: **not run during planning**.
- Application/source/config changes: **none**. Only this requested planning document was created/updated.
- Implementation task status: **all planned, none implemented by this document**.
