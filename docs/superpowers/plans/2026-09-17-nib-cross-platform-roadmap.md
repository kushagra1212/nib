# nib cross-platform roadmap

**Status:** agreed 2026-09-17. Supersedes nothing; nib v1.0.4 ships unchanged until Phase 1 lands.

**Goal:** one C++ core shared by a SwiftUI macOS app and a C# WPF Windows app, so every
feature nib has on macOS exists on Windows x64 and ARM64, behind an MSI installer, released
from the same tag.

---

## Why this shape

nib today is 17,122 lines of Swift. 8,006 of those are algorithmic — diffing, sentence
splitting, scoring, filtering, phonemising, tokenising, prompt building, engine plumbing —
and have no reason to be written twice. 8,645 are AppKit, SwiftUI and the macOS
Accessibility API, and cannot cross to Windows at all.

Measured, not assumed:

| Layer | LOC | Apple-framework files | Destination |
|---|---:|---|---|
| UI | 4,498 | all | stays SwiftUI; C# WPF counterpart written new |
| Inline | 2,821 | all | stays AppKit; Win32 layered-window counterpart written new |
| AX | 1,326 | all | stays; UI Automation counterpart written new |
| Lint | 1,882 | none | → C++ core |
| Rewrite | 1,100 | none | → C++ core |
| Speech | 2,591 | 2 of 18 (SpeechPlayer, SpeechController) | 16 files → C++ core |
| Dictation | 1,396 | 4 of 10 (AudioRecorder, AudioSamples, DictationController, DictationOverlay) | 6 files → C++ core |
| Practice | 614 | 1 of 5 (PracticeController) | 4 files → C++ core |
| Support | 423 | 1 of 3 (Footprint) | 2 files → C++ core |
| Tests | 6,979 | — | goldens captured first, then C++ Catch2 suites |

43 of the 50 logic files import nothing but Foundation.

## Decisions

| Decision | Choice |
|---|---|
| Core language | C++20, one `extern "C"` ABI serving both Swift and C# P/Invoke |
| Core boundary | compute **plus** process/HTTP plumbing and engine calls. Excludes audio hardware and UI |
| macOS UI | unchanged — SwiftUI/AppKit, rewired to call the core |
| Windows UI | C# .NET 9 + WPF, P/Invoke to `nibcore.dll`; inline overlay via Win32 layered window |
| Architectures | Windows x64 and ARM64. No 32-bit x86 — no inference engine ships it |
| Windows floor | Windows 10 22H2 (x64), Windows 11 (ARM64) |
| Migration | strangler, module by module, differential goldens captured from shipped Swift first |
| macOS releases | main stays shippable and taggable at every step |
| Repo | one repo, one tag builds DMG + both MSIs |
| Installer | WiX v5 MSI, per-user into `%LOCALAPPDATA%`, no admin prompt |
| Signing | unsigned initially, documented like the quarantine note. Azure Trusted Signing later |
| Distribution | GitHub release + winget manifest (the Homebrew-tap analogue) |
| Build host | Docker on macOS cross-compiles the core and the C# app. Windows CI runners test and package |
| Hotkeys (Windows) | Ctrl+Alt+Space panel, Ctrl+Alt+D dictation, Ctrl+Alt+P practice, Ctrl+Alt+N speak, Ctrl+Alt+H stop |
| Engine assets | bundled in the MSI (~140MB), mirroring the `.app`. Models remain a user download |

### Text offsets

The core speaks **UTF-16 code-unit offsets** everywhere. Not a detail — it is why the ABI
stays cheap. `NSRange`/`NSString` (56 uses across the logic layers) are UTF-16, LSP positions
are UTF-16, and C# `string` is UTF-16. Swift's grapheme-based `String.Index` never crosses
the boundary. Strings cross as `const uint16_t*` + length.

---

## What Docker on your Mac can and cannot do

Docker Desktop for Mac runs a Linux VM. It **cannot run Windows containers** — that needs a
Windows host. So:

- **Can:** cross-compile `nibcore.dll` for win-x64 and win-arm64 (llvm-mingw or clang-cl +
  `xwin`); `dotnet publish -r win-x64|win-arm64` for the WPF app; likely build the MSI (WiX v5
  is a dotnet tool — Phase 0 proves it).
- **Cannot:** execute any of it. No UI Automation, no WASAPI, no tray, no layered windows.
  Wine does not cover this.

Real Windows execution comes from GitHub Actions `windows-latest` (x64) and `windows-11-arm`
(ARM64) — free for public repos, and nib is public.

---

## Phases

Each phase ends with something shippable. Each gets its own bite-sized plan document.

### Phase 0 — toolchain and restructure
Prove the three assumptions that could invalidate everything, restructure the repo, stand up
CI across three runners, and migrate one tracer module end to end.
→ `2026-09-17-phase-0-toolchain-and-restructure.md`

**Exit:** `SentenceSplitter` lives in C++, macOS nib uses it and is green, `nibcore.dll` builds
for both Windows arches in Docker, CI runs on macos-14 + windows-latest + windows-11-arm.

