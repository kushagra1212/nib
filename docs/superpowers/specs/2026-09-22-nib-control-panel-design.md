# nib control panel — design

**Status:** agreed 2026-09-22.

## The problem

nib has no window. It is an `.accessory` app, so clicking it in Finder appears to do nothing,
and everything it can tell you is spread across twenty menu items. Reported from use:

> "I need a proper UI where I can check how I can load the model, what is working or not, how I
> can restart the three features, how I can debug it, how I can diagnose it — because sometimes
> nib also fails. Sometimes the microphone doesn't work, sometimes some other thing doesn't."

Most of the machinery already exists and is unreachable. `HealthWindow` shows all seven
features with state, reason, fix, a per-feature **Restart** and a **Restart nib** — behind a
menu item called *Status…* that a daily user had not found. `ModelSetupWindow` and
`VoiceSetupWindow` exist. Five probes exist. A log exists. None of it is discoverable, and the
one model with no UI at all — whisper — is the one whose absence looks exactly like "the
microphone doesn't work".

This is a consolidation and discoverability problem, not a missing-feature problem.

## Decisions

| Decision | Choice |
|---|---|
| Shape | one window, sidebar: Status · Models · Voices · Dictation Words · Diagnostics |
| Toolkit | AppKit, matching `HealthWindow` (`PillButton`, `Theme`, card layout) |
| Launch | opening nib opens the window; `applicationShouldHandleReopen` re-shows it |
| Dock | `.accessory` normally, `.regular` while the window is open |
| Health checks | passive on open; **Test** and **Fix** per feature, on demand |
| Models | all three kinds — rewrite, dictation, voice — in one section |
| Diagnostics | probes with inline output, live log toggle, **Copy report** |
| Menu | reduced to quick actions plus **Open nib… ⌘,** |

## Why passive by default

`Health.swift` already states the rule, and it stays:

> Every check here is passive: files on disk, permissions already granted, processes already
> running. Nothing is started to find out. Waking llama-server costs 2.7GB, and a health check
> that allocates is one that can cause the failure it was opened to explain.

So the window opens instantly and allocates nothing. **Test** is where the expensive, truthful
work happens, and only for the feature whose button was pressed.

## Sections

### Status

The seven `Feature` cases as cards, each showing state, what it means for the user, the reason
when broken, and the fix. Three buttons, of which the first two are new:

- **Test** — runs that feature's probe for real: opens the microphone, asks harper, loads the
  model. Reports what happened in the card.
- **Fix** — restarts the feature, then re-runs Test so the card says whether it worked rather
  than only that something was attempted.
- **Open setup** — unchanged, for anything needing a download.

**Restart nib** stays at the bottom.

### Models

One list across all three kinds, each row showing installed state, whether it is active, size
on disk, and Download / Switch / Remove.

| Kind | Today | Location |
|---|---|---|
| Rewrite | `ModelSetupWindow`, 461 lines | `~/Library/Application Support/nib/models/*.gguf` |
| Dictation | **nothing — a manual `curl` in the README** | `~/Library/Application Support/nib/speech/*.bin` |
| Voice | `VoiceSetupWindow`, 227 lines | `~/Library/Application Support/nib/voice/` |

The dictation row is the point of this section. A missing whisper model is silent: the menu
item is present, the hotkey fires, and nothing happens.

### Voices and Dictation Words

`VoiceSetupWindow` and the dictation vocabulary editor, moved into the window unchanged. No
behaviour change; they stop being separate top-level menu items.

### Diagnostics

- The five probes as buttons, output shown inline.
- A **live log** view with an on/off toggle.
- **Copy report** — one clipboard action carrying everything needed to describe a failure.

## What the report contains, and what it must never contain

nib's entire premise is that nothing leaves the machine. A diagnostic report is the one feature
that invites a user to paste its contents into a public issue, so its boundaries are part of
the design rather than an implementation detail.

**Included:** nib version and build date, macOS version and architecture, core ABI version,
per-feature `HealthState` and reason, installed models with sizes, permission flags
(Accessibility, Microphone), which hotkeys registered, memory footprint, recent log lines.

