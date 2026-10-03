# nib for Windows — design

Status: built and verified on x64; ARM64 built and tested in CI.

## Goal

Every nib feature on Windows (live lint underlines, the suggestion panel, AI
rewrite, dictation, practice takes, reading aloud, the control panel) as a
small native app with no runtime to install. macOS stays as it is.

## Shape

- **`core/`** — the shared C++20 core grows to hold the logic the Swift app had
  alone: suggestion filtering, edit planning, word diff, writing score, the LSP
  client for harper-ls, the llama-server rewrite client and model catalogue,
  presentation (fix cards, merge, placement), and all speech logic (Kokoro
  phonemizer and chunker, voice packs, whisper transcript cleaning, practice).
  Offsets are UTF-16 throughout, so they map directly onto both NSString and
  Win32 text. Swift tests were ported to Catch2 against the same goldens.
- **`core/src/platform/win`** — processes in a kill-on-close Job Object,
  WinHTTP, data paths under `%LOCALAPPDATA%\nib`, engine location.
- **`windows/`** — `nib.exe`, Win32 + Direct2D, linking the core statically
  with a static CRT:
  - `app/` orchestrator, tray, global hotkeys, settings, start-at-login, CLI.
  - `text/` UI Automation (TextPattern / ValuePattern) and `SendInput`
    write-back, so every fix is one Ctrl+Z.
  - `inline/` the watcher thread, underline overlay, fix card, badge and
    selection bar.
  - `ui/` layered Direct2D surfaces, the suggestion panel and control panel.
  - `speech/` WASAPI capture and playback and the three controllers.

## Engines

harper-ls 2.8.0 (LSP over stdio), llama-server (HTTP), whisper.cpp and ONNX
Runtime + espeak-ng loaded as DLLs at runtime — all fetched by
`Scripts/windows/fetch-engines.ps1` into `windows/vendor/<arch>/`, shipped under
`engines/` beside `nib.exe`. CPU builds only. See `docs/windows-engine-assets.md`.

## Hotkeys

Ctrl+Alt+Space panel, Ctrl+Alt+D dictate, Ctrl+Alt+P practice, Ctrl+Alt+N read
aloud, Ctrl+Alt+H stop. Re-registered after resume and unlock.

## Packaging

Per-user WiX v5 MSI into `%LOCALAPPDATA%\Programs\nib` (no elevation) and a
portable zip, built by `Scripts/windows/package.ps1`; winget manifests from
`Scripts/windows/winget.ps1`. CI builds and tests x64 and ARM64 on every push;
the release workflow attaches both installers to the macOS release.

## Known limits

Underlines need apps that report text bounds through UI Automation (otherwise a
badge and the panel); elevated apps are out of reach; no GPU backends; ARM64
has no dictation until whisper.cpp is built from source; installers unsigned.