### Phase 1 — core migration
Move the remaining 7,200 logic lines to C++, module by module, each against goldens captured
from the shipped Swift. Order is cheapest-and-most-depended-on first:
Lint pure (WordDiff, TextEdit/EditPlanner, SuggestionFilter, WritingScore, Suggestion,
PositionMapper, MessageFramer) → Lint plumbing (LSPClient, HarperEngine) → Rewrite
(RewriteEngine, ModelCatalog, ModelInstaller, ModelChecker) → Speech (16 files) →
Dictation logic (6 files) → Practice (4 files) → Support (Health, Footprint).

**Exit:** macOS nib passes its full suite with the logic in C++; Swift retains UI, AX, audio
I/O and controllers only. Taggable as v2.0.0 on macOS alone.

### Phase 2 — Windows shell
C# WPF app: tray icon, suggestion panel, model setup, voices, health, dictation words,
recent dictation, settings. UI Automation text layer. Global hotkeys. CLI parity
(`--lint`, `--rewrite`, `--speak`, `--speak-silent`, `--whisper-probe`, `--rehearse`,
`--model-bench`, `--bench`, `--ax-probe`, `--live-probe`, `--marker-probe`, `--help`).
MSI + winget.

**Exit:** Windows v1: harper linting, panel, selection rewrite, AI rewrite, tray, installer.
Shipped.

### Phase 3 — Windows inline underlines
Win32 layered click-through overlay, Direct2D squiggles, UIA text bounding rects, fix card,
selection bar, issue badge. The riskiest feature — see Risks.

**Exit:** Windows v2.

### Phase 4 — Windows speech
WASAPI capture and render behind the core's audio interface. Dictation, read-aloud, practice
take.

**Exit:** Windows v3 — feature parity with macOS.

---

## Risks, named

**Inline underlines may not reach parity.** macOS AX gives per-character bounds via
`AXBoundsForRange`. UIA's `TextPattern.GetBoundingRectangles` exists but is unimplemented or
wrong in many apps, and Chromium-based apps need `--force-renderer-accessibility` before they
expose anything. nib already has the fallback — the ⌥Space panel — so the failure mode is
"panel instead of underline", not "broken". Expect a smaller set of apps with underlines on
Windows than on macOS, and say so in the README rather than discovering it in an issue.

**ARM64 Windows engine assets are thinner than x64.** llama.cpp and onnxruntime publish
win-arm64. whisper.cpp and espeak-ng may need building from source for ARM64. Phase 0 audits
every one of the five and records what exists versus what must be built.

**WiX v5 on Linux is unverified.** Phase 0 Task 2 proves or disproves it. If it fails, MSI
packaging moves to the Windows CI runner — which costs nothing, since packaging happens in CI
anyway.

**WPF from Linux is unverified.** `EnableWindowsTargeting=true` should allow it. Phase 0
Task 3 proves it. If it fails, local Windows iteration is CI-only, which is slow but not
blocking.

**The C ABI will churn during Phase 1.** Keeping main shippable means the ABI grows
incrementally rather than being designed once. Mitigation: the ABI is versioned from the first
commit and the Swift and C# bindings are generated from one header, so a mismatch is a compile
error, not a crash.

**A behaviour no test asserts could change silently.** 47 of the 54 test files are
hand-written assertions, not goldens. This is exactly why goldens get captured from the
*shipped* binary before any module moves — see Phase 0 Task 6.

**Foundation is not a thin wrapper over ICU, and the gap is invisible until measured.**
Found in Phase 0, and recorded here because the same shape will recur for every Foundation API
the core replaces. Three layers of surprise in one function:

1. `enumerateSubstrings(.bySentences, .localized)` is ICU's sentence `BreakIterator` *plus*
   CLDR abbreviation exceptions. Raw ICU breaks after `"Dr."`; Foundation does not.
2. Those exceptions are missing from Homebrew's ICU 78 — every locale answers
   `U_USING_DEFAULT_WARNING` with no suppressions. Apple's ICU carries the data; a package
   manager's need not.
3. ICU's own fix for this, `FilteredBreakIteratorBuilder::suppressBreakAfter`, reports success
   for every entry and then only suppresses single-period abbreviations. `"e.g."`, `"i.e."`,
   `"a.m."`, `"U.S."` and `"Ph.D."` still break — precisely the ones that matter for prose.

The core therefore carries its own 62-entry exception list, derived by putting 266 candidates
through Foundation and recording which it declined to break after, and filters ICU's boundaries
itself. Verified by cross-checking all 266 against both implementations: identical.

The lesson for Phase 1: **do not assume a Foundation call maps onto its obvious C++ equivalent.**
Measure the current behaviour, record it, then match the recording.

---

## Not doing

- 32-bit x86. No engine ships it; a 2.5GB model cannot fit a 2GB address space.
- Linux. The core would permit it; nothing else is built for it.
- Replacing SwiftUI. macOS UI is good and stays.
- MSIX/Store. Sandboxing may restrict the UI Automation access nib depends on.