**Excluded:** document text, selections, clipboard contents, dictation transcripts, practice
transcripts, file paths outside nib's own directories.

`Log` already holds this line, and it is why the log is safe to include:

> No field text is written, only lengths and counts. This file records what someone typed into
> a password manager or a private channel otherwise.

Every `Log.write` call site is audited against that claim as part of the work, because the log
becoming one click from the clipboard raises the cost of an exception from "a line in a file
nobody reads" to "pasted into a GitHub issue".

## Two pieces of existing code that must change shape

**The probes are CLI-shaped.** Each returns `Int32` and prints to stdout —
`LiveProbe.run(seconds:engine:) async -> Int32`, `MarkerProbe.runFocused(delay:) -> Int32`,
`SpeechProbe.run(text:voice:play:) async -> Int32`. A window cannot show stdout. Each probe
gains a function returning its lines, and the existing CLI entry point becomes a thin caller
that prints them and maps to an exit code. Same output, two consumers, no duplicated logic.

**The log is decided at launch.** `Log.isEnabled` is a `let` read from `NIB_LOG`, so a toggle
cannot work without relaunching. It splits in two: a bounded in-memory ring buffer that is
always fed, and the file write that stays gated. The in-app view reads the buffer, so logging
can be turned on after the thing you wanted to see has already started going wrong — which is
the case that matters for an intermittent failure.

## Files

Created:

| File | Responsibility |
|---|---|
| `UI/ControlPanel/ControlPanelWindow.swift` | window, sidebar, section switching |
| `UI/ControlPanel/StatusSection.swift` | feature cards, Test / Fix |
| `UI/ControlPanel/ModelsSection.swift` | the three model kinds |
| `UI/ControlPanel/DiagnosticsSection.swift` | probes, log view, report |
| `Support/ModelInventory.swift` | one list across rewrite, dictation and voice |
| `Support/DiagnosticReport.swift` | builds the report text |
| `Support/LogBuffer.swift` | bounded ring buffer |
| `Support/ActivationPolicy.swift` | accessory ↔ regular |

Modified: `Log.swift` (tee to buffer, runtime flag), `AppDelegate.swift` (menu, open, reopen),
`HealthWindow.swift` (becomes `StatusSection`), each of the five probes (return lines),
`ModelSetupWindow.swift` and `VoiceSetupWindow.swift` (embeddable as sections rather than
standalone windows only).

## Menu afterwards

Status line · Check Selection · Underline As I Type · Dictate · Practice Take · Speak Selection
· Recent Dictation · Voice · **Open nib… ⌘,** · Start at Login · Quit nib.

Twenty items to eleven. Moving into the window: Voices…, Dictation Words…, Practice Takes…,
Status…, both Diagnose items, Accessibility Settings…, Licences…, the memory line, and the
"AI Rewrite: ready" line, which becomes a Status card like every other feature.

## Testing

`ModelInventory`, `DiagnosticReport` and `LogBuffer` are pure and get unit tests beside the
existing 705. Two of those tests earn their place beyond coverage:

- `DiagnosticReport` is asserted **not** to contain a sentinel string planted in a fake
  document, so the privacy boundary is enforced by the suite rather than by review.
- `LogBuffer` is asserted to bound its memory under sustained writes.

The window itself gets no tests, consistent with a codebase that has none for UI.

## Scope

Roughly 1,200–1,500 lines, split into two plans:

1. **Window shell, activation policy, Status section, menu reduction.** Ships the part you
   actually hit: nib becomes openable, and everything it knows is in one findable place with
   the Restart and Open setup buttons that already exist.
2. **Test and Fix, which means refactoring the five probes to return lines.** Split out of
   phase 1 deliberately: it is the largest single chunk in this design, and bundling it would
   mean phase 1 shipped nothing until all of it was done.
3. **Models, Voices, Dictation Words, Diagnostics.** Model management for whisper, and the
   report.

## Not doing

- Background monitoring with automatic repair. A restart loop against a genuinely broken engine
  is worse than a dead feature, and we have not measured how often these failures happen.
- Probing everything on open. It is the fastest way to make opening the panel cause the failure
  it was opened to explain.
- A SwiftUI rewrite of the existing windows. They work; they move.
